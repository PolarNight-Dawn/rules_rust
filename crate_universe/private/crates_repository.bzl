"""`crates_repository` rule implementation"""

load(
    "//crate_universe/private:common_utils.bzl",
    "REPIN_ALLOWLIST_ENV_VAR",
    "REPIN_ENV_VARS",
    "cargo_environ",
    "execute",
    "get_rust_tools",
    "new_cargo_bazel_fn",
)
load(
    "//crate_universe/private:fastpath_resolver.bzl",
    "fastpath_resolve_and_render",
    "normalize_fastpath_workspace_manifest",
)
load(
    "//crate_universe/private:generate_utils.bzl",
    "CRATES_REPOSITORY_ENVIRON",
    "determine_repin",
    "execute_generator",
    "generate_config",
    "get_generator",
    "get_lockfiles",
)
load(
    "//crate_universe/private:splicing_utils.bzl",
    "create_splicing_manifest",
    "splice_workspace_manifest",
)
load("//crate_universe/private:urls.bzl", "CARGO_BAZEL_SHA256S", "CARGO_BAZEL_URLS")
load("//rust:defs.bzl", "rust_common")
load("//rust/platform:triple.bzl", "get_host_triple")

# A reduced subset of platform triples that cover a wide range of known users.
# The reduced set is intended to speed up the splciing step which has `O(N^2)`
# complexity for each platform triple added.
SUPPORTED_PLATFORM_TRIPLES = [
    "aarch64-apple-darwin",
    "aarch64-unknown-linux-gnu",
    "wasm32-unknown-unknown",
    "wasm32-wasip1",
    "x86_64-pc-windows-msvc",
    "x86_64-unknown-linux-gnu",
    "x86_64-unknown-nixos-gnu",
]

def _is_lockfile_fastpath(repository_ctx):
    return repository_ctx.attr.resolver_backend == "lockfile_fastpath"

def _repin_requested(repository_ctx):
    return _repin_value(repository_ctx) != None

def _repin_value(repository_ctx):
    for var in REPIN_ENV_VARS:
        if var not in repository_ctx.os.environ:
            continue

        value = repository_ctx.os.environ[var]
        if value.lower() in ["false", "no", "0", "off"]:
            continue

        if REPIN_ALLOWLIST_ENV_VAR in repository_ctx.os.environ:
            indices_to_repin = repository_ctx.os.environ[REPIN_ALLOWLIST_ENV_VAR].split(",")
            if repository_ctx.name not in indices_to_repin:
                continue

        return value

    return None

def _determine_repin_for_backend(repository_ctx, cargo_bazel_fn, lockfiles, config_path, splicing_manifest):
    if _is_lockfile_fastpath(repository_ctx):
        return _repin_requested(repository_ctx)

    return determine_repin(
        repository_ctx = repository_ctx,
        repository_name = repository_ctx.name,
        cargo_bazel_fn = cargo_bazel_fn,
        lockfile_path = lockfiles.bazel,
        config = config_path,
        splicing_manifest = splicing_manifest,
        repin_instructions = repository_ctx.attr.repin_instructions,
    )

def _should_use_legacy_repin_fallback(repository_ctx):
    return (
        repository_ctx.attr.packages or
        repository_ctx.attr.skip_cargo_lockfile_overwrite or
        repository_ctx.attr.strip_internal_dependencies_from_cargo_lockfile
    )

def _copy_file(repository_ctx, source, destination):
    if str(source) == str(destination):
        return

    execute(
        repository_ctx,
        args = [
            "/bin/sh",
            "-c",
            'mkdir -p "$(dirname "$2")" && cp "$1" "$2"',
            "sh",
            str(source),
            str(destination),
        ],
        quiet = True,
    )

def _cargo_update_args(repin_value):
    value = repin_value or "true"
    lowered = value.lower()

    if lowered in ["true", "1", "yes", "on", "workspace", "minimal"]:
        return ["update", "--workspace"]
    if lowered in ["full", "eager", "all"]:
        return ["update"]

    package, _, precise = value.partition("=")
    args = ["update", "--package", package]
    if precise:
        args.extend(["--precise", precise])
    return args

def _run_cargo(repository_ctx, cargo_path, rustc_path, manifest_path, args):
    manifest_dir = manifest_path.dirname
    execute(
        repository_ctx,
        args = [
            "/bin/sh",
            "-c",
            'cd "$1" && shift && exec "$@"',
            "sh",
            str(manifest_dir),
            str(cargo_path),
        ] + args + [
            "--manifest-path",
            str(manifest_path),
        ],
        env = {
            "CARGO": str(cargo_path),
            "RUSTC": str(rustc_path),
        } | cargo_environ(repository_ctx, isolated = repository_ctx.attr.isolated),
        quiet = repository_ctx.attr.quiet,
    )

def _run_cargo_fetch(repository_ctx, cargo_path, rustc_path, manifest_path):
    _run_cargo(
        repository_ctx = repository_ctx,
        cargo_path = cargo_path,
        rustc_path = rustc_path,
        manifest_path = manifest_path,
        args = ["fetch", "--verbose"],
    )

def _run_cargo_lock_update(repository_ctx, lockfiles, cargo_path, rustc_path, manifest_path):
    manifest_lockfile = manifest_path.dirname.get_child("Cargo.lock")

    repin_value = _repin_value(repository_ctx)
    if lockfiles.cargo.exists:
        _copy_file(
            repository_ctx = repository_ctx,
            source = lockfiles.cargo,
            destination = manifest_lockfile,
        )
        cargo_args = _cargo_update_args(repin_value)
    else:
        cargo_args = ["generate-lockfile"]

    _run_cargo(
        repository_ctx = repository_ctx,
        cargo_path = cargo_path,
        rustc_path = rustc_path,
        manifest_path = manifest_path,
        args = cargo_args,
    )
    _run_cargo_fetch(
        repository_ctx = repository_ctx,
        cargo_path = cargo_path,
        rustc_path = rustc_path,
        manifest_path = manifest_path,
    )
    _copy_file(
        repository_ctx = repository_ctx,
        source = manifest_lockfile,
        destination = lockfiles.cargo,
    )

def _new_cargo_bazel_context(repository_ctx, host_triple, cargo_path, rustc_path):
    generator, generator_sha256 = get_generator(repository_ctx, host_triple.str)
    config_path = generate_config(repository_ctx)
    cargo_bazel_fn = new_cargo_bazel_fn(
        repository_ctx = repository_ctx,
        cargo_bazel_path = generator,
        cargo_path = cargo_path,
        rustc_path = rustc_path,
        isolated = repository_ctx.attr.isolated,
        quiet = repository_ctx.attr.quiet,
    )
    splicing_manifest = create_splicing_manifest(repository_ctx)
    return struct(
        cargo_bazel_fn = cargo_bazel_fn,
        config_path = config_path,
        generator_sha256 = generator_sha256,
        splicing_manifest = splicing_manifest,
    )

def _watch_splice_outputs(repository_ctx, splice_outputs, nonhermetic_root_bazel_workspace_dir):
    for path_to_track in splice_outputs.extra_paths_to_track:
        # We can only watch paths in our workspace.
        if path_to_track.startswith(str(nonhermetic_root_bazel_workspace_dir)):
            repository_ctx.watch(path_to_track)

def _run_fastpath_repin_and_render(repository_ctx, host_triple, lockfiles, cargo_path, rustc_path):
    normalized_manifest = normalize_fastpath_workspace_manifest(
        repository_ctx = repository_ctx,
        cargo_path = cargo_path,
        rustc_path = rustc_path,
        locked = False,
        fail_on_unsupported = False,
    )
    if normalized_manifest == None:
        repository_ctx.report_progress("Repinning with legacy cargo_bazel fallback.")
        return _run_legacy_cargo_bazel_flow(
            repository_ctx = repository_ctx,
            host_triple = host_triple,
            lockfiles = lockfiles,
            cargo_path = cargo_path,
            rustc_path = rustc_path,
        )

    repository_ctx.report_progress("Updating Cargo.lock for lockfile fastpath.")
    _run_cargo_lock_update(
        repository_ctx = repository_ctx,
        lockfiles = lockfiles,
        cargo_path = cargo_path,
        rustc_path = rustc_path,
        manifest_path = normalized_manifest.manifest_path,
    )

    repository_ctx.report_progress("Resolving repinned crates via lockfile fastpath.")
    fastpath_resolve_and_render(
        repository_ctx = repository_ctx,
        cargo_path = cargo_path,
        cargo_lockfile_path = lockfiles.cargo,
        rustc_path = rustc_path,
    )

    return None

def _run_legacy_cargo_bazel_flow(repository_ctx, host_triple, lockfiles, cargo_path, rustc_path):
    cargo_bazel_context = _new_cargo_bazel_context(
        repository_ctx = repository_ctx,
        host_triple = host_triple,
        cargo_path = cargo_path,
        rustc_path = rustc_path,
    )

    # Determine whether or not to repin dependencies
    repin = _determine_repin_for_backend(
        repository_ctx = repository_ctx,
        cargo_bazel_fn = cargo_bazel_context.cargo_bazel_fn,
        lockfiles = lockfiles,
        config_path = cargo_bazel_context.config_path,
        splicing_manifest = cargo_bazel_context.splicing_manifest,
    )

    nonhermetic_root_bazel_workspace_dir = repository_ctx.workspace_root

    # If re-pinning is enabled, gather additional inputs for the generator
    kwargs = dict()
    if repin:
        repository_ctx.report_progress("Splicing Cargo workspace.")

        # Generate a top level Cargo workspace and manifest for use in generation
        splice_outputs = splice_workspace_manifest(
            repository_ctx = repository_ctx,
            cargo_bazel_fn = cargo_bazel_context.cargo_bazel_fn,
            cargo_lockfile = lockfiles.cargo,
            splicing_manifest = cargo_bazel_context.splicing_manifest,
            config_path = cargo_bazel_context.config_path,
            output_dir = repository_ctx.path("splicing-output"),
            skip_cargo_lockfile_overwrite = repository_ctx.attr.skip_cargo_lockfile_overwrite,
            nonhermetic_root_bazel_workspace_dir = nonhermetic_root_bazel_workspace_dir,
            repository_name = repository_ctx.name,
        )
        _watch_splice_outputs(
            repository_ctx = repository_ctx,
            splice_outputs = splice_outputs,
            nonhermetic_root_bazel_workspace_dir = nonhermetic_root_bazel_workspace_dir,
        )

        kwargs.update({
            "metadata": splice_outputs.metadata,
        })

    paths_to_track_file = repository_ctx.path("paths-to-track")
    warnings_output_file = repository_ctx.path("warnings-output-file")

    # Run the generator
    repository_ctx.report_progress("Generating crate BUILD files.")
    execute_generator(
        cargo_bazel_fn = cargo_bazel_context.cargo_bazel_fn,
        generator_label = repository_ctx.attr.generator,
        config = cargo_bazel_context.config_path,
        splicing_manifest = cargo_bazel_context.splicing_manifest,
        lockfile_path = lockfiles.bazel,
        cargo_lockfile_path = lockfiles.cargo,
        repository_dir = repository_ctx.path("."),
        nonhermetic_root_bazel_workspace_dir = nonhermetic_root_bazel_workspace_dir,
        paths_to_track_file = paths_to_track_file,
        warnings_output_file = warnings_output_file,
        skip_cargo_lockfile_overwrite = repository_ctx.attr.skip_cargo_lockfile_overwrite,
        strip_internal_dependencies_from_cargo_lockfile = repository_ctx.attr.strip_internal_dependencies_from_cargo_lockfile,
        # sysroot = tools.sysroot,
        **kwargs
    )

    paths_to_track = json.decode(repository_ctx.read(paths_to_track_file))
    for path in paths_to_track:
        repository_ctx.watch(path)

    warnings_output_file = json.decode(repository_ctx.read(warnings_output_file))
    for warning in warnings_output_file:
        # buildifier: disable=print
        print("WARN: {}".format(warning))

    return cargo_bazel_context.generator_sha256

def _crates_repository_impl(repository_ctx):
    # Determine the current host's platform triple
    host_triple = get_host_triple(repository_ctx)

    # Locate the lockfiles
    lockfiles = get_lockfiles(repository_ctx)

    # Watch lockfiles and manifests for changes.
    repository_ctx.watch(lockfiles.cargo)
    if lockfiles.bazel:
        repository_ctx.watch(lockfiles.bazel)
    for m in repository_ctx.attr.manifests:
        repository_ctx.watch(repository_ctx.path(m))

    # Locate Rust tools (cargo, rustc)
    tools = get_rust_tools(repository_ctx, host_triple)
    cargo_path = repository_ctx.path(tools.cargo)
    rustc_path = repository_ctx.path(tools.rustc)
    generator_sha256 = None
    if _is_lockfile_fastpath(repository_ctx):
        if not _repin_requested(repository_ctx):
            repository_ctx.report_progress("Resolving crates from Cargo.lock via lockfile fastpath.")
            fastpath_resolve_and_render(
                repository_ctx = repository_ctx,
                cargo_path = cargo_path,
                cargo_lockfile_path = lockfiles.cargo,
                rustc_path = rustc_path,
            )
        elif _should_use_legacy_repin_fallback(repository_ctx):
            repository_ctx.report_progress("Repinning with legacy cargo_bazel fallback.")
            generator_sha256 = _run_legacy_cargo_bazel_flow(
                repository_ctx = repository_ctx,
                host_triple = host_triple,
                lockfiles = lockfiles,
                cargo_path = cargo_path,
                rustc_path = rustc_path,
            )
        else:
            generator_sha256 = _run_fastpath_repin_and_render(
                repository_ctx = repository_ctx,
                host_triple = host_triple,
                lockfiles = lockfiles,
                cargo_path = cargo_path,
                rustc_path = rustc_path,
            )
    else:
        generator_sha256 = _run_legacy_cargo_bazel_flow(
            repository_ctx = repository_ctx,
            host_triple = host_triple,
            lockfiles = lockfiles,
            cargo_path = cargo_path,
            rustc_path = rustc_path,
        )

    # Determine the set of reproducible values
    attrs = {attr: getattr(repository_ctx.attr, attr) for attr in dir(repository_ctx.attr)}
    exclude = ["to_json", "to_proto"]
    for attr in list(attrs.keys()):
        if attr in exclude or attr.startswith("_"):
            attrs.pop(attr, None)

    # Note that this is only scoped to the current host platform. Users should
    # ensure they provide all the values necessary for the host environments
    # they support
    if generator_sha256:
        attrs.update({"generator_sha256s": generator_sha256})

    # Inform users that the repository rule can be made deterministic if they
    # add a label to a lockfile path specifically for Bazel.
    if not lockfiles.bazel and not _is_lockfile_fastpath(repository_ctx):
        attrs.update({"lockfile": repository_ctx.attr.cargo_lockfile.relative("cargo-bazel-lock.json")})

    return attrs

crates_repository = repository_rule(
    doc = """\
A rule for defining and downloading Rust dependencies (crates). This rule
handles all the same [workflows](#workflows) `crate_universe` rules do.

Environment Variables:

| variable | usage |
| --- | --- |
| `CARGO_BAZEL_GENERATOR_SHA256` | The sha256 checksum of the file located at `CARGO_BAZEL_GENERATOR_URL` |
| `CARGO_BAZEL_GENERATOR_URL` | The URL of a cargo-bazel binary. This variable takes precedence over attributes and can use `file://` for local paths |
| `CARGO_BAZEL_ISOLATED` | An authoritative flag as to whether or not the `CARGO_HOME` environment variable should be isolated from the host configuration |
| `CARGO_BAZEL_FASTPATH_PROFILE` | When set for `resolver_backend = "lockfile_fastpath"`, emit per-phase timings and write `_fastpath_profile.json` into the generated hub repository |
| `CARGO_BAZEL_REPIN` | An indicator that the dependencies represented by the rule should be regenerated. `REPIN` may also be used. See [Repinning / Updating Dependencies](#repinning--updating-dependencies) for more details. |
| `CARGO_BAZEL_REPIN_ONLY` | A comma-delimited allowlist for rules to execute repinning. Can be useful if multiple instances of the repository rule are used in a Bazel workspace, but repinning should be limited to one of them. |
| `CARGO_BAZEL_TIMEOUT` | An integer value to override the default timeout setting when running the cargo-bazel binary. This value must be in seconds. |

Example:

Given the following workspace structure:

```text
[workspace]/
    WORKSPACE.bazel
    BUILD.bazel
    Cargo.toml
    Cargo.Bazel.lock
    src/
        main.rs
```

The following is something that'd be found in the `WORKSPACE` file:

```python
load("@rules_rust//crate_universe:defs.bzl", "crates_repository", "crate")

crates_repository(
    name = "crate_index",
    annotations = {
        "rand": [crate.annotation(
            default_features = False,
            features = ["small_rng"],
        )],
    },
    cargo_lockfile = "//:Cargo.Bazel.lock",
    lockfile = "//:cargo-bazel-lock.json",
    manifests = ["//:Cargo.toml"],
    # Should match the version represented by the currently registered `rust_toolchain`.
    rust_version = "1.60.0",
)
```

The above will create an external repository which contains aliases and macros for accessing
Rust targets found in the dependency graph defined by the given manifests.

**NOTE**: For the standard `cargo_bazel` backend, the `cargo_lockfile` and `lockfile` must be
manually created. The rule unfortunately does not yet create it on its own. When initially setting up
this rule, an empty file should be created and then populated by repinning dependencies. For
`resolver_backend = "lockfile_fastpath"`, `cargo_lockfile` is still required, but `lockfile` is
optional.

**EXPERIMENTAL**: Setting `resolver_backend = "lockfile_fastpath"` makes WORKSPACE usage behave
more like a lockfile-native fast path. The rule trusts the existing `Cargo.lock`, skips
`cargo-bazel query`, and uses a Cargo-native fastpath repin flow for explicit repins: Cargo
updates or generates `Cargo.lock`, then the lockfile fastpath consumes the updated lockfile for
rendering.
The optional `lockfile` attribute is still supported as a compatibility location for fastpath
facts; when omitted, facts are stored under `.cargo-bazel-fastpath-cache/facts`. A usable
`generator` or `generator_urls` configuration is only required when an unsupported repin
configuration falls back to the legacy `cargo_bazel` repin/generate flow.

### Repinning / Updating Dependencies

Dependency syncing and updating is done in the repository rule which means it's done during the
analysis phase of builds. As mentioned in the environments variable table above, the `CARGO_BAZEL_REPIN`
(or `REPIN`) environment variables can be used to force the rule to update dependencies and potentially
render a new lockfile. Given an instance of this repository rule named `crate_index`, the easiest way to
repin dependencies is to run:

```shell
CARGO_BAZEL_REPIN=1 bazel sync --only=crate_index
```

This will result in all dependencies being updated for a project. The `CARGO_BAZEL_REPIN` environment variable
can also be used to customize how dependencies are updated. The following table shows translations from environment
variable values to the equivalent [cargo update](https://doc.rust-lang.org/cargo/commands/cargo-update.html) command
that is called behind the scenes to update dependencies.

| Value | Cargo command |
| --- | --- |
| Any of [`true`, `1`, `yes`, `on`, `workspace`] | `cargo update --workspace` |
| Any of [`full`, `eager`, `all`] | `cargo update` |
| `package_name` | `cargo update --package package_name` |
| `package_name@1.2.3` | `cargo update --package package_name@1.2.3` |
| `package_name@1.2.3=4.5.6` | `cargo update --package package_name@1.2.3 --precise 4.5.6` |

If the `crates_repository` is used multiple times in the same Bazel workspace (e.g. for multiple independent
Rust workspaces), it may additionally be useful to use the `CARGO_BAZEL_REPIN_ONLY` environment variable, which
limits execution of the repinning to one or multiple instances of the `crates_repository` rule via a comma-delimited
allowlist:

```shell
CARGO_BAZEL_REPIN=1 CARGO_BAZEL_REPIN_ONLY=crate_index bazel sync --only=crate_index
```

""",
    implementation = _crates_repository_impl,
    attrs = {
        "annotations": attr.string_list_dict(
            doc = "Extra settings to apply to crates. See [crate.annotation](#crateannotation).",
        ),
        "cargo_config": attr.label(
            doc = "A [Cargo configuration](https://doc.rust-lang.org/cargo/reference/config.html) file",
        ),
        "cargo_lockfile": attr.label(
            doc = (
                "The path used to store the `crates_repository` specific " +
                "[Cargo.lock](https://doc.rust-lang.org/cargo/guide/cargo-toml-vs-cargo-lock.html) file. " +
                "In the case that your `crates_repository` corresponds directly with an existing " +
                "`Cargo.toml` file which has a paired `Cargo.lock` file, that `Cargo.lock` file " +
                "should be used here, which will keep the versions used by cargo and bazel in sync."
            ),
            mandatory = True,
        ),
        "compressed_windows_toolchain_names": attr.bool(
            doc = "Whether or not the toolchain names of windows toolchains are expected to be in a `compressed` format.",
            default = True,
        ),
        "generate_binaries": attr.bool(
            doc = (
                "Whether to generate `rust_binary` targets for all the binary crates in every package. " +
                "By default only the `rust_library` targets are generated."
            ),
            default = False,
        ),
        "generate_build_scripts": attr.bool(
            doc = (
                "Whether or not to generate " +
                "[cargo build scripts](https://doc.rust-lang.org/cargo/reference/build-scripts.html) by default."
            ),
            default = True,
        ),
        "generate_target_compatible_with": attr.bool(
            doc = "DEPRECATED: Moved to `render_config`.",
            default = True,
        ),
        "generator": attr.string(
            doc = (
                "The absolute label of a generator. Eg. `@cargo_bazel_bootstrap//:cargo-bazel`. " +
                "This is typically used when bootstrapping"
            ),
        ),
        "generator_sha256s": attr.string_dict(
            doc = "Dictionary of `host_triple` -> `sha256` for a `cargo-bazel` binary.",
            default = CARGO_BAZEL_SHA256S,
        ),
        "generator_urls": attr.string_dict(
            doc = (
                "URL template from which to download the `cargo-bazel` binary. `{host_triple}` and will be " +
                "filled in according to the host platform."
            ),
            default = CARGO_BAZEL_URLS,
        ),
        "isolated": attr.bool(
            doc = (
                "If true, `CARGO_HOME` will be overwritten to a directory within the generated repository in " +
                "order to prevent other uses of Cargo from impacting having any effect on the generated targets " +
                "produced by this rule. For users who either have multiple `crate_repository` definitions in a " +
                "WORKSPACE or rapidly re-pin dependencies, setting this to false may improve build times. This " +
                "variable is also controlled by `CARGO_BAZEL_ISOLATED` environment variable."
            ),
            default = True,
        ),
        "lockfile": attr.label(
            doc = (
                "The path to a file to use for reproducible renderings. " +
                "If set, this file must exist within the workspace (but can be empty) before this rule will work." +
                "If you already have a `MODULE.bazel.lock` file, you don't need this." +
                "If you don't have a `MODULE.bazel.lock` file, the `lockfile` will save you generation time."
            ),
        ),
        "manifests": attr.label_list(
            doc = "A list of Cargo manifests (`Cargo.toml` files).",
        ),
        "packages": attr.string_dict(
            doc = "A set of crates (packages) specifications to depend on. See [crate.spec](#crate.spec).",
        ),
        "quiet": attr.bool(
            doc = "If stdout and stderr should not be printed to the terminal.",
            default = True,
        ),
        "render_config": attr.string(
            doc = (
                "The configuration flags to use for rendering. Use `//crate_universe:defs.bzl\\%render_config` to " +
                "generate the value for this field. If unset, the defaults defined there will be used."
            ),
        ),
        "resolver_backend": attr.string(
            doc = (
                "Selects how dependency metadata is refreshed before rendering. " +
                "`cargo_bazel` preserves the existing query/splice/generate workflow. " +
                "`lockfile_fastpath` is an experimental WORKSPACE fast path that trusts the existing " +
                "`Cargo.lock`, skips `cargo-bazel query`, and uses a Cargo-native fastpath flow " +
                "when repinning is explicitly requested. The `lockfile` attribute is optional " +
                "for this backend. `generator` or `generator_urls` is only required when an " +
                "unsupported repin configuration falls back to the legacy `cargo_bazel` generate flow."
            ),
            default = "cargo_bazel",
            values = [
                "cargo_bazel",
                "lockfile_fastpath",
            ],
        ),
        "repin_instructions": attr.string(
            doc = "Instructions to re-pin the repository if required. Many people have wrapper scripts for keeping dependencies up to date, and would like to point users to that instead of the default.",
        ),
        "rust_toolchain_cargo_template": attr.string(
            doc = (
                "The template to use for finding the host `cargo` binary. `{version}` (eg. '1.53.0'), " +
                "`{triple}` (eg. 'x86_64-unknown-linux-gnu'), `{arch}` (eg. 'aarch64'), `{vendor}` (eg. 'unknown'), " +
                "`{system}` (eg. 'darwin'), `{cfg}` (eg. 'exec'), `{channel}` (eg. 'stable'), and `{tool}` (eg. " +
                "'rustc.exe') will be replaced in the string if present."
            ),
            default = "@rust_{system}_{arch}__{triple}__{channel}_tools//:bin/{tool}",
        ),
        "rust_toolchain_rustc_template": attr.string(
            doc = (
                "The template to use for finding the host `rustc` binary. `{version}` (eg. '1.53.0'), " +
                "`{triple}` (eg. 'x86_64-unknown-linux-gnu'), `{arch}` (eg. 'aarch64'), `{vendor}` (eg. 'unknown'), " +
                "`{system}` (eg. 'darwin'), `{cfg}` (eg. 'exec'), `{channel}` (eg. 'stable'), and `{tool}` (eg. " +
                "'cargo.exe') will be replaced in the string if present."
            ),
            default = "@rust_{system}_{arch}__{triple}__{channel}_tools//:bin/{tool}",
        ),
        "rust_version": attr.string(
            doc = "The version of Rust the currently registered toolchain is using. Eg. `1.56.0`, or `nightly/2021-09-08`",
            default = rust_common.default_version,
        ),
        "skip_cargo_lockfile_overwrite": attr.bool(
            doc = (
                "Whether to skip writing the cargo lockfile back after resolving. " +
                "You may want to set this if your dependency versions are maintained externally through a non-trivial set-up. " +
                "But you probably don't want to set this."
            ),
            default = False,
        ),
        "splicing_config": attr.string(
            doc = (
                "The configuration flags to use for splicing Cargo manifests. Use `//crate_universe:defs.bzl\\%rsplicing_config` to " +
                "generate the value for this field. If unset, the defaults defined there will be used."
            ),
        ),
        "strip_internal_dependencies_from_cargo_lockfile": attr.bool(
            doc = (
                "Whether to strip internal dependencies from the cargo lockfile. " +
                "You may want to use this if you want to maintain a cargo lockfile for bazel only. " +
                "Bazel only requires external dependencies to be present in the lockfile. " +
                "By removing internal dependencies, the lockfile changes less frequently which reduces merge conflicts " +
                "in other lockfiles where the cargo lockfile's sha is stored."
            ),
            default = False,
        ),
        "supported_platform_triples": attr.string_list(
            doc = "A set of all platform triples to consider when generating dependencies.",
            default = SUPPORTED_PLATFORM_TRIPLES,
        ),
    },
    environ = CRATES_REPOSITORY_ENVIRON,
)
