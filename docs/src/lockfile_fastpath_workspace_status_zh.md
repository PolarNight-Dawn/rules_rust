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
- 持久化 resolver facts：fastpath facts 会写入
  `cargo-bazel-lock-fastpath.json`，并可跨 Bazel output root 复用。
- 持久化 archive cache：registry crate archive 会写入
  `.cargo-bazel-fastpath-cache/archives`，避免重复下载。
- hub/spoke 分层：hub repository 负责依赖解图和元数据准备，spoke
  repository 在本地渲染每个 crate 的 `BUILD.bazel`。
- sparse index 驱动：registry crate 基于 `Cargo.lock` 和 sparse index
  数据解析，`git/path` crate 再按需回退到 metadata。
- 分阶段 profiling：后续做性能回归和瓶颈分析已经有足够细的 phase 数据。

### 还没完全对齐的部分

仍然有一些实现层面的差异，没有做到和 `rules_rs` 一比一。

- 没有 `module extension` 层的 `mctx.facts`，而是用 WORKSPACE lockfile
  和 sidecar cache 模拟。
- 没有 extension 层面的异步 downloader 编排；当前 repository rule
  仍然是更保守的同步执行模型。
- `cargo metadata --no-deps` 仍然会在每次 sync 时执行。
- hub 侧仍保留少量前置分类逻辑，用于 alias、proc-macro 和 build-script。
- `git/path` crate 仍然更依赖定向 `cargo metadata` fallback。

### 在达到预期收益的前提下，剩余部分还有没有必要继续

如果前提是“收益已经达到预期，并优先保证安全、稳定、可维护”，那么这些剩余
差异目前都不是必须继续追的。

当前已经拿到的收益已经足够说明 backend 成立：

- steady-state cold sync：相对 baseline 提升 `2.686x`
- steady-state hot sync：相对 baseline 提升 `5.059x`
- first-generation repin benchmark：相对 baseline 提升 `2.428x`

在这个前提下，更合理的策略是：

- 把当前 WORKSPACE fastpath 作为稳定方向收口
- 先补强文档、回归和防御性逻辑
- 只有在真实仓库再次出现新瓶颈时，再继续追剩下的差异

更适合作为后续低风险优化项的，只有两类：

1. 继续减少不必要的 `cargo metadata --no-deps`
2. 再压一点 hub 侧残余的前置 inspection

异步/并行 downloader 虽然理论上仍有收益，但风险最高，目前不建议默认继续。

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

### 性能基准

性能基准当前由 `examples/fastpath_ripgrep` 提供，它使用本地 `ripgrep`
checkout 做真实 Cargo workspace 的 A/B 对比。

这个 harness 已经把两个 backend 拆到彼此独立的 WORKSPACE 里：

- fastpath backend
- baseline `cargo_bazel` backend

这样可以避免互相污染，保证 benchmark 结果可信。

当前基准结果来自 `.tmp/fastpath_ripgrep_runs/benchmark_full.log`：

- steady-state cold
  - fastpath 中位数：`25930ms`
  - cargo_bazel 中位数：`69660ms`
  - speedup：`2.686x`
- steady-state hot
  - fastpath 中位数：`10730ms`
  - cargo_bazel 中位数：`54280ms`
  - speedup：`5.059x`
- first-generation repin
  - fastpath 中位数：`53110ms`
  - cargo_bazel 中位数：`128950ms`
  - speedup：`2.428x`

当前本地状态：

- `examples/fastpath_ripgrep/benchmark.sh validate`：通过

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

最近一次 warm-cache profile 来自 `.tmp/fastpath_ripgrep_runs/profile.log`：

- `cargo_metadata_no_deps = 432.686ms`
- `download_registry_metadata = 30.532ms`
- `inspect_external_crates = 32.406ms`
- `write_root_build_bazel = 24.155ms`
- `write_data_bzl = 28.424ms`
- `write_defs_bzl = 24.558ms`

## 结论

从实际收益、实现结构、回归覆盖和 profiling 粒度来看，当前 WORKSPACE
fastpath 已经在实用层面完成了对 `rules_rs` 性能思路的对齐。

剩余未完全对齐的部分，更多是实现形式差异或高风险优化项，而不是当前阶段的
能力缺口。就现在这个阶段来说，基本面已经覆盖到位，符合预期。
