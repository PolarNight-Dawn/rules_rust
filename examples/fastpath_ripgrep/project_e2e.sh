#!/usr/bin/env bash

set -euo pipefail

RULES_RUST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULT_REPO_ROOT="$(cd "${RULES_RUST_ROOT}/.." && pwd)"
BASELINE_PROJECT_DIR="${BASELINE_PROJECT_DIR:-${DEFAULT_REPO_ROOT}/ripgrep_baseline}"
FASTPATH_PROJECT_DIR="${FASTPATH_PROJECT_DIR:-${DEFAULT_REPO_ROOT}/ripgrep}"
WORKDIR="${PROJECT_E2E_WORKDIR:-${RULES_RUST_ROOT}/.tmp/fastpath_ripgrep_project_e2e}"
RESULTS_FILE="${WORKDIR}/project-e2e-results.tsv"
BAZEL="${BAZEL:-bazel}"
BAZEL_BATCH="${BAZEL_BATCH:-1}"
BAZEL_VERSION="${BAZEL_VERSION:-7.4.1}"
COLD_ITERATIONS="${COLD_ITERATIONS:-1}"
HOT_ITERATIONS="${HOT_ITERATIONS:-3}"
FIRST_GEN_ITERATIONS="${FIRST_GEN_ITERATIONS:-1}"

COMMON_FLAGS=(--noenable_bzlmod --enable_workspace)
FIRST_GEN_BACKUP_DIR=""
FIRST_GEN_BACKUP_KIND=""
FIRST_GEN_BACKUP_TARGET=""

backend_project_dir() {
  case "$1" in
    baseline) printf '%s\n' "${BASELINE_PROJECT_DIR}" ;;
    fastpath) printf '%s\n' "${FASTPATH_PROJECT_DIR}" ;;
    *) echo "unknown backend: $1" >&2; exit 1 ;;
  esac
}

backend_output_root() {
  local backend="$1"
  local scenario="$2"
  printf '%s\n' "${WORKDIR}/out/${scenario}/${backend}"
}

backend_profile_path() {
  local backend="$1"
  local scenario="$2"
  local mode="$3"
  local iteration="$4"
  mkdir -p "${WORKDIR}/profiles"
  printf '%s\n' "${WORKDIR}/profiles/${backend}-${scenario}-${mode}-${iteration}.json.gz"
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

ensure_project_dirs() {
  for backend in baseline fastpath; do
    local project_dir
    project_dir="$(backend_project_dir "${backend}")"
    if [[ ! -f "${project_dir}/WORKSPACE" && ! -f "${project_dir}/WORKSPACE.bazel" ]]; then
      echo "${backend} project checkout is not a Bazel workspace: ${project_dir}" >&2
      exit 1
    fi
    if [[ ! -f "${project_dir}/Cargo.lock" || ! -f "${project_dir}/Cargo.toml" ]]; then
      echo "${backend} project checkout is missing Cargo inputs: ${project_dir}" >&2
      exit 1
    fi
  done
}

run_bazel_logged() {
  local backend="$1"
  local output_user_root="$2"
  local log_name="$3"
  local command="$4"
  shift 4

  local project_dir
  local log_path
  local -a args
  project_dir="$(backend_project_dir "${backend}")"
  log_path="${WORKDIR}/logs/${log_name}.log"
  mkdir -p "$(dirname "${log_path}")"
  args=("${BAZEL}")
  if [[ "${BAZEL_BATCH}" == "1" ]]; then
    args+=(--batch)
  fi
  args+=(--output_user_root="${output_user_root}")

  (
    cd "${project_dir}"
    env USE_BAZEL_VERSION="${BAZEL_VERSION}" "${args[@]}" "${command}" "${COMMON_FLAGS[@]}" "$@"
  ) >"${log_path}" 2>&1 || {
    echo "command failed; log: ${log_path}" >&2
    tail -n 80 "${log_path}" >&2 || true
    exit 1
  }
}

measure_bazel_ms() {
  local backend="$1"
  local output_user_root="$2"
  local log_name="$3"
  local command="$4"
  shift 4

  local project_dir
  local log_path
  local -a args
  project_dir="$(backend_project_dir "${backend}")"
  log_path="${WORKDIR}/logs/${log_name}.log"
  mkdir -p "$(dirname "${log_path}")"
  args=("${BAZEL}")
  if [[ "${BAZEL_BATCH}" == "1" ]]; then
    args+=(--batch)
  fi
  args+=(--output_user_root="${output_user_root}")

  (
    cd "${project_dir}"
    env USE_BAZEL_VERSION="${BAZEL_VERSION}" /usr/bin/time -p "${args[@]}" "${command}" "${COMMON_FLAGS[@]}" "$@"
  ) >"${log_path}" 2>&1 || {
    echo "command failed; log: ${log_path}" >&2
    tail -n 80 "${log_path}" >&2 || true
    exit 1
  }

  awk '/^real / {printf "%.3f\n", $2 * 1000}' "${log_path}" | tail -n 1
}

measure_repin_sync_ms() {
  local backend="$1"
  local output_user_root="$2"
  local log_name="$3"

  local project_dir
  local log_path
  local -a args
  project_dir="$(backend_project_dir "${backend}")"
  log_path="${WORKDIR}/logs/${log_name}.log"
  mkdir -p "$(dirname "${log_path}")"
  args=("${BAZEL}")
  if [[ "${BAZEL_BATCH}" == "1" ]]; then
    args+=(--batch)
  fi
  args+=(--output_user_root="${output_user_root}")

  (
    cd "${project_dir}"
    env USE_BAZEL_VERSION="${BAZEL_VERSION}" CARGO_BAZEL_REPIN=1 /usr/bin/time -p "${args[@]}" sync "${COMMON_FLAGS[@]}" --only=crate_index
  ) >"${log_path}" 2>&1 || {
    echo "command failed; log: ${log_path}" >&2
    tail -n 80 "${log_path}" >&2 || true
    exit 1
  }

  awk '/^real / {printf "%.3f\n", $2 * 1000}' "${log_path}" | tail -n 1
}

record_result() {
  local scenario="$1"
  local backend="$2"
  local mode="$3"
  local iteration="$4"
  local step="$5"
  local value_ms="$6"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "${scenario}" "${backend}" "${mode}" "${iteration}" "${step}" "${value_ms}" >> "${RESULTS_FILE}"
}

restore_first_gen_state() {
  if [[ -z "${FIRST_GEN_BACKUP_DIR}" ]]; then
    return
  fi

  if [[ "${FIRST_GEN_BACKUP_KIND}" == "baseline_lockfile" ]]; then
    if [[ -f "${FIRST_GEN_BACKUP_DIR}/cargo-bazel-lock.json" ]]; then
      cp "${FIRST_GEN_BACKUP_DIR}/cargo-bazel-lock.json" "${FIRST_GEN_BACKUP_TARGET}"
    else
      rm -f "${FIRST_GEN_BACKUP_TARGET}"
    fi
  elif [[ "${FIRST_GEN_BACKUP_KIND}" == "fastpath_state" ]]; then
    if [[ -f "${FIRST_GEN_BACKUP_DIR}/Cargo.lock" ]]; then
      cp "${FIRST_GEN_BACKUP_DIR}/Cargo.lock" "${FIRST_GEN_BACKUP_TARGET}/Cargo.lock"
    fi
    reset_dir "${FIRST_GEN_BACKUP_TARGET}/.cargo-bazel-fastpath-cache"
    if [[ -d "${FIRST_GEN_BACKUP_DIR}/.cargo-bazel-fastpath-cache" ]]; then
      cp -R "${FIRST_GEN_BACKUP_DIR}/.cargo-bazel-fastpath-cache" "${FIRST_GEN_BACKUP_TARGET}/.cargo-bazel-fastpath-cache"
    fi
  fi

  reset_dir "${FIRST_GEN_BACKUP_DIR}"
  FIRST_GEN_BACKUP_DIR=""
  FIRST_GEN_BACKUP_KIND=""
  FIRST_GEN_BACKUP_TARGET=""
}

trap restore_first_gen_state EXIT

prepare_first_gen_state() {
  local backend="$1"
  local project_dir
  project_dir="$(backend_project_dir "${backend}")"

  restore_first_gen_state
  FIRST_GEN_BACKUP_DIR="$(mktemp -d "${WORKDIR}/first-gen-${backend}.XXXXXX")"

  if [[ "${backend}" == "baseline" ]]; then
    FIRST_GEN_BACKUP_KIND="baseline_lockfile"
    FIRST_GEN_BACKUP_TARGET="${project_dir}/cargo-bazel-lock.json"
    if [[ -f "${FIRST_GEN_BACKUP_TARGET}" ]]; then
      cp "${FIRST_GEN_BACKUP_TARGET}" "${FIRST_GEN_BACKUP_DIR}/cargo-bazel-lock.json"
    fi
    : > "${FIRST_GEN_BACKUP_TARGET}"
  else
    FIRST_GEN_BACKUP_KIND="fastpath_state"
    FIRST_GEN_BACKUP_TARGET="${project_dir}"
    cp "${project_dir}/Cargo.lock" "${FIRST_GEN_BACKUP_DIR}/Cargo.lock"
    if [[ -d "${project_dir}/.cargo-bazel-fastpath-cache" ]]; then
      cp -R "${project_dir}/.cargo-bazel-fastpath-cache" "${FIRST_GEN_BACKUP_DIR}/.cargo-bazel-fastpath-cache"
    fi
    reset_dir "${project_dir}/.cargo-bazel-fastpath-cache"
  fi
}

correctness() {
  mkdir -p "${WORKDIR}/logs"
  for backend in baseline fastpath; do
    local output_user_root
    output_user_root="$(backend_output_root "${backend}" correctness)"
    reset_dir "${output_user_root}"
    run_bazel_logged "${backend}" "${output_user_root}" "${backend}-correctness-query" query //...
    run_bazel_logged "${backend}" "${output_user_root}" "${backend}-correctness-build" build //...
    run_bazel_logged "${backend}" "${output_user_root}" "${backend}-correctness-run" run //:rg -- --version
    run_bazel_logged "${backend}" "${output_user_root}" "${backend}-correctness-test" test //...
  done
  echo "project end-to-end correctness passed"
}

benchmark_steady_state() {
  for backend in baseline fastpath; do
    local output_user_root
    output_user_root="$(backend_output_root "${backend}" steady_state)"

    for iteration in $(seq 1 "${COLD_ITERATIONS}"); do
      local profile
      profile="$(backend_profile_path "${backend}" steady_state cold "${iteration}")"
      reset_dir "${output_user_root}"
      record_result "steady_state" "${backend}" "cold" "${iteration}" "build" \
        "$(measure_bazel_ms "${backend}" "${output_user_root}" "${backend}-steady-cold-${iteration}" build --profile="${profile}" //...)"
    done

    reset_dir "${output_user_root}"
    run_bazel_logged "${backend}" "${output_user_root}" "${backend}-steady-hot-warmup" build //...
    for iteration in $(seq 1 "${HOT_ITERATIONS}"); do
      local profile
      profile="$(backend_profile_path "${backend}" steady_state hot "${iteration}")"
      record_result "steady_state" "${backend}" "hot" "${iteration}" "build" \
        "$(measure_bazel_ms "${backend}" "${output_user_root}" "${backend}-steady-hot-${iteration}" build --profile="${profile}" //...)"
    done
  done
}

benchmark_first_gen() {
  for backend in baseline fastpath; do
    local output_user_root
    output_user_root="$(backend_output_root "${backend}" first_gen)"

    for iteration in $(seq 1 "${FIRST_GEN_ITERATIONS}"); do
      local sync_ms
      local build_ms
      local total_ms
      local profile
      profile="$(backend_profile_path "${backend}" first_gen repin_build "${iteration}")"
      reset_dir "${output_user_root}"
      prepare_first_gen_state "${backend}"
      sync_ms="$(measure_repin_sync_ms "${backend}" "${output_user_root}" "${backend}-first-gen-sync-${iteration}")"
      build_ms="$(measure_bazel_ms "${backend}" "${output_user_root}" "${backend}-first-gen-build-${iteration}" build --profile="${profile}" //...)"
      total_ms="$(python3 - "${sync_ms}" "${build_ms}" <<'PY'
import sys
print(f"{float(sys.argv[1]) + float(sys.argv[2]):.3f}")
PY
)"
      record_result "first_gen" "${backend}" "repin" "${iteration}" "sync" "${sync_ms}"
      record_result "first_gen" "${backend}" "repin" "${iteration}" "build" "${build_ms}"
      record_result "first_gen" "${backend}" "repin" "${iteration}" "sync_plus_build" "${total_ms}"
      restore_first_gen_state
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
    scenario, backend, mode, iteration, step, value = line.split("\t")
    rows[(scenario, backend, mode, step)].append(float(value))

print("ripgrep project end-to-end benchmark (milliseconds):")
for key in sorted(rows):
    values = rows[key]
    print(
        f"  {key[0]} {key[1]} {key[2]} {key[3]}: "
        f"runs={len(values)} min={min(values):.3f} "
        f"median={statistics.median(values):.3f} max={max(values):.3f}"
    )

for scenario, mode, step in (
    ("steady_state", "cold", "build"),
    ("steady_state", "hot", "build"),
    ("first_gen", "repin", "sync_plus_build"),
):
    fast_key = (scenario, "fastpath", mode, step)
    base_key = (scenario, "baseline", mode, step)
    if fast_key not in rows or base_key not in rows:
        continue
    fast = statistics.median(rows[fast_key])
    base = statistics.median(rows[base_key])
    if fast == 0:
        continue
    print(f"  speedup {scenario} {mode} {step}: {base / fast:.3f}x")
PY
}

benchmark() {
  : > "${RESULTS_FILE}"
  benchmark_steady_state
  benchmark_first_gen
  print_benchmark_summary
}

main() {
  local command="${1:-correctness}"
  ensure_project_dirs
  mkdir -p "${WORKDIR}"

  case "${command}" in
    correctness)
      correctness
      ;;
    benchmark)
      benchmark
      ;;
    benchmark_steady_state)
      : > "${RESULTS_FILE}"
      benchmark_steady_state
      print_benchmark_summary
      ;;
    benchmark_first_gen)
      : > "${RESULTS_FILE}"
      benchmark_first_gen
      print_benchmark_summary
      ;;
    prepare)
      echo "baseline project: ${BASELINE_PROJECT_DIR}"
      echo "fastpath project: ${FASTPATH_PROJECT_DIR}"
      echo "project end-to-end workdir: ${WORKDIR}"
      ;;
    all)
      correctness
      benchmark
      ;;
    *)
      echo "unknown command: ${command}" >&2
      echo "usage: ./project_e2e.sh [prepare|correctness|benchmark|benchmark_steady_state|benchmark_first_gen|all]" >&2
      exit 1
      ;;
  esac
}

main "$@"
