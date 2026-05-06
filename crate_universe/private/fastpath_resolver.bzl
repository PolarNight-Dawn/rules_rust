"""Experimental rules_rs-style resolver for WORKSPACE `crates_repository`."""

load(
    ":common_utils.bzl",
    "CARGO_BAZEL_DEBUG",
    "CARGO_BAZEL_FASTPATH_PROFILE",
    "cargo_environ",
    "execute",
)
load(
    ":fastpath_cfg_parser.bzl",
    "cfg_matches_expr_for_cfg_attrs",
    "triple_to_cfg_attrs",
)
load(":fastpath_semver.bzl", "select_matching_version")
load(":fastpath_solver.bzl", "resolve")
load(
    ":generate_utils.bzl",
    "collect_crate_annotations",
    "render_config",
)

_CRATES_IO_INDEX = "registry+https://github.com/rust-lang/crates.io-index"
_CRATES_IO_SPARSE = "sparse+https://index.crates.io/"
_FASTPATH_ARCHIVE_CACHE_DIR = ".cargo-bazel-fastpath-cache/archives"
_FASTPATH_FACTS_CACHE_DIR = ".cargo-bazel-fastpath-cache/facts"
_FASTPATH_LOCKFILE_FILE = "_fastpath_lockfile.json"
_FASTPATH_LOCKFILE_VERSION = 1
_FASTPATH_PROFILE_FILE = "_fastpath_profile.json"
_SUPPORTED_ANNOTATION_KEYS = [
    "additive_build_file_content",
    "build_script_compile_data",
    "build_script_data",
    "build_script_data_glob",
    "build_script_deps",
    "build_script_env",
    "build_script_exec_properties",
    "build_script_link_deps",
    "build_script_proc_macro_deps",
    "build_script_rundir",
    "build_script_rustc_env",
    "build_script_toolchains",
    "build_script_tools",
    "build_script_use_default_shell_env",
    "compile_data",
    "compile_data_glob",
    "compile_data_glob_excludes",
    "crate_features",
    "data",
    "data_glob",
    "deps",
    "disable_pipelining",
    "extra_aliased_targets",
    "gen_binaries",
    "gen_build_script",
    "override_targets",
    "proc_macro_deps",
    "rustc_env",
    "rustc_env_files",
    "rustc_flags",
]

def _normalize_registry_source(source):
    if source == _CRATES_IO_INDEX:
        return _CRATES_IO_SPARSE
    return source

def _spoke_repo_name(hub_name, name, version):
    return "{}__{}-{}".format(hub_name, name, version).replace("+", "-")

def _normalize_source(source):
    if not source:
        return ""
    return _normalize_registry_source(source)

def _parse_git_url(url):
    parts = url.split("#")
    base = parts[0]
    commit = parts[1] if len(parts) > 1 else None
    if commit == None:
        fail("No commit SHA fragment found in git source {}".format(url))
    return base.split("?")[0].removeprefix("git+"), commit

def _github_archive_url(source):
    remote, commit = _parse_git_url(source)
    if not remote.startswith("https://github.com/"):
        return None
    repo_path = remote.removeprefix("https://github.com/").removesuffix(".git")
    return "https://codeload.github.com/{}/tar.gz/{}".format(repo_path, commit)

def _platform_label(triple):
    return "@rules_rust//rust/platform:{}".format(
        triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc"),
    )

def _fq_crate(name, version):
    return "{}-{}".format(name, version)

def _target_name(name):
    return name.replace("-", "_")

def _crate_archive_url(crate_name, version, source, registry_dl_templates, checksum = ""):
    source = _normalize_registry_source(source)
    template = registry_dl_templates.get(source)
    if not template:
        fail("Unsupported registry source for fastpath backend: {}".format(source))
    shard = _sharded_path(crate_name)
    return template.format(
        crate = crate_name,
        version = version,
        prefix = shard,
        lowerprefix = _sharded_path(crate_name.lower()),
        **{"sha256-checksum": checksum}
    )

def _sharded_path(crate):
    n = len(crate)
    if n == 0:
        fail("empty crate name")
    if n == 1:
        return "1/" + crate
    if n == 2:
        return "2/" + crate
    if n == 3:
        return "3/{}/{}".format(crate[0], crate)
    return "{}/{}/{}".format(crate[0:2], crate[2:4], crate)

def _add_to_list_dict(mapping, key, value):
    if key not in mapping:
        mapping[key] = []
    mapping[key].append(value)

def _new_set(values = []):
    items = {}
    for value in values:
        items[value] = True
    return items

def _set_add(items, value):
    already_present = value in items
    items[value] = True
    return not already_present

def _set_add_all(items, values):
    changed = False
    for value in values:
        if _set_add(items, value):
            changed = True
    return changed

def _set_to_sorted_list(items):
    return sorted(items.keys())

def _sorted_unique(values):
    return _set_to_sorted_list(_new_set(values))

def _add_to_set_dict(mapping, key, value):
    if key not in mapping:
        mapping[key] = {}
    mapping[key][value] = True

def _is_truthy_env(value):
    if value == None:
        return False
    return value.lower() not in ["", "0", "false", "no", "off"]

def _default_fastpath_lockfile():
    return {
        "facts": {
            "registry_entries": {},
            "registry_inspection": {},
            "workspace_metadata": {},
        },
        "version": _FASTPATH_LOCKFILE_VERSION,
    }

def _workspace_lockfile_path(repository_ctx):
    lockfile = repository_ctx.attr.lockfile
    if not lockfile:
        return None

    if lockfile.workspace_name not in ["", "__main__", "_main"]:
        return None

    path = repository_ctx.workspace_root
    if lockfile.package:
        for segment in lockfile.package.split("/"):
            if segment:
                path = path.get_child(segment)
    return path.get_child(lockfile.name)

def _workspace_facts_cache_path(repository_ctx):
    path = repository_ctx.workspace_root
    for segment in _FASTPATH_FACTS_CACHE_DIR.split("/"):
        path = path.get_child(segment)
    return path.get_child("{}.json".format(repository_ctx.name))

def _workspace_archive_cache_path(repository_ctx, crate_name, version, checksum):
    path = repository_ctx.workspace_root
    for segment in _FASTPATH_ARCHIVE_CACHE_DIR.split("/"):
        path = path.get_child(segment)
    return path.get_child("{}-{}-{}.tar.gz".format(crate_name, version, checksum[:12]))

def _fastpath_lockfile_path(repository_ctx):
    workspace_lockfile = _workspace_lockfile_path(repository_ctx)
    if workspace_lockfile:
        return workspace_lockfile
    if repository_ctx.attr.lockfile:
        return repository_ctx.path(repository_ctx.attr.lockfile)
    return _workspace_facts_cache_path(repository_ctx)

def _load_fastpath_lockfile(repository_ctx):
    lockfile = _default_fastpath_lockfile()
    lockfile_path = _fastpath_lockfile_path(repository_ctx)
    if not lockfile_path.exists:
        return lockfile

    content = repository_ctx.read(lockfile_path).strip()
    if not content:
        return lockfile

    parsed = json.decode(content)
    if type(parsed) != "dict" or parsed.get("version") != _FASTPATH_LOCKFILE_VERSION:
        return lockfile

    facts = parsed.get("facts")
    if type(facts) != "dict":
        return lockfile

    lockfile["facts"]["registry_entries"] = dict(facts.get("registry_entries", {}))
    lockfile["facts"]["registry_inspection"] = dict(facts.get("registry_inspection", {}))
    lockfile["facts"]["workspace_metadata"] = dict(facts.get("workspace_metadata", {}))
    return lockfile

def _write_fastpath_lockfile(repository_ctx, lockfile):
    content_lockfile = _clone_jsonish(lockfile)
    if repository_ctx.attr.lockfile:
        content_lockfile["facts"].pop("workspace_metadata", None)
    content = json.encode_indent(content_lockfile, indent = "    ") + "\n"
    lockfile_path = _fastpath_lockfile_path(repository_ctx)
    existing = ""
    if lockfile_path.exists:
        existing = repository_ctx.read(lockfile_path)
    if existing == content:
        return

    repository_ctx.file(_FASTPATH_LOCKFILE_FILE, content)
    execute(
        repository_ctx,
        args = [
            "/bin/sh",
            "-c",
            'mkdir -p "$1" && cat "$2" > "$3"',
            "sh",
            str(lockfile_path.dirname),
            str(repository_ctx.path(_FASTPATH_LOCKFILE_FILE)),
            str(lockfile_path),
        ],
        quiet = True,
    )

def _registry_entry_fact_key(source, crate_name, version):
    return "{}|{}|{}".format(_normalize_registry_source(source), crate_name, version)

def _registry_inspection_fact_key(source, crate_name, version, checksum):
    key = "{}|{}|{}".format(_normalize_registry_source(source), crate_name, version)
    if checksum:
        key += "|{}".format(checksum)
    return key

def _clone_jsonish(value):
    return json.decode(json.encode(value))

def _new_fastpath_profiler(repository_ctx):
    enabled = _is_truthy_env(repository_ctx.os.environ.get(CARGO_BAZEL_FASTPATH_PROFILE))
    profiler = {
        "enabled": enabled,
        "events": [],
        "python": None,
        "started_ns": 0,
    }
    if not enabled:
        return profiler

    python = repository_ctx.which("python3") or repository_ctx.which("python")
    if not python:
        fail(
            "Fastpath profiling requires `python3` or `python` to be available on PATH. " +
            "Install Python or unset CARGO_BAZEL_FASTPATH_PROFILE.",
        )
    profiler["python"] = str(python)
    profiler["started_ns"] = _fastpath_now_ns(repository_ctx, profiler)
    return profiler

def _fastpath_now_ns(repository_ctx, profiler):
    if not profiler["enabled"]:
        return 0
    return int(execute(
        repository_ctx,
        args = [
            profiler["python"],
            "-c",
            "import time; print(time.time_ns())",
        ],
        quiet = True,
    ).stdout.strip())

def _fastpath_profile_start(repository_ctx, profiler):
    return _fastpath_now_ns(repository_ctx, profiler)

def _fastpath_profile_record(repository_ctx, profiler, phase, started_ns, details = None):
    if not profiler["enabled"]:
        return

    duration_ns = _fastpath_now_ns(repository_ctx, profiler) - started_ns
    event = {
        "duration_ms": duration_ns / 1000000.0,
        "phase": phase,
    }
    if details:
        event["details"] = details
    profiler["events"].append(event)

def _format_duration_ms(duration_ns):
    whole_ms = duration_ns // 1000000
    fractional_ms = (duration_ns % 1000000) // 1000
    fractional = str(fractional_ms)
    if len(fractional) == 1:
        fractional = "00" + fractional
    elif len(fractional) == 2:
        fractional = "0" + fractional
    return "{}.{}".format(whole_ms, fractional)

def _write_fastpath_profile(repository_ctx, profiler, summary = None):
    if not profiler["enabled"]:
        return

    total_ns = _fastpath_now_ns(repository_ctx, profiler) - profiler["started_ns"]
    profile = {
        "events": profiler["events"],
        "summary": {
            "repository": repository_ctx.name,
            "total_ms": total_ns / 1000000.0,
        },
    }
    if summary:
        profile["summary"].update(summary)

    repository_ctx.file(_FASTPATH_PROFILE_FILE, json.encode_indent(profile, indent = "    "))

    print("FASTPATH PROFILE [{}] total={}ms".format(
        repository_ctx.name,
        _format_duration_ms(total_ns),
    ))
    for event in profiler["events"]:
        duration_ns = int(event["duration_ms"] * 1000000.0)
        print("FASTPATH PROFILE [{}] {}={}ms".format(
            repository_ctx.name,
            event["phase"],
            _format_duration_ms(duration_ns),
        ))

def _new_feature_resolutions(package_index, possible_deps, possible_features, platform_triples):
    return struct(
        aliases = {},
        build_deps = {triple: {} for triple in platform_triples},
        deps = {triple: {} for triple in platform_triples},
        features_enabled = {triple: {} for triple in platform_triples},
        package_index = package_index,
        possible_deps = possible_deps,
        possible_features = possible_features,
    )

def _cargo_metadata_dep_to_dep_dict(dep):
    rename = dep.get("rename")
    converted = {
        "default_features": dep.get("uses_default_features", True),
        "features": list(dep.get("features", [])),
        "name": rename or dep["name"],
        "optional": dep.get("optional", False),
    }

    req = dep.get("req")
    if req:
        converted["req"] = req

    kind = dep.get("kind")
    if kind and kind != "normal":
        converted["kind"] = kind

    target = dep.get("target")
    if target:
        converted["target"] = target

    if rename:
        converted["package"] = dep["name"]

    return converted

def _prepare_possible_deps(dependencies, converter = None):
    possible_deps = []
    for dep in dependencies:
        if converter:
            dep = converter(dep)
        if dep.get("kind") == "dev":
            continue
        if dep.get("default_features", True):
            _add_to_list_dict(dep, "features", "default")
        possible_deps.append(dep)
    return possible_deps

def _cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache):
    if not target:
        return struct(
            matches = [cfg_attr["_triple"] for cfg_attr in platform_cfg_attrs],
            uses_feature_cfg = False,
        )
    match_info = cfg_match_cache.get(target)
    if match_info:
        return match_info
    match_info = cfg_matches_expr_for_cfg_attrs(target, platform_cfg_attrs)
    cfg_match_cache[target] = match_info
    return match_info

def _dep_category(kind, is_proc_macro):
    if kind == "dev":
        return "proc_macro_dev" if is_proc_macro else "normal_dev"
    if kind == "build":
        return "build_proc_macro" if is_proc_macro else "build"
    return "proc_macro" if is_proc_macro else "normal"

def _sort_dict_values(mapping):
    return {
        key: sorted(values)
        for key, values in mapping.items()
        if values
    }

def _shared_and_per_platform(platform_items):
    if not platform_items:
        return [], {}

    common = None
    for items in platform_items.values():
        values = _new_set(items.keys() if type(items) == "dict" else items)
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
        item_values = items.keys() if type(items) == "dict" else items
        extra = sorted([
            item
            for item in item_values
            if item not in (common or {})
        ])
        if extra:
            per_platform[triple] = extra

    return shared, per_platform

def _shared_and_per_platform_dict(platform_items):
    if not platform_items:
        return {}, {}

    common = None
    for items in platform_items.values():
        values = {
            (key, value): True
            for key, value in items.items()
        }
        if common == None:
            common = values
        else:
            common = {
                entry: True
                for entry in common.keys()
                if entry in values
            }

    shared = {
        key: value
        for key, value in sorted((common or {}).keys())
    }
    per_platform = {}
    for triple, items in platform_items.items():
        extra_items = [
            (key, value)
            for key, value in items.items()
            if (key, value) not in (common or {})
        ]
        if extra_items:
            per_platform[triple] = {
                key: value
                for key, value in sorted(extra_items)
            }

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

def _parse_array_of_strings(initial, remaining_lines, line_index):
    values = []
    text = initial.strip()
    if text.startswith("["):
        text = text[1:]

    for current_index in range(line_index, len(remaining_lines)):
        if current_index != line_index:
            text = _strip_comment(remaining_lines[current_index]).strip()
        candidate = text.strip()
        if candidate.endswith("]"):
            candidate = candidate[:-1].strip()
            if candidate:
                for part in candidate.split(","):
                    part = part.strip()
                    if part:
                        values.append(_parse_scalar(part))
            return values, current_index

        if candidate:
            for part in candidate.split(","):
                part = part.strip()
                if part:
                    values.append(_parse_scalar(part))

    fail("unterminated array while parsing Cargo.lock")

def _parse_cargo_lock(content):
    packages = []
    current = None
    lines = content.splitlines()
    skip_until = -1

    for i in range(len(lines)):
        if i <= skip_until:
            continue
        line = _strip_comment(lines[i]).strip()
        if not line:
            continue
        if line == "[[package]]":
            if current:
                current.setdefault("dependencies", [])
                packages.append(current)
            current = {}
            continue
        if current == None or "=" not in line:
            continue

        key, raw_value = [part.strip() for part in line.split("=", 1)]
        if key == "dependencies":
            values, new_i = _parse_array_of_strings(raw_value, lines, i)
            current[key] = values
            skip_until = new_i
            continue
        current[key] = _parse_scalar(raw_value)

    if current:
        current.setdefault("dependencies", [])
        packages.append(current)

    return packages

def _compute_package_fq_deps(package, versions_by_name, strict = True):
    fq_by_name = {}
    for maybe_fq_dep in package.get("dependencies", []):
        idx = maybe_fq_dep.find(" ")
        if idx == -1:
            versions = versions_by_name.get(maybe_fq_dep)
            if not versions:
                if strict:
                    fail("Malformed Cargo.lock: missing version for dependency {}".format(maybe_fq_dep))
                continue
            dep = maybe_fq_dep
            version = versions[0]
        else:
            dep = maybe_fq_dep[:idx]
            version = maybe_fq_dep[idx + 1:]
        fq_by_name[dep] = _fq_crate(dep, version)
    return fq_by_name

def _compute_workspace_fq_deps(workspace_members, versions_by_name):
    workspace_fq_deps = {}
    for workspace_member in workspace_members:
        workspace_fq_deps[workspace_member["name"]] = _compute_package_fq_deps(
            workspace_member,
            versions_by_name,
            strict = False,
        )
    return workspace_fq_deps

def _relative_to_workspace(path, workspace_root):
    normalized_root = workspace_root.replace("\\", "/")
    normalized_path = path.replace("\\", "/")
    if not normalized_path.startswith(normalized_root):
        fail("Manifest {} is not under workspace root {}".format(path, workspace_root))
    relative = normalized_path[len(normalized_root):]
    if relative.startswith("/"):
        relative = relative[1:]
    return relative

def _manifest_package_name(manifest_path, workspace_root):
    relative = _relative_to_workspace(manifest_path, workspace_root)
    if relative == "Cargo.toml":
        return ""
    return relative.removesuffix("/Cargo.toml")

def _needs_full_metadata(lock_packages, workspace_member_keys):
    for package in lock_packages:
        if (package["name"], package["version"]) in workspace_member_keys:
            continue
        source = package.get("source")
        if not source or source.startswith("git+") or source.startswith("path+"):
            return True
    return False

def _full_metadata_key(name, version, source):
    return "{}|{}|{}".format(name, version, _normalize_source(source))

def _external_metadata_packages(full_metadata, workspace_member_keys):
    packages = {}
    if not full_metadata:
        return packages
    for package in full_metadata.get("packages", []):
        key = (package["name"], package["version"])
        if key in workspace_member_keys:
            continue
        packages[_full_metadata_key(
            package["name"],
            package["version"],
            package.get("source"),
        )] = package
    return packages

def _lookup_external_metadata_package(lock_package, metadata_packages):
    exact = metadata_packages.get(_full_metadata_key(
        lock_package["name"],
        lock_package["version"],
        lock_package.get("source"),
    ))
    if exact:
        return exact

    if lock_package.get("source"):
        return None

    fallback = []
    prefix = "{}|{}|".format(lock_package["name"], lock_package["version"])
    for key, package in metadata_packages.items():
        if key.startswith(prefix):
            fallback.append(package)
    if len(fallback) == 1:
        return fallback[0]
    return None

def _workspace_member_keys(metadata):
    workspace_member_ids = {
        package_id: True
        for package_id in metadata.get("workspace_members", [])
    }
    keys = {}
    for package in metadata.get("packages", []):
        if package["id"] not in workspace_member_ids:
            continue
        keys[(package["name"], package["version"])] = True
    return keys

def _track_local_source_tree(repository_ctx, root):
    result = execute(
        repository_ctx,
        args = ["find", root, "-type", "f"],
        quiet = True,
    )
    for path in result.stdout.strip().split("\n"):
        if path:
            repository_ctx.read(path)

def _new_source_probe(inspect_root = None, archive_entries = None, archive_prefix = "", file_presence = None):
    return struct(
        archive_entries = archive_entries,
        archive_prefix = archive_prefix,
        file_presence = file_presence,
        inspect_root = inspect_root,
    )

def _source_probe_contains(source_probe, relative_path):
    inspect_root = source_probe.inspect_root
    if inspect_root != None:
        return inspect_root.get_child(relative_path).exists

    file_presence = source_probe.file_presence
    if file_presence != None:
        return bool(file_presence.get(relative_path, False))

    archive_entries = source_probe.archive_entries
    if archive_entries == None:
        return False
    return "{}/{}".format(source_probe.archive_prefix, relative_path) in archive_entries

def _tar_binary(repository_ctx):
    tar = repository_ctx.which("tar")
    if tar:
        return str(tar)
    return None

def _inspect_registry_archive(repository_ctx, tar_binary, archive_path, crate_name, version):
    prefix = "{}-{}".format(crate_name, version)
    entries_output = execute(
        repository_ctx,
        args = [tar_binary, "-tf", archive_path],
        quiet = True,
    ).stdout
    archive_entries = {}
    for raw_entry in entries_output.splitlines():
        entry = raw_entry.strip().removeprefix("./").removesuffix("/")
        if not entry:
            continue
        archive_entries[entry] = True

    manifest_path = "{}/Cargo.toml".format(prefix)
    if manifest_path not in archive_entries:
        fail("Crate {} {} archive did not contain {}".format(crate_name, version, manifest_path))

    manifest_content = execute(
        repository_ctx,
        args = [tar_binary, "-xOf", archive_path, manifest_path],
        quiet = True,
    ).stdout

    return struct(
        archive_entries = archive_entries,
        manifest_info = _parse_manifest_subset(manifest_content),
        prefix = prefix,
    )

def _registry_inspection_fact(manifest_info, source_probe):
    return {
        "file_presence": {
            "build.rs": _source_probe_contains(source_probe, "build.rs"),
            "src/lib.rs": _source_probe_contains(source_probe, "src/lib.rs"),
            "src/main.rs": _source_probe_contains(source_probe, "src/main.rs"),
        },
        "manifest_info": manifest_info,
    }

def _source_probe_from_registry_inspection_fact(fact):
    return _new_source_probe(file_presence = dict(fact.get("file_presence", {})))

def _prepare_annotations(repository_ctx):
    flat_annotations = collect_crate_annotations(repository_ctx.attr.annotations, repository_ctx.name)
    annotations = {}

    for crate_id, raw_annotation in flat_annotations.items():
        split = crate_id.rfind(" ")
        if split == -1:
            fail("Malformed crate annotation id: {}".format(crate_id))

        crate_name = crate_id[:split]
        version = crate_id[split + 1:]
        annotation = dict(raw_annotation)

        additive_build_file = annotation.pop("additive_build_file", None)
        additive_content = []
        if annotation.get("additive_build_file_content"):
            additive_content.append(annotation.pop("additive_build_file_content"))
        if additive_build_file:
            additive_content.append(repository_ctx.read(Label(additive_build_file)))
        if additive_content:
            annotation["additive_build_file_content"] = "\n".join(additive_content)

        if crate_name not in annotations:
            annotations[crate_name] = {}
        annotations[crate_name][version] = annotation

    return annotations

def _ensure_supported_annotations(annotation, crate_name, version):
    unsupported = []
    for key in annotation.keys():
        if key not in _SUPPORTED_ANNOTATION_KEYS and annotation[key]:
            unsupported.append(key)
    if unsupported:
        fail(
            (
                "Fastpath backend does not yet support annotation fields {} for {} {}. " +
                "Use `resolver_backend = \"cargo_bazel\"` for this repository."
            ).format(sorted(unsupported), crate_name, version),
        )

def _selected_bins(repository_ctx, annotation, package_name, manifest_info, source_probe):
    bins = []
    seen = {}
    for bin_target in manifest_info["bin"]:
        name = bin_target.get("name")
        if not name:
            continue
        path = bin_target.get("path") or "src/bin/{}.rs".format(name)
        bins.append({"name": name, "path": path})
        seen[name] = True

    if _source_probe_contains(source_probe, "src/main.rs") and package_name not in seen:
        bins.append({"name": package_name, "path": "src/main.rs"})
        seen[package_name] = True

    requested = annotation.get("gen_binaries")
    if requested == True:
        return bins
    if type(requested) == "list":
        return [bin_target for bin_target in bins if bin_target["name"] in requested]
    if repository_ctx.attr.generate_binaries:
        return bins
    return []

def _infer_lib(manifest_info, package_name, source_probe):
    lib = dict(manifest_info.get("lib", {}))
    if lib.get("path"):
        return lib
    if lib or _source_probe_contains(source_probe, "src/lib.rs"):
        if "name" not in lib:
            lib["name"] = package_name
        if "path" not in lib:
            lib["path"] = "src/lib.rs"
    return lib

def _infer_build_script(repository_ctx, annotation, manifest_info, source_probe):
    gen_build_script = annotation.get("gen_build_script")
    if gen_build_script == False:
        return None
    if gen_build_script == None and not repository_ctx.attr.generate_build_scripts:
        return None

    package = manifest_info["package"]
    build = package.get("build")
    if build == False:
        return None
    if type(build) == "string":
        return build.removeprefix("./")
    if _source_probe_contains(source_probe, "build.rs"):
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

def _render_build_file(
        repository_ctx,
        annotation,
        crate_name,
        version,
        manifest_info,
        feature_resolutions,
        is_proc_macro_by_label,
        has_links_by_label,
        platform_triples,
        source_probe,
        generate_cargo_toml_env_vars = True,
        generate_target_compatible_with = True):
    lib = manifest_info["lib"]
    package = manifest_info["package"]
    target_name = _target_name(lib.get("name", crate_name))
    edition = package.get("edition", "2015")
    crate_root = lib["path"]
    is_proc_macro = lib.get("proc-macro", False) or lib.get("proc_macro", False)
    rule_override = _override_target_for_annotation(
        annotation,
        "proc-macro" if is_proc_macro else "lib",
    )
    build_script_override = _override_target_for_annotation(annotation, "custom-build")

    deps_by_triple = {triple: [] for triple in platform_triples}
    proc_macro_deps_by_triple = {triple: [] for triple in platform_triples}
    build_deps_by_triple = {triple: [] for triple in platform_triples}
    build_link_deps_by_triple = {triple: [] for triple in platform_triples}

    for triple in platform_triples:
        for label in sorted(feature_resolutions.deps[triple].keys()):
            if is_proc_macro_by_label.get(label, False):
                proc_macro_deps_by_triple[triple].append(label)
            else:
                deps_by_triple[triple].append(label)
        for label in sorted(feature_resolutions.build_deps[triple].keys()):
            build_deps_by_triple[triple].append(label)
            if has_links_by_label.get(label, False):
                build_link_deps_by_triple[triple].append(label)

    if is_proc_macro:
        for triple in platform_triples:
            deps_by_triple[triple].extend(proc_macro_deps_by_triple[triple])
            proc_macro_deps_by_triple[triple] = []

    crate_features_common, crate_features_select = _shared_and_per_platform(feature_resolutions.features_enabled)
    deps_common, deps_select = _shared_and_per_platform(deps_by_triple)
    proc_common, proc_select = _shared_and_per_platform(proc_macro_deps_by_triple)
    build_common, build_select = _shared_and_per_platform(build_deps_by_triple)
    build_link_common, build_link_select = _shared_and_per_platform(build_link_deps_by_triple)

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

    bins = _selected_bins(repository_ctx, annotation, crate_name, manifest_info, source_probe)
    build_script = _infer_build_script(repository_ctx, annotation, manifest_info, source_probe)
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

""".format(
        loads = "\n".join(_sorted_unique(loads)),
    )

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
            content += "    proc_macro_deps = {},\n".format(
                _render_select_list(proc_common, proc_select),
            )
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
""".format(
            crate_name = crate_name,
            rustc_flags = repr(rustc_flags),
        )
        if generate_target_compatible_with:
            content += "    target_compatible_with = {},\n".format(
                _render_target_compatible_with(platform_triples),
            )
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
            content += "    target_compatible_with = {},\n".format(
                _render_target_compatible_with(platform_triples),
            )
        content += """\
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

def _download_registry_templates(repository_ctx, packages):
    templates = {
        _CRATES_IO_SPARSE: "https://static.crates.io/crates/{crate}/{version}/download",
    }
    for package in packages:
        source = _normalize_registry_source(package["source"])
        if source in templates:
            continue
        if not source.startswith("sparse+"):
            fail("Fastpath backend only supports sparse registries today, got {}".format(source))
        config_path = repository_ctx.path("_fastpath_registry_{}.json".format(len(templates)))
        repository_ctx.download(
            output = config_path,
            url = source.removeprefix("sparse+") + "config.json",
        )
        config = json.decode(repository_ctx.read(config_path))
        templates[source] = config["dl"]
    return templates

def _download_registry_metadata(repository_ctx, packages, fastpath_lockfile):
    metadata_by_source_and_name = {}
    registry_entry_facts = fastpath_lockfile["facts"]["registry_entries"]
    cache_hits = 0
    cache_misses = 0
    fetches = []

    for package in packages:
        source = _normalize_registry_source(package["source"])
        key = "{}|{}".format(source, package["name"])
        if key in metadata_by_source_and_name:
            continue

        needed_versions = _new_set()
        for candidate in packages:
            candidate_source = _normalize_registry_source(candidate["source"])
            if candidate_source == source and candidate["name"] == package["name"]:
                needed_versions[candidate["version"]] = True

        entries = {}
        missing_versions = {}
        for version in needed_versions.keys():
            fact = registry_entry_facts.get(_registry_entry_fact_key(source, package["name"], version))
            if fact:
                entries[version] = _clone_jsonish(fact)
                cache_hits += 1
            else:
                missing_versions[version] = True

        if missing_versions:
            cache_misses += len(missing_versions)
            output = repository_ctx.path("_fastpath_index_{}_{}.jsonl".format(
                len(metadata_by_source_and_name),
                package["name"],
            ))
            token = repository_ctx.download(
                block = False,
                output = output,
                url = source.removeprefix("sparse+") + _sharded_path(package["name"].lower()),
            )
            fetches.append(struct(
                entries = entries,
                missing_versions = missing_versions,
                name = package["name"],
                output = output,
                source = source,
                token = token,
            ))

        metadata_by_source_and_name[key] = entries

    for fetch in fetches:
        fetch.token.wait()
        for line in repository_ctx.read(fetch.output).splitlines():
            line = line.strip()
            if not line:
                continue
            entry = json.decode(line)
            version = entry["vers"]
            if version not in fetch.missing_versions:
                continue
            features = dict(entry.get("features", {}))
            features2 = entry.get("features2")
            if features2:
                features.update(features2)
            fact = {
                "checksum": entry["cksum"],
                "dependencies": entry.get("deps", []),
                "features": features,
                "links": entry.get("links"),
            }
            fetch.entries[version] = _clone_jsonish(fact)
            registry_entry_facts[_registry_entry_fact_key(fetch.source, fetch.name, version)] = _clone_jsonish(fact)

    return struct(
        cache_hits = cache_hits,
        cache_misses = cache_misses,
        metadata = metadata_by_source_and_name,
    )

def _default_annotation():
    return {
        "additive_build_file": None,
        "additive_build_file_content": None,
        "build_script_compile_data": [],
        "build_script_data": [],
        "build_script_data_glob": [],
        "build_script_deps": [],
        "build_script_env": {},
        "build_script_exec_properties": {},
        "build_script_link_deps": [],
        "build_script_proc_macro_deps": [],
        "build_script_rundir": None,
        "build_script_rustc_env": {},
        "build_script_toolchains": [],
        "build_script_tools": [],
        "build_script_use_default_shell_env": None,
        "compile_data": [],
        "compile_data_glob": [],
        "compile_data_glob_excludes": [],
        "crate_features": [],
        "data": [],
        "data_glob": [],
        "deps": [],
        "disable_pipelining": False,
        "extra_aliased_targets": {},
        "gen_binaries": None,
        "gen_build_script": None,
        "override_targets": {},
        "proc_macro_deps": [],
        "rustc_env": {},
        "rustc_env_files": [],
        "rustc_flags": [],
    }

def _annotation_for(annotations, crate_name, version):
    annotation = _default_annotation()
    versioned = annotations.get(crate_name, {}).get(version)
    wildcard = annotations.get(crate_name, {}).get("*")
    for value in [wildcard, versioned]:
        if not value:
            continue
        annotation.update(value)
    _ensure_supported_annotations(annotation, crate_name, version)
    return annotation

def _override_target_for_annotation(annotation, rule_key):
    override_targets = annotation.get("override_targets") or {}
    legacy_map = {
        "build_script": "custom-build",
        "proc_macro": "proc-macro",
    }
    return override_targets.get(rule_key) or override_targets.get(legacy_map.get(rule_key, ""))

def _render_dep_data(dep_data):
    return "DEP_DATA = " + json.encode_indent(dep_data, indent = "    ")

def _render_defs_bzl(default_package_name):
    default_expr = repr(default_package_name) if default_package_name != None else "None"
    return """\
load("@bazel_skylib//lib:selects.bzl", "selects")
load("@bazel_tools//tools/build_defs/repo:utils.bzl", "maybe")
load("@rules_rust//crate_universe/private:fastpath_repo.bzl", "fastpath_crate_repository")
load(":data.bzl", "DEP_DATA", "REPOSITORIES")

_DEFAULT_PACKAGE_NAME = {default_package_name}

def _package_name(package_name):
    if package_name != None:
        return package_name
    if _DEFAULT_PACKAGE_NAME != None:
        return _DEFAULT_PACKAGE_NAME
    return native.package_name()

def _selected_categories(normal, normal_dev, proc_macro, proc_macro_dev, build, build_proc_macro):
    categories = []
    if normal:
        categories.append("normal")
    if normal_dev:
        categories.append("normal_dev")
    if proc_macro:
        categories.append("proc_macro")
    if proc_macro_dev:
        categories.append("proc_macro_dev")
    if build:
        categories.append("build")
    if build_proc_macro:
        categories.append("build_proc_macro")
    if not categories:
        categories = ["normal", "proc_macro"]
    return categories

def _list_value(common, selects):
    if not selects:
        return common
    branches = {{"//conditions:default": []}}
    for triple, values in selects.items():
        branches["@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")] = values
    return common + select(branches)

def _dict_value(common, selects):
    if not selects:
        return common
    branches = {{"//conditions:default": common}}
    for triple, values in selects.items():
        merged = dict(common)
        merged.update(values)
        branches["@rules_rust//rust/platform:" + triple.replace("-musl", "-gnu").replace("-gnullvm", "-msvc")] = merged
    return select(branches)

def _label_keyed_aliases(aliases):
    return {{
        label: alias
        for alias, label in aliases.items()
    }}

def aliases(
        normal = False,
        normal_dev = False,
        proc_macro = False,
        proc_macro_dev = False,
        build = False,
        build_proc_macro = False,
        package_name = None):
    dep_data = DEP_DATA.get(_package_name(package_name))
    if not dep_data:
        return {{}}

    categories = _selected_categories(normal, normal_dev, proc_macro, proc_macro_dev, build, build_proc_macro)
    common = {{}}
    selects = {{}}
    for category in categories:
        aliases_data = dep_data.get(category + "_aliases")
        if not aliases_data:
            continue
        common.update(aliases_data.get("common", {{}}))
        for triple, values in aliases_data.get("selects", {{}}).items():
            existing = selects.get(triple, {{}})
            existing.update(values)
            selects[triple] = existing

    common = _label_keyed_aliases(common)
    selects = {{
        triple: _label_keyed_aliases(values)
        for triple, values in selects.items()
    }}
    return _dict_value(common, selects)

def all_crate_deps(
        normal = False,
        normal_dev = False,
        proc_macro = False,
        proc_macro_dev = False,
        build = False,
        build_proc_macro = False,
        package_name = None):
    dep_data = DEP_DATA.get(_package_name(package_name))
    if not dep_data:
        return []

    categories = _selected_categories(normal, normal_dev, proc_macro, proc_macro_dev, build, build_proc_macro)
    common = []
    selects = {{}}
    seen_common = {{}}
    for category in categories:
        category_data = dep_data.get(category)
        if not category_data:
            continue
        for label in category_data.get("common", []):
            if label in seen_common:
                continue
            common.append(label)
            seen_common[label] = True
        for triple, values in category_data.get("selects", {{}}).items():
            existing = selects.get(triple, [])
            existing_seen = {{value: True for value in existing}}
            for value in values:
                if value not in existing_seen:
                    existing.append(value)
                    existing_seen[value] = True
            selects[triple] = existing
    return _list_value(common, selects)

def crate_deps(deps, package_name = None):
    dep_data = DEP_DATA.get(_package_name(package_name))
    if not dep_data:
        fail("Tried to get crate_deps for package %s but it had no Cargo.toml file" % _package_name(package_name))

    flat = {{}}
    for category in ["normal", "normal_dev", "proc_macro", "proc_macro_dev", "build", "build_proc_macro"]:
        aliases_data = dep_data.get(category + "_aliases")
        if aliases_data:
            flat.update(aliases_data.get("common", {{}}))
            for values in aliases_data.get("selects", {{}}).values():
                flat.update(values)

    missing = [dep for dep in deps if dep not in flat]
    if missing:
        fail("Could not find crates `%s` among dependencies of `%s`" % (missing, _package_name(package_name)))
    return [flat[dep] for dep in deps]

def crate_repositories():
    for repository in REPOSITORIES:
        maybe(
            fastpath_crate_repository,
            name = repository["name"],
            url = repository.get("url", ""),
            sha256 = repository.get("sha256", ""),
            strip_prefix = repository.get("strip_prefix", ""),
            path = repository.get("path", ""),
            archive = repository.get("archive", ""),
            render_metadata = repository["render_metadata"],
        )
    return [
        struct(repo = repository["name"], is_dev_dep = False)
        for repository in REPOSITORIES
        if repository.get("direct")
    ]
""".format(
        default_package_name = default_expr,
    )

def _render_build_root():
    return """\
package(default_visibility = ["//visibility:public"])

exports_files(
    [
        "crates.bzl",
        "data.bzl",
        "defs.bzl",
    ],
)

filegroup(
    name = "srcs",
    srcs = glob(
        include = [
            "*.bazel",
            "*.bzl",
        ],
        allow_empty = True,
    ),
)
"""

def _render_repositories_data(repositories):
    return "REPOSITORIES = " + repr(repositories)

def _feature_resolutions_render_metadata(feature_resolutions, platform_triples):
    return {
        "build_deps": {
            triple: sorted(feature_resolutions.build_deps[triple].keys())
            for triple in platform_triples
        },
        "deps": {
            triple: sorted(feature_resolutions.deps[triple].keys())
            for triple in platform_triples
        },
        "features_enabled": {
            triple: sorted(feature_resolutions.features_enabled[triple].keys())
            for triple in platform_triples
        },
    }

def _cargo_metadata_no_deps(repository_ctx, cargo_path, rustc_path, manifest_path, locked = True, allow_fail = False):
    args = [
        cargo_path,
        "metadata",
        "--format-version",
        "1",
    ]
    if locked:
        args.append("--locked")
    args.extend([
        "--no-deps",
        "--manifest-path",
        manifest_path,
    ])

    result = execute(
        repository_ctx,
        args = args,
        env = {
            "CARGO": str(cargo_path),
            "RUSTC": str(rustc_path),
        } | cargo_environ(repository_ctx, isolated = repository_ctx.attr.isolated),
        allow_fail = allow_fail,
        quiet = not repository_ctx.os.environ.get(CARGO_BAZEL_DEBUG),
    )
    if result.return_code:
        return None

    return json.decode(result.stdout)

def _manifest_label_relative_path(manifest):
    label = str(manifest)
    _, _, label_body = label.partition("//")
    package, _, name = label_body.partition(":")
    if package:
        return "{}/{}".format(package, name)
    return name

def _workspace_metadata_fact_key(repository_ctx, locked):
    return "{}|{}".format(
        "locked" if locked else "unlocked",
        "|".join([str(manifest) for manifest in repository_ctx.attr.manifests]),
    )

def _workspace_manifest_path(repository_ctx, workspace_root, relative_manifest):
    return repository_ctx.path("{}/{}".format(workspace_root, relative_manifest))

def _read_workspace_manifest_contents(repository_ctx, workspace_root, relative_manifests):
    manifest_contents = {}
    for relative_manifest in sorted(relative_manifests):
        manifest_path = _workspace_manifest_path(repository_ctx, workspace_root, relative_manifest)
        if not manifest_path.exists:
            return None
        manifest_contents[relative_manifest] = repository_ctx.read(manifest_path)
    return manifest_contents

def _cached_normalized_manifest(repository_ctx, fastpath_lockfile, cargo_lock_content, locked):
    if fastpath_lockfile == None or cargo_lock_content == None or not locked or repository_ctx.attr.lockfile:
        return None

    fact = fastpath_lockfile["facts"]["workspace_metadata"].get(_workspace_metadata_fact_key(repository_ctx, locked))
    if not fact:
        return None

    input_manifest_labels = [str(manifest) for manifest in repository_ctx.attr.manifests]
    if fact.get("input_manifest_labels") != input_manifest_labels:
        return None
    if fact.get("cargo_lock_content") != cargo_lock_content:
        return None

    workspace_root = fact.get("workspace_root")
    manifest_contents = fact.get("manifest_contents")
    manifest_path = fact.get("manifest_path")
    cargo_metadata = fact.get("cargo_metadata")
    if not workspace_root or type(manifest_contents) != "dict" or not manifest_path or type(cargo_metadata) != "dict":
        return None

    for relative_manifest, expected_content in manifest_contents.items():
        current_manifest_path = _workspace_manifest_path(repository_ctx, workspace_root, relative_manifest)
        if not current_manifest_path.exists:
            return None
        if repository_ctx.read(current_manifest_path) != expected_content:
            return None

    normalized_manifest_path = repository_ctx.path(manifest_path)
    if not normalized_manifest_path.exists:
        return None

    return struct(
        cache_hit = True,
        cargo_metadata = cargo_metadata,
        input_manifest_count = fact.get("input_manifest_count", len(repository_ctx.attr.manifests)),
        manifest_path = normalized_manifest_path,
    )

def _store_normalized_manifest(repository_ctx, fastpath_lockfile, cargo_lock_content, locked, normalized_manifest, workspace_root, relative_manifests):
    if fastpath_lockfile == None or cargo_lock_content == None or not locked or repository_ctx.attr.lockfile:
        return

    manifest_contents = _read_workspace_manifest_contents(
        repository_ctx = repository_ctx,
        workspace_root = workspace_root,
        relative_manifests = relative_manifests,
    )
    if manifest_contents == None:
        return

    fastpath_lockfile["facts"]["workspace_metadata"][_workspace_metadata_fact_key(repository_ctx, locked)] = {
        "cargo_lock_content": cargo_lock_content,
        "cargo_metadata": _clone_jsonish(normalized_manifest.cargo_metadata),
        "input_manifest_count": normalized_manifest.input_manifest_count,
        "input_manifest_labels": [str(manifest) for manifest in repository_ctx.attr.manifests],
        "manifest_contents": manifest_contents,
        "manifest_path": str(normalized_manifest.manifest_path),
        "workspace_root": workspace_root,
    }

def normalize_fastpath_workspace_manifest(
        repository_ctx,
        cargo_path,
        rustc_path,
        locked = True,
        fail_on_unsupported = True,
        fastpath_lockfile = None,
        cargo_lock_content = None):
    if repository_ctx.attr.packages:
        if fail_on_unsupported:
            fail("`resolver_backend = \"lockfile_fastpath\"` currently supports WORKSPACE manifest flows only; `packages` is not supported yet.")
        return None
    if not repository_ctx.attr.manifests:
        if fail_on_unsupported:
            fail("`resolver_backend = \"lockfile_fastpath\"` requires at least one manifest.")
        return None

    cached_manifest = _cached_normalized_manifest(
        repository_ctx = repository_ctx,
        fastpath_lockfile = fastpath_lockfile,
        cargo_lock_content = cargo_lock_content,
        locked = locked,
    )
    if cached_manifest != None:
        return cached_manifest

    first_manifest_path = repository_ctx.path(repository_ctx.attr.manifests[0])
    first_metadata = _cargo_metadata_no_deps(
        repository_ctx = repository_ctx,
        cargo_path = cargo_path,
        rustc_path = rustc_path,
        manifest_path = first_manifest_path,
        locked = locked,
        allow_fail = not fail_on_unsupported,
    )
    if first_metadata == None:
        return None

    workspace_root = first_metadata.get("workspace_root")
    if not workspace_root:
        if fail_on_unsupported:
            fail("Cargo metadata for {} did not report a workspace root.".format(first_manifest_path))
        return None

    workspace_member_package_ids = {
        package_id: True
        for package_id in first_metadata.get("workspace_members", [])
    }
    workspace_member_manifests = {
        _relative_to_workspace(package["manifest_path"], workspace_root): True
        for package in first_metadata.get("packages", [])
        if package.get("id") in workspace_member_package_ids
    }

    workspace_manifest = None
    for manifest in repository_ctx.attr.manifests:
        relative_manifest = _manifest_label_relative_path(manifest)
        if relative_manifest == "Cargo.toml":
            workspace_manifest = manifest
        if relative_manifest not in workspace_member_manifests:
            if fail_on_unsupported:
                fail(
                    "`resolver_backend = \"lockfile_fastpath\"` only supports multiple manifests " +
                    "when they normalize to the same Cargo workspace root. {} was not reported " +
                    "as a workspace member under {}.".format(manifest, workspace_root),
                )
            return None

    if workspace_manifest:
        workspace_manifest_path = repository_ctx.path(workspace_manifest)
    else:
        workspace_manifest_path = repository_ctx.path("{}/Cargo.toml".format(workspace_root))

    cargo_metadata = first_metadata
    if str(workspace_manifest_path) != str(first_manifest_path):
        cargo_metadata = _cargo_metadata_no_deps(
            repository_ctx = repository_ctx,
            cargo_path = cargo_path,
            rustc_path = rustc_path,
            manifest_path = workspace_manifest_path,
            locked = locked,
            allow_fail = not fail_on_unsupported,
        )
        if cargo_metadata == None:
            return None

    relative_manifests_to_track = dict(workspace_member_manifests)
    relative_manifests_to_track[_relative_to_workspace(str(workspace_manifest_path), workspace_root)] = True

    normalized_manifest = struct(
        cache_hit = False,
        cargo_metadata = cargo_metadata,
        input_manifest_count = len(repository_ctx.attr.manifests),
        manifest_path = workspace_manifest_path,
    )
    _store_normalized_manifest(
        repository_ctx = repository_ctx,
        fastpath_lockfile = fastpath_lockfile,
        cargo_lock_content = cargo_lock_content,
        locked = locked,
        normalized_manifest = normalized_manifest,
        workspace_root = workspace_root,
        relative_manifests = relative_manifests_to_track.keys(),
    )
    return normalized_manifest

def fastpath_resolve_and_render(repository_ctx, cargo_path, cargo_lockfile_path, rustc_path):
    """Resolve external crates from Cargo.lock and render hub/spoke data."""

    cargo_lock_content = repository_ctx.read(cargo_lockfile_path)
    profiler = _new_fastpath_profiler(repository_ctx)
    fastpath_lockfile = _load_fastpath_lockfile(repository_ctx)

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    normalized_manifest = normalize_fastpath_workspace_manifest(
        repository_ctx = repository_ctx,
        cargo_path = cargo_path,
        rustc_path = rustc_path,
        locked = True,
        fastpath_lockfile = fastpath_lockfile,
        cargo_lock_content = cargo_lock_content,
    )
    manifest_path = normalized_manifest.manifest_path
    cargo_metadata = normalized_manifest.cargo_metadata
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "cargo_metadata_no_deps",
        phase_started_ns,
        details = {
            "cache_hit": normalized_manifest.cache_hit,
            "input_manifests": normalized_manifest.input_manifest_count,
            "workspace_members": len(cargo_metadata.get("workspace_members", [])),
        },
    )

    render_config_dict = dict(json.decode(repository_ctx.attr.render_config or render_config()))
    default_package_name = render_config_dict.get("default_package_name")
    generate_cargo_toml_env_vars = render_config_dict.get("generate_cargo_toml_env_vars", True)
    generate_target_compatible_with = render_config_dict.get("generate_target_compatible_with", True)
    annotations = _prepare_annotations(repository_ctx)

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    lock_packages = _parse_cargo_lock(cargo_lock_content)
    platform_triples = list(repository_ctx.attr.supported_platform_triples)
    platform_cfg_attrs = [triple_to_cfg_attrs(triple) for triple in platform_triples]
    platform_cfg_attrs_by_triple = {
        cfg_attr["_triple"]: cfg_attr
        for cfg_attr in platform_cfg_attrs
    }
    cfg_match_cache = {}
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "parse_lockfile_and_platforms",
        phase_started_ns,
        details = {
            "lock_packages": len(lock_packages),
            "platforms": len(platform_triples),
        },
    )

    workspace_member_keys = _workspace_member_keys(cargo_metadata)
    full_metadata = None
    external_metadata_packages = {}
    if _needs_full_metadata(lock_packages, workspace_member_keys):
        phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
        full_metadata = json.decode(execute(
            repository_ctx,
            args = [
                cargo_path,
                "metadata",
                "--format-version",
                "1",
                "--locked",
                "--manifest-path",
                manifest_path,
            ],
            env = {
                "CARGO": str(cargo_path),
                "RUSTC": str(rustc_path),
            } | cargo_environ(repository_ctx, isolated = repository_ctx.attr.isolated),
            quiet = not repository_ctx.os.environ.get(CARGO_BAZEL_DEBUG),
        ).stdout)
        external_metadata_packages = _external_metadata_packages(full_metadata, workspace_member_keys)
        _fastpath_profile_record(
            repository_ctx,
            profiler,
            "cargo_metadata_full",
            phase_started_ns,
            details = {
                "external_metadata_packages": len(external_metadata_packages),
            },
        )

    lock_workspace_members = []
    registry_packages = []
    local_source_packages = []
    versions_by_name = {}

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    for package in lock_packages:
        name = package["name"]
        version = package["version"]
        _add_to_list_dict(versions_by_name, name, version)

        source = _normalize_source(package.get("source"))
        package["source"] = source

        if (name, version) in workspace_member_keys:
            lock_workspace_members.append(package)
        elif source.startswith("sparse+"):
            registry_packages.append(package)
        else:
            metadata_package = _lookup_external_metadata_package(package, external_metadata_packages)
            if not metadata_package:
                fail(
                    (
                        "Could not map non-registry dependency {} {} to cargo metadata. " +
                        "Fastpath currently expects `cargo metadata --locked` to report git/path dependencies."
                    ).format(name, version),
                )

            effective_source = source or _normalize_source(metadata_package.get("source"))
            if effective_source and not (
                effective_source.startswith("git+") or
                effective_source.startswith("path+")
            ):
                fail("Fastpath backend only supports sparse registry, git, and path crates today: {} {}".format(name, effective_source))

            local_package = dict(package)
            local_package["local_path"] = metadata_package["manifest_path"].removesuffix("/Cargo.toml")
            local_package["metadata_package"] = metadata_package
            local_package["source"] = effective_source
            local_source_packages.append(local_package)
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "classify_lock_packages",
        phase_started_ns,
        details = {
            "local_source_packages": len(local_source_packages),
            "registry_packages": len(registry_packages),
            "workspace_members": len(lock_workspace_members),
        },
    )

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    registry_dl_templates = _download_registry_templates(repository_ctx, registry_packages)
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "download_registry_templates",
        phase_started_ns,
        details = {"sources": len(registry_dl_templates)},
    )

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    registry_metadata_result = _download_registry_metadata(repository_ctx, registry_packages, fastpath_lockfile)
    registry_metadata = registry_metadata_result.metadata
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "download_registry_metadata",
        phase_started_ns,
        details = {
            "cache_hits": registry_metadata_result.cache_hits,
            "cache_misses": registry_metadata_result.cache_misses,
            "packages": len(registry_packages),
        },
    )

    feature_resolutions_by_fq_crate = {}
    resolver_packages = []

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    for package in registry_packages:
        name = package["name"]
        version = package["version"]
        source = package["source"]
        metadata = registry_metadata["{}|{}".format(source, name)].get(version)
        if not metadata:
            fail("Could not find {} {} in sparse index {}".format(name, version, source))
        checksum = package.get("checksum")
        if checksum and metadata["checksum"] != checksum:
            fail("Checksum mismatch for {} {} between Cargo.lock and sparse index".format(name, version))

        package_index = len(resolver_packages)
        possible_features = metadata["features"]
        possible_deps = _prepare_possible_deps(metadata["dependencies"])
        feature_resolutions = _new_feature_resolutions(
            package_index,
            possible_deps,
            possible_features,
            platform_triples,
        )
        package["links"] = metadata.get("links")
        package["feature_resolutions"] = feature_resolutions
        resolver_packages.append(package)
        feature_resolutions_by_fq_crate[_fq_crate(name, version)] = feature_resolutions

    for package in local_source_packages:
        metadata_package = package["metadata_package"]
        package_index = len(resolver_packages)
        feature_resolutions = _new_feature_resolutions(
            package_index,
            _prepare_possible_deps(
                metadata_package.get("dependencies", []),
                converter = _cargo_metadata_dep_to_dep_dict,
            ),
            metadata_package.get("features", {}),
            platform_triples,
        )
        package["links"] = metadata_package.get("links")
        package["feature_resolutions"] = feature_resolutions
        resolver_packages.append(package)
        feature_resolutions_by_fq_crate[_fq_crate(package["name"], package["version"])] = feature_resolutions

    resolver_versions_by_name = {
        name: _sorted_unique(versions)
        for name, versions in versions_by_name.items()
    }
    workspace_members_by_key = {
        (package["name"], package["version"]): package
        for package in lock_workspace_members
    }
    workspace_metadata = full_metadata or cargo_metadata
    workspace_packages = [
        package
        for package in workspace_metadata.get("packages", [])
        if (package["name"], package["version"]) in workspace_member_keys
    ]

    for package in workspace_packages:
        name = package["name"]
        version = package["version"]
        if name not in resolver_versions_by_name:
            resolver_versions_by_name[name] = []
        if version not in resolver_versions_by_name[name]:
            resolver_versions_by_name[name].append(version)

        feature_resolutions = _new_feature_resolutions(
            len(resolver_packages),
            _prepare_possible_deps(package.get("dependencies", []), converter = _cargo_metadata_dep_to_dep_dict),
            package.get("features", {}),
            platform_triples,
        )
        resolver_package = {
            "dependencies": workspace_members_by_key.get((name, version), {}).get("dependencies", []),
            "feature_resolutions": feature_resolutions,
            "name": name,
            "version": version,
        }
        resolver_packages.append(resolver_package)
        feature_resolutions_by_fq_crate[_fq_crate(name, version)] = feature_resolutions
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "prepare_resolver_inputs",
        phase_started_ns,
        details = {"resolver_packages": len(resolver_packages)},
    )

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    for package in resolver_packages:
        deps_by_name = {}
        for maybe_fq_dep in package.get("dependencies", []):
            idx = maybe_fq_dep.find(" ")
            if idx != -1:
                dep_name = maybe_fq_dep[:idx]
                dep_version = maybe_fq_dep[idx + 1:]
                _add_to_list_dict(deps_by_name, dep_name, dep_version)

        for dep in package["feature_resolutions"].possible_deps:
            dep_package = dep.get("package") or dep["name"]
            versions = resolver_versions_by_name.get(dep_package)
            if not versions:
                continue

            constrained_versions = deps_by_name.get(dep_package)
            if constrained_versions:
                versions = constrained_versions

            if len(versions) == 1:
                resolved_version = versions[0]
            else:
                req = dep.get("req")
                if not req:
                    continue
                resolved_version = select_matching_version(req, versions)
                if not resolved_version:
                    if not dep.get("optional"):
                        print("WARNING: could not resolve {} {} among {}".format(dep_package, req, versions))
                    continue

            dep_fq = _fq_crate(dep_package, resolved_version)
            dep["bazel_target"] = "@{}//:{}".format(repository_ctx.name, dep_fq)
            dep["feature_resolutions"] = feature_resolutions_by_fq_crate[dep_fq]

            target = dep.get("target")
            match_info = _cfg_match_info_for_target(target, platform_cfg_attrs, cfg_match_cache)
            if target and match_info.uses_feature_cfg:
                dep["target_expr"] = target
                dep["feature_sensitive"] = True
                dep["target"] = list(platform_triples)
            else:
                dep["target"] = list(match_info.matches)

    workspace_fq_deps = _compute_workspace_fq_deps(lock_workspace_members, resolver_versions_by_name)
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "resolve_dependency_targets",
        phase_started_ns,
        details = {"workspace_fq_deps": len(workspace_fq_deps)},
    )

    for package in workspace_packages:
        fq_deps = workspace_fq_deps.get(package["name"], {})
        for dep in package.get("dependencies", []):
            dep_name = dep["name"]
            dep_fq = fq_deps.get(dep_name)
            if not dep_fq:
                continue
            feature_resolutions = feature_resolutions_by_fq_crate[dep_fq]
            for triple in _cfg_match_info_for_target(dep.get("target"), platform_cfg_attrs, cfg_match_cache).matches:
                for feature in dep.get("features", []):
                    _set_add(feature_resolutions.features_enabled[triple], feature)
                if dep.get("uses_default_features", True):
                    _set_add(feature_resolutions.features_enabled[triple], "default")

    for crate_name, version_map in annotations.items():
        for version, annotation in version_map.items():
            if not annotation.get("crate_features"):
                continue
            target_versions = resolver_versions_by_name.get(crate_name, [])
            if version != "*":
                if version not in target_versions:
                    continue
                target_versions = [version]
            for target_version in target_versions:
                features_enabled = feature_resolutions_by_fq_crate[_fq_crate(crate_name, target_version)].features_enabled
                for triple in platform_triples:
                    _set_add_all(features_enabled[triple], annotation["crate_features"])

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    resolve(
        repository_ctx,
        resolver_packages,
        feature_resolutions_by_fq_crate,
        cfg_matches_expr_for_cfg_attrs,
        platform_cfg_attrs_by_triple,
        bool(repository_ctx.os.environ.get(CARGO_BAZEL_DEBUG)),
    )
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "solve_features",
        phase_started_ns,
        details = {"feature_resolution_crates": len(feature_resolutions_by_fq_crate)},
    )

    build_root = _render_build_root()
    dep_data = {}
    repositories = []
    direct_repo_names = {}
    is_proc_macro_by_fq = {}
    is_proc_macro_by_label = {}
    has_links_by_label = {}
    build_inputs_by_fq = {}
    external_packages = registry_packages + local_source_packages
    tar_binary = _tar_binary(repository_ctx)
    inspection_cache_hits = 0
    inspection_cache_misses = 0
    registry_archive_fetches_by_fq = {}

    for package in external_packages:
        if not package["source"].startswith("sparse+"):
            continue

        crate_name = package["name"]
        version = package["version"]
        checksum = package["checksum"]
        archive_path = _workspace_archive_cache_path(repository_ctx, crate_name, version, checksum)
        if archive_path.exists:
            continue

        repo_name = _spoke_repo_name(repository_ctx.name, crate_name, version)
        archive_rel = "_fastpath_archive/{}.tar.gz".format(repo_name)
        download_path = repository_ctx.path(archive_rel)
        registry_archive_fetches_by_fq[_fq_crate(crate_name, version)] = struct(
            archive_path = archive_path,
            download_path = download_path,
            token = repository_ctx.download(
                block = False,
                output = download_path,
                sha256 = checksum,
                url = _crate_archive_url(crate_name, version, package["source"], registry_dl_templates, checksum = checksum),
            ),
        )

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    for package in external_packages:
        crate_name = package["name"]
        version = package["version"]
        fq = _fq_crate(crate_name, version)
        annotation = _annotation_for(annotations, crate_name, version)
        repo_name = _spoke_repo_name(repository_ctx.name, crate_name, version)

        if package["source"].startswith("sparse+"):
            archive_url = _crate_archive_url(crate_name, version, package["source"], registry_dl_templates, checksum = package["checksum"])
            archive_path = _workspace_archive_cache_path(repository_ctx, crate_name, version, package["checksum"])
            archive_fetch = registry_archive_fetches_by_fq.get(fq)
            if archive_fetch:
                archive_fetch.token.wait()
                execute(
                    repository_ctx,
                    args = [
                        "/bin/sh",
                        "-c",
                        'mkdir -p "$1" && cp "$2" "$3"',
                        "sh",
                        str(archive_fetch.archive_path.dirname),
                        str(archive_fetch.download_path),
                        str(archive_fetch.archive_path),
                    ],
                    quiet = True,
                )
            inspection_fact_key = _registry_inspection_fact_key(
                package["source"],
                crate_name,
                version,
                "" if repository_ctx.attr.lockfile else package["checksum"],
            )
            inspection_fact = fastpath_lockfile["facts"]["registry_inspection"].get(inspection_fact_key)
            if inspection_fact:
                inspection_cache_hits += 1
                inspection_fact = _clone_jsonish(inspection_fact)
                manifest_info = dict(inspection_fact["manifest_info"])
                source_probe = _source_probe_from_registry_inspection_fact(inspection_fact)
            else:
                inspection_cache_misses += 1
                if tar_binary:
                    archive_inspection = _inspect_registry_archive(repository_ctx, tar_binary, archive_path, crate_name, version)
                    manifest_info = archive_inspection.manifest_info
                    source_probe = _new_source_probe(
                        archive_entries = archive_inspection.archive_entries,
                        archive_prefix = archive_inspection.prefix,
                    )
                else:
                    inspect_root_rel = "_fastpath_inspect/{}_{}".format(repo_name, len(build_inputs_by_fq))
                    inspect_root = repository_ctx.path(inspect_root_rel)
                    repository_ctx.download_and_extract(
                        output = inspect_root,
                        sha256 = package["checksum"],
                        stripPrefix = "{}-{}".format(crate_name, version),
                        type = "tar.gz",
                        url = archive_url,
                    )
                    manifest_file = inspect_root.get_child("Cargo.toml")
                    if not manifest_file.exists:
                        fail("Crate {} {} did not contain Cargo.toml at {}".format(crate_name, version, manifest_file))
                    manifest_info = _parse_manifest_subset(repository_ctx.read(manifest_file))
                    source_probe = _new_source_probe(inspect_root = inspect_root)
                fastpath_lockfile["facts"]["registry_inspection"][inspection_fact_key] = _clone_jsonish(_registry_inspection_fact(manifest_info, source_probe))
            repository = {
                "archive": str(archive_path),
                "direct": False,
                "name": repo_name,
                "sha256": package["checksum"],
                "strip_prefix": "{}-{}".format(crate_name, version),
                "url": archive_url,
            }
        else:
            inspect_root = repository_ctx.path(package["local_path"])
            if not package["source"] or package["source"].startswith("path+"):
                _track_local_source_tree(repository_ctx, package["local_path"])
            manifest_file = inspect_root.get_child("Cargo.toml")
            if not manifest_file.exists:
                fail("Crate {} {} did not contain Cargo.toml at {}".format(crate_name, version, manifest_file))
            manifest_info = _parse_manifest_subset(repository_ctx.read(manifest_file))
            source_probe = _new_source_probe(inspect_root = inspect_root)
            repository = {
                "direct": False,
                "name": repo_name,
                "path": package["local_path"],
            }

        manifest_info["lib"] = _infer_lib(manifest_info, crate_name, source_probe)
        if not manifest_info["lib"]:
            fail("Fastpath backend currently requires library crates. {} {} has no library target.".format(crate_name, version))

        is_proc_macro = manifest_info["lib"].get("proc-macro", False) or manifest_info["lib"].get("proc_macro", False)
        is_proc_macro_by_fq[fq] = is_proc_macro
        hub_label = "@{}//:{}".format(repository_ctx.name, fq)
        is_proc_macro_by_label[hub_label] = is_proc_macro
        if package.get("links"):
            has_links_by_label[hub_label] = True

        build_inputs_by_fq[fq] = struct(
            annotation = annotation,
            manifest_info = manifest_info,
            package = package,
            source_probe = source_probe,
        )
        repositories.append(repository)
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "inspect_external_crates",
        phase_started_ns,
        details = {
            "cache_hits": inspection_cache_hits,
            "cache_misses": inspection_cache_misses,
            "external_packages": len(external_packages),
        },
    )

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    for fq, build_input in build_inputs_by_fq.items():
        package = build_input.package
        for repository in repositories:
            if repository["name"] != _spoke_repo_name(repository_ctx.name, package["name"], package["version"]):
                continue
            repository["render_metadata"] = json.encode({
                "annotation": build_input.annotation,
                "crate_name": package["name"],
                "feature_resolutions": _feature_resolutions_render_metadata(package["feature_resolutions"], platform_triples),
                "generate_binaries": repository_ctx.attr.generate_binaries,
                "generate_build_scripts": repository_ctx.attr.generate_build_scripts,
                "generate_cargo_toml_env_vars": generate_cargo_toml_env_vars,
                "generate_target_compatible_with": generate_target_compatible_with,
                "links_labels": sorted(has_links_by_label.keys()),
                "platform_triples": platform_triples,
                "proc_macro_labels": sorted([
                    label
                    for label, is_proc_macro in is_proc_macro_by_label.items()
                    if is_proc_macro
                ]),
                "version": package["version"],
            })
            break
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "prepare_spoke_render_metadata",
        phase_started_ns,
        details = {"repositories": len(repositories)},
    )

    versions_by_name = {
        name: _sorted_unique(versions)
        for name, versions in resolver_versions_by_name.items()
    }

    build_root += "\n# Workspace Member Dependencies\n"
    workspace_dep_versions_by_name = {}
    workspace_root = workspace_metadata["workspace_root"]

    for package in workspace_packages:
        package_name = _manifest_package_name(package["manifest_path"], workspace_root)
        fq = _fq_crate(package["name"], package["version"])
        package_feature_resolutions = feature_resolutions_by_fq_crate[fq]
        dep_entry = {}
        for category in [
            "normal",
            "normal_dev",
            "proc_macro",
            "proc_macro_dev",
            "build",
            "build_proc_macro",
        ]:
            dep_entry[category] = {"selects": {}}
            dep_entry[category + "_aliases"] = {"common": {}, "selects": {}}

        fq_deps = workspace_fq_deps.get(package["name"], {})
        for dep in package.get("dependencies", []):
            dep_name = dep["name"]
            dep_fq = fq_deps.get(dep_name)
            if not dep_fq:
                continue
            dep_version = dep_fq[len(dep_name) + 1:] if dep_fq.startswith(dep_name + "-") else None
            is_first_party_dep = not dep.get("source") and dep_version and workspace_member_keys.get((dep_name, dep_version))
            if is_first_party_dep:
                continue

            label = "@{}//:{}".format(repository_ctx.name, dep_fq)
            match = _cfg_match_info_for_target(dep.get("target"), platform_cfg_attrs, cfg_match_cache).matches
            category = _dep_category(dep.get("kind", "normal"), is_proc_macro_by_fq.get(dep_fq, False))

            for triple in match:
                if dep.get("optional"):
                    dep_alias = dep.get("rename") or dep_name
                    triple_features = package_feature_resolutions.features_enabled[triple]
                    if dep_alias not in triple_features and ("dep:" + dep_alias) not in triple_features:
                        continue
                _add_to_set_dict(dep_entry[category]["selects"], triple, label)

                aliases_for_triple = dep_entry[category + "_aliases"]["selects"].get(triple, {})
                alias_name = (dep.get("rename") or dep_name).replace("-", "_")
                aliases_for_triple[alias_name] = label
                dep_entry[category + "_aliases"]["selects"][triple] = aliases_for_triple

            _add_to_set_dict(workspace_dep_versions_by_name, dep_name, dep_fq)
            if dep.get("kind") != "dev":
                direct_repo_names[_spoke_repo_name(repository_ctx.name, dep_name, dep_fq[len(dep_name) + 1:])] = True

        dep_data[package_name] = {}
        for category, category_data in dep_entry.items():
            common, selects = _shared_and_per_platform(
                category_data["selects"],
            ) if not category.endswith("_aliases") else _shared_and_per_platform_dict(category_data["selects"])
            dep_data[package_name][category] = {
                "common": common,
                "selects": _sort_dict_values(selects) if not category.endswith("_aliases") else selects,
            }

    for repository in repositories:
        if repository["name"] in direct_repo_names:
            repository["direct"] = True

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    for name, versions in sorted(versions_by_name.items()):
        for version in versions:
            fq = _fq_crate(name, version)
            build_input = build_inputs_by_fq.get(fq)
            if not build_input:
                continue
            spoke_repo = _spoke_repo_name(repository_ctx.name, name, version)
            build_root += """
alias(
    name = {versioned},
    actual = {actual},
    tags = ["manual"],
)
""".format(
                actual = repr("@{}//:{}".format(spoke_repo, name)),
                versioned = repr(fq),
            )

            generated_bins = _selected_bins(
                repository_ctx,
                build_input.annotation,
                name,
                build_input.manifest_info,
                build_input.source_probe,
            ) if build_input else []
            for bin_target in generated_bins:
                build_root += """
alias(
    name = {name},
    actual = {actual},
    tags = ["manual"],
)
""".format(
                    actual = repr("@{}//:{}__bin".format(spoke_repo, bin_target["name"])),
                    name = repr("{}__{}".format(fq, bin_target["name"])),
                )

            for alias_name, target in sorted((build_input.annotation.get("extra_aliased_targets") or {}).items()):
                build_root += """
alias(
    name = {name},
    actual = {actual},
    tags = ["manual"],
)
""".format(
                    actual = repr("@{}//:{}".format(spoke_repo, target)),
                    name = repr("{}__{}".format(fq, alias_name)),
                )

        workspace_versions = sorted((workspace_dep_versions_by_name.get(name) or {}).keys())
        if workspace_versions:
            default_fq = workspace_versions[-1]
            build_root += """
alias(
    name = {name},
    actual = {actual},
    tags = ["manual"],
)
""".format(
                actual = repr(":{}".format(default_fq)),
                name = repr(name),
            )
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "render_hub_repo_metadata",
        phase_started_ns,
        details = {
            "direct_repositories": len(direct_repo_names),
            "workspace_packages": len(workspace_packages),
        },
    )

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    repository_ctx.file("BUILD.bazel", build_root)
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "write_root_build_bazel",
        phase_started_ns,
        details = {"repository_rules": len(repositories)},
    )

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    repository_ctx.file("data.bzl", _render_dep_data(dep_data) + "\n\n" + _render_repositories_data(repositories))
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "write_data_bzl",
        phase_started_ns,
        details = {
            "packages": len(dep_data),
            "repository_rules": len(repositories),
        },
    )

    phase_started_ns = _fastpath_profile_start(repository_ctx, profiler)
    repository_ctx.file("defs.bzl", _render_defs_bzl(default_package_name))
    repository_ctx.file("crates.bzl", 'load(":defs.bzl", "crate_repositories")\n')
    _fastpath_profile_record(
        repository_ctx,
        profiler,
        "write_defs_bzl",
        phase_started_ns,
        details = {"default_package_name": default_package_name != None},
    )

    _write_fastpath_lockfile(repository_ctx, fastpath_lockfile)
    _write_fastpath_profile(
        repository_ctx,
        profiler,
        summary = {
            "build_files": len(repositories),
            "direct_repositories": len(direct_repo_names),
            "external_packages": len(external_packages),
            "full_metadata_used": full_metadata != None,
            "inspection_cache_entries": len(fastpath_lockfile["facts"]["registry_inspection"]),
            "local_source_packages": len(local_source_packages),
            "registry_entry_cache_entries": len(fastpath_lockfile["facts"]["registry_entries"]),
            "registry_packages": len(registry_packages),
            "repository_rules": len(repositories),
            "workspace_metadata_cache_entries": len(fastpath_lockfile["facts"]["workspace_metadata"]),
            "workspace_packages": len(workspace_packages),
        },
    )
