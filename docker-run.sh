#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2022-2024 Mickaël Salaün <mic@digikod.net>.

set -e -u -o pipefail

BASE_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
NAME="${1:-}"

print_images() {
	local name docker

	for docker in "${BASE_DIR}"/containers/*/*/Dockerfile; do
		name="${docker##${BASE_DIR}/containers/}"
		name="${name%%/Dockerfile}"
		echo "* ${name}"
	done
}

SOURCE_IMAGE="${NAME%%/*}"
TAG="${NAME##*/}"
IMAGE_NAME="landlock-dev-${SOURCE_IMAGE}:${TAG}"
IMAGE_DIR="${BASE_DIR}/containers/${SOURCE_IMAGE}/${TAG}"

if [[ ! -f "${IMAGE_DIR}/Dockerfile" ]]; then
	echo "ERROR: Must use an existing image" >&2
	echo >&2
	echo "List of images:" >&2
	print_images >&2
	exit 1
fi

REPOSITORY="$(git rev-parse --path-format=absolute --git-common-dir)"
WORKTREE="$(git rev-parse --path-format=absolute --show-toplevel)"

ALTERNATE_FILE="${REPOSITORY}/objects/info/alternates"
VOLUME_ALTERNATE=()
if [[ -f "${ALTERNATE_FILE}" ]]; then
	# Only support one alternate object store.
	ALTERNATE_ENTRY="$(head -n 1 -- "${ALTERNATE_FILE}")"
	VOLUME_ALTERNATE=(-v "${ALTERNATE_ENTRY}:${ALTERNATE_ENTRY}:ro")
fi

docker build \
	--build-arg "BASE_DIR=${BASE_DIR}" \
	--build-arg "WORKTREE=${WORKTREE}" \
	--build-arg "USER=$(id -un)" \
	--build-arg "GROUP=$(id -gn)" \
	--build-arg "UID=$(id -u)" \
	--build-arg "GID=$(id -g)" \
	--build-arg "SMATCH_REF=1805d8ab5fb06a176404b52774d124de7f2591ed" \
	--tag "${IMAGE_NAME}" \
	"${IMAGE_DIR}"

docker run \
	--cap-drop ALL \
	-it \
	-v "${WORKTREE}:${WORKTREE}" \
	-v "${REPOSITORY}:${REPOSITORY}:ro" \
	-v "${BASE_DIR}:${BASE_DIR}:ro" \
	"${VOLUME_ALTERNATE[@]}" \
	-v /dev/shm:/dev/shm \
	--rm \
	"${IMAGE_NAME}"
