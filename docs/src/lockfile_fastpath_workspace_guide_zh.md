# WORKSPACE Lockfile Fastpath 迁移手册

[English version](./lockfile_fastpath_workspace_guide_en.md)

这份手册说明如何在 WORKSPACE 项目里启用、验证和回滚
`resolver_backend = "lockfile_fastpath"`，也列出 `rules_rust` fork 需要带走哪些
内容才能继续维护这套 backend。

运行模型见[概览文档](./lockfile_fastpath_workspace_zh.md)。当前结果和下一阶段工作见
[现状总结](./lockfile_fastpath_workspace_status_zh.md)。

## 快速判断

适合启用 fastpath 的项目：

- 使用 WORKSPACE `crates_repository`
- 已提交 `Cargo.lock`
- `manifests` 指向一个 Cargo workspace root，或同一个 Cargo workspace 的多个
  members
- 依赖更新可以表示为 Cargo 更新或生成 `Cargo.lock`

继续使用 legacy backend，或预期走 fallback 的项目：

- 使用 `packages`
- 在一个 `crates_repository` 里混入多个独立 Cargo workspace
- 使用 `skip_cargo_lockfile_overwrite`
- 使用 `strip_internal_dependencies_from_cargo_lockfile`
- 依赖其他 legacy `cargo_bazel` generate 语义

## 在项目中启用

在目标 `crates_repository` 上设置 `resolver_backend = "lockfile_fastpath"`。

```python
crates_repository(
    name = "crate_index",
    cargo_lockfile = "//:Cargo.lock",
    manifests = ["//:Cargo.toml"],
    resolver_backend = "lockfile_fastpath",
)
```

必须输入：

- 已提交的 `Cargo.lock`
- 单个 workspace-root manifest，或多个 same-Cargo-workspace member manifests

可选兼容输入：

- 如果项目希望把 fastpath facts 存到 Bazel lockfile 风格文件中，可以设置
  `lockfile = "//:cargo-bazel-lock-fastpath.json"`

对新迁移项目来说，`lockfile` 属性是可选的。不设置时，facts 会写到
`.cargo-bazel-fastpath-cache/facts/<repo>.json`。

## Multi-Manifest 规则

多个 manifest 只支持 same-Cargo-workspace normalization。fastpath 会运行
`cargo metadata --no-deps`，确认每个列出的 manifest 都属于同一个 Cargo
workspace，然后从归一后的 workspace-root manifest 渲染。

这用于兼容传统 `cargo_bazel` 项目列出每个 member crate 的写法。fastpath 未支持
把多个彼此独立的 Cargo workspace 放进同一个 `crates_repository.manifests`。

原因：一个 repository rule 应对应一个 Cargo workspace root 和一份 lockfile。
独立 workspace 应拆成多个 `crates_repository`。

## Sync 和 Repin 行为

普通 sync：

```bash
bazel sync --only=<repo_name>
```

设置 `resolver_backend = "lockfile_fastpath"` 后，普通 sync 会从已提交的
`Cargo.lock` 和 fastpath facts 解图。

Supported repin：

```bash
CARGO_BAZEL_REPIN=1 bazel sync --only=<repo_name>
```

supported repin 请求会：

- 解析 repin 请求
- 通过 Cargo 更新或生成 `Cargo.lock`
- 运行 `cargo fetch`
- 写回 workspace `Cargo.lock`
- 按需刷新过期 fastpath facts
- 通过 fastpath 渲染

supported fastpath repin 不需要 cargo-bazel generator。

unsupported repin 配置会回退到 legacy `cargo_bazel` repin/generate。如果项目依赖
这些 fallback 配置，需要继续保留可用的 generator。

## 预期缓存文件

第一次成功 sync 后，workspace 里可能出现：

- `.cargo-bazel-fastpath-cache/facts/<repo>.json`
- `.cargo-bazel-fastpath-cache/archives/`

facts 文件保存 sparse registry facts、registry inspection facts 和经过校验的
workspace metadata facts。archive 目录保存 registry crate archives，用于跨 Bazel
output root 复用。

这些缓存都是 advisory cache，可以安全删除；下一次 sync 会重新计算或下载需要的内容。

workspace metadata facts 只有在记录的 `Cargo.lock`、workspace-root manifest 和
每个已记录 workspace member manifest 仍然匹配当前文件时才会复用。

## 项目迁移清单

1. 确认现有 WORKSPACE `crate_universe` 流程是健康的。
2. 如果还没有提交 `Cargo.lock`，先提交它。
3. 在目标 `crates_repository` 增加
   `resolver_backend = "lockfile_fastpath"`。
4. 如果传入多个 manifest，确认它们都属于同一个 Cargo workspace。
5. 如果仓库使用仍不在 fastpath 范围内、因此需要 fallback 的 repin 设置，保留
   cargo-bazel generator。
6. 运行 `bazel sync --only=<repo_name>`。
7. 如需 repin，运行
   `CARGO_BAZEL_REPIN=1 bazel sync --only=<repo_name>`。
8. 提交 WORKSPACE 改动，以及 repin 产生的 `Cargo.lock` 更新。
9. 只有在项目明确希望 CI 首次 sync 是 warm cache 时，才提交 fastpath facts。
10. 如果本次使用 legacy fallback repin，照常提交重新生成的 Bazel lockfile 内容。

## 验证流程

推荐顺序：

```bash
cd examples/fastpath_smoke
bazel sync --only=fastpath_smoke_index
bazel test //:smoke_test
```

```bash
cd examples/fastpath_regression
./validate.sh
```

`validate.sh` 已包含小粒度边界回归。如果只想运行较小的边界检查：

```bash
cd examples/fastpath_regression
./validate_boundaries.sh
```

```bash
cd examples/fastpath_ripgrep
./benchmark.sh prepare
./benchmark.sh validate
./benchmark.sh profile
./benchmark.sh benchmark
```

对于本地 Bazel 化 ripgrep checkouts：

```bash
cd examples/fastpath_ripgrep
./project_e2e.sh correctness
./project_e2e.sh benchmark
```

`project_e2e.sh correctness` 会在 baseline 和 fastpath 两边都跑：

- `bazel query //...`
- `bazel build //...`
- `bazel run //:rg -- --version`
- `bazel test //...`

`project_e2e.sh benchmark` 会记录：

- `steady_state cold`：保留 dependency facts/lock/cache，清 Bazel output cache，
  然后计时 `bazel build //...`
- `steady_state hot`：保留 Bazel output cache，计时无改动 `bazel build //...`
- `first_gen repin`：清 fastpath facts/archive cache 或 baseline lockfile 生成
  状态，运行 `CARGO_BAZEL_REPIN=1 bazel sync --only=crate_index`，再计时
  `bazel build //...`

## 读取 Profile

通过下面的环境变量启用 profiling：

```bash
CARGO_BAZEL_FASTPATH_PROFILE=1
```

hub repository 会写出 `_fastpath_profile.json`。

优先看这些 phase：

- `cargo_metadata_no_deps`：workspace metadata load 或 cache hit
- `cargo_metadata_full`：`git`/`path` crates 的定向 fallback
- `download_registry_metadata`：sparse registry facts
- `inspect_external_crates`：registry inspection facts
- `prepare_spoke_render_metadata`：spoke metadata 准备
- `render_hub_repo_metadata`：内存中的 hub 渲染
- `write_root_build_bazel`、`write_data_bzl`、`write_defs_bzl`：按文件族拆分的
  hub 输出写入

## 回滚

项目回滚步骤：

1. 删除 `resolver_backend = "lockfile_fastpath"`。
2. 回到原有 `cargo_bazel` 配置。
3. 如有需要，删除：
   - `.cargo-bazel-fastpath-cache/facts/<repo>.json`
   - `.cargo-bazel-fastpath-cache/archives`

fastpath cache 不是依赖选择的真实来源，因此删除它们不会改变正确性。

## Fork 维护者清单

这些实现文件需要一起带走：

- `crate_universe/private/crates_repository.bzl`
- `crate_universe/private/fastpath_resolver.bzl`
- `crate_universe/private/fastpath_repo.bzl`
- `crate_universe/private/fastpath_spoke_render.bzl`
- `crate_universe/private/fastpath_cfg_parser.bzl`
- `crate_universe/private/fastpath_semver.bzl`
- `crate_universe/private/fastpath_solver.bzl`
- `crate_universe/private/common_utils.bzl`
- `crate_universe/private/generate_utils.bzl`

这些 examples 和文档也需要一起带走：

- `examples/fastpath_smoke`
- `examples/fastpath_regression`
- `examples/fastpath_ripgrep`
- `docs/src/lockfile_fastpath_workspace.md`
- `docs/src/lockfile_fastpath_workspace_zh.md`
- `docs/src/lockfile_fastpath_workspace_status_en.md`
- `docs/src/lockfile_fastpath_workspace_status_zh.md`
- `docs/src/lockfile_fastpath_workspace_guide_en.md`
- `docs/src/lockfile_fastpath_workspace_guide_zh.md`

发布 fork 前：

1. 跑 smoke 和 regression checks。
2. 跑 ripgrep resolver/sync benchmark。
3. 如果本地 checkouts 可用，跑 ripgrep project end-to-end correctness。
4. 确认 unsupported repin cases 仍会回退到 legacy `cargo_bazel`。
