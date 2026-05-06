# Fastpath Ripgrep 基准工具

[English version](./README.md)

这个目录包含两套互补的 ripgrep 流程：

- `benchmark.sh`：针对生成式 WORKSPACE harness 的 resolver/sync benchmark
- `project_e2e.sh`：针对本地 Bazel 化 ripgrep checkout 的 project end-to-end
  benchmark

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

## Resolver/Sync Benchmark 命令

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

## 每个 Resolver/Sync 命令做什么

`prepare`

- 创建或复用三个 workspace 目录
- 为 baseline workspace bootstrap `cargo-bazel-lock-cargo-bazel.json`
- 把同一组 10 个 ripgrep workspace manifest 写入 baseline 和 fastpath
  配置，确保 fastpath 覆盖 same-Cargo-workspace manifest normalization，而不是只测
  单 manifest shortcut。这些 manifest 都是同一个 Cargo workspace 的 member；
  这个 harness 不表示支持在一个 `crates_repository` 里混入多个独立 Cargo
  workspace。

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

## Project End-To-End 命令

`project_e2e.sh` 对比两份本地 Bazel 化 ripgrep checkout：

- baseline：`BASELINE_PROJECT_DIR`，默认
  `/Users/dengjiahong/repo/ripgrep_baseline`
- fastpath：`FASTPATH_PROJECT_DIR`，默认 `/Users/dengjiahong/repo/ripgrep`

Correctness 覆盖：

```bash
./project_e2e.sh prepare
./project_e2e.sh correctness
```

这会在 baseline 和 fastpath 两边都跑 `bazel query //...`、`bazel build //...`、
`bazel run //:rg -- --version` 和 `bazel test //...`，用于覆盖 target 完整性、
全项目 build、binary 可执行性、测试套件，以及 fastpath 切换是否破坏传统
`cargo_bazel` 能 build 的项目。

Performance 覆盖：

```bash
./project_e2e.sh benchmark
./project_e2e.sh benchmark_steady_state
./project_e2e.sh benchmark_first_gen
```

project benchmark 会记录：

- `steady_state cold`：保留依赖 facts/lock/cache，清 Bazel output cache，然后计时
  `bazel build //...`
- `steady_state hot`：不清 Bazel output cache，连续计时无改动
  `bazel build //...`
- `first_gen repin`：清 fastpath facts/archive cache 或 baseline lockfile 生成状态，
  跑 `CARGO_BAZEL_REPIN=1 bazel sync --only=crate_index`，再计时
  `bazel build //...`

`first_gen repin` 运行时，脚本会备份并恢复 baseline 的
`cargo-bazel-lock.json`，以及 fastpath 的 `Cargo.lock` 和
`.cargo-bazel-fastpath-cache`，避免计时后把项目 checkout 留在生成状态。

## 常用覆盖项

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

说明：

- `RECREATE_WORKSPACE=1` 会强制重写生成出来的 workspace。
- fastpath workspace 会跨次 sync 持久化两层缓存：
  - `.cargo-bazel-fastpath-cache/facts/ripgrep_fastpath_index.json` facts
  - `.cargo-bazel-fastpath-cache/archives` crate archive
- warm-cache `profile` 运行时，应当能看到 `download_registry_metadata`
  和 `inspect_external_crates` 都出现 cache hit。
- 两层缓存都是 advisory cache，可以安全删除；下次 sync 会基于 `Cargo.lock`、
  workspace metadata 和 registry 源重新生成。

## 缓存回退行为

fastpath workspace 的设计目标是“降级时安全”。

- fastpath facts cache 缺失或为空，只会造成 cache miss，不会产生错误解析。
- lockfile schema version 不符合预期时，会忽略旧缓存并重新计算。
- archive 文件缺失时，会重新下载到 `.cargo-bazel-fastpath-cache/archives`。
- `CARGO_BAZEL_REPIN=1` 会绕过普通 steady-state shortcut，直接用 Cargo 更新
  或生成 `Cargo.lock`，再通过 fastpath 渲染。
- 不支持的 repin 配置仍可回到 legacy `cargo_bazel` repin/generate 流程。

如果你想强制拿到一个干净的 fastpath steady-state 测量结果，可以先删掉
fastpath facts cache 和 archive cache，再重新执行 `prepare` 或 `profile`。

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

## 当前 Resolver/Sync 结果

最近一次 resolver/sync benchmark 结果由 `examples/fastpath_ripgrep/benchmark.sh benchmark`
产出，使用 `RIPGREP_DIR=/Users/dengjiahong/repo/ripgrep`：

- `profile` 的 fastpath warm sync 大约是 `641ms`，并在 workspace metadata cache
  命中的情况下，从同一个 Cargo workspace 归一了 `input_manifests = 10`
- `steady_state cold`：`24630ms` 对 `71300ms`（`2.895x`）
- `steady_state hot`：`10810ms` 对 `54070ms`（`5.002x`）
- `first_gen repin`：`31840ms` 对 `71990ms`（`2.261x`）

## 当前 Project End-To-End 结果

最近一次本地 project end-to-end 对比使用
`/Users/dengjiahong/repo/ripgrep_baseline` 加
`/Users/dengjiahong/repo/rules_rust_baseline` 对比
`/Users/dengjiahong/repo/ripgrep` 加当前 `rules_rust` checkout。在 Bazel
7.4.1、stable Rust toolchain，以及两边相同的 10 个 ripgrep manifests，且它们
都来自同一个 Cargo workspace，冷启动 `bazel build //...` 的 fastpath real time
为 `80.95s`，baseline 为 `122.24s`。无改动 hot build 基本同量级：
fastpath 中位数 `2.84s`，baseline 中位数 `2.68s`。first-generation repin 加
build 现在走 Cargo-native repin fastpath，这次完整运行里更快：fastpath
`95.48s`，baseline `137.34s`。

使用 `./project_e2e.sh correctness` 刷新完整 query/build/run/test correctness
对比，使用 `./project_e2e.sh benchmark` 刷新 steady-state cold、steady-state hot
和 first-gen repin 的 project 计时。

具体数字会受机器、Bazel 运行模式以及 Cargo/Bazel 缓存温度影响。

如果本地没有 `ripgrep`，先执行：

```bash
git clone https://github.com/BurntSushi/ripgrep /path/to/ripgrep
```
