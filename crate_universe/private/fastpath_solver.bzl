"""Feature/dependency fixpoint solver for the experimental fastpath backend."""

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

def _set_remove_all(items, values):
    for value in values:
        if value in items:
            items.pop(value)

def _count(feature_resolutions_by_fq_crate):
    n = 0
    for feature_resolutions in feature_resolutions_by_fq_crate.values():
        for features in feature_resolutions.features_enabled.values():
            n += len(features)

        for build_deps in feature_resolutions.build_deps.values():
            n += len(build_deps)

        for deps in feature_resolutions.deps.values():
            n += len(deps)

    return n

def _dep_target_matches_triple(dep, triple, package_feature_set, cfg_matches_expr_for_cfg_attrs, cfg_attrs_by_triple):
    remaining = dep["target"]
    if triple not in remaining:
        return False

    if not dep.get("feature_sensitive", False):
        return True

    cfg_attr = cfg_attrs_by_triple[triple]
    return bool(cfg_matches_expr_for_cfg_attrs(
        dep["target_expr"],
        [cfg_attr],
        features = package_feature_set,
    ).matches)

def _propagate_feature_enablement(
        package_changed,
        dirty_package_indices,
        package,
        features_enabled,
        feature_resolutions,
        cfg_matches_expr_for_cfg_attrs,
        cfg_attrs_by_triple,
        debug):
    possible_features = feature_resolutions.possible_features

    for triple, feature_set in features_enabled.items():
        if not feature_set:
            continue

        for enabled_feature in list(feature_set):
            enables = possible_features.get(enabled_feature)
            if not enables:
                continue

            for feature in enables:
                idx = feature.find("/")
                if idx == -1:
                    if feature not in feature_set:
                        package_changed = True
                        _set_add(feature_set, feature)
                    continue

                dep_name = feature[:idx]
                dep_feature = feature[idx + 1:]

                dep_optional = False
                optional_marker = False
                if dep_name[-1] == "?":
                    optional_marker = True
                    dep_name = dep_name[:-1]

                found = False
                for dep in feature_resolutions.possible_deps:
                    if dep_name == dep["name"] and _dep_target_matches_triple(
                        dep,
                        triple,
                        feature_set,
                        cfg_matches_expr_for_cfg_attrs,
                        cfg_attrs_by_triple,
                    ):
                        found = True
                        dep_optional = dep.get("optional", False)
                        if not optional_marker or not dep_optional or dep_name in feature_set or ("dep:" + dep_name) in feature_set:
                            dep_feature_resolutions = dep["feature_resolutions"]
                            triple_features = dep_feature_resolutions.features_enabled[triple]
                            if _set_add(triple_features, dep_feature):
                                _set_add(dirty_package_indices, dep_feature_resolutions.package_index)
                        break

                if dep_optional and (not optional_marker) and dep_name not in feature_set:
                    package_changed = True
                    _set_add(feature_set, dep_name)

                if not found and debug:
                    print("Skipping enabling subfeature", feature, "for", package["name"], "@", package["version"], "it's not a dep...")

    return package_changed

def _resolve_one_round(packages, dirty_package_indices, cfg_matches_expr_for_cfg_attrs, cfg_attrs_by_triple, debug):
    new_dirty_package_indices = {}

    for index in dirty_package_indices:
        package = packages[index]
        package_changed = False

        feature_resolutions = package["feature_resolutions"]
        features_enabled = feature_resolutions.features_enabled
        deps = feature_resolutions.deps

        if _propagate_feature_enablement(
            package_changed,
            new_dirty_package_indices,
            package,
            features_enabled,
            feature_resolutions,
            cfg_matches_expr_for_cfg_attrs,
            cfg_attrs_by_triple,
            debug,
        ):
            package_changed = True

        for dep in feature_resolutions.possible_deps:
            bazel_target = dep.get("bazel_target")
            if not bazel_target:
                continue

            kind = dep.get("kind", "normal")
            dep_feature_resolutions = dep["feature_resolutions"]

            has_alias = "package" in dep
            dep_name = dep["name"]
            prefixed_dep_alias = "dep:" + dep_name
            optional = dep.get("optional", False)

            if dep.get("feature_sensitive"):
                match = _new_set([
                    triple
                    for triple in dep["target"]
                    if _dep_target_matches_triple(
                        dep,
                        triple,
                        features_enabled[triple],
                        cfg_matches_expr_for_cfg_attrs,
                        cfg_attrs_by_triple,
                    )
                ])
            else:
                match = _new_set(dep["target"])

            to_remove = None
            for triple in match.keys():
                if optional:
                    features_for_triple = features_enabled[triple]
                    if dep_name not in features_for_triple and prefixed_dep_alias not in features_for_triple:
                        continue

                triple_deps = deps[triple] if kind == "normal" else feature_resolutions.build_deps[triple]
                if package_changed or bazel_target not in triple_deps:
                    package_changed = True
                    _set_add(triple_deps, bazel_target)

                if has_alias:
                    feature_resolutions.aliases[dep_name.replace("-", "_")] = bazel_target

                triple_features = dep_feature_resolutions.features_enabled[triple]

                dep_features = dep.get("features")
                if dep_features:
                    prev_length = len(triple_features)
                    _set_add_all(triple_features, dep_features)
                    if prev_length != len(triple_features):
                        _set_add(new_dirty_package_indices, dep_feature_resolutions.package_index)
                if not to_remove:
                    to_remove = {}
                _set_add(to_remove, triple)

            if to_remove:
                if len(to_remove) == len(match):
                    dep["bazel_target"] = None

        if package_changed:
            _set_add(new_dirty_package_indices, index)

    return new_dirty_package_indices

_MAX_ROUNDS = 50

def resolve(repository_ctx, packages, feature_resolutions_by_fq_crate, cfg_matches_expr_for_cfg_attrs, cfg_attrs_by_triple, debug):
    """Run fixpoint resolution until features and transitive deps converge."""

    dirty_package_indices = range(len(packages))
    converged = False
    for i in range(_MAX_ROUNDS):
        repository_ctx.report_progress("Running lockfile fastpath resolution round {}".format(i))

        dirty_package_indices = _resolve_one_round(
            packages,
            dirty_package_indices,
            cfg_matches_expr_for_cfg_attrs,
            cfg_attrs_by_triple,
            debug,
        )
        if not dirty_package_indices:
            if debug:
                count = _count(feature_resolutions_by_fq_crate)
                print("Fastpath resolved", count, "items in", i + 1, "rounds")
            converged = True
            break
        dirty_package_indices = sorted(dirty_package_indices.keys())

    if not converged:
        fail("Lockfile fastpath resolution did not converge. Please report this to rules_rust.")
