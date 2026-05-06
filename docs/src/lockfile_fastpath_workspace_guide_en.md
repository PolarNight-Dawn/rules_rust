# WORKSPACE Lockfile Fastpath Migration Guide

[中文版本](./lockfile_fastpath_workspace_guide_zh.md)

This guide explains how to enable, validate, and roll back
`resolver_backend = "lockfile_fastpath"` in a WORKSPACE project. It also lists
what a `rules_rust` fork must carry to keep the backend working.

For the runtime model, see [the overview](./lockfile_fastpath_workspace.md).
For current results and next-phase work, see
[the status document](./lockfile_fastpath_workspace_status_en.md).

## Quick Decision

Use the fastpath when the repository has:

- a WORKSPACE `crates_repository`
- a checked-in `Cargo.lock`
- `manifests` pointing at either one Cargo workspace root or multiple members
  of the same Cargo workspace
- normal dependency updates that can be represented by Cargo updating or
  generating `Cargo.lock`

Use the legacy backend, or expect fallback, when the repository depends on:

- `packages`
- multiple independent Cargo workspaces inside one `crates_repository`
- `skip_cargo_lockfile_overwrite`
- `strip_internal_dependencies_from_cargo_lockfile`
- other behavior that requires legacy `cargo_bazel` generate semantics

## Enable In A Project

Set `resolver_backend = "lockfile_fastpath"` on the target
`crates_repository`.

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
  manifests

Optional compatibility input:

- `lockfile = "//:cargo-bazel-lock-fastpath.json"` if the project wants
  fastpath facts stored in a Bazel lockfile-style file

For new migrations, the `lockfile` attribute is optional. Without it, facts are
stored under `.cargo-bazel-fastpath-cache/facts/<repo>.json`.

## Multi-Manifest Rule

Multiple manifests are supported only as same-Cargo-workspace normalization.
Fastpath runs `cargo metadata --no-deps`, verifies that every listed manifest is
a member of the same Cargo workspace, then renders from the normalized
workspace-root manifest.

This supports traditional `cargo_bazel` projects that list every member crate.
Fastpath does not support combining multiple independent Cargo workspaces in
one `crates_repository.manifests` list.

Reason: one repository rule should represent one Cargo workspace root and one
lockfile. Use separate `crates_repository` instances for independent Cargo
workspaces.

## Sync And Repin Behavior

Normal sync:

```bash
bazel sync --only=<repo_name>
```

With `resolver_backend = "lockfile_fastpath"`, normal sync resolves from the
checked-in `Cargo.lock` and fastpath facts.

Supported repin:

```bash
CARGO_BAZEL_REPIN=1 bazel sync --only=<repo_name>
```

Supported repin requests:

- parse the repin request
- update or generate `Cargo.lock` with Cargo
- run `cargo fetch`
- write back the workspace `Cargo.lock`
- refresh stale fastpath facts as needed
- render through fastpath

Supported fastpath repins do not require a cargo-bazel generator.

Unsupported repin configurations fall back to legacy `cargo_bazel`
repin/generate. Keep a usable generator configured if the project relies on
those fallback configurations.

## Expected Cache Files

After the first successful sync, the workspace may contain:

- `.cargo-bazel-fastpath-cache/facts/<repo>.json`
- `.cargo-bazel-fastpath-cache/archives/`

The facts file stores sparse registry facts, registry inspection facts, and
validated workspace metadata facts. The archive directory stores registry crate
archives for reuse across Bazel output roots.

These caches are advisory. Deleting them is safe; the next sync will recompute
or re-download what it needs.

Workspace metadata facts are reused only when the recorded `Cargo.lock`, the
workspace-root manifest, and every recorded workspace member manifest still
match the current files.

## Project Migration Checklist

1. Confirm the existing WORKSPACE `crate_universe` flow is healthy.
2. Check in `Cargo.lock` if it is not already tracked.
3. Add `resolver_backend = "lockfile_fastpath"` to the target
   `crates_repository`.
4. If multiple manifests are passed, ensure they all belong to the same Cargo
   workspace.
5. Keep a cargo-bazel generator configured if the repository uses repin
   settings that remain outside the fastpath and therefore need fallback.
6. Run `bazel sync --only=<repo_name>`.
7. Run a supported repin if needed with
   `CARGO_BAZEL_REPIN=1 bazel sync --only=<repo_name>`.
8. Commit the WORKSPACE changes and any `Cargo.lock` updates from the repin.
9. Commit fastpath facts only if the project intentionally wants warm first
   syncs in CI.
10. If a legacy fallback repin was used, commit the regenerated Bazel lockfile
    content as usual.

## Validation Workflow

Recommended order:

```bash
cd examples/fastpath_smoke
bazel sync --only=fastpath_smoke_index
bazel test //:smoke_test
```

```bash
cd examples/fastpath_regression
./validate.sh
```

`validate.sh` includes the focused boundary regression. To run only that
smaller check:

```bash
cd examples/fastpath_regression
./validate_boundaries.sh
```

```bash
cd examples/fastpath_ripgrep
./benchmark.sh prepare
./benchmark.sh validate
./benchmark.sh profile
./benchmark.sh benchmark
```

For local Bazelized ripgrep checkouts:

```bash
cd examples/fastpath_ripgrep
./project_e2e.sh correctness
./project_e2e.sh benchmark
```

`project_e2e.sh correctness` runs these commands for both baseline and
fastpath:

- `bazel query //...`
- `bazel build //...`
- `bazel run //:rg -- --version`
- `bazel test //...`

`project_e2e.sh benchmark` records:

- `steady_state cold`: keep dependency facts/lock/cache, clear Bazel output
  cache, then time `bazel build //...`
- `steady_state hot`: keep Bazel output cache warm and time no-change
  `bazel build //...`
- `first_gen repin`: clear fastpath facts/archive cache or baseline lockfile
  generation state, run `CARGO_BAZEL_REPIN=1 bazel sync --only=crate_index`,
  then time `bazel build //...`

## Reading Profiles

Enable profiling with:

```bash
CARGO_BAZEL_FASTPATH_PROFILE=1
```

The hub repository writes `_fastpath_profile.json`.

Start with these phases:

- `cargo_metadata_no_deps`: workspace metadata load or cache hit
- `cargo_metadata_full`: targeted fallback for `git`/`path` crates
- `download_registry_metadata`: sparse registry facts
- `inspect_external_crates`: registry inspection facts
- `prepare_spoke_render_metadata`: spoke metadata preparation
- `render_hub_repo_metadata`: in-memory hub rendering
- `write_root_build_bazel`, `write_data_bzl`, `write_defs_bzl`: hub output
  writes split by file family

## Rollback

To roll back a project:

1. Remove `resolver_backend = "lockfile_fastpath"`.
2. Return to the existing `cargo_bazel` configuration.
3. Optionally delete:
   - `.cargo-bazel-fastpath-cache/facts/<repo>.json`
   - `.cargo-bazel-fastpath-cache/archives`

Fastpath caches are not the source of truth for dependency selection, so
deleting them does not change correctness.

## Fork Maintainer Checklist

Carry these implementation files together:

- `crate_universe/private/crates_repository.bzl`
- `crate_universe/private/fastpath_resolver.bzl`
- `crate_universe/private/fastpath_repo.bzl`
- `crate_universe/private/fastpath_spoke_render.bzl`
- `crate_universe/private/fastpath_cfg_parser.bzl`
- `crate_universe/private/fastpath_semver.bzl`
- `crate_universe/private/fastpath_solver.bzl`
- `crate_universe/private/common_utils.bzl`
- `crate_universe/private/generate_utils.bzl`

Carry these examples and docs:

- `examples/fastpath_smoke`
- `examples/fastpath_regression`
- `examples/fastpath_ripgrep`
- `docs/src/lockfile_fastpath_workspace.md`
- `docs/src/lockfile_fastpath_workspace_zh.md`
- `docs/src/lockfile_fastpath_workspace_status_en.md`
- `docs/src/lockfile_fastpath_workspace_status_zh.md`
- `docs/src/lockfile_fastpath_workspace_guide_en.md`
- `docs/src/lockfile_fastpath_workspace_guide_zh.md`

Before publishing a fork:

1. Run the smoke and regression checks.
2. Run the ripgrep resolver/sync benchmark.
3. Run the ripgrep project end-to-end correctness flow if the local checkouts
   are available.
4. Confirm unsupported repin cases still fall back to legacy `cargo_bazel`.
