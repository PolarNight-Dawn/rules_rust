# Fastpath Ripgrep Harness

[中文版本](./README.zh.md)

This directory contains two complementary ripgrep workflows:

- `benchmark.sh`: resolver/sync benchmark for the generated WORKSPACE harness
- `project_e2e.sh`: project end-to-end benchmark for local Bazelized ripgrep
  checkouts

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

### Resolver/Sync Benchmark Commands

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

### What Each Resolver/Sync Command Does

`prepare`

- Creates or reuses the three workspace directories
- Bootstraps `cargo-bazel-lock-cargo-bazel.json` for the baseline workspace
- Writes the same 10 ripgrep workspace manifests into both baseline and
  fastpath configurations, so fastpath exercises same-Cargo-workspace
  manifest normalization instead of a single-manifest shortcut. The listed
  manifests are all members of the same Cargo workspace; this harness does not
  model multiple independent Cargo workspaces in one `crates_repository`.

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

### Project End-To-End Commands

`project_e2e.sh` compares two local Bazelized ripgrep checkouts:

- baseline: `BASELINE_PROJECT_DIR`, defaulting to
  `/Users/dengjiahong/repo/ripgrep_baseline`
- fastpath: `FASTPATH_PROJECT_DIR`, defaulting to
  `/Users/dengjiahong/repo/ripgrep`

Correctness coverage:

```bash
./project_e2e.sh prepare
./project_e2e.sh correctness
```

This runs `bazel query //...`, `bazel build //...`,
`bazel run //:rg -- --version`, and `bazel test //...` for both baseline and
fastpath. It covers target completeness, full-project build behavior, binary
execution, test-suite behavior, and whether switching to fastpath breaks a
project that builds with the traditional `cargo_bazel` flow.

Performance coverage:

```bash
./project_e2e.sh benchmark
./project_e2e.sh benchmark_steady_state
./project_e2e.sh benchmark_first_gen
```

The project benchmark records:

- `steady_state cold`: keep dependency facts/lock/cache, clear the Bazel output
  cache, then time `bazel build //...`
- `steady_state hot`: keep the Bazel output cache warm and repeatedly time
  no-change `bazel build //...`
- `first_gen repin`: clear fastpath facts/archive cache or baseline lockfile
  generation state, run `CARGO_BAZEL_REPIN=1 bazel sync --only=crate_index`,
  then time `bazel build //...`

During `first_gen repin`, the script backs up and restores the baseline
`cargo-bazel-lock.json`, plus the fastpath `Cargo.lock` and
`.cargo-bazel-fastpath-cache`, so the measurement does not leave the project
checkouts in a generated state.

### Useful Overrides

```bash
RIPGREP_DIR=/path/to/ripgrep ./benchmark.sh validate
BAZEL=/path/to/bazel ./benchmark.sh benchmark
BAZEL_BATCH=0 ./benchmark.sh benchmark
FASTPATH_RIPGREP_WORKDIR="$PWD/.tmp/run" ./benchmark.sh profile
PROJECT_E2E_WORKDIR="$PWD/.tmp/project" ./project_e2e.sh benchmark
BASELINE_PROJECT_DIR=/path/to/ripgrep_baseline FASTPATH_PROJECT_DIR=/path/to/ripgrep ./project_e2e.sh correctness
RECREATE_WORKSPACE=1 ./benchmark.sh prepare
COLD_ITERATIONS=2 HOT_ITERATIONS=3 ./benchmark.sh benchmark_steady_state
FIRST_GEN_ITERATIONS=1 ./benchmark.sh benchmark_first_gen
```

Notes:

- `RECREATE_WORKSPACE=1` forces the harness to rewrite the generated
  workspaces.
- The fastpath workspace persists two caches across syncs:
  - `.cargo-bazel-fastpath-cache/facts/ripgrep_fastpath_index.json` facts
  - `.cargo-bazel-fastpath-cache/archives` crate archives
- Warm-cache `profile` runs should show cache hits for both
  `download_registry_metadata` and `inspect_external_crates`.
- Both caches are advisory and safe to delete. The next sync rebuilds them from
  `Cargo.lock`, workspace metadata, and registry sources.

### Cache Fallback Behavior

The fastpath workspace is designed to degrade safely.

- Missing or empty fastpath facts cache causes a cache miss, not an incorrect
  resolution.
- Unexpected lockfile schema versions are ignored and recomputed.
- Missing archive files are downloaded again into
  `.cargo-bazel-fastpath-cache/archives`.
- `CARGO_BAZEL_REPIN=1` bypasses the normal steady-state shortcut, updates
  or generates `Cargo.lock` directly with Cargo, and then renders through
  fastpath.
- The legacy `cargo_bazel` repin/generate flow remains available for
  unsupported repin configurations.

If you want to force a clean fastpath steady-state measurement, delete the
fastpath facts and archive caches before rerunning `prepare` or `profile`.

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

### Current Resolver/Sync Results

Recent resolver/sync benchmark results produced by `examples/fastpath_ripgrep/benchmark.sh benchmark`
using `RIPGREP_DIR=/Users/dengjiahong/repo/ripgrep`:

- `profile` warm fastpath sync is about `641ms`; it normalized
  `input_manifests = 10` from one Cargo workspace with a workspace metadata
  cache hit
- `steady_state cold`: `24630ms` vs `71300ms` (`2.895x`)
- `steady_state hot`: `10810ms` vs `54070ms` (`5.002x`)
- `first_gen repin`: `31840ms` vs `71990ms` (`2.261x`)

### Current Project End-To-End Results

The latest local project end-to-end comparison used
`/Users/dengjiahong/repo/ripgrep_baseline` with
`/Users/dengjiahong/repo/rules_rust_baseline` against
`/Users/dengjiahong/repo/ripgrep` with this `rules_rust` checkout. With Bazel
7.4.1, stable Rust toolchains, and the same 10 ripgrep manifests from one
Cargo workspace on both sides, the cold `bazel build //...` run completed in
`80.95s` real time for fastpath versus `122.24s` for baseline.
Hot no-change builds were effectively the same order of magnitude:
`2.84s` median for fastpath versus `2.68s` for baseline. First-generation
repin plus build now also goes through the Cargo-native repin fastpath and was
faster in this run: `95.48s` for fastpath versus `137.34s` for baseline.

Use `./project_e2e.sh correctness` for the full query/build/run/test
correctness comparison and `./project_e2e.sh benchmark` to refresh
steady-state cold, steady-state hot, and first-gen repin project timings.

Exact numbers will vary by host, Bazel mode, and whether the Cargo and Bazel
caches are already warm.

If `ripgrep` is not available locally, clone it first:

```bash
git clone https://github.com/BurntSushi/ripgrep /path/to/ripgrep
```
