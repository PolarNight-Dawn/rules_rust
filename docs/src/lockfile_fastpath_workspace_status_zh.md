# WORKSPACE Lockfile Fastpath 现状总结

[English version](./lockfile_fastpath_workspace_status_en.md)

这份文档记录实验性 `resolver_backend = "lockfile_fastpath"` backend 的当前阶段。
它是 WORKSPACE fastpath 工作的状态和决策记录。

设计细节见[概览文档](./lockfile_fastpath_workspace_zh.md)。命令和迁移步骤见
[迁移手册](./lockfile_fastpath_workspace_guide_zh.md)。

## 阶段结论

当前阶段目标已经完成。

backend 已经从：

- `rules_rs`：lockfile-native
- `rules_rust` fastpath：lockfile-consume fast path + legacy repin fallback

推进到：

- `rules_rs`：lockfile-native
- `rules_rust` fastpath：lockfile-consume fast path + Cargo-native repin
  fastpath + unsupported case legacy fallback

当前实现已经达到这一阶段目标：拿到明显 WORKSPACE 性能收益，同时保持兼容性稳定。

## 已完成能力

核心 backend：

- `crates_repository` 支持 `resolver_backend = "lockfile_fastpath"`。
- 普通 sync 通过 lockfile fastpath 解图和渲染。
- supported `CARGO_BAZEL_REPIN=1` 直接通过 Cargo 更新或生成 `Cargo.lock`，
  然后回到 fastpath render。
- unsupported repin 配置回退到 legacy `cargo_bazel`。
- fastpath 支持 same-Cargo-workspace multi-manifest normalization。
- warm same-Cargo-workspace sync 可以复用经过校验的 `workspace_metadata`
  facts，避免不必要的 `cargo metadata --no-deps` 重跑。
- sparse registry facts、registry inspection facts 和 crate archives 可跨
  Bazel output root 缓存。
- hub/spoke 渲染把 crate-local inspection 和 BUILD 渲染留在 spoke repository。
- 通过 `CARGO_BAZEL_FASTPATH_PROFILE=1` 支持分阶段 profiling。

实现文件：

- `crate_universe/private/crates_repository.bzl`：backend 分流、fastpath repin
  编排和 legacy fallback 接线
- `crate_universe/private/fastpath_resolver.bzl`：lockfile-native resolution、
  same-Cargo-workspace normalization、facts/cache、solver 输入、hub 渲染和
  profiling
- `crate_universe/private/fastpath_repo.bzl`：spoke repository rule
- `crate_universe/private/fastpath_spoke_render.bzl`：crate-local BUILD 渲染
- `crate_universe/private/fastpath_cfg_parser.bzl`：target `cfg(...)` 解析
- `crate_universe/private/fastpath_semver.bzl`：semver requirement 匹配
- `crate_universe/private/fastpath_solver.bzl`：feature/dependency fixpoint
  solver
- `crate_universe/private/common_utils.bzl`：共用 execution/environment helpers
- `crate_universe/private/generate_utils.bzl`：standard backend 和 unsupported
  fallback 使用的 legacy generator helpers

examples 和 harnesses：

- `examples/fastpath_smoke`：最小 WORKSPACE smoke
- `examples/fastpath_regression`：correctness regression 矩阵
- `examples/fastpath_regression/validate_boundaries.sh`：聚焦边界回归，覆盖
  workspace metadata cache hit/miss、same-workspace multi-manifest
  normalization、independent workspace rejection/fallback、supported repin
  fastpath 和 legacy fallback
- `examples/fastpath_ripgrep/benchmark.sh`：resolver/sync benchmark 和 warm
  profile
- `examples/fastpath_ripgrep/project_e2e.sh`：project end-to-end correctness
  和 performance benchmark

## 与 `rules_rs` 的对齐情况

### 本阶段关键部分已经对齐

- lockfile-first dependency resolution
- 持久化 resolver facts
- 持久化 archive cache
- sparse-index-driven registry metadata
- hub/spoke split
- supported case 的 Cargo-native fastpath repin
- phase-level profiling

### WORKSPACE 特有的实现取舍

- WORKSPACE 使用 sidecar facts，或显式兼容 `lockfile`，而不是 `mctx.facts`。
  原因：WORKSPACE repository rule 没有 module-extension facts API。
- 下载编排是 repository-rule-local，而不是共享 module-extension downloader。
  原因：当前本地 prefetch 模型已经拿到收益，风险更低。
- `cargo metadata --no-deps` 仍然是 workspace metadata 的权威 fallback。
  原因：path/git crates、workspace members 和 feature source 信息仍需要 Cargo
  作为 correctness fallback。
- hub 保留 alias、proc macro、build script 和 `links` 的最小前置 facts。
  原因：这些 facts 是生成正确 hub targets 和 aliases 的必要输入。

这些不是“不支持的功能”，而是为了安全适配 WORKSPACE repository rule 保留的实现形态差异。

### 当前阶段不纳入范围

以下能力未纳入本阶段 fastpath 范围：

- 未在一个 `crates_repository.manifests` 中支持混入多个彼此独立的 Cargo
  workspace。
  原因：一个 repository rule 应对应一个 Cargo workspace root 和一份 lockfile。
- 未实现 `packages` 属性的 native fastpath 支持。
  原因：该路径使用不同的 selection/generate 模型，继续走 legacy
  `cargo_bazel` 更稳。
- 未实现 Bzlmod/module-extension 完整对齐。
  原因：当前阶段专注 WORKSPACE 兼容路径。
- 未删除 legacy `cargo_bazel` splice/generate。
  原因：standard backend 和 unsupported repin fallback 仍需要它。
- 未 fastpath 化依赖 `skip_cargo_lockfile_overwrite` 或
  `strip_internal_dependencies_from_cargo_lockfile` 的 repin 配置。
  原因：这些选项带有 legacy lockfile/write-back 语义。

## 验证覆盖

Correctness 覆盖：

- `examples/fastpath_smoke`：最小 fastpath sync 和 test
- `examples/fastpath_regression/validate.sh`：registry、`path`、`git`、
  build script、proc macro、overrides、annotations、data/compile_data globs 和
  render config，并通过 `validate_boundaries.sh` 覆盖小粒度边界检查
- `examples/fastpath_regression/validate_boundaries.sh`：workspace metadata
  cache hit/miss、same-Cargo-workspace multi-manifest normalization、
  independent workspace rejection 和 repin fallback、不依赖 generator 的
  supported repin fastpath，以及 unsupported repin 设置的 legacy fallback
- `examples/fastpath_ripgrep/project_e2e.sh correctness`：baseline 和 fastpath
  都跑：
  - `bazel query //...`
  - `bazel build //...`
  - `bazel run //:rg -- --version`
  - `bazel test //...`

Performance 覆盖：

- `examples/fastpath_ripgrep/benchmark.sh benchmark`：resolver/sync 的
  steady-state cold、steady-state hot 和 first-generation repin
- `examples/fastpath_ripgrep/project_e2e.sh benchmark`：project end-to-end 的
  steady-state cold、steady-state hot 和 first-generation repin plus build
- `examples/fastpath_ripgrep/benchmark.sh profile`：warm-cache phase profile

最近一次记录的本地状态：

- `examples/fastpath_regression/validate.sh`：通过
- `examples/fastpath_regression/validate_boundaries.sh`：通过
- `examples/fastpath_ripgrep/benchmark.sh validate`：通过
- `examples/fastpath_ripgrep/benchmark.sh profile`：通过
- `examples/fastpath_ripgrep/benchmark.sh benchmark`：通过
- `examples/fastpath_ripgrep/project_e2e.sh correctness`：通过
- `examples/fastpath_ripgrep/project_e2e.sh benchmark`：通过

## 已记录结果

Resolver/sync benchmark，使用
`RIPGREP_DIR=/Users/dengjiahong/repo/ripgrep`：

| scenario | fastpath | cargo_bazel baseline | speedup |
| --- | ---: | ---: | ---: |
| steady-state cold sync | `24630ms` | `71300ms` | `2.895x` |
| steady-state hot sync | `10810ms` | `54070ms` | `5.002x` |
| first-generation repin | `31840ms` | `71990ms` | `2.261x` |

Project end-to-end benchmark：

- baseline：`/Users/dengjiahong/repo/ripgrep_baseline` 加
  `/Users/dengjiahong/repo/rules_rust_baseline`
- fastpath：`/Users/dengjiahong/repo/ripgrep` 加
  `/Users/dengjiahong/repo/rules_rust`
- 两边都传入同一组 10 个 same-Cargo-workspace ripgrep manifests
- `USE_BAZEL_VERSION=7.4.1`
- `--noenable_bzlmod --enable_workspace`
- `.bazelrc` 选择 stable Rust toolchain

| metric | baseline | fastpath | delta |
| --- | ---: | ---: | ---: |
| steady-state cold `bazel build //...` real time | `122.24s` | `80.95s` | `-41.29s` |
| steady-state hot `bazel build //...` median | `2.68s` | `2.84s` | `+0.16s` |
| first-gen repin sync | `76.09s` | `38.93s` | `-37.16s` |
| first-gen repin build | `61.25s` | `56.55s` | `-4.70s` |
| first-gen repin sync plus build | `137.34s` | `95.48s` | `-41.86s` |

解读：

- Resolver/sync 收益大，是因为 fastpath 避免完整
  `cargo-bazel query + splice + generate`。
- Project cold build 收益主要来自 repository resolution/loading。
- Hot no-change project build 基本持平，因为两边最终构建同一组 project targets
  和 actions。
- First-generation repin 在 supported fastpath 路径上更快，因为不再支付
  cargo-bazel generator/bootstrap 成本。

最近一次 warm-cache profile：

- `total = 640.864ms`
- `cargo_metadata_no_deps = 25.089ms`，其中 `cache_hit = True` 且
  `input_manifests = 10`
- `download_registry_metadata = 28.293ms`
- `inspect_external_crates = 23.784ms`
- `write_root_build_bazel = 23.421ms`
- `write_data_bzl = 23.398ms`
- `write_defs_bzl = 17.972ms`

## 下一阶段

建议下一阶段目标：PR-ready hardening 和 upstreaming preparation。

具体工作：

- 决定哪些 smoke/regression 检查进入 CI，包括新的小粒度边界回归。
- 决定 ripgrep resolver/sync 和 project end-to-end benchmark 的运行频率。
- 准备 upstream PR 描述、迁移说明、风险说明和 fallback 解释。
- 决定当前工作是否拆成更易 review 的 commits。
