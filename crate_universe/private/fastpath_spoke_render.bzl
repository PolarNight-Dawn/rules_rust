"""Spoke BUILD rendering helpers for the WORKSPACE fastpath backend."""

def _platform_label(triple):
    return "@rules_rust//rust/platform:{}".format(
        triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc"),
    )

def _target_name(name):
    return name.replace("-", "_")

def _sorted_unique(values):
    return sorted({value: True for value in values}.keys())

def _shared_and_per_platform(platform_items):
    if not platform_items:
        return [], {}

    common = None
    for items in platform_items.values():
        values = {item: True for item in items}
        if common == None:
            common = values
        else:
            common = {
                key: True
                for key in common.keys()
                if key in values
            }

    shared = sorted((common or {}).keys())
    per_platform = {}
    for triple, items in platform_items.items():
        extra = sorted([
            item
            for item in items
            if item not in (common or {})
        ])
        if extra:
            per_platform[triple] = extra

    return shared, per_platform

def _strip_comment(line):
    in_string = False
    escape = False
    out = []
    for ch in line.elems():
        if in_string:
            out.append(ch)
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == "\"":
                in_string = False
            continue
        if ch == "\"":
            in_string = True
            out.append(ch)
            continue
        if ch == "#":
            break
        out.append(ch)
    return "".join(out)

def _parse_scalar(value):
    value = value.strip()
    if value in ["true", "false"]:
        return value == "true"
    if len(value) >= 2 and value[0] == "\"" and value[-1] == "\"":
        return value[1:-1]
    if len(value) >= 2 and value[0] == "'" and value[-1] == "'":
        return value[1:-1]
    return value

def _parse_manifest_subset(content):
    package = {}
    lib = {}
    bins = []
    current = None
    current_bin = None

    for raw_line in content.splitlines():
        line = _strip_comment(raw_line).strip()
        if not line:
            continue

        if line == "[package]":
            current = "package"
            current_bin = None
            continue
        if line == "[lib]":
            current = "lib"
            current_bin = None
            continue
        if line == "[[bin]]":
            current = "bin"
            current_bin = {}
            bins.append(current_bin)
            continue
        if line.startswith("["):
            current = None
            current_bin = None
            continue
        if "=" not in line:
            continue

        key, value = [part.strip() for part in line.split("=", 1)]
        parsed = _parse_scalar(value)
        if current == "package":
            package[key] = parsed
        elif current == "lib":
            lib[key] = parsed
        elif current == "bin" and current_bin != None:
            current_bin[key] = parsed

    return {
        "bin": bins,
        "lib": lib,
        "package": package,
    }

def _source_exists(repository_ctx, relative_path):
    return repository_ctx.path(relative_path).exists

def _override_target_for_annotation(annotation, rule_key):
    override_targets = annotation.get("override_targets") or {}
    legacy_map = {
        "build_script": "custom-build",
        "proc_macro": "proc-macro",
    }
    return override_targets.get(rule_key) or override_targets.get(legacy_map.get(rule_key, ""))

def _selected_bins(repository_ctx, render_metadata, annotation, package_name, manifest_info):
    bins = []
    seen = {}
    for bin_target in manifest_info["bin"]:
        name = bin_target.get("name")
        if not name:
            continue
        path = bin_target.get("path") or "src/bin/{}.rs".format(name)
        bins.append({"name": name, "path": path})
        seen[name] = True

    if _source_exists(repository_ctx, "src/main.rs") and package_name not in seen:
        bins.append({"name": package_name, "path": "src/main.rs"})

    requested = annotation.get("gen_binaries")
    if requested == True:
        return bins
    if type(requested) == "list":
        return [bin_target for bin_target in bins if bin_target["name"] in requested]
    if render_metadata.get("generate_binaries"):
        return bins
    return []

def _infer_lib(repository_ctx, manifest_info, package_name):
    lib = dict(manifest_info.get("lib", {}))
    if lib.get("path"):
        return lib
    if lib or _source_exists(repository_ctx, "src/lib.rs"):
        if "name" not in lib:
            lib["name"] = package_name
        if "path" not in lib:
            lib["path"] = "src/lib.rs"
    return lib

def _infer_build_script(repository_ctx, render_metadata, annotation, manifest_info):
    gen_build_script = annotation.get("gen_build_script")
    if gen_build_script == False:
        return None
    if gen_build_script == None and not render_metadata.get("generate_build_scripts", True):
        return None

    build = manifest_info["package"].get("build")
    if build == False:
        return None
    if type(build) == "string":
        return build.removeprefix("./")
    if _source_exists(repository_ctx, "build.rs"):
        return "build.rs"
    return None

def _render_string_list(items, indent = " " * 8):
    if not items:
        return "[]"
    return "[\n{items}\n{indent}]".format(
        items = ",\n".join(["{}{}".format(indent, repr(item)) for item in items]),
        indent = indent[:-4] if len(indent) >= 4 else "",
    )

def _render_dict(value):
    return json.encode_indent(value, indent = " " * 8)

def _render_select_list(common, by_triple, indent = " " * 8):
    base = _render_string_list(common, indent = indent)
    if not by_triple:
        return base

    branches = []
    for triple in sorted(by_triple):
        branches.append(
            '{}"{}": {},'.format(
                indent,
                _platform_label(triple),
                _render_string_list(by_triple[triple], indent = indent + " " * 4),
            ),
        )
    branches.append('{}"//conditions:default": [],'.format(indent))
    return "{} + select({{\n{}\n{}}})".format(
        base,
        "\n".join(branches),
        indent[:-4] if len(indent) >= 4 else "",
    )

def _render_target_compatible_with(platform_triples):
    branches = []
    for triple in platform_triples:
        branches.append('        "{}": [],'.format(_platform_label(triple)))
    branches.append('        "//conditions:default": ["@platforms//:incompatible"],')
    return "select({\n%s\n    })" % "\n".join(branches)

def _render_glob_expr(include, exclude):
    return """glob(
        include = {include},
        allow_empty = True,
        exclude = {exclude},
    )""".format(
        exclude = _render_string_list(exclude, indent = " " * 12),
        include = _render_string_list(include, indent = " " * 12),
    )

def _render_glob_plus_list(include, exclude, extra_items):
    expression = _render_glob_expr(include, exclude)
    if extra_items:
        expression += " + {}".format(_render_string_list(_sorted_unique(extra_items)))
    return expression

def render_spoke_build_file(repository_ctx, render_metadata):
    manifest_path = repository_ctx.path("Cargo.toml")
    if not manifest_path.exists:
        fail("Fastpath spoke repository {} did not contain Cargo.toml".format(repository_ctx.name))

    manifest_info = _parse_manifest_subset(repository_ctx.read(manifest_path))
    annotation = dict(render_metadata.get("annotation", {}))
    crate_name = render_metadata["crate_name"]
    version = render_metadata["version"]
    platform_triples = list(render_metadata["platform_triples"])
    feature_resolutions = render_metadata["feature_resolutions"]
    is_proc_macro_by_label = {label: True for label in render_metadata.get("proc_macro_labels", [])}
    has_links_by_label = {label: True for label in render_metadata.get("links_labels", [])}
    generate_cargo_toml_env_vars = render_metadata.get("generate_cargo_toml_env_vars", True)
    generate_target_compatible_with = render_metadata.get("generate_target_compatible_with", True)

    manifest_info["lib"] = _infer_lib(repository_ctx, manifest_info, crate_name)
    if not manifest_info["lib"]:
        fail("Fastpath backend currently requires library crates. {} {} has no library target.".format(crate_name, version))

    lib = manifest_info["lib"]
    package = manifest_info["package"]
    target_name = _target_name(lib.get("name", crate_name))
    edition = package.get("edition", "2015")
    crate_root = lib["path"]
    is_proc_macro = lib.get("proc-macro", False) or lib.get("proc_macro", False)
    rule_override = _override_target_for_annotation(annotation, "proc-macro" if is_proc_macro else "lib")
    build_script_override = _override_target_for_annotation(annotation, "custom-build")

    deps_common, deps_select = _shared_and_per_platform(feature_resolutions["deps"])
    proc_common = []
    proc_select = {}
    build_common, build_select = _shared_and_per_platform(feature_resolutions["build_deps"])
    build_link_common = []
    build_link_select = {}
    crate_features_common, crate_features_select = _shared_and_per_platform(feature_resolutions["features_enabled"])

    deps_by_triple = {}
    proc_macro_deps_by_triple = {}
    build_link_deps_by_triple = {}
    for triple in platform_triples:
        deps_by_triple[triple] = []
        proc_macro_deps_by_triple[triple] = []
        build_link_deps_by_triple[triple] = []

        for label in feature_resolutions["deps"].get(triple, []):
            if is_proc_macro_by_label.get(label, False):
                proc_macro_deps_by_triple[triple].append(label)
            else:
                deps_by_triple[triple].append(label)

        for label in feature_resolutions["build_deps"].get(triple, []):
            if has_links_by_label.get(label, False):
                build_link_deps_by_triple[triple].append(label)

    deps_common, deps_select = _shared_and_per_platform(deps_by_triple)
    proc_common, proc_select = _shared_and_per_platform(proc_macro_deps_by_triple)
    build_link_common, build_link_select = _shared_and_per_platform(build_link_deps_by_triple)

    if is_proc_macro:
        merged_common = _sorted_unique(deps_common + proc_common)
        merged_select = {}
        for triple in platform_triples:
            merged_values = _sorted_unique(
                deps_select.get(triple, []) + proc_select.get(triple, []),
            )
            if merged_values:
                merged_select[triple] = merged_values
        deps_common = merged_common
        deps_select = merged_select
        proc_common = []
        proc_select = {}

    if annotation.get("deps"):
        deps_common = _sorted_unique(deps_common + annotation["deps"])
    if annotation.get("proc_macro_deps"):
        proc_common = _sorted_unique(proc_common + annotation["proc_macro_deps"])
    if annotation.get("build_script_deps"):
        build_common = _sorted_unique(build_common + annotation["build_script_deps"])
    if annotation.get("build_script_link_deps"):
        build_link_common = _sorted_unique(build_link_common + annotation["build_script_link_deps"])
    if annotation.get("crate_features"):
        crate_features_common = _sorted_unique(crate_features_common + annotation["crate_features"])

    rustc_flags = _sorted_unique(["--cap-lints=allow"] + (annotation.get("rustc_flags") or []))
    shared_glob_excludes = [
        "**/* *",
        ".tmp_git_root/**/*",
        "BUILD",
        "BUILD.bazel",
        "WORKSPACE",
        "WORKSPACE.bazel",
    ]
    compile_data_expr = _render_glob_plus_list(
        ["**"] + _sorted_unique(annotation.get("compile_data_glob") or []),
        shared_glob_excludes + _sorted_unique(annotation.get("compile_data_glob_excludes") or []),
        annotation.get("compile_data") or [],
    )
    data_expr = _render_glob_plus_list(
        ["**"] + _sorted_unique(annotation.get("data_glob") or []),
        shared_glob_excludes,
        annotation.get("data") or [],
    )
    build_script_compile_data_expr = _render_glob_plus_list(
        ["**"],
        ["**/*.rs"] + shared_glob_excludes,
        annotation.get("build_script_compile_data") or [],
    )
    build_script_data_expr = _render_glob_plus_list(
        ["**"] + _sorted_unique(annotation.get("build_script_data_glob") or []),
        shared_glob_excludes,
        annotation.get("build_script_data") or [],
    )

    rustc_env_files = _sorted_unique(annotation.get("rustc_env_files") or [])
    if generate_cargo_toml_env_vars:
        rustc_env_files = [":cargo_toml_env_vars"] + rustc_env_files

    bins = _selected_bins(repository_ctx, render_metadata, annotation, crate_name, manifest_info)
    build_script = _infer_build_script(repository_ctx, render_metadata, annotation, manifest_info)
    if build_script:
        deps_common = _sorted_unique(deps_common + [":build_script_build"])

    rule_name = "rust_proc_macro" if is_proc_macro else "rust_library"
    loads = []
    if not rule_override:
        loads.append('load("@rules_rust//rust:defs.bzl", "{}")'.format(rule_name))
    if generate_cargo_toml_env_vars:
        loads.append('load("@rules_rust//cargo:defs.bzl", "cargo_toml_env_vars")')
    if build_script:
        loads.append('load("@rules_rust//cargo:defs.bzl", "cargo_build_script")')
    if bins:
        loads.append('load("@rules_rust//rust:defs.bzl", "rust_binary")')

    content = """\
###############################################################################
# @generated
# DO NOT MODIFY: This file is auto-generated by the experimental lockfile fastpath.
###############################################################################

{loads}

package(default_visibility = ["//visibility:public"])

""".format(loads = "\n".join(_sorted_unique(loads)))

    if generate_cargo_toml_env_vars:
        content += """
cargo_toml_env_vars(
    name = "cargo_toml_env_vars",
    src = "Cargo.toml",
)
"""

    if not rule_override:
        content += """
{rule_name}(
    name = {target_name},
    srcs = glob(
        include = ["**/*.rs"],
        allow_empty = True,
    ),
    compile_data = {compile_data},
    crate_features = {crate_features},
    crate_root = {crate_root},
    data = {data},
    edition = {edition},
""".format(
            compile_data = compile_data_expr,
            crate_features = _render_select_list(crate_features_common, crate_features_select),
            crate_root = repr(crate_root),
            data = data_expr,
            edition = repr(edition),
            rule_name = rule_name,
            target_name = repr(target_name),
        )
        if rule_name == "rust_library" and (proc_common or proc_select):
            content += "    proc_macro_deps = {},\n".format(_render_select_list(proc_common, proc_select))
        if annotation.get("disable_pipelining"):
            content += "    disable_pipelining = True,\n"
        if annotation.get("rustc_env"):
            content += "    rustc_env = {},\n".format(_render_dict(annotation["rustc_env"]))
        if rustc_env_files:
            content += "    rustc_env_files = {},\n".format(_render_string_list(rustc_env_files))
        content += """\
    rustc_flags = {rustc_flags},
    tags = [
        "cargo-bazel",
        "crate-name={crate_name}",
        "manual",
        "noclippy",
        "norustfmt",
    ],
""".format(crate_name = crate_name, rustc_flags = repr(rustc_flags))
        if generate_target_compatible_with:
            content += "    target_compatible_with = {},\n".format(_render_target_compatible_with(platform_triples))
        content += "    version = {},\n".format(repr(version))
        if deps_common or deps_select:
            content += "    deps = {},\n".format(_render_select_list(deps_common, deps_select))
        content += ")\n"

    if build_script:
        content += """

cargo_build_script(
    name = "_bs",
    srcs = glob(
        include = ["**/*.rs"],
        allow_empty = True,
    ),
    compile_data = {build_script_compile_data},
    crate_features = {crate_features},
    crate_name = "build_script_build",
    crate_root = {crate_root},
    data = {build_script_data},
    edition = {edition},
    link_deps = {build_script_link_deps},
    tools = {build_script_tools},
    proc_macro_deps = {build_script_proc_macro_deps},
    pkg_name = {pkg_name},
    rustc_env = {build_script_rustc_env},
    rustc_env_files = {rustc_env_files},
    rustc_flags = {rustc_flags},
    tags = [
        "cargo-bazel",
        "crate-name={crate_name}",
        "manual",
        "noclippy",
        "norustfmt",
    ],
    version = {version},
    visibility = ["//visibility:private"],
""".format(
            build_script_compile_data = build_script_compile_data_expr,
            build_script_data = build_script_data_expr,
            build_script_link_deps = _render_select_list(build_link_common, build_link_select),
            build_script_proc_macro_deps = _render_string_list(_sorted_unique(annotation.get("build_script_proc_macro_deps") or [])),
            build_script_rustc_env = _render_dict(annotation.get("build_script_rustc_env") or {}),
            build_script_tools = _render_string_list(_sorted_unique(annotation.get("build_script_tools") or [])),
            crate_features = _render_select_list(crate_features_common, crate_features_select),
            crate_name = crate_name,
            crate_root = repr(build_script),
            edition = repr(edition),
            pkg_name = repr(crate_name),
            rustc_env_files = _render_string_list(rustc_env_files),
            rustc_flags = repr(rustc_flags),
            version = repr(version),
        )
        if build_common or build_select:
            content += "    deps = {},\n".format(_render_select_list(build_common, build_select))
        if annotation.get("build_script_env"):
            content += "    build_script_env = {},\n".format(_render_dict(annotation["build_script_env"]))
        if annotation.get("build_script_exec_properties"):
            content += "    exec_properties = {},\n".format(_render_dict(annotation["build_script_exec_properties"]))
        if annotation.get("build_script_toolchains"):
            content += "    toolchains = {},\n".format(_render_string_list(_sorted_unique(annotation["build_script_toolchains"])))
        if annotation.get("build_script_use_default_shell_env") != None:
            content += "    use_default_shell_env = {},\n".format(repr(annotation["build_script_use_default_shell_env"]))
        if annotation.get("build_script_rundir") != None:
            content += "    rundir = {},\n".format(repr(annotation["build_script_rundir"]))
        if generate_target_compatible_with:
            content += "    target_compatible_with = {},\n".format(_render_target_compatible_with(platform_triples))
        content += """
)

alias(
    name = "build_script_build",
    actual = {build_script_actual},
    tags = ["manual"],
)
""".format(build_script_actual = repr(build_script_override or ":_bs"))

    if rule_override or target_name != crate_name:
        content += """

alias(
    name = {package_name},
    actual = {actual},
    tags = ["manual"],
)
""".format(
            actual = repr(rule_override or (":" + target_name)),
            package_name = repr(crate_name),
        )

    for bin_target in bins:
        content += """

rust_binary(
    name = {name},
    srcs = glob(
        include = ["**/*.rs"],
        allow_empty = True,
    ),
    compile_data = {compile_data},
    data = {data},
    crate_name = {crate_name_attr},
    crate_root = {crate_root},
    edition = {edition},
    deps = {deps},
    proc_macro_deps = {proc_macro_deps},
    rustc_env = {rustc_env},
    rustc_env_files = {rustc_env_files},
    rustc_flags = {rustc_flags},
    tags = [
        "cargo-bazel",
        "crate-name={crate_name}",
        "manual",
        "noclippy",
        "norustfmt",
    ],
)
""".format(
            crate_name = crate_name,
            crate_name_attr = repr(_target_name(bin_target["name"])),
            crate_root = repr(bin_target["path"]),
            compile_data = compile_data_expr,
            data = data_expr,
            deps = _render_select_list(deps_common, deps_select),
            edition = repr(edition),
            name = repr("{}__bin".format(bin_target["name"])),
            proc_macro_deps = _render_select_list(proc_common, proc_select),
            rustc_env = _render_dict(annotation.get("rustc_env") or {}),
            rustc_env_files = _render_string_list(rustc_env_files),
            rustc_flags = repr(rustc_flags),
        )

    if annotation.get("additive_build_file_content"):
        content += "\n" + annotation["additive_build_file_content"] + "\n"

    return content
