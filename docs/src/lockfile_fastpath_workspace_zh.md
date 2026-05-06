# WORKSPACE Lockfile Fastpath 快路径

[English version](./lockfile_fastpath_workspace.md)

实验性的 `resolver_backend = "lockfile_fastpath"` 会让 WORKSPACE 下的
`crate_universe` 更接近一个以 lockfile 为中心的 resolver。它不会在每次
同步时都执行完整的 `cargo-bazel query + splice + generate` 链路，而是优先
信任现有的 `Cargo.lock`，直接从 lockfile 元数据恢复依赖图；显式 repin 时
也优先留在 fastpath 上：直接用 Cargo 更新或生成 `Cargo.lock`，再由
fastpath 消费更新后的 lockfile 完成渲染。已有 Bazel `lockfile` 属性仍可继续
作为 facts 存储位置，但不再是 fastpath 的必需输入。

## 延伸阅读

- [WORKSPACE lockfile fastpath status](./lockfile_fastpath_workspace_status_en.md)
- [WORKSPACE lockfile fastpath migration guide](./lockfile_fastpath_workspace_guide_en.md)
- [WORKSPACE lockfile fastpath 现状总结](./lockfile_fastpath_workspace_status_zh.md)
- [WORKSPACE lockfile fastpath 迁移手册](./lockfile_fastpath_workspace_guide_zh.md)

## 目标

这个 backend 主要针对 WORKSPACE 下最常见的稳态场景优化：

- 让现有 `Cargo.lock` 保持权威
- 普通 `sync` 不再执行 `cargo-bazel query` 和 workspace splice
- 把昂贵的 registry/manifest facts 持久化，跨 Bazel output root 复用
- 把每个 crate 的 BUILD 渲染留在 spoke repository，而不是在 hub repository
  里预先做完

## 设计

fastpath backend 被刻意拆成两层。

`hub repository`

- 运行 `cargo metadata --no-deps`
- 解析 `Cargo.lock`
- 只为未命中缓存的 registry crate 下载 sparse index 元数据
- 解析 feature 和 target-specific 依赖边
- 准备 spoke 侧渲染所需的 metadata
- 写出 hub repository 文件：`BUILD.bazel`、`data.bzl`、`defs.bzl`、
  `crates.bzl`

`spoke repository`

- 落地 crate 源码
- 解析本地 `Cargo.toml`
- 探测本地源码树
- 渲染该 crate 自己的 `BUILD.bazel`

这套结构在策略上对齐了 `rules_rs`：把昂贵 facts 缓存下来，让 hub 更聚焦在
resolution，把 crate 本地 BUILD 渲染下放到 spoke repository，同时保持
WORKSPACE repository rule 兼容。

## 持久化缓存

WORKSPACE fastpath 会在 workspace 根目录维护两层缓存。

`.cargo-bazel-fastpath-cache/facts/<repo>.json`

- 用于保存 fastpath `facts`
- 当前包含：
  - `registry_entries`：从 sparse index 行裁剪出的 resolver 输入
  - `registry_inspection`：spoke 渲染准备阶段使用的 manifest 子集和源码树探测结果
  - `workspace_metadata`：same-Cargo-workspace manifest normalization 路径中，
    已验证的 `cargo metadata --no-deps` 结果
- 如果显式传入了 `lockfile = "//:..."`，这些 facts 会继续写入该文件，以兼容
  已迁移的 WORKSPACE 配置

`.cargo-bazel-fastpath-cache/archives`

- 保存已下载的 registry crate archive
- 可以跨 Bazel output base 复用
- 避免在新的 output root 上重新下载 crate tarball

这些缓存都是 advisory cache。它们只负责提速，不是依赖选择的真实来源。

## 缓存回退策略

fastpath backend 的设计原则是“失败时安全回退”。

- 如果 facts cache 不存在、为空、格式损坏，或者 schema version 不匹配，
  backend 会忽略它，并从权威输入重新计算 facts。
- 如果单个 `registry_entries` 或 `registry_inspection` fact 缺失，只会对该 crate
  重新计算，并在结束时重写缓存。
- 如果某个 archive 文件不存在，会重新下载并回填
  `.cargo-bazel-fastpath-cache/archives`。
- 如果本地 `path` 或 `git` crate 发生变化，下一次 sync 会重新读取最新的
  Cargo metadata 和 manifest。
- 如果 `manifests` 传入多个条目，fastpath 会把它当作
  same-Cargo-workspace manifest normalization：所有列出的 manifest 都必须是同一个
  Cargo workspace 的 member manifest，最终从归一后的 workspace root manifest
  渲染。不支持把多个彼此独立的 Cargo workspace 混在同一个
  `crates_repository.manifests` 列表里走 fastpath。
- workspace metadata cache 只有在记录的 `Cargo.lock`、workspace-root
  manifest，以及每个已记录 workspace member manifest 都仍然匹配当前文件时才会复用。
  任意一个输入变化时，fastpath 会安全回退到重新执行
  `cargo metadata --no-deps`，并重写缓存。
- 如果通过 `CARGO_BAZEL_REPIN=1` 请求 repin，WORKSPACE 默认会走 repin
  fastpath：直接用 Cargo 更新或生成 `Cargo.lock`，fetch 选中的 crate，按需
  刷新过期 facts，然后继续用 fastpath 渲染。
- 对仍需要 cargo-bazel generate 语义的 repin 配置，继续保留 legacy
  `cargo_bazel` repin/generate fallback。

实际运维上，这意味着缓存始终可以安全删除。删掉任意一层缓存只会让下一次
sync 变慢，不应该影响正确性。

## Profiling

设置 `CARGO_BAZEL_FASTPATH_PROFILE=1` 后，生成出的 hub repository 里会写出
`_fastpath_profile.json`。

当前 phase 含义如下：

| phase | 含义 |
| --- | --- |
| `cargo_metadata_no_deps` | 加载 workspace package metadata，但不展开第三方依赖 |
| `cargo_metadata_full` | 当 lockfile 信息不足以处理 `git`/`path` crate 时的可选 fallback metadata |
| `parse_lockfile_and_platforms` | 解析 `Cargo.lock`，并计算 cfg 解析所需的平台集合 |
| `classify_lock_packages` | 划分 workspace package、registry package 和本地 source package |
| `download_registry_templates` | 读取 sparse registry 的 `config.json`，确定 archive 下载模板 |
| `download_registry_metadata` | 为 registry crate 填充 sparse index facts，理想情况下全部命中 `registry_entries` cache |
| `prepare_resolver_inputs` | 把 package metadata 归一化为 solver 输入 |
| `resolve_dependency_targets` | 展开 target-specific dependency 的适用范围 |
| `solve_features` | 执行 feature/dependency fixpoint solver |
| `inspect_external_crates` | 准备 manifest 和源码树 inspection facts，理想情况下全部命中 `registry_inspection` cache |
| `prepare_spoke_render_metadata` | 生成传给 spoke repository 的本地 BUILD 渲染 metadata |
| `render_hub_repo_metadata` | 在内存中渲染 hub repository 内容 |
| `write_root_build_bazel` | 写出 hub 的 `BUILD.bazel` |
| `write_data_bzl` | 写出 `data.bzl` |
| `write_defs_bzl` | 写出 `defs.bzl` 和 `crates.bzl` |

最后三段被刻意拆开，是为了让渲染回归可以直接定位到根 `BUILD.bazel`、
`data.bzl` 或 `defs.bzl` 这三类输出。

## 验证与基准

当前 fastpath example 同时覆盖了正确性和性能。

`examples/fastpath_regression`

- 面向回归测试的 WORKSPACE example
- 使用单个 workspace-root manifest，覆盖最简单的 fastpath 输入形态
- 覆盖 registry、`path`、`git`、`build.rs`、proc-macro、override targets、
  annotation 覆盖面和 render-config 开关

`examples/fastpath_ripgrep`

- 使用本地 `ripgrep` checkout 和隔离生成 WORKSPACE root 的 resolver/sync
  benchmark
- baseline 和 fastpath 传入同一组 same-Cargo-workspace member manifests，
  专门覆盖传统 `cargo_bazel` multi-manifest 项目的兼容性
- 使用本地 Bazel 化 baseline 和 fastpath ripgrep checkout 的 project
  end-to-end benchmark
- 对 warm-cache sync 做 profiling，并为 resolver/sync 和项目级流程报告
  steady-state 与 first-generation 耗时

最近一次 `examples/fastpath_ripgrep` resolver/sync benchmark 结果是：

- steady-state cold sync：`24630ms` 对 `71300ms`（快 `2.895x`）
- steady-state hot sync：`10810ms` 对 `54070ms`（快 `5.002x`）
- first-generation repin benchmark：`31840ms` 对 `71990ms`（快 `2.261x`）

最近一次 project end-to-end 结果：

- correctness：baseline 和 fastpath 都通过了 `bazel query //...`、
  `bazel build //...`、`bazel run //:rg -- --version` 和
  `bazel test //...`
- steady-state cold `bazel build //...`：`80.95s` 对 `122.24s`
  real time（快 `1.510x`）
- steady-state hot `bazel build //...` 中位数：`2.84s` 对 `2.68s`
  （基本持平）
- first-generation `CARGO_BAZEL_REPIN=1` sync plus build：`95.48s` 对
  `137.34s`（快 `1.438x`）

具体数字会受到机器、Bazel 运行模式和缓存温度影响。
