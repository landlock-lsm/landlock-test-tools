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
CONTAINER="${IMAGE_NAME//:/-}"

if [[ ! -f "${IMAGE_DIR}/Dockerfile" ]]; then
	echo "ERROR: Must use an existing image" >&2
	echo >&2
	echo "List of images:" >&2
	print_images >&2
	exit 1
fi

REPOSITORY="$(git rev-parse --path-format=absolute --git-common-dir)"
WORKTREE="$(git rev-parse --path-format=absolute --show-toplevel)"

docker container kill "${CONTAINER}" 2>/dev/null || :
docker container rm "${CONTAINER}" 2>/dev/null || :

docker build \
	--build-arg "BASE_DIR=${BASE_DIR}" \
	--build-arg "WORKTREE=${WORKTREE}" \
	--build-arg "USER=$(id -un)" \
	--build-arg "GROUP=$(id -gn)" \
	--build-arg "UID=$(id -u)" \
	--build-arg "GID=$(id -g)" \
	--build-arg "SMATCH_REF=2b596bf0d9bc4d0e8dbe3c6d73ef0fbf9a4d1337" \
	--tag "${IMAGE_NAME}" \
	"${IMAGE_DIR}"

echo "[*] Launching container ${CONTAINER}"

docker run \
	--cap-drop ALL \
	-it \
	-v "${WORKTREE}:${WORKTREE}" \
	-v "${REPOSITORY}:${REPOSITORY}:ro" \
	-v "${BASE_DIR}:${BASE_DIR}:ro" \
	-v /dev/shm:/dev/shm \
	--name "${CONTAINER}" \
	"${IMAGE_NAME}"
