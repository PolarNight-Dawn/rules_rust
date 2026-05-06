# WORKSPACE Lockfile Fastpath

[中文版本](./lockfile_fastpath_workspace_zh.md)

`resolver_backend = "lockfile_fastpath"` is an experimental
`crates_repository` backend for WORKSPACE users. It makes the dependency flow
lockfile-first: normal syncs trust the checked-in `Cargo.lock`, avoid the full
`cargo-bazel query + splice + generate` pipeline, and render external crates
through a lightweight hub/spoke layout.

Explicit repins stay on the fastpath when the configuration is supported:
Cargo updates or generates `Cargo.lock`, then the fastpath resolver consumes
the updated lockfile and renders the repository. Configurations that still
require legacy `cargo_bazel` generate semantics fall back to the legacy path.

## Document Map

- [Status](./lockfile_fastpath_workspace_status_en.md): current stage,
  completed work, scope boundaries, test coverage, and recorded benchmark
  results.
- [Migration guide](./lockfile_fastpath_workspace_guide_en.md): how to enable,
  validate, roll back, and carry the backend in a fork.

## Scope And Boundaries

The fastpath backend is designed for WORKSPACE manifest + Cargo.lock flows.

Supported input shapes:

- one workspace-root manifest in `manifests`
- multiple manifests only when every listed manifest belongs to the same Cargo
  workspace
- checked-in `Cargo.lock`
- registry crates from sparse registry metadata
- targeted metadata fallback for `git` and `path` crates
- supported `CARGO_BAZEL_REPIN=1` requests through Cargo-native repin fastpath

Out of scope for this fastpath:

- Multiple independent Cargo workspaces are not supported inside one
  `crates_repository.manifests` list.
  Reason: one repository rule should represent one Cargo workspace root and
  one lockfile.
- Native fastpath handling for the `packages` attribute is not implemented.
  Reason: `packages` uses a different selection/generate model.
- Repin configurations that depend on
  `skip_cargo_lockfile_overwrite` or
  `strip_internal_dependencies_from_cargo_lockfile` are not fastpathed.
  Reason: those options carry legacy lockfile/write-back semantics.

Unsupported repin configurations use the legacy `cargo_bazel` fallback rather
than silently changing behavior.

## Runtime Model

The generated repository is split into a hub and crate-local spoke
repositories.

Hub repository responsibilities:

- run `cargo metadata --no-deps`, or reuse validated workspace metadata facts
- parse `Cargo.lock`
- fetch sparse registry rows for uncached registry crates
- resolve features and target-specific dependency edges
- prepare metadata for spoke repositories
- write `BUILD.bazel`, `data.bzl`, `defs.bzl`, and `crates.bzl`

Spoke repository responsibilities:

- materialize one crate source
- parse that crate's local `Cargo.toml`
- probe local source files
- render that crate's `BUILD.bazel`

This mirrors the important `rules_rs` performance idea while staying inside the
WORKSPACE repository-rule model: cache expensive facts, keep the hub focused on
resolution, and move crate-local BUILD rendering into spoke repositories.

## Persistent Cache

The fastpath keeps advisory caches in the workspace root.

`.cargo-bazel-fastpath-cache/facts/<repo>.json`

- `registry_entries`: sparse index rows reduced to resolver inputs
- `registry_inspection`: manifest subset and source-tree probes used before
  spoke rendering
- `workspace_metadata`: validated `cargo metadata --no-deps` results for
  same-Cargo-workspace manifest normalization

`.cargo-bazel-fastpath-cache/archives`

- downloaded registry crate archives
- reusable across Bazel output roots

If `lockfile = "//:..."` is explicitly configured, fastpath facts continue to
be stored there for compatibility. The `lockfile` attribute is not required for
new fastpath users.

## Fallback Rules

The caches are advisory and safe to delete.

- Missing or malformed facts are ignored and recomputed.
- Missing registry entry or inspection facts are recomputed per crate.
- Missing archives are downloaded again.
- Changed local `path` or `git` crates are re-read from Cargo metadata and the
  source tree.
- Changed `Cargo.lock`, workspace-root manifest, or recorded workspace member
  manifests invalidate the workspace metadata cache and rerun
  `cargo metadata --no-deps`.
- Supported repins update or generate `Cargo.lock` with Cargo and return to
  fastpath rendering.
- Unsupported repin configurations fall back to legacy `cargo_bazel`
  repin/generate.

## Profiling

Set `CARGO_BAZEL_FASTPATH_PROFILE=1` to write `_fastpath_profile.json` into the
generated hub repository.

Important phases:

| phase | purpose |
| --- | --- |
| `cargo_metadata_no_deps` | Load workspace package metadata without expanding third-party deps, or reuse validated workspace metadata facts |
| `cargo_metadata_full` | Optional fallback metadata for `git`/`path` crates when lockfile data is insufficient |
| `parse_lockfile_and_platforms` | Parse `Cargo.lock` and compute platform cfg data |
| `classify_lock_packages` | Split workspace, registry, and local source packages |
| `download_registry_templates` | Read sparse registry `config.json` download templates |
| `download_registry_metadata` | Populate sparse registry facts, ideally from cache |
| `prepare_resolver_inputs` | Normalize metadata into solver inputs |
| `resolve_dependency_targets` | Apply target-specific dependency cfgs |
| `solve_features` | Run the feature/dependency fixpoint solver |
| `inspect_external_crates` | Prepare manifest and source-tree facts, ideally from cache |
| `prepare_spoke_render_metadata` | Prepare per-crate spoke render metadata |
| `render_hub_repo_metadata` | Render hub repository content in memory |
| `write_root_build_bazel` | Write hub `BUILD.bazel` |
| `write_data_bzl` | Write `data.bzl` |
| `write_defs_bzl` | Write `defs.bzl` and `crates.bzl` |

## Validation And Benchmarks

Use the migration guide for commands. The current coverage is organized as:

- `examples/fastpath_smoke`: minimal WORKSPACE smoke test
- `examples/fastpath_regression`: correctness regression for registry,
  `path`, `git`, build scripts, proc macros, annotations, render config, and
  fastpath boundary behavior
- `examples/fastpath_ripgrep/benchmark.sh`: resolver/sync benchmark and warm
  profile
- `examples/fastpath_ripgrep/project_e2e.sh`: project end-to-end
  query/build/run/test correctness plus steady-state cold/hot and first-gen
  repin performance

Latest recorded results are kept in the status document.
