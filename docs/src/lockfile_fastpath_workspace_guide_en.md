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
- the Bazel lockfile
- `cargo metadata --no-deps`
- sparse index metadata
- targeted fallbacks for `git` and `path` crates

The steady-state goal is to keep lockfiles authoritative and make normal
WORKSPACE syncs cheap.

## 2. Code Areas To Carry In A Fork

If another `rules_rust` fork wants this backend, the main implementation lives
in the following files:

- `crate_universe/private/crates_repository.bzl`
- `crate_universe/private/fastpath_resolver.bzl`
- `crate_universe/private/fastpath_repo.bzl`
- `crate_universe/private/fastpath_spoke_render.bzl`
- `crate_universe/private/fastpath_cfg_parser.bzl`
- `crate_universe/private/fastpath_semver.bzl`
- `crate_universe/private/fastpath_solver.bzl`

Supporting updates also exist in:

- `crate_universe/private/common_utils.bzl`
- `crate_universe/private/generate_utils.bzl`

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
    lockfile = "//:cargo-bazel-lock-fastpath.json",
    manifests = ["//:Cargo.toml"],
    resolver_backend = "lockfile_fastpath",
)
```

Required inputs:

- a checked-in `Cargo.lock`
- a checked-in Bazel lockfile
- one or more manifests passed through `manifests`

Important behavior:

- normal syncs use the fastpath backend
- `CARGO_BAZEL_REPIN=1` falls back to the standard repin flow

## 4. Expected Cache Files

After the first successful sync, the workspace will contain:

- `cargo-bazel-lock-fastpath.json`
- `.cargo-bazel-fastpath-cache/archives/`

What they do:

- `cargo-bazel-lock-fastpath.json`
  - stores fastpath facts
  - caches reduced sparse index entries and registry inspection facts
- `.cargo-bazel-fastpath-cache/archives`
  - stores registry crate archives
  - allows reuse across Bazel output roots

Both caches are advisory. Deleting them is safe and only slows down the next
sync.

## 5. Migration Checklist For A Project Repo

1. Ensure the repo already has a stable WORKSPACE `crate_universe` flow.
2. Check in a `Cargo.lock` if it is not already tracked.
3. Add a dedicated Bazel lockfile such as `cargo-bazel-lock-fastpath.json`.
4. Set `resolver_backend = "lockfile_fastpath"` on the target
   `crates_repository`.
5. Run:

```bash
bazel sync --only=<repo_name>
```

6. If needed, run a repin once:

```bash
CARGO_BAZEL_REPIN=1 bazel sync --only=<repo_name>
```

7. Commit:
   - the WORKSPACE changes
   - `cargo-bazel-lock-fastpath.json`
   - any regenerated Bazel lockfile content

## 6. Migration Checklist For A Fork Maintainer

1. Bring over the fastpath implementation files.
2. Keep `crates_repository.bzl` wired so:
   - fastpath is used for normal syncs when `resolver_backend` is
     `"lockfile_fastpath"`
   - standard repin remains available
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

### A/B validation and benchmark

```bash
cd examples/fastpath_ripgrep
./benchmark.sh validate
./benchmark.sh benchmark
```

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
   - `cargo-bazel-lock-fastpath.json`
   - `.cargo-bazel-fastpath-cache/archives`

This rollback is straightforward because the fastpath caches are not the source
of truth for dependency selection.

## 10. Current Recommended Operating Mode

For most projects, the recommended operating mode is:

- use fastpath for normal WORKSPACE syncs
- use the standard repin flow when updating dependencies
- keep the ripgrep harness or an equivalent real-repo benchmark available for
  regression checks

That gives the performance benefit without requiring riskier implementation
changes such as async downloader orchestration.
