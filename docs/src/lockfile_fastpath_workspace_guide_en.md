# WORKSPACE Lockfile Fastpath Migration Guide

[中文版本](./lockfile_fastpath_workspace_guide_zh.md)

This guide is for two audiences:

- maintainers of a `rules_rust` fork who want to carry the WORKSPACE fastpath
  backend forward
- projects that want to consume that fork and migrate their WORKSPACE-based
  dependency flow to `resolver_backend = "lockfile_fastpath"`

## 1. What This Backend Changes

The WORKSPACE fastpath keeps the existing `crates_repository` API surface, but
changes how normal syncs are resolved.

Instead of always using the full `cargo-bazel query + splice + generate`
pipeline, the fastpath backend uses:

- `Cargo.lock`
- `cargo metadata --no-deps`
- sparse index metadata
- targeted fallbacks for `git` and `path` crates

The steady-state goal is to keep lockfiles authoritative and make normal
WORKSPACE syncs cheap.

## 2. Code Areas To Carry In A Fork

If another `rules_rust` fork wants this backend, the main implementation lives
in the following files:

- `crate_universe/private/crates_repository.bzl`: backend selection, fastpath
  repin orchestration, and legacy fallback wiring.
- `crate_universe/private/fastpath_resolver.bzl`: lockfile-native resolution,
  same-Cargo-workspace manifest normalization, validated workspace metadata
  caching, sparse registry facts, feature solving inputs, and hub rendering.
- `crate_universe/private/fastpath_repo.bzl`: spoke repository rule that
  materializes crate sources and delegates local BUILD rendering.
- `crate_universe/private/fastpath_spoke_render.bzl`: crate-local BUILD
  rendering for libraries, binaries, build scripts, annotations, and render
  config knobs.
- `crate_universe/private/fastpath_cfg_parser.bzl`: target `cfg(...)`
  parsing used for platform-specific dependencies.
- `crate_universe/private/fastpath_semver.bzl`: semver requirement matching
  used when resolving dependency versions from the lockfile graph.
- `crate_universe/private/fastpath_solver.bzl`: feature/dependency fixpoint
  solver.

Supporting updates also exist in:

- `crate_universe/private/common_utils.bzl`: shared execution/environment
  utilities reused by the fastpath flow.
- `crate_universe/private/generate_utils.bzl`: shared generator helpers kept
  for the legacy `cargo_bazel` path and unsupported fallback cases.

Examples and docs to carry with it:

- `examples/fastpath_smoke`
- `examples/fastpath_regression`
- `examples/fastpath_ripgrep`
- `docs/src/lockfile_fastpath_workspace.md`
- `docs/src/lockfile_fastpath_workspace_zh.md`
- `docs/src/lockfile_fastpath_workspace_status_en.md`
- `docs/src/lockfile_fastpath_workspace_status_zh.md`
- `docs/src/lockfile_fastpath_workspace_guide_en.md`
- `docs/src/lockfile_fastpath_workspace_guide_zh.md`

## 3. How To Enable It In A Project

In a WORKSPACE-based project, use `crates_repository` as usual and set:

```python
crates_repository(
    name = "crate_index",
    cargo_lockfile = "//:Cargo.lock",
    manifests = ["//:Cargo.toml"],
    resolver_backend = "lockfile_fastpath",
)
```

Required inputs:

- a checked-in `Cargo.lock`
- either one workspace-root manifest or multiple same-Cargo-workspace member
  manifests passed through `manifests`

The multi-manifest case is intentionally narrow. When multiple manifests are
listed, fastpath performs same-Cargo-workspace manifest normalization: it uses
`cargo metadata --no-deps` to verify that every listed manifest is a member of
one Cargo workspace, then renders from the normalized workspace root manifest.
This keeps compatibility with existing `cargo_bazel` projects that list every
member crate, without opening support for multiple independent Cargo workspaces
inside one `crates_repository.manifests` list.

Optional compatibility input:

- `lockfile = "//:cargo-bazel-lock-fastpath.json"` may still be set to keep
  storing fastpath facts in an existing Bazel lockfile-style cache

Important behavior:

- normal syncs use the fastpath backend
- `CARGO_BAZEL_REPIN=1` uses the repin fastpath by default: Cargo updates or
  generates `Cargo.lock`, then fastpath consumes the updated lockfile
- a cargo-bazel generator is not required for supported fastpath repins
- the legacy `cargo_bazel` repin/generate flow remains the fallback for
  configurations that still require cargo-bazel generate semantics

## 4. Expected Cache Files

After the first successful sync, the workspace will contain:

- `.cargo-bazel-fastpath-cache/facts/<repo>.json`
- `.cargo-bazel-fastpath-cache/archives/`

What they do:

- `.cargo-bazel-fastpath-cache/facts/<repo>.json`
  - stores fastpath facts
  - caches reduced sparse index entries, registry inspection facts, and
    validated workspace metadata for same-Cargo-workspace manifest
    normalization
- an explicit `lockfile = "//:..."` overrides this facts cache path for
  compatibility
- `.cargo-bazel-fastpath-cache/archives`
  - stores registry crate archives
  - allows reuse across Bazel output roots

Both caches are advisory. Deleting them is safe and only slows down the next
sync.

The workspace metadata cache is reused only when the recorded `Cargo.lock`,
workspace-root manifest, and recorded workspace member manifests still match
the current files. Otherwise fastpath reruns `cargo metadata --no-deps` and
rewrites the cache.

## 5. Migration Checklist For A Project Repo

1. Ensure the repo already has a stable WORKSPACE `crate_universe` flow.
2. Check in a `Cargo.lock` if it is not already tracked.
3. Set `resolver_backend = "lockfile_fastpath"` on the target
   `crates_repository`.
4. If the repository passes multiple manifests, keep that list limited to
   member manifests of one Cargo workspace. Use separate `crates_repository`
   instances for independent Cargo workspaces.
5. If the repository uses a repin configuration that still needs the legacy
   fallback, keep a usable cargo-bazel generator configured for that fallback.
6. Run:

```bash
bazel sync --only=<repo_name>
```

7. If needed, run a fastpath repin once. Supported repin requests update or
   generate `Cargo.lock` with Cargo and then render through fastpath; only
   unsupported repin configurations use the legacy `cargo_bazel` fallback.

```bash
CARGO_BAZEL_REPIN=1 bazel sync --only=<repo_name>
```

8. Commit:
   - the WORKSPACE changes
   - any intentionally checked-in fastpath facts cache, if the project wants a
     warm first sync in CI
   - any updated `Cargo.lock` content from the repin fastpath
   - any regenerated Bazel lockfile content if a legacy fallback repin was used

## 6. Migration Checklist For A Fork Maintainer

1. Bring over the fastpath implementation files.
2. Keep `crates_repository.bzl` wired so:
   - fastpath is used for normal syncs and supported repins when
     `resolver_backend` is `"lockfile_fastpath"`
   - explicit repin requests update or generate `Cargo.lock` through Cargo and
     then return to fastpath rendering
   - the legacy `cargo_bazel` repin/generate path remains available for
     unsupported repin configurations
3. Carry the examples and docs with the implementation.
4. Run the correctness regression suite.
5. Run the ripgrep benchmark harness before publishing the fork.

## 7. Validation Workflow

Recommended validation order:

### Minimal smoke

```bash
cd examples/fastpath_smoke
bazel sync --only=fastpath_smoke_index
bazel test //:smoke_test
```

### Correctness regression

```bash
cd examples/fastpath_regression
./validate.sh
```

### Fastpath profiling

```bash
cd examples/fastpath_ripgrep
./benchmark.sh prepare
./benchmark.sh profile
```

### Resolver/sync benchmark

```bash
cd examples/fastpath_ripgrep
./benchmark.sh validate
./benchmark.sh benchmark
```

### Project end-to-end correctness

For the local Bazelized ripgrep checkouts, run the compatibility checks against
both the baseline `cargo_bazel` setup and the fastpath setup:

```bash
cd examples/fastpath_ripgrep
./project_e2e.sh correctness
```

This covers:

- target completeness with `bazel query //...`
- full-project build behavior with `bazel build //...`
- binary execution with `bazel run //:rg -- --version`
- test-suite behavior with `bazel test //...`
- whether fastpath breaks a project that already builds with the traditional
  `cargo_bazel` backend

### Project end-to-end benchmark

For project-level timing, use:

```bash
cd examples/fastpath_ripgrep
./project_e2e.sh benchmark
```

It records:

- `steady_state cold`: keep dependency facts/lock/cache, clear the Bazel output
  cache, then time `bazel build //...`
- `steady_state hot`: keep the Bazel output cache warm and repeatedly time
  no-change `bazel build //...`
- `first_gen repin`: clear fastpath facts/archive cache or baseline lockfile
  generation state, run `CARGO_BAZEL_REPIN=1 bazel sync --only=crate_index`,
  then time `bazel build //...`

The script keeps the Bazel version and flags consistent across both sides and
writes Bazel profiles for measured build steps.

## 8. How To Read The Profile Output

Set:

```bash
CARGO_BAZEL_FASTPATH_PROFILE=1
```

The hub repository will emit `_fastpath_profile.json`.

The most important phases are:

- `cargo_metadata_no_deps`
- `cargo_metadata_full`
- `download_registry_metadata`
- `inspect_external_crates`
- `prepare_spoke_render_metadata`
- `render_hub_repo_metadata`
- `write_root_build_bazel`
- `write_data_bzl`
- `write_defs_bzl`

Interpretation tips:

- high `cargo_metadata_full` usually means `git` or `path` fallback work
- high `download_registry_metadata` means sparse facts are not warm yet
- high `inspect_external_crates` means registry inspection facts are not warm
- high `write_*` phases indicate hub rendering work, now split by file family

## 9. Rollback And Safety

If a migration needs to be rolled back:

1. remove `resolver_backend = "lockfile_fastpath"`
2. keep using the existing standard `cargo_bazel` flow
3. optionally delete:
   - `.cargo-bazel-fastpath-cache/facts/<repo>.json`
   - `.cargo-bazel-fastpath-cache/archives`

This rollback is straightforward because the fastpath caches are not the source
of truth for dependency selection.

## 10. Current Recommended Operating Mode

For most projects, the recommended operating mode is:

- use fastpath for normal WORKSPACE syncs
- use Cargo-native fastpath rendering when updating dependencies
- keep legacy repin/generate fallback available for unsupported repin modes
- keep the ripgrep harness or an equivalent real-repo benchmark available for
  regression checks

That gives the performance benefit without requiring riskier implementation
changes beyond the repository-rule-local prefetching already in place.
