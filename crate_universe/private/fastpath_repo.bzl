"""Repository rule used by the experimental lockfile fastpath backend."""

load(":fastpath_spoke_render.bzl", "render_spoke_build_file")

def _copy_tree(repository_ctx, root):
    for child in root.readdir():
        repository_ctx.execute(["cp", "-R", child, repository_ctx.path(child.basename)])

def _fastpath_crate_repository_impl(repository_ctx):
    if repository_ctx.attr.path:
        _copy_tree(repository_ctx, repository_ctx.path(repository_ctx.attr.path))
    elif repository_ctx.attr.archive:
        repository_ctx.download_and_extract(
            url = "file://" + repository_ctx.attr.archive,
            sha256 = repository_ctx.attr.sha256,
            stripPrefix = repository_ctx.attr.strip_prefix,
            type = "tar.gz",
        )
    else:
        repository_ctx.download_and_extract(
            url = repository_ctx.attr.url,
            sha256 = repository_ctx.attr.sha256,
            stripPrefix = repository_ctx.attr.strip_prefix,
            type = "tar.gz",
        )

    repository_ctx.file("BUILD.bazel", render_spoke_build_file(
        repository_ctx,
        json.decode(repository_ctx.attr.render_metadata),
    ))
    repository_ctx.file(
        "WORKSPACE.bazel",
        'workspace(name = "{}")'.format(repository_ctx.name),
    )

fastpath_crate_repository = repository_rule(
    doc = "Downloads a crate archive and renders the BUILD file inside the spoke repository.",
    implementation = _fastpath_crate_repository_impl,
    attrs = {
        "archive": attr.string(
            default = "",
            doc = "Optional absolute path to a previously downloaded crate archive.",
        ),
        "render_metadata": attr.string(
            mandatory = True,
            doc = "Serialized metadata used to render the spoke BUILD file.",
        ),
        "path": attr.string(
            default = "",
            doc = "Optional local path to mirror instead of downloading an archive.",
        ),
        "sha256": attr.string(
            default = "",
            doc = "sha256 of the downloaded crate archive.",
        ),
        "strip_prefix": attr.string(
            default = "",
            doc = "Prefix to strip when extracting the crate archive.",
        ),
        "url": attr.string(
            default = "",
            doc = "URL of the crate archive.",
        ),
    },
)
