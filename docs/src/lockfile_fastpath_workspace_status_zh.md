# WORKSPACE Lockfile Fastpath 现状总结

[English version](./lockfile_fastpath_workspace_status_en.md)

这份文档总结当前实验性 `resolver_backend = "lockfile_fastpath"` 在
WORKSPACE 模式下的状态，主要回答两个问题：

1. 它是否已经对齐 `rules_rs` 的性能优化思路和策略？
2. 当前测试和 profiling 覆盖是否已经把基本面覆盖到位？

## 1. 与 `rules_rs` 的对齐情况

### 已经对齐的部分

当前 WORKSPACE fastpath 已经在最关键的层面上对齐了 `rules_rs` 的性能思路。

- `lockfile-first`：普通 WORKSPACE `sync` 不再走完整的
  `cargo-bazel query + splice + generate` 链路。
- repin fastpath：显式 `CARGO_BAZEL_REPIN=1` 直接通过 Cargo 更新或生成
  `Cargo.lock`，然后回到 fastpath 解图和渲染。
- 持久化 resolver facts：fastpath facts 默认写入
  `.cargo-bazel-fastpath-cache/facts/<repo>.json`，如果显式配置了兼容
  `lockfile` 则继续写入该文件，并可跨 Bazel output root 复用。
- 持久化 archive cache：registry crate archive 会写入
  `.cargo-bazel-fastpath-cache/archives`，避免重复下载。
- hub/spoke 分层：hub repository 负责依赖解图和元数据准备，spoke
  repository 在本地渲染每个 crate 的 `BUILD.bazel`。
- sparse index 驱动：registry crate 基于 `Cargo.lock` 和 sparse index
  数据解析，`git/path` crate 再按需回退到 metadata。
- 分阶段 profiling：后续做性能回归和瓶颈分析已经有足够细的 phase 数据。

### 还没完全对齐的部分

仍然有一些实现层面的差异，没有做到和 `rules_rs` 一比一。

- 没有 `module extension` 层的 `mctx.facts`，而是用 sidecar cache，或显式
  兼容 `lockfile`，来模拟。
- 没有 extension 层面的异步 downloader 编排；当前 repository rule 已经用
  非阻塞 `repository_ctx.download` 预取 sparse index 行和 registry archive，
  但这仍然是 repository rule 内部的局部并行，而不是共享的 module-extension
  downloader。
- `cargo metadata --no-deps` 仍然是 workspace metadata 的安全 fallback；
  但在 `Cargo.lock` 和已记录 workspace manifests 都未变化时，warm sync 已可复用
  经过校验的 `workspace_metadata` facts cache。
- hub 侧仍保留少量前置分类逻辑，用于 alias、proc-macro 和 build-script。
- `git/path` crate 仍然更依赖定向 `cargo metadata` fallback。
- 依赖 `skip_cargo_lockfile_overwrite` 或
  `strip_internal_dependencies_from_cargo_lockfile` 的 repin 配置仍走 legacy
  `cargo_bazel` repin/generate fallback。

### 在达到预期收益的前提下，剩余部分还有没有必要继续

如果前提是“收益已经达到预期，并优先保证安全、稳定、可维护”，那么这些剩余
差异目前都不是必须继续追的。

当前已经拿到的收益已经足够说明 backend 成立：

- steady-state cold sync：相对 baseline 提升 `2.895x`
- steady-state hot sync：相对 baseline 提升 `5.002x`
- first-generation repin benchmark：相对 baseline 提升 `2.261x`
- project end-to-end steady-state cold build：本地 Bazel 化 ripgrep 对比里
  real time 提升 `1.510x`
- project end-to-end 的 hot no-change build 基本持平；first-generation
  `CARGO_BAZEL_REPIN=1` sync plus build 在最近一次完整运行里提升 `1.438x`

在这个前提下，更合理的策略是：

- 把当前 WORKSPACE fastpath 作为稳定方向收口
- 先补强文档、回归和防御性逻辑
- 只有在真实仓库再次出现新瓶颈时，再继续追剩下的差异

### 当前优化姿态

最新一轮已经通过经过校验的 `workspace_metadata` facts，去掉了 warm
same-Cargo-workspace manifest normalization 路径上主要的不必要
`cargo metadata --no-deps` 重跑。hub 侧前置 inspection 也继续保持很薄：
crate-local 探测留在 spoke repository，hub 只保留 alias、proc-macro、
build-script 和 links 等必须提前知道的事实。

当前 repository-rule-local download prefetching 已经足够支撑这一阶段。更大的
共享 downloader 模型后续仍可考虑，但风险最高，目前不建议默认继续。

## 2. 测试和 profiling 是否覆盖到基本面

### 正确性回归测试

当前正确性回归覆盖已经达到预期的基本面。

`examples/fastpath_smoke`

- 最小可运行 WORKSPACE smoke example
- 覆盖 `resolver_backend = "lockfile_fastpath"` 的最小 end-to-end 流程
- 覆盖一个 `path` crate 和一个简单 annotation

`examples/fastpath_regression`

- 更完整的 WORKSPACE 回归 example
- 当前覆盖：
  - registry crate
  - `path` crate
  - `git` crate
  - `build.rs`
  - proc-macro crate
  - `override_targets`
  - `additive_build_file`
  - `build_script_link_deps`
  - `extra_aliased_targets`
  - `compile_data_glob`
  - `compile_data_glob_excludes`
  - `data_glob`
  - `build_script_data_glob`
  - `build_script_exec_properties`
  - `render_config(generate_cargo_toml_env_vars = False, generate_target_compatible_with = False)`

当前本地状态：

- `examples/fastpath_regression/validate.sh`：通过

### Resolver/sync benchmark

resolver/sync benchmark 当前由 `examples/fastpath_ripgrep/benchmark.sh`
提供。它在隔离生成的 WORKSPACE harness 中测 dependency resolution 和 repository
generation 行为。

这个 harness 已经把两个 backend 拆到彼此独立的 WORKSPACE 里：

- fastpath backend
- baseline `cargo_bazel` backend

这样可以避免互相污染，保证 benchmark 结果可信。

当前基准结果由 `examples/fastpath_ripgrep/benchmark.sh benchmark` 产出，使用
`RIPGREP_DIR=/Users/dengjiahong/repo/ripgrep`：

- steady-state cold
  - fastpath 中位数：`24630ms`
  - cargo_bazel 中位数：`71300ms`
  - speedup：`2.895x`
- steady-state hot
  - fastpath 中位数：`10810ms`
  - cargo_bazel 中位数：`54070ms`
  - speedup：`5.002x`
- first-generation repin
  - fastpath 中位数：`31840ms`
  - cargo_bazel 中位数：`71990ms`
  - speedup：`2.261x`

当前本地状态：

- `examples/fastpath_ripgrep/benchmark.sh validate`：通过
- `examples/fastpath_ripgrep/benchmark.sh profile`：通过
- `examples/fastpath_ripgrep/benchmark.sh benchmark`：通过
- `examples/fastpath_ripgrep/project_e2e.sh correctness`：通过
- `examples/fastpath_ripgrep/project_e2e.sh benchmark`：通过

### Project end-to-end benchmark

project end-to-end benchmark 由
`examples/fastpath_ripgrep/project_e2e.sh` 提供。它直接对比本地 checkout：

- baseline：`/Users/dengjiahong/repo/ripgrep_baseline` 加
  `/Users/dengjiahong/repo/rules_rust_baseline`
- fastpath：`/Users/dengjiahong/repo/ripgrep` 加
  `/Users/dengjiahong/repo/rules_rust`

两边都向 `crates_repository` 传入同一组 10 个 ripgrep workspace manifest；
这是 same-Cargo-workspace manifest normalization 场景。fastpath 会确认每个
manifest 都属于同一个 Cargo workspace，归一到该 workspace root，再从 root
manifest 渲染。这个 benchmark 不表示支持把多个彼此独立的 Cargo workspace
混在同一个 `crates_repository.manifests` 列表里。

两边运行条件一致：

- `USE_BAZEL_VERSION=7.4.1`
- `--noenable_bzlmod --enable_workspace`
- `.bazelrc` 选择 stable Rust toolchain
- 每次 build 前清空 Bazel output cache

完整 correctness 覆盖会在 baseline 和 fastpath 两边都跑：

- `bazel query //...`
- `bazel build //...`
- `bazel run //:rg -- --version`
- `bazel test //...`

这覆盖 target 完整性、全项目 build、binary 可执行性、测试套件，以及 fastpath
切换是否破坏传统 `cargo_bazel` 能 build 的项目。

完整 performance 覆盖对齐 resolver/sync benchmark 的形态：

- `steady_state cold`：保留依赖 facts/lock/cache，清 Bazel output cache，然后计时
  `bazel build //...`
- `steady_state hot`：不清 Bazel output cache，连续计时无改动
  `bazel build //...`
- `first_gen repin`：清 fastpath facts/archive cache 或 baseline lockfile 生成状态，
  跑 `CARGO_BAZEL_REPIN=1 bazel sync --only=crate_index`，再计时
  `bazel build //...`

脚本会在 repin 计时前后备份并恢复 first-generation 状态，包括 fastpath 的
`Cargo.lock` 和 fastpath cache，避免本地项目 checkout 残留重新生成的
lockfile 或 cache。

当前已记录的 project benchmark 结果：

| 指标 | baseline | fastpath | 差值 |
| --- | ---: | ---: | ---: |
| steady-state cold build real time | `122.24s` | `80.95s` | `-41.29s` |
| steady-state hot build 中位数 | `2.68s` | `2.84s` | `+0.16s` |
| first-gen repin sync | `76.09s` | `38.93s` | `-37.16s` |
| first-gen repin build | `61.25s` | `56.55s` | `-4.70s` |
| first-gen repin sync plus build | `137.34s` | `95.48s` | `-41.86s` |

解读：project end-to-end 的冷启动收益主要来自 repository resolution/loading。
两边最终构建的是同一个项目目标和 action 集合；hot no-change build 基本持平。
first-gen repin 现在使用 Cargo-native fastpath 渲染，supported fastpath
路径不再支付 cargo-bazel generator/bootstrap 成本。

### 分阶段 profiling

当前 profiling 已经覆盖了预期里的关键阶段。

已覆盖 phase：

- `cargo_metadata_no_deps`
- `cargo_metadata_full`
- `download_registry_metadata`
- `inspect_external_crates`
- `write_root_build_bazel`
- `write_data_bzl`
- `write_defs_bzl`

这和要求的 profiling 维度是一一对应的：

- `cargo metadata --no-deps`：已覆盖
- 可选的 full metadata：已覆盖
- sparse index 下载：已覆盖
- crate manifest inspect：已覆盖
- BUILD/data/defs 渲染：已覆盖，而且已经拆分成三个独立 phase

最近一次 warm-cache profile 来自 `examples/fastpath_ripgrep/benchmark.sh profile`：

- `total = 640.864ms`
- `cargo_metadata_no_deps = 25.089ms`，其中 `cache_hit = True` 且
  `input_manifests = 10`
- `download_registry_metadata = 28.293ms`
- `inspect_external_crates = 23.784ms`
- `write_root_build_bazel = 23.421ms`
- `write_data_bzl = 23.398ms`
- `write_defs_bzl = 17.972ms`

## 结论

从实际收益、实现结构、回归覆盖和 profiling 粒度来看，当前 WORKSPACE
fastpath 已经在实用层面完成了对 `rules_rs` 性能思路的对齐。

剩余未完全对齐的部分，更多是实现形式差异或高风险优化项，而不是当前阶段的
能力缺口。就现在这个阶段来说，基本面已经覆盖到位，符合预期。
