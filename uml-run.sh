#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2015-2023 Mickaël Salaün <mic@digikod.net>
#
# Launch a minimal User-Mode Linux system to run all Landlock tests.
#
# Example: ./uml-run.sh linux-6.1 bash HISTFILE=/dev/null

set -e -u -o pipefail

if [[ $# -lt 2 ]]; then
	echo "usage: ${BASH_SOURCE[0]} <linux-uml-kernel> <exec-path> [VAR=value]..." >&2
	exit 1
fi

BASE_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

KERNEL="${BASE_DIR}/kernels/artifacts/$1"
EXEC="$(command -v -- "$2")"
shift 2

OUT_RET="$(mktemp uml-ret.XXXXXXXXXX)"

cleanup() {
	rm -- "${OUT_RET}"
}

trap cleanup QUIT INT TERM EXIT

"${KERNEL}" \
	"rootfstype=hostfs" \
	"rootflags=/" \
	"rw" \
	"quiet" \
	"init=${BASE_DIR}/uml-init.sh" \
	"UML_UID=$(id -u)" \
	"UML_CWD=$(pwd)" \
	"UML_EXEC=${EXEC}" \
	"UML_RET=${OUT_RET}" \
	"PATH=${PATH:-}" \
	"$@"

exit "$(< "${OUT_RET}")"
