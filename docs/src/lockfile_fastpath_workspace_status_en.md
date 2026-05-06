# WORKSPACE Lockfile Fastpath Status

[中文版本](./lockfile_fastpath_workspace_status_zh.md)

This document summarizes the current state of the experimental
`resolver_backend = "lockfile_fastpath"` backend for WORKSPACE users.

It answers two questions:

1. How closely does the WORKSPACE fastpath align with the optimization strategy
   used by `rules_rs`?
2. Does the current test and profiling coverage cover the basics well enough to
   trust the backend for continued development and migration work?

## 1. Alignment With `rules_rs`

### Already aligned

The WORKSPACE fastpath now matches the main `rules_rs` performance strategy in
the areas that matter most for steady-state and first-generation syncs.

- `lockfile-first` resolution: normal WORKSPACE syncs no longer go through the
  full `cargo-bazel query + splice + generate` pipeline.
- repin fastpath: explicit `CARGO_BAZEL_REPIN=1` updates or generates
  `Cargo.lock` directly through Cargo, then returns to fastpath resolution and
  rendering.
- persistent resolver facts: fastpath facts are stored in
  `.cargo-bazel-fastpath-cache/facts/<repo>.json` by default, or in an explicit
  `lockfile` when one is configured for compatibility, and reused across Bazel
  output roots.
- persistent archive cache: registry crate archives are reused from
  `.cargo-bazel-fastpath-cache/archives`.
- hub/spoke split: the hub repository resolves dependency metadata, while the
  spoke repository renders each crate's `BUILD.bazel` locally.
- sparse-index-driven registry resolution: registry crates are resolved from
  `Cargo.lock` plus sparse index metadata, with targeted fallbacks for `git`
  and `path` crates.
- phase-level profiling: the backend emits per-phase timing data that is good
  enough to track regressions and guide follow-up optimization work.

### Not fully aligned yet

Some parts of the original `rules_rs` implementation model are still not
reproduced one-for-one in WORKSPACE mode.

- no `module extension` facts API: WORKSPACE uses sidecar caches, or an
  explicit compatibility `lockfile`, instead of `mctx.facts`.
- no extension-level async downloader orchestration: repository rules now
  prefetch sparse index rows and registry archives with non-blocking
  `repository_ctx.download`, but this is still repository-rule-local rather
  than a shared module-extension downloader.
- `cargo metadata --no-deps` is still the safety fallback for workspace
  metadata, but warm syncs can now reuse the validated `workspace_metadata`
  facts cache when `Cargo.lock` and recorded workspace manifests are unchanged.
- the hub still performs a small amount of up-front classification work for
  aliases, proc-macro handling, and build-script handling.
- `git` and `path` crates still rely on targeted `cargo metadata` fallback more
  than `rules_rs` does.
- repin configurations that depend on `skip_cargo_lockfile_overwrite` or
  `strip_internal_dependencies_from_cargo_lockfile` still use the legacy
  `cargo_bazel` repin/generate fallback.

### Is more alignment still necessary?

Given the current results, more alignment is not required for now if the
priority is safety, predictability, and maintainability.

The current backend already reaches the expected benefit range:

- steady-state cold sync: `2.895x` faster than the baseline harness
- steady-state hot sync: `5.002x` faster
- first-generation repin benchmark: `2.261x` faster
- project end-to-end steady-state cold build: `1.510x` faster real time on
  the local Bazelized ripgrep comparison
- project end-to-end hot no-change builds are effectively flat, while
  first-generation `CARGO_BAZEL_REPIN=1` sync plus build is `1.438x` faster in
  the latest full run

Under that constraint, the remaining gaps should be treated as optional, not
mandatory.

Recommended position:

- keep the current design as the default direction for WORKSPACE
- prefer hardening and documentation over another round of aggressive
  optimization
- only revisit deeper alignment if a new bottleneck appears in real repos

### Current optimization posture

The latest round already removed the main unnecessary `cargo metadata
--no-deps` rerun on warm same-Cargo-workspace manifest normalization paths by
adding validated `workspace_metadata` facts. Hub-side inspection is also kept
small: crate-local probing remains in spoke repositories, while the hub keeps
only the facts needed for aliases, proc-macro handling, build scripts, and
links.

The current repository-rule-local download prefetching is enough for this
stage. A larger shared downloader model is still possible later, but it carries
the highest stability risk and is not necessary to justify the backend anymore.

## 2. Test And Profiling Coverage

### Correctness regression coverage

The current regression surface covers the expected basics.

`examples/fastpath_smoke`

- minimal WORKSPACE smoke example
- validates `resolver_backend = "lockfile_fastpath"` end to end
- covers a `path` crate and a simple annotation

`examples/fastpath_regression`

- broader regression-oriented WORKSPACE example
- covers:
  - registry crates
  - `path` crates
  - `git` crates
  - `build.rs`
  - proc-macro crates
  - `override_targets`
  - `additive_build_file`
  - `build_script_link_deps`
  - `extra_aliased_targets`
  - rendered annotation coverage for `compile_data_glob`,
    `compile_data_glob_excludes`, `data_glob`, `build_script_data_glob`,
    `build_script_exec_properties`
  - `render_config(generate_cargo_toml_env_vars = False, generate_target_compatible_with = False)`

Current local status:

- `examples/fastpath_regression/validate.sh`: passing

### Resolver/sync benchmark

The resolver/sync benchmark is covered by `examples/fastpath_ripgrep/benchmark.sh`.
It measures dependency resolution and repository generation behavior in an
isolated generated WORKSPACE harness.

The harness compares two separate generated WORKSPACE roots:

- fastpath backend
- baseline `cargo_bazel` backend

This prevents cross-loading and makes the A/B numbers meaningful.

Current benchmark summary produced by `examples/fastpath_ripgrep/benchmark.sh benchmark`
using `RIPGREP_DIR=/Users/dengjiahong/repo/ripgrep`:

- steady-state cold
  - fastpath median: `24630ms`
  - cargo_bazel median: `71300ms`
  - speedup: `2.895x`
- steady-state hot
  - fastpath median: `10810ms`
  - cargo_bazel median: `54070ms`
  - speedup: `5.002x`
- first-generation repin
  - fastpath median: `31840ms`
  - cargo_bazel median: `71990ms`
  - speedup: `2.261x`

Current local status:

- `examples/fastpath_ripgrep/benchmark.sh validate`: passing
- `examples/fastpath_ripgrep/benchmark.sh profile`: passing
- `examples/fastpath_ripgrep/benchmark.sh benchmark`: passing
- `examples/fastpath_ripgrep/project_e2e.sh correctness`: passing
- `examples/fastpath_ripgrep/project_e2e.sh benchmark`: passing

### Project end-to-end benchmark

The project end-to-end benchmark is covered by
`examples/fastpath_ripgrep/project_e2e.sh`. It compares the checked-out local
projects directly:

- baseline: `/Users/dengjiahong/repo/ripgrep_baseline` with
  `/Users/dengjiahong/repo/rules_rust_baseline`
- fastpath: `/Users/dengjiahong/repo/ripgrep` with
  `/Users/dengjiahong/repo/rules_rust`

Both projects pass the same 10 ripgrep workspace manifests to
`crates_repository`; this is a same-Cargo-workspace manifest normalization
case. Fastpath verifies that every listed manifest belongs to the same Cargo
workspace, normalizes to that workspace root, and renders from the root
manifest. This benchmark does not claim support for multiple independent Cargo
workspaces in one `crates_repository.manifests` list.

Both sides were run with:

- `USE_BAZEL_VERSION=7.4.1`
- `--noenable_bzlmod --enable_workspace`
- stable Rust toolchain selected in `.bazelrc`
- Bazel output cache cleared before each build

Complete correctness coverage runs the following commands for both baseline and
fastpath:

- `bazel query //...`
- `bazel build //...`
- `bazel run //:rg -- --version`
- `bazel test //...`

That covers target completeness, full-project build behavior, binary execution,
test-suite behavior, and whether fastpath breaks a project that already builds
with the traditional `cargo_bazel` backend.

Complete performance coverage follows the resolver/sync benchmark shape:

- `steady_state cold`: keep dependency facts/lock/cache, clear the Bazel output
  cache, then time `bazel build //...`
- `steady_state hot`: keep the Bazel output cache warm and repeatedly time
  no-change `bazel build //...`
- `first_gen repin`: clear fastpath facts/archive cache or baseline lockfile
  generation state, run `CARGO_BAZEL_REPIN=1 bazel sync --only=crate_index`,
  then time `bazel build //...`

The script backs up and restores first-generation state around repin
measurements, including the fastpath `Cargo.lock` and fastpath cache, so the
local project checkouts are not left with regenerated lockfiles or caches.

Current recorded project benchmark result:

| metric | baseline | fastpath | delta |
| --- | ---: | ---: | ---: |
| steady-state cold build real time | `122.24s` | `80.95s` | `-41.29s` |
| steady-state hot build median | `2.68s` | `2.84s` | `+0.16s` |
| first-gen repin sync | `76.09s` | `38.93s` | `-37.16s` |
| first-gen repin build | `61.25s` | `56.55s` | `-4.70s` |
| first-gen repin sync plus build | `137.34s` | `95.48s` | `-41.86s` |

Interpretation: the project end-to-end cold win comes mostly from repository
resolution/loading. Both sides ultimately build the same project targets and
actions; hot no-change builds are effectively flat. First-generation repin now
uses Cargo-native fastpath rendering, so it no longer pays the cargo-bazel
generator/bootstrap cost on the supported fastpath path.

### Phase profiling coverage

The backend now exposes the expected phase breakdown.

Covered phases:

- `cargo_metadata_no_deps`
- `cargo_metadata_full`
- `download_registry_metadata`
- `inspect_external_crates`
- `write_root_build_bazel`
- `write_data_bzl`
- `write_defs_bzl`

That maps directly to the requested profiling categories:

- `cargo metadata --no-deps`: covered
- optional full metadata: covered
- sparse index download: covered
- crate manifest inspection: covered
- BUILD/data/defs rendering: covered and split by output file family

Recent warm-cache profile from
`examples/fastpath_ripgrep/benchmark.sh profile` showed:

- `total = 640.864ms`
- `cargo_metadata_no_deps = 25.089ms` with `cache_hit = True` and
  `input_manifests = 10`
- `download_registry_metadata = 28.293ms`
- `inspect_external_crates = 23.784ms`
- `write_root_build_bazel = 23.421ms`
- `write_data_bzl = 23.398ms`
- `write_defs_bzl = 17.972ms`

## Conclusion

The WORKSPACE fastpath is now aligned with the important `rules_rs`
optimization strategy at the level that matters in practice.

The remaining gaps are mostly implementation-shape differences or
higher-risk optimizations, not missing fundamentals. Correctness coverage,
benchmark coverage, and profiling coverage now all cover the expected basics.
