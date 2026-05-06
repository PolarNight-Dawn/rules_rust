# WORKSPACE Lockfile Fastpath Status

[中文版本](./lockfile_fastpath_workspace_status_zh.md)

This document records the current stage of the experimental
`resolver_backend = "lockfile_fastpath"` backend. It is the status and decision
log for the WORKSPACE fastpath work.

For design details, see [the overview](./lockfile_fastpath_workspace.md). For
commands and migration steps, see
[the migration guide](./lockfile_fastpath_workspace_guide_en.md).

## Stage Conclusion

The current stage is complete.

The backend has moved from:

- `rules_rs`: lockfile-native
- `rules_rust` fastpath: lockfile-consume fast path + legacy repin fallback

to:

- `rules_rs`: lockfile-native
- `rules_rust` fastpath: lockfile-consume fast path + Cargo-native repin
  fastpath + legacy fallback for unsupported cases

The current implementation meets the stage goal: get clear WORKSPACE
performance wins while keeping compatibility stable.

## Completed Capabilities

Core backend:

- `crates_repository` supports `resolver_backend = "lockfile_fastpath"`.
- Normal syncs resolve and render through the lockfile fastpath.
- Supported `CARGO_BAZEL_REPIN=1` requests update or generate `Cargo.lock`
  through Cargo, then return to fastpath rendering.
- Unsupported repin configurations fall back to legacy `cargo_bazel`.
- The fastpath supports same-Cargo-workspace multi-manifest normalization.
- Warm same-Cargo-workspace syncs can reuse validated `workspace_metadata`
  facts and avoid unnecessary `cargo metadata --no-deps` reruns.
- Sparse registry facts, registry inspection facts, and crate archives are
  cached across Bazel output roots.
- Hub/spoke rendering keeps crate-local inspection and BUILD rendering in spoke
  repositories.
- Phase profiling is available through `CARGO_BAZEL_FASTPATH_PROFILE=1`.

Implementation files:

- `crate_universe/private/crates_repository.bzl`: backend selection, fastpath
  repin orchestration, and legacy fallback wiring
- `crate_universe/private/fastpath_resolver.bzl`: lockfile-native resolution,
  same-Cargo-workspace normalization, facts/cache handling, solver inputs, hub
  rendering, and profiling
- `crate_universe/private/fastpath_repo.bzl`: spoke repository rule
- `crate_universe/private/fastpath_spoke_render.bzl`: crate-local BUILD
  rendering
- `crate_universe/private/fastpath_cfg_parser.bzl`: target `cfg(...)` parsing
- `crate_universe/private/fastpath_semver.bzl`: semver requirement matching
- `crate_universe/private/fastpath_solver.bzl`: feature/dependency fixpoint
  solver
- `crate_universe/private/common_utils.bzl`: shared execution/environment
  helpers
- `crate_universe/private/generate_utils.bzl`: legacy generator helpers used by
  the standard backend and unsupported fallback cases

Examples and harnesses:

- `examples/fastpath_smoke`: minimal WORKSPACE smoke
- `examples/fastpath_regression`: correctness regression matrix
- `examples/fastpath_regression/validate_boundaries.sh`: focused boundary
  regression for workspace metadata cache hit/miss, same-workspace
  multi-manifest normalization, independent workspace rejection/fallback,
  supported repin fastpath, and legacy fallback
- `examples/fastpath_ripgrep/benchmark.sh`: resolver/sync benchmark and warm
  profile
- `examples/fastpath_ripgrep/project_e2e.sh`: project end-to-end correctness
  and performance benchmark

## Alignment With `rules_rs`

### Aligned In This Stage

- lockfile-first dependency resolution
- persistent resolver facts
- persistent archive cache
- sparse-index-driven registry metadata
- hub/spoke split
- Cargo-native fastpath repin for supported cases
- phase-level profiling

### WORKSPACE-Specific Implementation Choices

- WORKSPACE uses sidecar facts, or an explicit compatibility `lockfile`, rather
  than `mctx.facts`.
  Reason: WORKSPACE repository rules do not have the module-extension facts API.
- Downloads are repository-rule-local instead of coordinated through a shared
  module-extension downloader.
  Reason: the local prefetch model already produces the current wins and is
  less risky.
- `cargo metadata --no-deps` remains the authoritative fallback for workspace
  metadata.
  Reason: path/git crates, workspace members, and feature source information
  still need Cargo as the correctness fallback.
- The hub keeps minimal up-front facts for aliases, proc macros, build scripts,
  and `links`.
  Reason: those facts are needed to produce correct hub targets and aliases.

These are not unsupported features; they are implementation-shape differences
kept to make the fastpath fit WORKSPACE repository rules safely.

### Out Of Scope For This Stage

The following capabilities are not part of this stage's fastpath scope:

- Multiple independent Cargo workspaces are not supported inside one
  `crates_repository.manifests` list.
  Reason: one repository rule should represent one Cargo workspace root and
  one lockfile.
- Native fastpath support for the `packages` attribute is not implemented.
  Reason: that path uses a different selection/generate model, so legacy
  `cargo_bazel` remains safer.
- Full Bzlmod/module-extension parity is not implemented in this WORKSPACE
  backend.
  Reason: this stage targets the WORKSPACE compatibility path.
- Legacy `cargo_bazel` splice/generate is not deleted.
  Reason: the standard backend and unsupported repin fallback still need it.
- Repin configurations that depend on
  `skip_cargo_lockfile_overwrite` or
  `strip_internal_dependencies_from_cargo_lockfile` are not fastpathed.
  Reason: those options carry legacy lockfile/write-back semantics.

## Validation Coverage

Correctness coverage:

- `examples/fastpath_smoke`: minimal fastpath sync and test
- `examples/fastpath_regression/validate.sh`: registry, `path`, `git`,
  build script, proc macro, overrides, annotations, data/compile_data globs,
  render config coverage, and focused boundary checks through
  `validate_boundaries.sh`
- `examples/fastpath_regression/validate_boundaries.sh`: workspace metadata
  cache hit/miss, same-Cargo-workspace multi-manifest normalization,
  independent workspace rejection and repin fallback, supported repin fastpath
  without a generator, and legacy fallback for unsupported repin settings
- `examples/fastpath_ripgrep/project_e2e.sh correctness`: both baseline and
  fastpath run:
  - `bazel query //...`
  - `bazel build //...`
  - `bazel run //:rg -- --version`
  - `bazel test //...`

Performance coverage:

- `examples/fastpath_ripgrep/benchmark.sh benchmark`: resolver/sync
  steady-state cold, steady-state hot, and first-generation repin
- `examples/fastpath_ripgrep/project_e2e.sh benchmark`: project end-to-end
  steady-state cold, steady-state hot, and first-generation repin plus build
- `examples/fastpath_ripgrep/benchmark.sh profile`: warm-cache phase profile

Latest recorded local status:

- `examples/fastpath_regression/validate.sh`: passing
- `examples/fastpath_regression/validate_boundaries.sh`: passing
- `examples/fastpath_ripgrep/benchmark.sh validate`: passing
- `examples/fastpath_ripgrep/benchmark.sh profile`: passing
- `examples/fastpath_ripgrep/benchmark.sh benchmark`: passing
- `examples/fastpath_ripgrep/project_e2e.sh correctness`: passing
- `examples/fastpath_ripgrep/project_e2e.sh benchmark`: passing

## Recorded Results

Resolver/sync benchmark, using
`RIPGREP_DIR=/Users/dengjiahong/repo/ripgrep`:

| scenario | fastpath | cargo_bazel baseline | speedup |
| --- | ---: | ---: | ---: |
| steady-state cold sync | `24630ms` | `71300ms` | `2.895x` |
| steady-state hot sync | `10810ms` | `54070ms` | `5.002x` |
| first-generation repin | `31840ms` | `71990ms` | `2.261x` |

Project end-to-end benchmark:

- baseline: `/Users/dengjiahong/repo/ripgrep_baseline` with
  `/Users/dengjiahong/repo/rules_rust_baseline`
- fastpath: `/Users/dengjiahong/repo/ripgrep` with
  `/Users/dengjiahong/repo/rules_rust`
- both sides pass the same 10 same-Cargo-workspace ripgrep manifests
- `USE_BAZEL_VERSION=7.4.1`
- `--noenable_bzlmod --enable_workspace`
- stable Rust toolchain selected in `.bazelrc`

| metric | baseline | fastpath | delta |
| --- | ---: | ---: | ---: |
| steady-state cold `bazel build //...` real time | `122.24s` | `80.95s` | `-41.29s` |
| steady-state hot `bazel build //...` median | `2.68s` | `2.84s` | `+0.16s` |
| first-gen repin sync | `76.09s` | `38.93s` | `-37.16s` |
| first-gen repin build | `61.25s` | `56.55s` | `-4.70s` |
| first-gen repin sync plus build | `137.34s` | `95.48s` | `-41.86s` |

Interpretation:

- Resolver/sync wins are large because fastpath avoids the full
  `cargo-bazel query + splice + generate` path.
- Project cold build wins mostly come from repository resolution/loading.
- Hot no-change project builds are effectively flat because both sides build
  the same project targets and actions.
- First-generation repin is now faster on the supported fastpath path because
  it no longer pays the cargo-bazel generator/bootstrap cost.

Recent warm-cache profile:

- `total = 640.864ms`
- `cargo_metadata_no_deps = 25.089ms`, with `cache_hit = True` and
  `input_manifests = 10`
- `download_registry_metadata = 28.293ms`
- `inspect_external_crates = 23.784ms`
- `write_root_build_bazel = 23.421ms`
- `write_data_bzl = 23.398ms`
- `write_defs_bzl = 17.972ms`

## Next Phase

Recommended next target: PR-ready hardening and upstreaming preparation.

Concrete work:

- Decide which smoke/regression checks should run in CI, including the new
  focused boundary regression.
- Decide benchmark cadence for ripgrep resolver/sync and project end-to-end
  runs.
- Prepare the upstream PR description, migration notes, risk notes, and
  fallback explanation.
- Decide whether the current work should be split into review-friendly commits.
