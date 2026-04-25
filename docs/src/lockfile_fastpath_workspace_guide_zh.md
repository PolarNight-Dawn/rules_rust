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
- Bazel lockfile
- `cargo metadata --no-deps`
- sparse index 元数据
- 对 `git/path` crate 的定向 fallback

它的目标是让 lockfile 保持权威，同时把 WORKSPACE 常态 `sync` 做轻。

## 2. fork 需要带走哪些代码

如果其他 `rules_rust` fork 想保留这套 backend，核心实现主要在这些文件里：

- `crate_universe/private/crates_repository.bzl`
- `crate_universe/private/fastpath_resolver.bzl`
- `crate_universe/private/fastpath_repo.bzl`
- `crate_universe/private/fastpath_spoke_render.bzl`
- `crate_universe/private/fastpath_cfg_parser.bzl`
- `crate_universe/private/fastpath_semver.bzl`
- `crate_universe/private/fastpath_solver.bzl`

配套改动还包括：

- `crate_universe/private/common_utils.bzl`
- `crate_universe/private/generate_utils.bzl`

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
    lockfile = "//:cargo-bazel-lock-fastpath.json",
    manifests = ["//:Cargo.toml"],
    resolver_backend = "lockfile_fastpath",
)
```

必须准备好的输入：

- 已提交的 `Cargo.lock`
- 已提交的 Bazel lockfile
- 通过 `manifests` 传入的一个或多个 manifest

关键行为：

- 普通 `sync` 会走 fastpath backend
- `CARGO_BAZEL_REPIN=1` 会回退到标准 repin 流程

## 4. 预期会出现哪些缓存文件

第一次成功 `sync` 后，workspace 根目录会出现：

- `cargo-bazel-lock-fastpath.json`
- `.cargo-bazel-fastpath-cache/archives/`

作用分别是：

- `cargo-bazel-lock-fastpath.json`
  - 保存 fastpath facts
  - 缓存 sparse index 裁剪结果和 registry inspection facts
- `.cargo-bazel-fastpath-cache/archives`
  - 保存 registry crate archive
  - 跨 Bazel output root 复用

这两层缓存都是 advisory cache，可以安全删除；删除后只会让下一次 sync 变慢。

## 5. 项目仓库迁移清单

1. 先确认仓库当前已经有稳定的 WORKSPACE `crate_universe` 流程
2. 如果还没有，把 `Cargo.lock` 提交进仓库
3. 新增专用 Bazel lockfile，例如 `cargo-bazel-lock-fastpath.json`
4. 在目标 `crates_repository` 上增加
   `resolver_backend = "lockfile_fastpath"`
5. 执行：

```bash
bazel sync --only=<repo_name>
```

6. 如果需要先做一次标准 repin：

```bash
CARGO_BAZEL_REPIN=1 bazel sync --only=<repo_name>
```

7. 提交：
   - WORKSPACE 配置改动
   - `cargo-bazel-lock-fastpath.json`
   - 其他更新后的 Bazel lockfile 内容

## 6. fork 维护者迁移清单

1. 迁入 fastpath 核心实现文件
2. 保证 `crates_repository.bzl` 的分流逻辑正确：
   - `resolver_backend = "lockfile_fastpath"` 且非 repin 时走 fastpath
   - repin 时仍然可走标准流程
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

### A/B 验证和 benchmark

```bash
cd examples/fastpath_ripgrep
./benchmark.sh validate
./benchmark.sh benchmark
```

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
   - `cargo-bazel-lock-fastpath.json`
   - `.cargo-bazel-fastpath-cache/archives`

之所以可以安全回滚，是因为 fastpath cache 只负责提速，不是依赖选择的真实来源。

## 10. 当前推荐使用方式

对大多数项目来说，当前推荐模式是：

- 普通 WORKSPACE `sync` 使用 fastpath
- 更新依赖时继续使用标准 repin 流程
- 保留 ripgrep harness 或类似真实仓库 benchmark，作为后续回归检查

这样已经可以拿到明显收益，同时避免更高风险的实现，例如异步 downloader 编排。
