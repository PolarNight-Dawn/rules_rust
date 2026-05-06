#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_RUST_ROOT="$(cd "${ROOT}/../.." && pwd)"
WORKDIR="${FASTPATH_BOUNDARY_WORKDIR:-${ROOT}/.tmp/boundary_workspace}"
OUTPUT_USER_ROOT="${OUTPUT_USER_ROOT:-${ROOT}/.tmp/boundary_bazel_output_user_root}"
BAZEL="${BAZEL:-bazel}"
BAZEL_BATCH="${BAZEL_BATCH:-1}"
KEEP_GENERATED="${KEEP_GENERATED:-0}"

bazel_cmd() {
  local args=("${BAZEL}")
  if [[ "${BAZEL_BATCH}" == "1" ]]; then
    args+=(--batch)
  fi
  args+=(--output_user_root="${OUTPUT_USER_ROOT}")
  (
    cd "${WORKDIR}"
    "${args[@]}" "$@"
  )
}

reset_dir() {
  local path="$1"
  if [[ ! -e "${path}" ]]; then
    return
  fi
  chmod -R u+w "${path}" 2>/dev/null || true
  find "${path}" -depth -exec chmod u+w {} + 2>/dev/null || true
  rm -rf "${path}"
}

cleanup() {
  if [[ "${KEEP_GENERATED}" != "1" ]]; then
    reset_dir "${WORKDIR}"
  fi
}

trap cleanup EXIT

write_boundary_workspace() {
  reset_dir "${WORKDIR}"
  mkdir -p "${WORKDIR}/src" "${WORKDIR}/member/src" "${WORKDIR}/other/src"

  cat > "${WORKDIR}/.bazelrc" <<'EOF'
common --noenable_bzlmod --enable_workspace
common --lockfile_mode=off
EOF

  cat > "${WORKDIR}/.bazelversion" <<'EOF'
7.4.1
EOF

  cat > "${WORKDIR}/MODULE.bazel" <<'EOF'
###############################################################################
# Bazel now uses Bzlmod by default to manage external dependencies.
###############################################################################
EOF

  cat > "${WORKDIR}/BUILD.bazel" <<'EOF'
exports_files([
    "Cargo.lock",
    "Cargo.toml",
    "cargo-bazel-lock-independent.json",
    "cargo-bazel-lock-skip.json",
])
EOF

  cat > "${WORKDIR}/Cargo.toml" <<'EOF'
[package]
name = "boundary_root"
version = "0.1.0"
edition = "2021"

[workspace]
members = ["member"]
resolver = "2"

[lib]
path = "src/lib.rs"

[dependencies]
boundary_member = { path = "member" }
EOF

  cat > "${WORKDIR}/src/lib.rs" <<'EOF'
pub fn root_message() -> &'static str {
    boundary_member::message()
}
EOF

  cat > "${WORKDIR}/member/Cargo.toml" <<'EOF'
[package]
name = "boundary_member"
version = "0.1.0"
edition = "2021"

[lib]
path = "src/lib.rs"
EOF

  cat > "${WORKDIR}/member/src/lib.rs" <<'EOF'
pub fn message() -> &'static str {
    "member"
}
EOF

  cat > "${WORKDIR}/other/Cargo.toml" <<'EOF'
[package]
name = "independent_workspace"
version = "0.1.0"
edition = "2021"

[lib]
path = "src/lib.rs"
EOF

  cat > "${WORKDIR}/other/src/lib.rs" <<'EOF'
pub fn independent() -> &'static str {
    "independent"
}
EOF

  cat > "${WORKDIR}/Cargo.lock" <<'EOF'
# This file is intentionally small and stable for fastpath boundary tests.
version = 4

[[package]]
name = "boundary_member"
version = "0.1.0"

[[package]]
name = "boundary_root"
version = "0.1.0"
dependencies = [
 "boundary_member",
]
EOF

  : > "${WORKDIR}/cargo-bazel-lock-independent.json"
  : > "${WORKDIR}/cargo-bazel-lock-skip.json"

  cat > "${WORKDIR}/WORKSPACE.bazel" <<EOF
workspace(name = "fastpath_boundary_regression")

local_repository(
    name = "rules_rust",
    path = "${RULES_RUST_ROOT}",
)

load("@rules_rust//rust:repositories.bzl", "rules_rust_dependencies", "rust_register_toolchains")

rules_rust_dependencies()

rust_register_toolchains(
    edition = "2021",
)

load("@rules_rust//crate_universe:repositories.bzl", "crate_universe_dependencies")

crate_universe_dependencies(bootstrap = True)

load("@rules_rust//crate_universe:defs.bzl", "crates_repository")

crates_repository(
    name = "boundary_multi_index",
    cargo_lockfile = "//:Cargo.lock",
    generator_urls = {},
    manifests = [
        "//:Cargo.toml",
        "//:member/Cargo.toml",
    ],
    resolver_backend = "lockfile_fastpath",
)

crates_repository(
    name = "boundary_independent_index",
    cargo_lockfile = "//:Cargo.lock",
    generator = "@cargo_bazel_bootstrap//:cargo-bazel",
    lockfile = "//:cargo-bazel-lock-independent.json",
    manifests = [
        "//:Cargo.toml",
        "//:other/Cargo.toml",
    ],
    resolver_backend = "lockfile_fastpath",
)

crates_repository(
    name = "boundary_skip_fallback_index",
    cargo_lockfile = "//:Cargo.lock",
    generator = "@cargo_bazel_bootstrap//:cargo-bazel",
    lockfile = "//:cargo-bazel-lock-skip.json",
    manifests = ["//:Cargo.toml"],
    resolver_backend = "lockfile_fastpath",
    skip_cargo_lockfile_overwrite = True,
)
EOF
}

output_base() {
  bazel_cmd info output_base
}

profile_path() {
  local repo="$1"
  printf '%s/external/%s/_fastpath_profile.json\n' "$(output_base)" "${repo}"
}

sync_logged() {
  local log="$1"
  shift
  mkdir -p "${WORKDIR}/logs"
  bazel_cmd "$@" >"${WORKDIR}/logs/${log}.log" 2>&1
}

expect_sync_failure() {
  local log="$1"
  shift
  mkdir -p "${WORKDIR}/logs"
  if bazel_cmd "$@" >"${WORKDIR}/logs/${log}.log" 2>&1; then
    echo "expected command to fail: bazel $*" >&2
    exit 1
  fi
}

assert_profile_cache_state() {
  local profile="$1"
  local expected_cache_hit="$2"
  local expected_input_manifests="$3"
  python3 - "${profile}" "${expected_cache_hit}" "${expected_input_manifests}" <<'PY'
import json
import pathlib
import sys

profile = json.loads(pathlib.Path(sys.argv[1]).read_text())
expected_cache_hit = sys.argv[2] == "true"
expected_input_manifests = int(sys.argv[3])
events = {event["phase"]: event for event in profile["events"]}
event = events.get("cargo_metadata_no_deps")
if not event:
    raise SystemExit("missing cargo_metadata_no_deps profile event")
details = event.get("details") or {}
if details.get("cache_hit") is not expected_cache_hit:
    raise SystemExit(
        f"expected cache_hit={expected_cache_hit}, got {details.get('cache_hit')}"
    )
if details.get("input_manifests") != expected_input_manifests:
    raise SystemExit(
        f"expected input_manifests={expected_input_manifests}, got {details.get('input_manifests')}"
    )
if profile.get("summary", {}).get("workspace_metadata_cache_entries", 0) < 1:
    raise SystemExit("expected workspace metadata cache entries")
PY
}

assert_log_contains() {
  local log="$1"
  local needle="$2"
  if ! grep -F "${needle}" "${WORKDIR}/logs/${log}.log" >/dev/null; then
    echo "expected ${WORKDIR}/logs/${log}.log to contain: ${needle}" >&2
    tail -n 80 "${WORKDIR}/logs/${log}.log" >&2 || true
    exit 1
  fi
}

assert_log_not_contains() {
  local log="$1"
  local needle="$2"
  if grep -F "${needle}" "${WORKDIR}/logs/${log}.log" >/dev/null; then
    echo "expected ${WORKDIR}/logs/${log}.log not to contain: ${needle}" >&2
    tail -n 80 "${WORKDIR}/logs/${log}.log" >&2 || true
    exit 1
  fi
}

assert_no_fastpath_profile() {
  local repo="$1"
  local profile
  profile="$(profile_path "${repo}")"
  if [[ -f "${profile}" ]]; then
    echo "expected ${repo} to use legacy fallback, but fastpath profile exists: ${profile}" >&2
    exit 1
  fi
}

write_boundary_workspace
reset_dir "${OUTPUT_USER_ROOT}"
export CARGO_BAZEL_FASTPATH_PROFILE=1

sync_logged multi-cold sync --only=boundary_multi_index
sync_logged multi-hot sync --only=boundary_multi_index
assert_profile_cache_state "$(profile_path boundary_multi_index)" true 2

cat >> "${WORKDIR}/member/Cargo.toml" <<'EOF'

# Invalidate workspace_metadata cache.
EOF

sync_logged multi-miss sync --only=boundary_multi_index
assert_profile_cache_state "$(profile_path boundary_multi_index)" false 2
sync_logged multi-hit-after-miss sync --only=boundary_multi_index
assert_profile_cache_state "$(profile_path boundary_multi_index)" true 2

sync_logged supported-repin sync --only=boundary_multi_index
(
  export CARGO_BAZEL_REPIN=1
  sync_logged supported-repin-fastpath sync --only=boundary_multi_index
)
assert_log_not_contains supported-repin-fastpath "Repinning with legacy cargo_bazel fallback."

expect_sync_failure independent-reject sync --only=boundary_independent_index
assert_log_contains independent-reject "only supports multiple manifests when they normalize to the same Cargo workspace root"

(
  export CARGO_BAZEL_REPIN=1
  sync_logged independent-fallback sync --only=boundary_independent_index
)
test -s "${WORKDIR}/cargo-bazel-lock-independent.json"
assert_no_fastpath_profile boundary_independent_index

(
  export CARGO_BAZEL_REPIN=1
  sync_logged skip-fallback sync --only=boundary_skip_fallback_index
)
test -s "${WORKDIR}/cargo-bazel-lock-skip.json"
assert_no_fastpath_profile boundary_skip_fallback_index

echo "fastpath boundary regression validation passed"
