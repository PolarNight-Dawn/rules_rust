# WORKSPACE Lockfile Fastpath

[中文版本](./lockfile_fastpath_workspace_zh.md)

The experimental `resolver_backend = "lockfile_fastpath"` backend makes the
WORKSPACE `crate_universe` flow behave more like a lockfile-driven resolver.
Instead of always running the full `cargo-bazel query + splice + generate`
pipeline, it trusts the existing `Cargo.lock` plus Bazel lockfile, resolves the
dependency graph from lockfile metadata, and only falls back to the slower
repin path when repinning is explicitly requested.

## Further Reading

- [WORKSPACE lockfile fastpath status](./lockfile_fastpath_workspace_status_en.md)
- [WORKSPACE lockfile fastpath migration guide](./lockfile_fastpath_workspace_guide_en.md)
- [WORKSPACE lockfile fastpath 现状总结](./lockfile_fastpath_workspace_status_zh.md)
- [WORKSPACE lockfile fastpath 迁移手册](./lockfile_fastpath_workspace_guide_zh.md)

## Goals

The backend is optimized for the common WORKSPACE steady-state case:

- keep existing `Cargo.lock` and Bazel lockfile authoritative
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

`cargo-bazel-lock-fastpath.json`

- stores fastpath `facts`
- currently includes:
  - `registry_entries`: sparse index rows reduced to resolver inputs
  - `registry_inspection`: manifest subset and source-tree probes used during
    spoke render preparation

`.cargo-bazel-fastpath-cache/archives`

- stores downloaded registry crate archives
- is shared across Bazel output bases
- avoids re-downloading crate tarballs on cold output roots

These caches are advisory. They speed up future syncs, but they are not the
source of truth for dependency selection.

## Cache Fallback Strategy

The fastpath backend is designed to fail safe.

- If `cargo-bazel-lock-fastpath.json` is missing, empty, malformed, or has an
  unexpected schema version, the backend ignores it and rebuilds the facts from
  authoritative inputs.
- If an individual `registry_entries` or `registry_inspection` fact is missing,
  that crate is recomputed and the cache is rewritten.
- If a cached crate archive is missing, the backend downloads it again and
  repopulates `.cargo-bazel-fastpath-cache/archives`.
- If a local `path` or `git` crate changes, fresh Cargo metadata and manifest
  reads are used during the next sync.
- If repinning is requested with `CARGO_BAZEL_REPIN=1`, WORKSPACE usage falls
  back to the standard repin flow instead of trusting fastpath caches.

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
- covers registry, `path`, `git`, `build.rs`, proc-macro, override targets,
  annotation coverage, and render-config toggles

`examples/fastpath_ripgrep`

- isolated A/B benchmark harness against a local `ripgrep` checkout
- validates both fastpath and baseline `cargo_bazel` workspaces
- profiles warm-cache syncs and reports steady-state plus first-generation
  timings

Recent benchmark results from `examples/fastpath_ripgrep` were:

- steady-state cold sync: `25930ms` vs `69660ms` (`2.686x` faster)
- steady-state hot sync: `10730ms` vs `54280ms` (`5.059x` faster)
- first-generation repin benchmark: `53110ms` vs `128950ms` (`2.428x` faster)

Exact numbers will vary by host, Bazel mode, and cache warmth.
