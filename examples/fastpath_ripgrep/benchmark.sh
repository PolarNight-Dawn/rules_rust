#!/usr/bin/env bash

set -euo pipefail

RULES_RUST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_RIPGREP_DIR="$(cd "${RULES_RUST_ROOT}/.." && pwd)/ripgrep"
RIPGREP_DIR="${RIPGREP_DIR:-${DEFAULT_RIPGREP_DIR}}"
WORKDIR="${FASTPATH_RIPGREP_WORKDIR:-${RULES_RUST_ROOT}/.tmp/fastpath_ripgrep}"
FASTPATH_WORKSPACE_DIR="${WORKDIR}/fastpath_workspace"
CARGO_BAZEL_WORKSPACE_DIR="${WORKDIR}/cargo_bazel_workspace"
BOOTSTRAP_WORKSPACE_DIR="${WORKDIR}/bootstrap_workspace"
RESULTS_FILE="${WORKDIR}/benchmark-results.tsv"
BAZEL="${BAZEL:-bazel}"
BAZEL_BATCH="${BAZEL_BATCH:-1}"
BAZEL_VERSION="${BAZEL_VERSION:-7.4.1}"
RECREATE_WORKSPACE="${RECREATE_WORKSPACE:-0}"

backend_workspace_dir() {
  case "$1" in
    fastpath) printf '%s\n' "${FASTPATH_WORKSPACE_DIR}" ;;
    cargo_bazel) printf '%s\n' "${CARGO_BAZEL_WORKSPACE_DIR}" ;;
    *) echo "unknown backend: $1" >&2; exit 1 ;;
  esac
}

backend_repo_name() {
  case "$1" in
    fastpath) printf '%s\n' "ripgrep_fastpath_index" ;;
    cargo_bazel) printf '%s\n' "ripgrep_cargo_bazel_index" ;;
    *) echo "unknown backend: $1" >&2; exit 1 ;;
  esac
}

backend_lockfile_name() {
  case "$1" in
    fastpath) printf '%s\n' "" ;;
    cargo_bazel) printf '%s\n' "cargo-bazel-lock-cargo-bazel.json" ;;
    *) echo "unknown backend: $1" >&2; exit 1 ;;
  esac
}

backend_target_name() {
  case "$1" in
    fastpath) printf '%s\n' "fastpath_root_deps" ;;
    cargo_bazel) printf '%s\n' "cargo_bazel_root_deps" ;;
    *) echo "unknown backend: $1" >&2; exit 1 ;;
  esac
}

run_sync_in_workspace() {
  local workspace_dir="$1"
  local output_user_root="$2"
  local repo_name="$3"
  shift 3

  local -a args=("${BAZEL}")
  if [[ "${BAZEL_BATCH}" == "1" ]]; then
    args+=(--batch)
  fi
  args+=(--output_user_root="${output_user_root}")

  (
    cd "${workspace_dir}"
    env "$@" "${args[@]}" sync --only="${repo_name}"
  )
}

run_build_in_workspace() {
  local workspace_dir="$1"
  local output_user_root="$2"
  shift 2

  local -a args=("${BAZEL}")
  if [[ "${BAZEL_BATCH}" == "1" ]]; then
    args+=(--batch)
  fi
  args+=(--output_user_root="${output_user_root}")

  (
    cd "${workspace_dir}"
    "${args[@]}" build "$@"
  )
}

bazel_output_base_for_workspace() {
  local workspace_dir="$1"
  local output_user_root="$2"

  local -a args=("${BAZEL}")
  if [[ "${BAZEL_BATCH}" == "1" ]]; then
    args+=(--batch)
  fi
  args+=(--output_user_root="${output_user_root}")

  (
    cd "${workspace_dir}"
    "${args[@]}" info output_base
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

ensure_ripgrep_dir() {
  if [[ -d "${RIPGREP_DIR}" && -f "${RIPGREP_DIR}/Cargo.toml" && -f "${RIPGREP_DIR}/Cargo.lock" ]]; then
    return
  fi

  cat <<EOF >&2
ripgrep checkout not found at ${RIPGREP_DIR}

Clone it with:
  git clone https://github.com/BurntSushi/ripgrep ${RIPGREP_DIR}
Or re-run with:
  RIPGREP_DIR=/path/to/ripgrep ./benchmark.sh $*
EOF
  exit 1
}

write_common_workspace_files() {
  local workspace_dir="$1"
  local lockfile_name="$2"

  rm -rf "${workspace_dir}"
  mkdir -p "${workspace_dir}/zz_bench"

  cat > "${workspace_dir}/.bazelrc" <<'EOF'
common --noenable_bzlmod --enable_workspace
common --lockfile_mode=off
EOF

  printf '%s\n' "${BAZEL_VERSION}" > "${workspace_dir}/.bazelversion"

  cat > "${workspace_dir}/MODULE.bazel" <<'EOF'
###############################################################################
# Bazel now uses Bzlmod by default to manage external dependencies.
###############################################################################
EOF

  if [[ -n "${lockfile_name}" ]]; then
    cat > "${workspace_dir}/BUILD.bazel" <<EOF
exports_files(["${lockfile_name}"])
EOF

    : > "${workspace_dir}/${lockfile_name}"
  else
    : > "${workspace_dir}/BUILD.bazel"
  fi
}

write_backend_workspace() {
  local backend="$1"
  local workspace_dir
  local repo_name
  local lockfile_name
  local target_name
  local generator_line=""
  local backend_attrs=""
  local lockfile_line=""
  local bootstrap_arg=""

  workspace_dir="$(backend_workspace_dir "${backend}")"
  repo_name="$(backend_repo_name "${backend}")"
  lockfile_name="$(backend_lockfile_name "${backend}")"
  target_name="$(backend_target_name "${backend}")"

  write_common_workspace_files "${workspace_dir}" "${lockfile_name}"

  if [[ "${backend}" == "cargo_bazel" ]]; then
    generator_line='    generator = "@cargo_bazel_bootstrap//:cargo-bazel",'
    lockfile_line="    lockfile = \"//:${lockfile_name}\","
    bootstrap_arg="bootstrap = True"
  else
    backend_attrs='    resolver_backend = "lockfile_fastpath",'
  fi

  cat > "${workspace_dir}/WORKSPACE.bazel" <<EOF
workspace(name = "ripgrep_${backend}_bench")

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository", "new_local_repository")

local_repository(
    name = "rules_rust",
    path = "${RULES_RUST_ROOT}",
)

new_local_repository(
    name = "ripgrep",
    path = "${RIPGREP_DIR}",
    build_file_content = """
exports_files([
    "Cargo.lock",
    "Cargo.toml",
    "crates/cli/Cargo.toml",
    "crates/globset/Cargo.toml",
    "crates/grep/Cargo.toml",
    "crates/ignore/Cargo.toml",
    "crates/matcher/Cargo.toml",
    "crates/pcre2/Cargo.toml",
    "crates/printer/Cargo.toml",
    "crates/regex/Cargo.toml",
    "crates/searcher/Cargo.toml",
])
""",
)

load("@rules_rust//rust:repositories.bzl", "rules_rust_dependencies", "rust_register_toolchains")

rules_rust_dependencies()

rust_register_toolchains(
    edition = "2021",
)

load("@rules_rust//crate_universe:repositories.bzl", "crate_universe_dependencies")

crate_universe_dependencies(${bootstrap_arg})

load("@rules_rust//crate_universe:defs.bzl", "crates_repository")

crates_repository(
    name = "${repo_name}",
    cargo_lockfile = "@ripgrep//:Cargo.lock",
${generator_line}
${lockfile_line}
    # Same-Cargo-workspace manifest normalization coverage: every listed
    # manifest below is a member of the ripgrep Cargo workspace.
    manifests = [
        "@ripgrep//:Cargo.toml",
        "@ripgrep//:crates/globset/Cargo.toml",
        "@ripgrep//:crates/grep/Cargo.toml",
        "@ripgrep//:crates/cli/Cargo.toml",
        "@ripgrep//:crates/matcher/Cargo.toml",
        "@ripgrep//:crates/pcre2/Cargo.toml",
        "@ripgrep//:crates/printer/Cargo.toml",
        "@ripgrep//:crates/regex/Cargo.toml",
        "@ripgrep//:crates/searcher/Cargo.toml",
        "@ripgrep//:crates/ignore/Cargo.toml",
    ],
${backend_attrs}
)

load("@${repo_name}//:defs.bzl", "all_crate_deps", "crate_repositories")

crate_repositories()
EOF

  cat > "${workspace_dir}/zz_bench/BUILD.bazel" <<EOF
load("@${repo_name}//:defs.bzl", "all_crate_deps")
load("@rules_rust//rust:defs.bzl", "rust_library")

rust_library(
    name = "${target_name}",
    srcs = ["lib.rs"],
    edition = "2021",
    deps = all_crate_deps(package_name = ""),
)
EOF

  cat > "${workspace_dir}/zz_bench/lib.rs" <<EOF
pub fn marker() -> &'static str {
    "ripgrep-${backend}-benchmark"
}
EOF
}

write_bootstrap_workspace() {
  write_common_workspace_files "${BOOTSTRAP_WORKSPACE_DIR}" "cargo-bazel-lock-cargo-bazel.json"

  cat > "${BOOTSTRAP_WORKSPACE_DIR}/WORKSPACE.bazel" <<EOF
workspace(name = "fastpath_ripgrep_bootstrap")

load("@bazel_tools//tools/build_defs/repo:local.bzl", "local_repository", "new_local_repository")

local_repository(
    name = "rules_rust",
    path = "${RULES_RUST_ROOT}",
)

new_local_repository(
    name = "ripgrep",
    path = "${RIPGREP_DIR}",
    build_file_content = """
exports_files([
    "Cargo.lock",
    "Cargo.toml",
    "crates/cli/Cargo.toml",
    "crates/globset/Cargo.toml",
    "crates/grep/Cargo.toml",
    "crates/ignore/Cargo.toml",
    "crates/matcher/Cargo.toml",
    "crates/pcre2/Cargo.toml",
    "crates/printer/Cargo.toml",
    "crates/regex/Cargo.toml",
    "crates/searcher/Cargo.toml",
])
""",
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
    name = "ripgrep_cargo_bazel_index",
    cargo_lockfile = "@ripgrep//:Cargo.lock",
    generator = "@cargo_bazel_bootstrap//:cargo-bazel",
    lockfile = "//:cargo-bazel-lock-cargo-bazel.json",
    # Same Cargo workspace manifest set as the fastpath benchmark workspace.
    manifests = [
        "@ripgrep//:Cargo.toml",
        "@ripgrep//:crates/globset/Cargo.toml",
        "@ripgrep//:crates/grep/Cargo.toml",
        "@ripgrep//:crates/cli/Cargo.toml",
        "@ripgrep//:crates/matcher/Cargo.toml",
        "@ripgrep//:crates/pcre2/Cargo.toml",
        "@ripgrep//:crates/printer/Cargo.toml",
        "@ripgrep//:crates/regex/Cargo.toml",
        "@ripgrep//:crates/searcher/Cargo.toml",
        "@ripgrep//:crates/ignore/Cargo.toml",
    ],
)
EOF
}

prepare() {
  ensure_ripgrep_dir "$@"
  mkdir -p "${WORKDIR}"
  if [[ "${RECREATE_WORKSPACE}" == "1" || ! -f "${FASTPATH_WORKSPACE_DIR}/WORKSPACE.bazel" ]] ||
     grep -q 'lockfile = "//:cargo-bazel-lock-fastpath.json"' "${FASTPATH_WORKSPACE_DIR}/WORKSPACE.bazel" 2>/dev/null ||
     grep -q 'generator = "@cargo_bazel_bootstrap//:cargo-bazel"' "${FASTPATH_WORKSPACE_DIR}/WORKSPACE.bazel" 2>/dev/null; then
    write_backend_workspace fastpath
  fi
  if [[ "${RECREATE_WORKSPACE}" == "1" || ! -f "${CARGO_BAZEL_WORKSPACE_DIR}/WORKSPACE.bazel" ]]; then
    write_backend_workspace cargo_bazel
  fi
  if [[ "${RECREATE_WORKSPACE}" == "1" || ! -f "${BOOTSTRAP_WORKSPACE_DIR}/WORKSPACE.bazel" ]]; then
    write_bootstrap_workspace
  fi
  bootstrap_cargo_bazel_lockfile
}

reset_backend_lockfile() {
  local backend="$1"
  local workspace_dir
  local lockfile_name
  workspace_dir="$(backend_workspace_dir "${backend}")"
  lockfile_name="$(backend_lockfile_name "${backend}")"
  if [[ -n "${lockfile_name}" ]]; then
    : > "${workspace_dir}/${lockfile_name}"
  fi
  if [[ "${backend}" == "fastpath" ]]; then
    reset_dir "${workspace_dir}/.cargo-bazel-fastpath-cache"
  fi
}

bootstrap_cargo_bazel_lockfile() {
  local bootstrap_root="${WORKDIR}/out/bootstrap"
  local bootstrap_lockfile="${BOOTSTRAP_WORKSPACE_DIR}/cargo-bazel-lock-cargo-bazel.json"
  local workspace_lockfile="${CARGO_BAZEL_WORKSPACE_DIR}/cargo-bazel-lock-cargo-bazel.json"

  if [[ -s "${workspace_lockfile}" ]]; then
    return
  fi

  reset_dir "${bootstrap_root}"
  run_sync_in_workspace "${BOOTSTRAP_WORKSPACE_DIR}" "${bootstrap_root}" ripgrep_cargo_bazel_index CARGO_BAZEL_REPIN=true >/dev/null
  cp "${bootstrap_lockfile}" "${workspace_lockfile}"
}

run_sync() {
  local backend="$1"
  local output_user_root="$2"
  shift 2
  run_sync_in_workspace "$(backend_workspace_dir "${backend}")" "${output_user_root}" "$(backend_repo_name "${backend}")" "$@"
}

run_backend_build() {
  local backend="$1"
  local output_user_root="$2"
  shift 2
  run_build_in_workspace "$(backend_workspace_dir "${backend}")" "${output_user_root}" "$@"
}

measure_sync_ms() {
  local backend="$1"
  local output_user_root="$2"
  shift 2

  local workspace_dir
  local repo_name
  local -a args=("${BAZEL}")
  local timing

  workspace_dir="$(backend_workspace_dir "${backend}")"
  repo_name="$(backend_repo_name "${backend}")"
  if [[ "${BAZEL_BATCH}" == "1" ]]; then
    args+=(--batch)
  fi
  args+=(--output_user_root="${output_user_root}")

  timing="$(
    (
      cd "${workspace_dir}"
      env "$@" /usr/bin/time -p "${args[@]}" sync --only="${repo_name}" >/dev/null
    ) 2>&1
  )"
  awk '/^real / {printf "%.3f\n", $2 * 1000}' <<<"${timing}"
}

profile_fastpath() {
  local output_user_root="${WORKDIR}/out/profile_fastpath"
  local output_base
  local profile_path

  reset_dir "${output_user_root}"
  run_sync fastpath "${output_user_root}" >/dev/null
  run_sync fastpath "${output_user_root}" CARGO_BAZEL_FASTPATH_PROFILE=1 >/dev/null

  output_base="$(bazel_output_base_for_workspace "${FASTPATH_WORKSPACE_DIR}" "${output_user_root}")"
  profile_path="${output_base}/external/ripgrep_fastpath_index/_fastpath_profile.json"
  python3 - "${profile_path}" <<'PY'
import json
import pathlib
import sys

profile = json.loads(pathlib.Path(sys.argv[1]).read_text())
print("ripgrep fastpath profile summary:")
for key in sorted(profile["summary"]):
    print(f"  {key}: {profile['summary'][key]}")
print("ripgrep fastpath profile phases:")
for event in profile["events"]:
    details = event.get("details") or {}
    suffix = ""
    if details:
        suffix = f" details={details}"
    print(f"  {event['phase']}: {event['duration_ms']:.3f}ms{suffix}")
PY
}

validate() {
  local fastpath_output_user_root="${WORKDIR}/out/validate_fastpath"
  local cargo_output_user_root="${WORKDIR}/out/validate_cargo_bazel"
  local output_base
  local profile_path

  reset_dir "${fastpath_output_user_root}"
  reset_dir "${cargo_output_user_root}"

  run_sync fastpath "${fastpath_output_user_root}" >/dev/null
  run_sync fastpath "${fastpath_output_user_root}" CARGO_BAZEL_FASTPATH_PROFILE=1 >/dev/null

  output_base="$(bazel_output_base_for_workspace "${FASTPATH_WORKSPACE_DIR}" "${fastpath_output_user_root}")"
  profile_path="${output_base}/external/ripgrep_fastpath_index/_fastpath_profile.json"
  test -f "${profile_path}"

  python3 - "${profile_path}" <<'PY'
import json
import pathlib
import sys

profile = json.loads(pathlib.Path(sys.argv[1]).read_text())
if profile["summary"]["workspace_packages"] < 1:
    raise SystemExit("expected ripgrep workspace members in fastpath profile")
if profile["summary"]["registry_packages"] < 1:
    raise SystemExit("expected registry crates in fastpath profile")
if profile["summary"]["repository_rules"] < profile["summary"]["registry_packages"]:
    raise SystemExit("expected rendered spoke repositories in fastpath profile")

events = {event["phase"]: event for event in profile["events"]}
for phase in ("download_registry_metadata", "inspect_external_crates"):
    if phase not in events:
        raise SystemExit(f"missing fastpath phase {phase}")
    details = events[phase].get("details", {})
    if details.get("cache_hits", 0) < 1:
        raise SystemExit(f"expected warm-cache hits for {phase}")
PY

  run_build_in_workspace "${FASTPATH_WORKSPACE_DIR}" "${fastpath_output_user_root}" //zz_bench:fastpath_root_deps >/dev/null
  run_sync cargo_bazel "${cargo_output_user_root}" >/dev/null
  run_build_in_workspace "${CARGO_BAZEL_WORKSPACE_DIR}" "${cargo_output_user_root}" //zz_bench:cargo_bazel_root_deps >/dev/null

  echo "ripgrep validation passed"
}

record_result() {
  local scenario="$1"
  local backend="$2"
  local mode="$3"
  local iteration="$4"
  local value_ms="$5"
  printf "%s\t%s\t%s\t%s\t%s\n" "${scenario}" "${backend}" "${mode}" "${iteration}" "${value_ms}" >> "${RESULTS_FILE}"
}

benchmark_steady_state() {
  local cold_iterations="${COLD_ITERATIONS:-3}"
  local hot_iterations="${HOT_ITERATIONS:-5}"

  for backend in fastpath cargo_bazel; do
    local output_user_root="${WORKDIR}/out/${backend}"

    for iteration in $(seq 1 "${cold_iterations}"); do
      reset_dir "${output_user_root}"
      record_result "steady_state" "${backend}" "cold" "${iteration}" \
        "$(measure_sync_ms "${backend}" "${output_user_root}")"
    done

    reset_dir "${output_user_root}"
    run_sync "${backend}" "${output_user_root}" >/dev/null 2>&1
    for iteration in $(seq 1 "${hot_iterations}"); do
      record_result "steady_state" "${backend}" "hot" "${iteration}" \
        "$(measure_sync_ms "${backend}" "${output_user_root}")"
    done
  done
}

benchmark_first_gen() {
  local iterations="${FIRST_GEN_ITERATIONS:-3}"

  for backend in fastpath cargo_bazel; do
    local output_user_root="${WORKDIR}/out/${backend}_first_gen"

    for iteration in $(seq 1 "${iterations}"); do
      reset_dir "${output_user_root}"
      reset_backend_lockfile "${backend}"
      if [[ "${backend}" == "cargo_bazel" ]]; then
        record_result "first_gen" "${backend}" "repin" "${iteration}" \
          "$(measure_sync_ms "${backend}" "${output_user_root}" CARGO_BAZEL_REPIN=true)"
      else
        record_result "first_gen" "${backend}" "repin" "${iteration}" \
          "$(measure_sync_ms "${backend}" "${output_user_root}")"
      fi
    done
  done
}

print_benchmark_summary() {
  python3 - "${RESULTS_FILE}" <<'PY'
import collections
import pathlib
import statistics
import sys

rows = collections.defaultdict(list)
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not line.strip():
        continue
    scenario, backend, mode, iteration, value = line.split("\t")
    rows[(scenario, backend, mode)].append(float(value))

print("ripgrep sync benchmark (milliseconds):")
for key in sorted(rows):
    values = rows[key]
    print(
        f"  {key[0]} {key[1]} {key[2]}: "
        f"runs={len(values)} min={min(values):.3f} median={statistics.median(values):.3f} max={max(values):.3f}"
    )

for scenario, mode in (
    ("steady_state", "cold"),
    ("steady_state", "hot"),
    ("first_gen", "repin"),
):
    fast_key = (scenario, "fastpath", mode)
    base_key = (scenario, "cargo_bazel", mode)
    if fast_key not in rows or base_key not in rows:
        continue
    fast = statistics.median(rows[fast_key])
    base = statistics.median(rows[base_key])
    if fast == 0:
        continue
    print(f"  speedup {scenario} {mode}: {base / fast:.3f}x")
PY
}

benchmark() {
  : > "${RESULTS_FILE}"
  benchmark_steady_state
  benchmark_first_gen
  print_benchmark_summary
}

benchmark_steady_state_command() {
  : > "${RESULTS_FILE}"
  benchmark_steady_state
  print_benchmark_summary
}

benchmark_first_gen_command() {
  : > "${RESULTS_FILE}"
  benchmark_first_gen
  print_benchmark_summary
}

main() {
  local command="${1:-benchmark}"
  shift || true

  prepare "$@"

  case "${command}" in
    benchmark)
      benchmark
      ;;
    benchmark_steady_state)
      benchmark_steady_state_command
      ;;
    benchmark_first_gen)
      benchmark_first_gen_command
      ;;
    profile)
      profile_fastpath
      ;;
    validate)
      validate
      ;;
    prepare)
      echo "fastpath workspace prepared at ${FASTPATH_WORKSPACE_DIR}"
      echo "cargo_bazel workspace prepared at ${CARGO_BAZEL_WORKSPACE_DIR}"
      ;;
    *)
      echo "unknown command: ${command}" >&2
      echo "usage: ./benchmark.sh [prepare|validate|profile|benchmark|benchmark_steady_state|benchmark_first_gen]" >&2
      exit 1
      ;;
  esac
}

main "$@"
