# Fastpath Regression

[中文版本](./README.zh.md)

This example exercises the WORKSPACE `resolver_backend = "lockfile_fastpath"`
path against a broader matrix than the minimal smoke test.

It covers:

- a single workspace-root manifest input
- registry crates
- path crates
- a git crate backed by a temporary local git repository
- `build.rs`
- a proc-macro crate
- `override_targets`
- `additive_build_file`
- `build_script_link_deps`
- `extra_aliased_targets`
- rendered annotation coverage for `compile_data_glob`,
  `compile_data_glob_excludes`, `data_glob`,
  `build_script_data_glob`, and `build_script_exec_properties`
- `render_config(generate_cargo_toml_env_vars = False, generate_target_compatible_with = False)`
- fastpath per-phase profiling via `CARGO_BAZEL_FASTPATH_PROFILE=1`
- fine-grained fastpath boundary coverage:
  - workspace metadata cache hit/miss behavior
  - same-Cargo-workspace multi-manifest normalization
  - independent workspace rejection and repin fallback
  - supported repin fastpath without a cargo-bazel generator
  - legacy fallback for unsupported repin settings

Run it with:

```bash
cd examples/fastpath_regression
./validate.sh
```

`validate.sh` also runs `validate_boundaries.sh`. Run that script directly when
you only need the smaller boundary checks.

Helpful overrides:

```bash
BAZEL=/path/to/bazel ./validate.sh
BAZEL_BATCH=0 ./validate.sh
OUTPUT_USER_ROOT="$PWD/.tmp/custom_bazel_root" ./validate.sh
KEEP_GENERATED=1 ./validate.sh
```

For the fastpath cache layout, fallback behavior, profile phase glossary,
status summary, and migration/testing guidance, see:

- [`docs/src/lockfile_fastpath_workspace.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace.md)
- [`docs/src/lockfile_fastpath_workspace_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_zh.md)
- [`docs/src/lockfile_fastpath_workspace_status_en.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_status_en.md)
- [`docs/src/lockfile_fastpath_workspace_status_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_status_zh.md)
- [`docs/src/lockfile_fastpath_workspace_guide_en.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_guide_en.md)
- [`docs/src/lockfile_fastpath_workspace_guide_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_guide_zh.md)
