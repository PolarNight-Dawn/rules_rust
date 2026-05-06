# WORKSPACE Lockfile Fastpath 迁移手册

[English version](./lockfile_fastpath_workspace_guide_en.md)

这份手册面向两类读者：

- 维护 `rules_rust` fork 的人：希望把 WORKSPACE fastpath backend 持续带下去
- 使用该 fork 的项目仓库：希望把现有 WORKSPACE 依赖流迁移到
  `resolver_backend = "lockfile_fastpath"`

## 1. 这个 backend 改变了什么

WORKSPACE fastpath 不改变 `crates_repository` 的主要使用方式，但会改变普通
`sync` 的解析路径。

它不再总是依赖完整的 `cargo-bazel query + splice + generate`，而是改为使用：

- `Cargo.lock`
- `cargo metadata --no-deps`
- sparse index 元数据
- 对 `git/path` crate 的定向 fallback

它的目标是让 lockfile 保持权威，同时把 WORKSPACE 常态 `sync` 做轻。

## 2. fork 需要带走哪些代码

如果其他 `rules_rust` fork 想保留这套 backend，核心实现主要在这些文件里：

- `crate_universe/private/crates_repository.bzl`：backend 分流、fastpath repin
  编排，以及 legacy fallback 接线。
- `crate_universe/private/fastpath_resolver.bzl`：lockfile-native 解图、
  same-Cargo-workspace manifest normalization、经过校验的 workspace metadata
  cache、sparse registry facts、feature solver 输入和 hub 渲染。
- `crate_universe/private/fastpath_repo.bzl`：spoke repository rule，负责
  materialize crate 源码并调用本地 BUILD 渲染。
- `crate_universe/private/fastpath_spoke_render.bzl`：crate-local BUILD
  渲染，包括 library、binary、build script、annotations 和 render config。
- `crate_universe/private/fastpath_cfg_parser.bzl`：解析 target `cfg(...)`，
  用于平台相关依赖。
- `crate_universe/private/fastpath_semver.bzl`：基于 lockfile graph 匹配 semver
  requirement。
- `crate_universe/private/fastpath_solver.bzl`：feature/dependency fixpoint
  solver。

配套改动还包括：

- `crate_universe/private/common_utils.bzl`：fastpath flow 复用的 execution 和
  environment 工具。
- `crate_universe/private/generate_utils.bzl`：legacy `cargo_bazel` 路径和
  unsupported fallback 场景继续使用的 generator helpers。

建议一并带走的 example 和文档：

- `examples/fastpath_smoke`
- `examples/fastpath_regression`
- `examples/fastpath_ripgrep`
- `docs/src/lockfile_fastpath_workspace.md`
- `docs/src/lockfile_fastpath_workspace_zh.md`
- `docs/src/lockfile_fastpath_workspace_status_en.md`
- `docs/src/lockfile_fastpath_workspace_status_zh.md`
- `docs/src/lockfile_fastpath_workspace_guide_en.md`
- `docs/src/lockfile_fastpath_workspace_guide_zh.md`

## 3. 项目仓库里如何启用

对 WORKSPACE 项目来说，`crates_repository` 的写法基本不变，只需要显式设置：

```python
crates_repository(
    name = "crate_index",
    cargo_lockfile = "//:Cargo.lock",
    manifests = ["//:Cargo.toml"],
    resolver_backend = "lockfile_fastpath",
)
```

必须准备好的输入：

- 已提交的 `Cargo.lock`
- 通过 `manifests` 传入的单个 workspace-root manifest，或同一个 Cargo
  workspace 内的多个 member manifests

multi-manifest 场景的边界是刻意收窄的。传入多个 manifest 时，fastpath 做的是
same-Cargo-workspace manifest normalization：通过 `cargo metadata --no-deps`
确认所有列出的 manifest 都是同一个 Cargo workspace 的 member manifest，然后从归一后的
workspace root manifest 渲染。这样可以兼容传统 `cargo_bazel` 项目列出所有
member crate 的写法，但不支持把多个彼此独立的 Cargo workspace 混在同一个
`crates_repository.manifests` 列表里。

可选的兼容输入：

- 仍然可以设置 `lockfile = "//:cargo-bazel-lock-fastpath.json"`，让 fastpath
  facts 继续写入已有 Bazel lockfile 风格缓存

关键行为：

- 普通 `sync` 会走 fastpath backend
- `CARGO_BAZEL_REPIN=1` 默认走 repin fastpath：直接用 Cargo 更新或生成
  `Cargo.lock`，再让 fastpath 消费更新后的 lockfile
- supported fastpath repin 不再需要 cargo-bazel generator
- 对仍需要 cargo-bazel generate 语义的配置，legacy `cargo_bazel`
  repin/generate 流程仍作为 fallback 保留

## 4. 预期会出现哪些缓存文件

第一次成功 `sync` 后，workspace 根目录会出现：

- `.cargo-bazel-fastpath-cache/facts/<repo>.json`
- `.cargo-bazel-fastpath-cache/archives/`

作用分别是：

- `.cargo-bazel-fastpath-cache/facts/<repo>.json`
  - 保存 fastpath facts
  - 缓存 sparse index 裁剪结果、registry inspection facts，以及
    same-Cargo-workspace manifest normalization 使用的已验证 workspace metadata
- 显式设置 `lockfile = "//:..."` 时，会继续用该路径保存 facts，以兼容旧迁移方式
- `.cargo-bazel-fastpath-cache/archives`
  - 保存 registry crate archive
  - 跨 Bazel output root 复用

这两层缓存都是 advisory cache，可以安全删除；删除后只会让下一次 sync 变慢。

workspace metadata cache 只有在记录的 `Cargo.lock`、workspace-root manifest
和已记录 workspace member manifests 都仍然匹配当前文件时才会复用；否则 fastpath
会重新执行 `cargo metadata --no-deps` 并重写缓存。

## 5. 项目仓库迁移清单

1. 先确认仓库当前已经有稳定的 WORKSPACE `crate_universe` 流程
2. 如果还没有，把 `Cargo.lock` 提交进仓库
3. 在目标 `crates_repository` 上增加
   `resolver_backend = "lockfile_fastpath"`
4. 如果仓库传入多个 manifest，确保这组 manifest 只来自同一个 Cargo
   workspace 的 member crates。多个独立 Cargo workspace 应拆成多个
   `crates_repository`
5. 如果仓库使用了仍需 legacy fallback 的 repin 配置，继续保留可用的
   cargo-bazel generator 供 fallback 使用
6. 执行：

```bash
bazel sync --only=<repo_name>
```

7. 如果需要先做一次 fastpath repin：supported repin 请求会通过 Cargo 更新或生成
   `Cargo.lock`，然后继续通过 fastpath 渲染；只有不支持的 repin 配置才会走
   legacy `cargo_bazel` fallback。

```bash
CARGO_BAZEL_REPIN=1 bazel sync --only=<repo_name>
```

8. 提交：
   - WORKSPACE 配置改动
   - 如果项目希望 CI 首次 sync 也是 warm cache，可以有意提交 fastpath facts
     cache
   - repin fastpath 更新后的 `Cargo.lock`
   - 如果本次使用了 legacy fallback，再提交对应 Bazel lockfile 更新

## 6. fork 维护者迁移清单

1. 迁入 fastpath 核心实现文件
2. 保证 `crates_repository.bzl` 的分流逻辑正确：
   - `resolver_backend = "lockfile_fastpath"` 时，普通 sync 和 supported repin
     都走 fastpath
   - 显式 repin 请求通过 Cargo 更新或生成 `Cargo.lock`，然后回到 fastpath
     渲染
   - legacy `cargo_bazel` repin/generate 路径继续作为不支持配置的 fallback
3. 连同 example 和文档一起迁入
4. 先跑正确性回归
5. 发布前再跑 ripgrep benchmark harness

## 7. 推荐验证流程

建议按这个顺序验证：

### 最小 smoke

```bash
cd examples/fastpath_smoke
bazel sync --only=fastpath_smoke_index
bazel test //:smoke_test
```

### 正确性回归

```bash
cd examples/fastpath_regression
./validate.sh
```

### fastpath profiling

```bash
cd examples/fastpath_ripgrep
./benchmark.sh prepare
./benchmark.sh profile
```

### Resolver/sync benchmark

```bash
cd examples/fastpath_ripgrep
./benchmark.sh validate
./benchmark.sh benchmark
```

### Project end-to-end correctness

对于本地 Bazel 化 ripgrep checkout，baseline `cargo_bazel` 配置和 fastpath
配置都应覆盖这些兼容性检查：

```bash
cd examples/fastpath_ripgrep
./project_e2e.sh correctness
```

它覆盖：

- `bazel query //...` 检查 target 完整性
- `bazel build //...` 检查全项目 build
- `bazel run //:rg -- --version` 检查 binary 可执行性
- `bazel test //...` 检查测试套件
- fastpath 切换是否破坏传统 `cargo_bazel` 能 build 的项目

### Project end-to-end benchmark

项目级计时使用：

```bash
cd examples/fastpath_ripgrep
./project_e2e.sh benchmark
```

它记录：

- `steady_state cold`：保留依赖 facts/lock/cache，清 Bazel output cache，然后计时
  `bazel build //...`
- `steady_state hot`：不清 Bazel output cache，连续计时无改动
  `bazel build //...`
- `first_gen repin`：清 fastpath facts/archive cache 或 baseline lockfile 生成状态，
  跑 `CARGO_BAZEL_REPIN=1 bazel sync --only=crate_index`，再计时
  `bazel build //...`

脚本会保持两边 Bazel 版本和 flags 一致，并为被计时的 build 步骤写出 Bazel
profile。

## 8. 如何读 profile 输出

设置：

```bash
CARGO_BAZEL_FASTPATH_PROFILE=1
```

hub repository 会写出 `_fastpath_profile.json`。

最值得关注的 phase：

- `cargo_metadata_no_deps`
- `cargo_metadata_full`
- `download_registry_metadata`
- `inspect_external_crates`
- `prepare_spoke_render_metadata`
- `render_hub_repo_metadata`
- `write_root_build_bazel`
- `write_data_bzl`
- `write_defs_bzl`

解读建议：

- `cargo_metadata_full` 偏高，通常说明 `git/path` fallback 成本较高
- `download_registry_metadata` 偏高，通常说明 sparse facts 还没热起来
- `inspect_external_crates` 偏高，通常说明 registry inspection facts 还没热起来
- `write_*` 偏高，说明 hub 渲染阶段有回归；现在已经按输出文件拆分

## 9. 回滚与安全性

如果迁移后需要回滚：

1. 去掉 `resolver_backend = "lockfile_fastpath"`
2. 回到原来的标准 `cargo_bazel` WORKSPACE 流程
3. 如有需要，删除：
   - `.cargo-bazel-fastpath-cache/facts/<repo>.json`
   - `.cargo-bazel-fastpath-cache/archives`

之所以可以安全回滚，是因为 fastpath cache 只负责提速，不是依赖选择的真实来源。

## 10. 当前推荐使用方式

对大多数项目来说，当前推荐模式是：

- 普通 WORKSPACE `sync` 使用 fastpath
- 更新依赖时使用 Cargo-native fastpath 渲染
- 保留 legacy repin/generate fallback 覆盖暂不支持的 repin 模式
- 保留 ripgrep harness 或类似真实仓库 benchmark，作为后续回归检查

这样已经可以拿到明显收益，同时不需要继续追更高风险的实现。当前已经落地的
repository-rule-local prefetching 继续保留即可。
