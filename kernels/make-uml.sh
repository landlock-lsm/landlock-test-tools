#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2023 Microsoft Corporation
#
# Build a deterministic User-Mode Linux kernel.

set -e -u -o pipefail

BASE_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"
PATCH="${BASE_DIR}/0001-test-Landlock-with-UML.patch"

if [[ -f security/landlock/Kconfig ]]; then
	git apply "${PATCH}" || :
fi

export KBUILD_BUILD_USER="root"
export KBUILD_BUILD_HOST="localhost"
export KBUILD_BUILD_TIMESTAMP="$(git log --no-walk --pretty=format:%aD)"
export ARCH="um"

if [[ -e .version ]]; then
	rm .version
fi

make "-j$(nproc)"

strip linux
