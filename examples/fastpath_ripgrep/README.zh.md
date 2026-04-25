# Fastpath Ripgrep 基准工具

[English version](./README.md)

这个 harness 用本地 `ripgrep` checkout，对 WORKSPACE fastpath backend 做真实
Cargo workspace 的验证和基准测试。

实现细节、设计说明、缓存策略、现状总结和迁移手册都在这些文档里：

- [`docs/src/lockfile_fastpath_workspace.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace.md)
- [`docs/src/lockfile_fastpath_workspace_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_zh.md)
- [`docs/src/lockfile_fastpath_workspace_status_en.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_status_en.md)
- [`docs/src/lockfile_fastpath_workspace_status_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_status_zh.md)
- [`docs/src/lockfile_fastpath_workspace_guide_en.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_guide_en.md)
- [`docs/src/lockfile_fastpath_workspace_guide_zh.md`](/Users/dengjiahong/repo/rules_rust/docs/src/lockfile_fastpath_workspace_guide_zh.md)

默认情况下，它会在当前仓库旁边寻找 `ripgrep`：

```text
.../repo/rules_rust
.../repo/ripgrep
```

如果路径不同，可以通过 `RIPGREP_DIR=/path/to/ripgrep` 覆盖。

## 目录结构

harness 会在 `.tmp/fastpath_ripgrep` 下生成三个彼此独立的 WORKSPACE 根目录：

- `fastpath_workspace`：`resolver_backend = "lockfile_fastpath"`
- `cargo_bazel_workspace`：baseline `cargo_bazel` 流程
- `bootstrap_workspace`：仅用于 baseline workspace 的一次性
  `cargo_bazel` lockfile bootstrap

这个隔离很重要。它可以避免 fastpath 运行时顺带加载 baseline repository，并让
`profile` 只聚焦 fastpath backend 本身。

## 命令

```bash
cd examples/fastpath_ripgrep
./benchmark.sh prepare
./benchmark.sh validate
./benchmark.sh profile
./benchmark.sh benchmark
```

常用的单项 benchmark 命令：

```bash
./benchmark.sh benchmark_steady_state
./benchmark.sh benchmark_first_gen
```

## 每个命令做什么

`prepare`

- 创建或复用三个 workspace 目录
- 为 baseline workspace bootstrap `cargo-bazel-lock-cargo-bazel.json`

`validate`

- 先做一次 fastpath warm run
- 确认 fastpath profile 里已经出现 cache hit
- 在两个 workspace 里都构建一个依赖 ripgrep 根依赖集的小 Bazel target

`profile`

- 在 fastpath workspace 里连续执行两次 sync
- 打印第二次 sync 的 `_fastpath_profile.json`
- 它是检查 warm-cache 行为时最应该使用的命令

`benchmark`

- 同时执行 `benchmark_steady_state` 和 `benchmark_first_gen`
- 输出中位数耗时和 speedup

## 常用覆盖项

```bash
RIPGREP_DIR=/path/to/ripgrep ./benchmark.sh validate
BAZEL=/path/to/bazel ./benchmark.sh benchmark
BAZEL_BATCH=0 ./benchmark.sh benchmark
FASTPATH_RIPGREP_WORKDIR="$PWD/.tmp/run" ./benchmark.sh profile
RECREATE_WORKSPACE=1 ./benchmark.sh prepare
COLD_ITERATIONS=2 HOT_ITERATIONS=3 ./benchmark.sh benchmark_steady_state
FIRST_GEN_ITERATIONS=1 ./benchmark.sh benchmark_first_gen
```

说明：

- `RECREATE_WORKSPACE=1` 会强制重写生成出来的 workspace。
- fastpath workspace 会跨次 sync 持久化两层缓存：
  - `cargo-bazel-lock-fastpath.json` facts
  - `.cargo-bazel-fastpath-cache/archives` crate archive
- warm-cache `profile` 运行时，应当能看到 `download_registry_metadata`
  和 `inspect_external_crates` 都出现 cache hit。
- 两层缓存都是 advisory cache，可以安全删除；下次 sync 会基于 `Cargo.lock`、
  workspace metadata 和 registry 源重新生成。

## 缓存回退行为

fastpath workspace 的设计目标是“降级时安全”。

- `cargo-bazel-lock-fastpath.json` 缺失或为空，只会造成 cache miss，不会产生错误解析。
- lockfile schema version 不符合预期时，会忽略旧缓存并重新计算。
- archive 文件缺失时，会重新下载到 `.cargo-bazel-fastpath-cache/archives`。
- `CARGO_BAZEL_REPIN=1` 会绕过普通 fastpath 稳态流程，改走标准 repin 流程。

如果你想强制拿到一个干净的 fastpath steady-state 测量结果，可以先删掉
fastpath lockfile 和 archive cache，再重新执行 `prepare` 或 `profile`。

## Profile Phases

`./benchmark.sh profile` 会打印第二次 fastpath sync 的
`_fastpath_profile.json`。最值得关注的 phase 有：

- `cargo_metadata_no_deps`
- `cargo_metadata_full`
- `download_registry_metadata`
- `inspect_external_crates`
- `prepare_spoke_render_metadata`
- `render_hub_repo_metadata`
- `write_root_build_bazel`
- `write_data_bzl`
- `write_defs_bzl`

最后三段会把 hub 渲染输出按文件族拆开，这样回归时可以直接定位到根
`BUILD.bazel`、`data.bzl` 或 `defs.bzl` 的生成阶段。

## 当前结果

最近一次完整 benchmark 结果来自
`.tmp/fastpath_ripgrep_runs/benchmark_full.log`：

- `profile` 的 fastpath warm sync 大约是 `1s`
- `steady_state cold`：`25930ms` 对 `69660ms`（`2.686x`）
- `steady_state hot`：`10730ms` 对 `54280ms`（`5.059x`）
- `first_gen repin`：`53110ms` 对 `128950ms`（`2.428x`）

具体数字会受机器、Bazel 运行模式以及 Cargo/Bazel 缓存温度影响。

如果本地没有 `ripgrep`，先执行：

```bash
git clone https://github.com/BurntSushi/ripgrep /path/to/ripgrep
```
