# Fastpath Ripgrep Harness

[中文版本](./README.zh.md)

This harness benchmarks and validates the WORKSPACE fastpath backend against a
real Cargo workspace using a local `ripgrep` checkout.

Implementation notes, design details, cache strategy, status summaries, and
migration guidance are documented in:

- [`docs/src/lockfile_fastpath_workspace.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace.md)
- [`docs/src/lockfile_fastpath_workspace_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_zh.md)
- [`docs/src/lockfile_fastpath_workspace_status_en.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_status_en.md)
- [`docs/src/lockfile_fastpath_workspace_status_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_status_zh.md)
- [`docs/src/lockfile_fastpath_workspace_guide_en.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_guide_en.md)
- [`docs/src/lockfile_fastpath_workspace_guide_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_guide_zh.md)

By default it looks for `ripgrep` next to this repository:

```text
.../repo/rules_rust
.../repo/ripgrep
```

Override that with `RIPGREP_DIR=/path/to/ripgrep`.

### Layout

The harness uses three separate WORKSPACE roots under `.tmp/fastpath_ripgrep`:

- `fastpath_workspace`: `resolver_backend = "lockfile_fastpath"`
- `cargo_bazel_workspace`: baseline `cargo_bazel` flow
- `bootstrap_workspace`: one-time `cargo_bazel` lockfile bootstrap for the
  baseline workspace

This separation matters. It prevents fastpath runs from loading the baseline
repository and keeps `profile` focused on the fastpath backend alone.

### Commands

```bash
cd examples/fastpath_ripgrep
./benchmark.sh prepare
./benchmark.sh validate
./benchmark.sh profile
./benchmark.sh benchmark
```

Useful one-off benchmark commands:

```bash
./benchmark.sh benchmark_steady_state
./benchmark.sh benchmark_first_gen
```

### What Each Command Does

`prepare`

- Creates or reuses the three workspace directories
- Bootstraps `cargo-bazel-lock-cargo-bazel.json` for the baseline workspace

`validate`

- Warm-runs the fastpath workspace
- Confirms fastpath profile cache hits are present
- Builds a small Bazel target against ripgrep's root dependency set in both
  workspaces

`profile`

- Runs two fastpath syncs in the fastpath workspace
- Prints the second sync's `_fastpath_profile.json`
- Is the command to use when checking warm-cache behavior

`benchmark`

- Runs both `benchmark_steady_state` and `benchmark_first_gen`
- Prints median timings and speedups

### Useful Overrides

```bash
RIPGREP_DIR=/path/to/ripgrep ./benchmark.sh validate
BAZEL=/path/to/bazel ./benchmark.sh benchmark
BAZEL_BATCH=0 ./benchmark.sh benchmark
FASTPATH_RIPGREP_WORKDIR="$PWD/.tmp/run" ./benchmark.sh profile
RECREATE_WORKSPACE=1 ./benchmark.sh prepare
COLD_ITERATIONS=2 HOT_ITERATIONS=3 ./benchmark.sh benchmark_steady_state
FIRST_GEN_ITERATIONS=1 ./benchmark.sh benchmark_first_gen
```

Notes:

- `RECREATE_WORKSPACE=1` forces the harness to rewrite the generated
  workspaces.
- The fastpath workspace persists two caches across syncs:
  - `cargo-bazel-lock-fastpath.json` facts
  - `.cargo-bazel-fastpath-cache/archives` crate archives
- Warm-cache `profile` runs should show cache hits for both
  `download_registry_metadata` and `inspect_external_crates`.
- Both caches are advisory and safe to delete. The next sync rebuilds them from
  `Cargo.lock`, workspace metadata, and registry sources.

### Cache Fallback Behavior

The fastpath workspace is designed to degrade safely.

- Missing or empty `cargo-bazel-lock-fastpath.json` causes a cache miss, not an
  incorrect resolution.
- Unexpected lockfile schema versions are ignored and recomputed.
- Missing archive files are downloaded again into
  `.cargo-bazel-fastpath-cache/archives`.
- `CARGO_BAZEL_REPIN=1` bypasses the normal fastpath steady-state behavior and
  uses the standard repin flow.

If you want to force a clean fastpath steady-state measurement, delete the
fastpath lockfile and archive cache before rerunning `prepare` or `profile`.

### Profile Phases

`./benchmark.sh profile` prints `_fastpath_profile.json` for the second
fastpath sync. The most useful phases are:

- `cargo_metadata_no_deps`
- `cargo_metadata_full`
- `download_registry_metadata`
- `inspect_external_crates`
- `prepare_spoke_render_metadata`
- `render_hub_repo_metadata`
- `write_root_build_bazel`
- `write_data_bzl`
- `write_defs_bzl`

The final three phases split hub rendering output by file family so regressions
can be traced to root `BUILD.bazel`, `data.bzl`, or `defs.bzl` generation.

### Current Results

Recent full benchmark results from
`.tmp/fastpath_ripgrep_runs/benchmark_full.log`:

- `profile` warm fastpath sync is about `1s`
- `steady_state cold`: `25930ms` vs `69660ms` (`2.686x`)
- `steady_state hot`: `10730ms` vs `54280ms` (`5.059x`)
- `first_gen repin`: `53110ms` vs `128950ms` (`2.428x`)

Exact numbers will vary by host, Bazel mode, and whether the Cargo and Bazel
caches are already warm.

If `ripgrep` is not available locally, clone it first:

```bash
git clone https://github.com/BurntSushi/ripgrep /path/to/ripgrep
```
