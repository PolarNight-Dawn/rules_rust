# WORKSPACE Lockfile Fastpath

[中文版本](./lockfile_fastpath_workspace_zh.md)

The experimental `resolver_backend = "lockfile_fastpath"` backend makes the
WORKSPACE `crate_universe` flow behave more like a lockfile-native resolver.
Instead of always running the full `cargo-bazel query + splice + generate`
pipeline, it trusts the existing `Cargo.lock`, resolves the dependency graph
from lockfile metadata, and keeps explicit repins on the fastpath where
possible: Cargo updates or generates `Cargo.lock`, then fastpath consumes the
updated lockfile for rendering. Existing Bazel `lockfile` usage remains
supported as a compatibility location for facts, but it is no longer required.

## Further Reading

- [WORKSPACE lockfile fastpath status](./lockfile_fastpath_workspace_status_en.md)
- [WORKSPACE lockfile fastpath migration guide](./lockfile_fastpath_workspace_guide_en.md)
- [WORKSPACE lockfile fastpath 现状总结](./lockfile_fastpath_workspace_status_zh.md)
- [WORKSPACE lockfile fastpath 迁移手册](./lockfile_fastpath_workspace_guide_zh.md)

## Goals

The backend is optimized for the common WORKSPACE steady-state case:

- keep existing `Cargo.lock` authoritative
- avoid `cargo-bazel query` and workspace splicing on normal syncs
- persist expensive registry and manifest facts across Bazel output roots
- keep per-crate BUILD rendering in spoke repositories instead of front-loading
  that work in the hub repository

## Design

The fastpath backend is intentionally split into two layers.

`hub repository`

- runs `cargo metadata --no-deps`
- parses `Cargo.lock`
- downloads sparse index metadata for uncached registry crates
- resolves features and target-specific dependency edges
- prepares spoke render metadata
- writes the hub repository files: `BUILD.bazel`, `data.bzl`, `defs.bzl`,
  `crates.bzl`

`spoke repository`

- materializes the crate source
- parses the local `Cargo.toml`
- probes the local source tree
- renders that crate's `BUILD.bazel`

This mirrors the main `rules_rs` optimization strategy while staying compatible
with WORKSPACE repository rules: cache expensive facts, keep the hub focused on
resolution, and push crate-local BUILD rendering into spoke repositories.

## Persistent Caches

The WORKSPACE fastpath persists two cache layers in the workspace root.

`.cargo-bazel-fastpath-cache/facts/<repo>.json`

- stores fastpath `facts`
- currently includes:
  - `registry_entries`: sparse index rows reduced to resolver inputs
  - `registry_inspection`: manifest subset and source-tree probes used during
    spoke render preparation
  - `workspace_metadata`: validated `cargo metadata --no-deps` results for the
    same-Cargo-workspace manifest normalization path
- if `lockfile = "//:..."` is set explicitly, facts continue to be written
  there for compatibility with already-migrated WORKSPACE setups

`.cargo-bazel-fastpath-cache/archives`

- stores downloaded registry crate archives
- is shared across Bazel output bases
- avoids re-downloading crate tarballs on cold output roots

These caches are advisory. They speed up future syncs, but they are not the
source of truth for dependency selection.

## Cache Fallback Strategy

The fastpath backend is designed to fail safe.

- If the facts cache is missing, empty, malformed, or has an unexpected schema
  version, the backend ignores it and rebuilds the facts from authoritative
  inputs.
- If an individual `registry_entries` or `registry_inspection` fact is missing,
  that crate is recomputed and the cache is rewritten.
- If a cached crate archive is missing, the backend downloads it again and
  repopulates `.cargo-bazel-fastpath-cache/archives`.
- If a local `path` or `git` crate changes, fresh Cargo metadata and manifest
  reads are used during the next sync.
- If `manifests` contains multiple entries, fastpath treats this as
  same-Cargo-workspace manifest normalization: all listed manifests must be
  member manifests of one Cargo workspace, and fastpath renders from that
  normalized workspace root manifest. Multiple independent Cargo workspaces in
  one `crates_repository.manifests` list are not a supported fastpath shape.
- Cached workspace metadata is reused only when the recorded `Cargo.lock`, the
  workspace-root manifest, and every recorded workspace member manifest still
  match the current files. If any of those inputs changes, fastpath falls back
  to a fresh `cargo metadata --no-deps` run and rewrites the cache.
- If repinning is requested with `CARGO_BAZEL_REPIN=1`, WORKSPACE usage runs
  the repin fastpath by default: update or generate `Cargo.lock` directly with
  Cargo, fetch the selected crates, invalidate stale facts as needed, then
  render through fastpath again.
- The legacy `cargo_bazel` repin/generate flow remains the fallback for repin
  configurations that still require cargo-bazel generate semantics.

In practice this means the caches are always safe to delete. Deleting either
cache only slows down the next sync; it should not change correctness.

## Profiling

Set `CARGO_BAZEL_FASTPATH_PROFILE=1` to emit `_fastpath_profile.json` in the
generated hub repository.

The current phases are:

| phase | purpose |
| --- | --- |
| `cargo_metadata_no_deps` | Load workspace package metadata without third-party dependency expansion |
| `cargo_metadata_full` | Optional fallback metadata run for `git` and `path` crates when lockfile data alone is insufficient |
| `parse_lockfile_and_platforms` | Parse `Cargo.lock` and compute the platform set used by cfg resolution |
| `classify_lock_packages` | Partition workspace packages, registry packages, and local source packages |
| `download_registry_templates` | Read sparse registry `config.json` files to discover archive download templates |
| `download_registry_metadata` | Populate sparse index facts for registry crates, ideally from `registry_entries` cache |
| `prepare_resolver_inputs` | Normalize package metadata into solver inputs |
| `resolve_dependency_targets` | Expand target-specific dependency applicability |
| `solve_features` | Run the feature/dependency fixpoint solver |
| `inspect_external_crates` | Prepare manifest and source-tree inspection facts, ideally from `registry_inspection` cache |
| `prepare_spoke_render_metadata` | Build the metadata passed to each spoke repository for local BUILD rendering |
| `render_hub_repo_metadata` | Render in-memory hub repository content |
| `write_root_build_bazel` | Write the hub `BUILD.bazel` file |
| `write_data_bzl` | Write `data.bzl` |
| `write_defs_bzl` | Write `defs.bzl` and `crates.bzl` |

The last three phases are intentionally split so render regressions can be
localized to `BUILD.bazel`, `data.bzl`, or `defs.bzl` generation separately.

## Validation And Benchmarks

The current fastpath examples cover both correctness and performance.

`examples/fastpath_regression`

- regression-oriented WORKSPACE example
- uses a single workspace-root manifest, matching the simplest supported
  fastpath input shape
- covers registry, `path`, `git`, `build.rs`, proc-macro, override targets,
  annotation coverage, and render-config toggles

`examples/fastpath_ripgrep`

- resolver/sync benchmark against a local `ripgrep` checkout using isolated
  generated WORKSPACE roots
- passes the same-Cargo-workspace member manifest set to both baseline and
  fastpath, specifically to cover compatibility with traditional
  `cargo_bazel` multi-manifest projects
- project end-to-end benchmark against local Bazelized baseline and fastpath
  ripgrep checkouts
- profiles warm-cache syncs and reports steady-state plus first-generation
  timings for both resolver/sync and project-level workflows

Recent resolver/sync benchmark results from `examples/fastpath_ripgrep` were:

- steady-state cold sync: `24630ms` vs `71300ms` (`2.895x` faster)
- steady-state hot sync: `10810ms` vs `54070ms` (`5.002x` faster)
- first-generation repin benchmark: `31840ms` vs `71990ms` (`2.261x` faster)

Recent project end-to-end result:

- correctness: both baseline and fastpath passed `bazel query //...`,
  `bazel build //...`, `bazel run //:rg -- --version`, and `bazel test //...`
- steady-state cold `bazel build //...`: `80.95s` vs `122.24s` real time
  (`1.510x` faster)
- steady-state hot `bazel build //...` median: `2.84s` vs `2.68s`
  (effectively flat)
- first-generation `CARGO_BAZEL_REPIN=1` sync plus build: `95.48s` vs
  `137.34s` (`1.438x` faster)

Exact numbers will vary by host, Bazel mode, and cache warmth.
