# Fastpath Regression

[English version](./README.md)

这个 example 用比最小 smoke test 更大的矩阵来验证 WORKSPACE
`resolver_backend = "lockfile_fastpath"` 路径。

当前覆盖：

- 单个 workspace-root manifest 输入
- registry crate
- path crate
- 通过临时本地 git 仓库提供的 git crate
- `build.rs`
- proc-macro crate
- `override_targets`
- `additive_build_file`
- `build_script_link_deps`
- `extra_aliased_targets`
- 渲染类 annotation 覆盖：
  - `compile_data_glob`
  - `compile_data_glob_excludes`
  - `data_glob`
  - `build_script_data_glob`
  - `build_script_exec_properties`
- `render_config(generate_cargo_toml_env_vars = False, generate_target_compatible_with = False)`
- 通过 `CARGO_BAZEL_FASTPATH_PROFILE=1` 启用的 fastpath 分阶段 profiling
- 小粒度 fastpath 边界覆盖：
  - workspace metadata cache hit/miss
  - same-Cargo-workspace multi-manifest normalization
  - independent workspace rejection 和 repin fallback
  - 不依赖 cargo-bazel generator 的 supported repin fastpath
  - unsupported repin 设置的 legacy fallback

执行方式：

```bash
cd examples/fastpath_regression
./validate.sh
```

`validate.sh` 也会运行 `validate_boundaries.sh`。如果只需要较小的边界检查，可以
直接运行该脚本。

常用覆盖项：

```bash
BAZEL=/path/to/bazel ./validate.sh
BAZEL_BATCH=0 ./validate.sh
OUTPUT_USER_ROOT="$PWD/.tmp/custom_bazel_root" ./validate.sh
KEEP_GENERATED=1 ./validate.sh
```

fastpath 的缓存布局、回退策略、profile phase 说明、现状总结和迁移/测试手册见：

- [`docs/src/lockfile_fastpath_workspace.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace.md)
- [`docs/src/lockfile_fastpath_workspace_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_zh.md)
- [`docs/src/lockfile_fastpath_workspace_status_en.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_status_en.md)
- [`docs/src/lockfile_fastpath_workspace_status_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_status_zh.md)
- [`docs/src/lockfile_fastpath_workspace_guide_en.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_guide_en.md)
- [`docs/src/lockfile_fastpath_workspace_guide_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_guide_zh.md)
