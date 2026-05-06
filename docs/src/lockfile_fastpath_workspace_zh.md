# WORKSPACE Lockfile Fastpath 快路径

[English version](./lockfile_fastpath_workspace.md)

`resolver_backend = "lockfile_fastpath"` 是面向 WORKSPACE 用户的实验性
`crates_repository` backend。它把依赖流程改成 lockfile-first：普通 sync 信任
已提交的 `Cargo.lock`，跳过完整的
`cargo-bazel query + splice + generate` 链路，并通过轻量的 hub/spoke 结构渲染
外部 crate。

显式 repin 在受支持配置下也会留在 fastpath：先由 Cargo 更新或生成
`Cargo.lock`，再由 fastpath resolver 消费更新后的 lockfile 并完成渲染。仍依赖
legacy `cargo_bazel` generate 语义的配置会回退到 legacy 路径。

## 文档地图

- [现状总结](./lockfile_fastpath_workspace_status_zh.md)：当前阶段、已完成内容、
  范围边界、测试覆盖和已记录 benchmark 结果。
- [迁移手册](./lockfile_fastpath_workspace_guide_zh.md)：如何启用、验证、回滚，
  以及 fork 如何带走这套 backend。

## 范围和边界

fastpath backend 面向 WORKSPACE manifest + Cargo.lock 流程。

支持的输入形态：

- `manifests` 中传入单个 workspace-root manifest
- 传入多个 manifest，但所有 manifest 必须属于同一个 Cargo workspace
- 已提交的 `Cargo.lock`
- 基于 sparse registry metadata 的 registry crate
- 对 `git` 和 `path` crate 的定向 metadata fallback
- supported `CARGO_BAZEL_REPIN=1` 请求走 Cargo-native repin fastpath

当前 fastpath 不纳入范围：

- 未在一个 `crates_repository.manifests` 中支持混入多个彼此独立的 Cargo
  workspace。
  原因：一个 repository rule 应对应一个 Cargo workspace root 和一份 lockfile。
- 未实现 `packages` 属性的 native fastpath 处理。
  原因：`packages` 使用不同的 selection/generate 模型。
- 未 fastpath 化依赖 `skip_cargo_lockfile_overwrite` 或
  `strip_internal_dependencies_from_cargo_lockfile` 的 repin 配置。
  原因：这些选项带有 legacy lockfile/write-back 语义。

不支持的 repin 配置会走 legacy `cargo_bazel` fallback，而不是静默改变行为。

## 运行模型

生成出的 repository 拆成 hub 和 crate-local spoke repositories。

hub repository 负责：

- 运行 `cargo metadata --no-deps`，或复用经过校验的 workspace metadata facts
- 解析 `Cargo.lock`
- 为未命中缓存的 registry crate 拉取 sparse registry 行
- 解析 features 和 target-specific dependency edges
- 准备 spoke repository 需要的 metadata
- 写出 `BUILD.bazel`、`data.bzl`、`defs.bzl` 和 `crates.bzl`

spoke repository 负责：

- materialize 单个 crate source
- 解析该 crate 本地 `Cargo.toml`
- 探测本地源码文件
- 渲染该 crate 的 `BUILD.bazel`

这对齐了 `rules_rs` 的核心性能思路，同时仍留在 WORKSPACE repository rule 模型内：
缓存昂贵 facts，让 hub 聚焦 resolution，把 crate-local BUILD 渲染下放到 spoke。

## 持久化缓存

fastpath 会在 workspace 根目录维护 advisory cache。

`.cargo-bazel-fastpath-cache/facts/<repo>.json`

- `registry_entries`：裁剪成 resolver 输入的 sparse index 行
- `registry_inspection`：spoke 渲染前使用的 manifest 子集和源码树探测结果
- `workspace_metadata`：same-Cargo-workspace manifest normalization 使用的已验证
  `cargo metadata --no-deps` 结果

`.cargo-bazel-fastpath-cache/archives`

- 已下载的 registry crate archives
- 可跨 Bazel output root 复用

如果显式配置了 `lockfile = "//:..."`，fastpath facts 会继续写入该路径以保持兼容。
新 fastpath 用户不需要配置 `lockfile`。

## 回退规则

这些缓存都是 advisory cache，可以安全删除。

- facts 缺失、损坏或 schema 不匹配时会被忽略并重新计算。
- 单个 registry entry 或 inspection fact 缺失时，只重算对应 crate。
- archive 缺失时会重新下载。
- 本地 `path` 或 `git` crate 变化时，会重新读取 Cargo metadata 和源码树。
- `Cargo.lock`、workspace-root manifest 或已记录 workspace member manifest 变化时，
  workspace metadata cache 失效，并重新执行 `cargo metadata --no-deps`。
- supported repin 会用 Cargo 更新或生成 `Cargo.lock`，然后回到 fastpath 渲染。
- unsupported repin 配置会回退到 legacy `cargo_bazel` repin/generate。

## Profiling

设置 `CARGO_BAZEL_FASTPATH_PROFILE=1` 后，生成出的 hub repository 会写出
`_fastpath_profile.json`。

重要 phase：

| phase | 含义 |
| --- | --- |
| `cargo_metadata_no_deps` | 加载 workspace package metadata，或复用已验证 workspace metadata facts |
| `cargo_metadata_full` | 当 lockfile 信息不足以处理 `git`/`path` crate 时的可选 fallback metadata |
| `parse_lockfile_and_platforms` | 解析 `Cargo.lock` 并计算 platform cfg 数据 |
| `classify_lock_packages` | 划分 workspace、registry 和 local source packages |
| `download_registry_templates` | 读取 sparse registry `config.json` 下载模板 |
| `download_registry_metadata` | 填充 sparse registry facts，理想情况下从缓存命中 |
| `prepare_resolver_inputs` | 把 metadata 归一成 solver 输入 |
| `resolve_dependency_targets` | 应用 target-specific dependency cfg |
| `solve_features` | 执行 feature/dependency fixpoint solver |
| `inspect_external_crates` | 准备 manifest 和源码树 facts，理想情况下从缓存命中 |
| `prepare_spoke_render_metadata` | 准备每个 crate 的 spoke render metadata |
| `render_hub_repo_metadata` | 在内存中渲染 hub repository 内容 |
| `write_root_build_bazel` | 写出 hub `BUILD.bazel` |
| `write_data_bzl` | 写出 `data.bzl` |
| `write_defs_bzl` | 写出 `defs.bzl` 和 `crates.bzl` |

## 验证与基准

具体命令见迁移手册。当前覆盖按下面几层组织：

- `examples/fastpath_smoke`：最小 WORKSPACE smoke test
- `examples/fastpath_regression`：覆盖 registry、`path`、`git`、build script、
  proc macro、annotations、render config 和 fastpath 边界行为的 correctness
  regression
- `examples/fastpath_ripgrep/benchmark.sh`：resolver/sync benchmark 和 warm
  profile
- `examples/fastpath_ripgrep/project_e2e.sh`：project end-to-end
  query/build/run/test correctness，以及 steady-state cold/hot 和 first-gen
  repin performance

最新已记录结果保存在现状总结文档中。
