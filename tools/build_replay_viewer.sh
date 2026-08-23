#!/usr/bin/env bash
# Coworld replay-viewer build hook: invoked by `coworld build` with one
# argument, the absolute path of the static bundle directory to produce
# (<manifest-dir>/static-replay-viewer, which must end up containing
# index.html). Forked from paintbot's, safety checks and all: the target must
# be absolute, must be named static-replay-viewer, must live inside the repo,
# and index.html must exist at the end.
#
# `coworld build` hard-requires os.X_OK on this file, so it is committed
# mode 100755 (git update-index --chmod=+x tools/build_replay_viewer.sh).
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$#" -ne 1 ]]; then
  echo "usage: $0 /absolute/path/to/static-replay-viewer" >&2
  exit 1
fi

requested_output="$1"

if [[ "${requested_output}" != /* || \
      "$(basename "${requested_output}")" != "static-replay-viewer" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

mkdir -p "$(dirname "${requested_output}")"
output_parent="$(cd "$(dirname "${requested_output}")" && pwd -P)"
output_dir="${output_parent}/static-replay-viewer"
if [[ "${output_dir}" != "${repo_dir}"/* || -L "${output_dir}" ]]; then
  echo "unsafe bundle output: ${requested_output}" >&2
  exit 1
fi

rm -rf "${output_dir}"
mkdir -p "${output_dir}"

image_tag="coworld-hive-replay-viewer-build:$$"
container_id=""
cleanup() {
  if [[ -n "${container_id}" ]]; then
    docker rm "${container_id}" >/dev/null 2>&1 || true
  fi
  docker image rm "${image_tag}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

build_args=(
  --platform linux/amd64
  --file "${repo_dir}/Dockerfile.replay-viewer"
  --target replay-viewer-builder
  --tag "${image_tag}"
  "${repo_dir}"
)
if docker buildx version >/dev/null 2>&1; then
  docker buildx build --load "${build_args[@]}"
else
  docker build "${build_args[@]}"
fi
container_id="$(docker create --platform linux/amd64 "${image_tag}")"
docker cp "${container_id}:/workspace/hive/replay-viewer/dist/." "${output_dir}"

test -f "${output_dir}/index.html"
test -s "${output_dir}/hive_replay.wasm"
echo "hive replay viewer bundle: ${output_dir}"
