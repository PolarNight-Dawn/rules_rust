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
- persistent resolver facts: fastpath facts are stored in
  `cargo-bazel-lock-fastpath.json` and reused across Bazel output roots.
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

- no `module extension` facts API: WORKSPACE uses lockfile and sidecar caches
  instead of `mctx.facts`.
- no extension-level async downloader orchestration: repository rules still use
  a simpler synchronous execution model.
- `cargo metadata --no-deps` still runs on each sync.
- the hub still performs a small amount of up-front classification work for
  aliases, proc-macro handling, and build-script handling.
- `git` and `path` crates still rely on targeted `cargo metadata` fallback more
  than `rules_rs` does.

### Is more alignment still necessary?

Given the current results, more alignment is not required for now if the
priority is safety, predictability, and maintainability.

The current backend already reaches the expected benefit range:

- steady-state cold sync: `2.686x` faster than the baseline harness
- steady-state hot sync: `5.059x` faster
- first-generation repin benchmark: `2.428x` faster

Under that constraint, the remaining gaps should be treated as optional, not
mandatory.

Recommended position:

- keep the current design as the default direction for WORKSPACE
- prefer hardening and documentation over another round of aggressive
  optimization
- only revisit deeper alignment if a new bottleneck appears in real repos

### Recommended follow-up priorities

If more work is needed later, the safest next targets are:

1. reduce unnecessary reruns of `cargo metadata --no-deps`
2. trim small remaining hub-side inspection work

Async or parallel downloader work is still possible, but it carries the
highest stability risk and is not necessary to justify the backend anymore.

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

### Performance benchmarks

The performance baseline is covered by the isolated ripgrep harness in
`examples/fastpath_ripgrep`.

The harness compares two separate generated WORKSPACE roots:

- fastpath backend
- baseline `cargo_bazel` backend

This prevents cross-loading and makes the A/B numbers meaningful.

Current benchmark summary from
`.tmp/fastpath_ripgrep_runs/benchmark_full.log`:

- steady-state cold
  - fastpath median: `25930ms`
  - cargo_bazel median: `69660ms`
  - speedup: `2.686x`
- steady-state hot
  - fastpath median: `10730ms`
  - cargo_bazel median: `54280ms`
  - speedup: `5.059x`
- first-generation repin
  - fastpath median: `53110ms`
  - cargo_bazel median: `128950ms`
  - speedup: `2.428x`

Current local status:

- `examples/fastpath_ripgrep/benchmark.sh validate`: passing

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
`.tmp/fastpath_ripgrep_runs/profile.log` showed:

- `cargo_metadata_no_deps = 432.686ms`
- `download_registry_metadata = 30.532ms`
- `inspect_external_crates = 32.406ms`
- `write_root_build_bazel = 24.155ms`
- `write_data_bzl = 28.424ms`
- `write_defs_bzl = 24.558ms`

## Conclusion

The WORKSPACE fastpath is now aligned with the important `rules_rs`
optimization strategy at the level that matters in practice.

The remaining gaps are mostly implementation-shape differences or
higher-risk optimizations, not missing fundamentals. Correctness coverage,
benchmark coverage, and profiling coverage now all cover the expected basics.
