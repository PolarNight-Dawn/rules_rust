#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/fastpath-regression.XXXXXX")"
KEEP_GENERATED="${KEEP_GENERATED:-0}"
BAZEL="${BAZEL:-bazel}"
BAZEL_BATCH="${BAZEL_BATCH:-1}"
OUTPUT_USER_ROOT="${OUTPUT_USER_ROOT:-${ROOT}/.tmp/bazel_output_user_root}"

bazel_cmd() {
  local args=("${BAZEL}")
  if [[ "${BAZEL_BATCH}" == "1" ]]; then
    args+=(--batch)
  fi
  args+=(--output_user_root="${OUTPUT_USER_ROOT}")
  "${args[@]}" "$@"
}

cleanup() {
  if [[ "${KEEP_GENERATED}" != "1" ]]; then
    rm -f "${ROOT}/Cargo.toml" "${ROOT}/Cargo.lock"
    rm -rf "${TMPDIR}"
  fi
}

trap cleanup EXIT

GIT_DEP_DIR="${TMPDIR}/git_message"
mkdir -p "${GIT_DEP_DIR}/src"

cat > "${GIT_DEP_DIR}/Cargo.toml" <<'EOF'
[package]
name = "git_message"
version = "0.1.0"
edition = "2021"

[lib]
path = "src/lib.rs"
EOF

cat > "${GIT_DEP_DIR}/src/lib.rs" <<'EOF'
pub fn message() -> &'static str {
    "hello from git dependency"
}
EOF

git init -q "${GIT_DEP_DIR}"
git -C "${GIT_DEP_DIR}" add Cargo.toml src/lib.rs
GIT_AUTHOR_NAME=rules_rust \
GIT_AUTHOR_EMAIL=rules_rust@example.com \
GIT_COMMITTER_NAME=rules_rust \
GIT_COMMITTER_EMAIL=rules_rust@example.com \
git -C "${GIT_DEP_DIR}" commit -q -m "seed git dependency"

GIT_DEP_URL="file://${GIT_DEP_DIR}"
GIT_DEP_REV="$(git -C "${GIT_DEP_DIR}" rev-parse HEAD)"

python3 - "${ROOT}/Cargo.toml.template" "${ROOT}/Cargo.toml" "${GIT_DEP_URL}" "${GIT_DEP_REV}" <<'PY'
import pathlib
import sys

template = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(
    template.replace("__GIT_DEP_URL__", sys.argv[3]).replace("__GIT_DEP_REV__", sys.argv[4])
)
PY

python3 - "${ROOT}/Cargo.lock.template" "${ROOT}/Cargo.lock" "${GIT_DEP_URL}" "${GIT_DEP_REV}" <<'PY'
import pathlib
import sys

template = pathlib.Path(sys.argv[1]).read_text()
pathlib.Path(sys.argv[2]).write_text(
    template.replace("__GIT_DEP_URL__", sys.argv[3]).replace("__GIT_DEP_REV__", sys.argv[4])
)
PY

export CARGO_BAZEL_FASTPATH_PROFILE=1

cd "${ROOT}"

bazel_cmd sync --only=fastpath_regression_index
bazel_cmd sync --only=fastpath_regression_render_config_index
bazel_cmd test //:regression_test --verbose_failures

OUTPUT_BASE="$(bazel_cmd info output_base)"
REPO_DIR="${OUTPUT_BASE}/external/fastpath_regression_index"
RENDER_CONFIG_REPO_DIR="${OUTPUT_BASE}/external/fastpath_regression_render_config_index"
ANYHOW_REPO_DIR="${OUTPUT_BASE}/external/fastpath_regression_index__anyhow-1.0.102"
BUILD_HELPER_REPO_DIR="${OUTPUT_BASE}/external/fastpath_regression_index__build_helper-0.1.0"
OVERRIDE_REPO_DIR="${OUTPUT_BASE}/external/fastpath_regression_index__override_dep-0.1.0"

grep -F '"**/*.md"' "${ANYHOW_REPO_DIR}/BUILD.bazel" >/dev/null
grep -F '"tests/**/*"' "${ANYHOW_REPO_DIR}/BUILD.bazel" >/dev/null
grep -F '"src/**/*.rs"' "${ANYHOW_REPO_DIR}/BUILD.bazel" >/dev/null
grep -F 'fastpath_anyhow_marker' "${ANYHOW_REPO_DIR}/BUILD.bazel" >/dev/null
grep -F '"data/**/*.txt"' "${BUILD_HELPER_REPO_DIR}/BUILD.bazel" >/dev/null
grep -F '"fastpath-regression": "1"' "${BUILD_HELPER_REPO_DIR}/BUILD.bazel" >/dev/null
grep -F '"@//:build_link_dep"' "${BUILD_HELPER_REPO_DIR}/BUILD.bazel" >/dev/null
grep -F 'actual = "@//:override_dep_impl"' "${OVERRIDE_REPO_DIR}/BUILD.bazel" >/dev/null
grep -F 'name = "build_helper-0.1.0__build_script"' "${REPO_DIR}/BUILD.bazel" >/dev/null
if ! grep -F 'generate_cargo_toml_env_vars\":false' "${RENDER_CONFIG_REPO_DIR}/data.bzl" >/dev/null; then
  echo "render_config fastpath repo did not propagate generate_cargo_toml_env_vars = False" >&2
  exit 1
fi
if ! grep -F 'generate_target_compatible_with\":false' "${RENDER_CONFIG_REPO_DIR}/data.bzl" >/dev/null; then
  echo "render_config fastpath repo did not propagate generate_target_compatible_with = False" >&2
  exit 1
fi
test -f "${REPO_DIR}/_fastpath_profile.json"

python3 - "${REPO_DIR}/_fastpath_profile.json" <<'PY'
import json
import pathlib
import sys

profile = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected = {
    "cargo_metadata_no_deps",
    "classify_lock_packages",
    "solve_features",
    "prepare_spoke_render_metadata",
    "write_root_build_bazel",
    "write_data_bzl",
    "write_defs_bzl",
}

phases = {event["phase"] for event in profile["events"]}
missing = sorted(expected - phases)
if missing:
    raise SystemExit("missing fastpath profile phases: " + ", ".join(missing))

summary = profile["summary"]
if summary["local_source_packages"] < 3:
    raise SystemExit("expected path/git crates to be counted in the profile summary")
if summary["repository_rules"] < 3:
    raise SystemExit("expected generated spoke repositories in the profile summary")
if not summary["full_metadata_used"]:
    raise SystemExit("expected fastpath regression to require full cargo metadata")
PY

BAZEL="${BAZEL}" BAZEL_BATCH="${BAZEL_BATCH}" "${ROOT}/validate_boundaries.sh"

echo "fastpath regression validation passed"
