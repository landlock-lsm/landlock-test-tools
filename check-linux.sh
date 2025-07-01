#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2016-2024 Mickaël Salaün <mic@digikod.net>.
#
# Build the kernel, samples, tests and check everything for Landlock.
#
# usage: [ARCH=um] [CC=gcc] check-linux.sh <command>...

set -e -u -o pipefail

REF="${1:-$(git describe --all --abbrev=0 HEAD~)}"

if [[ -z "${REF}" ]]; then
	echo "ERROR: Must be run in the Git repository of the Linux kernel" >&2
	exit 1
fi

BASE_DIR="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")"

if [[ -z "${ARCH:-}" ]]; then
	export ARCH="um"
fi

if [[ -z "${CC:-}" ]]; then
	export CC="gcc"
fi

if [[ -z "${O:-}" ]]; then
	export O="./.out-landlock_local-${ARCH}-${CC}"
fi

# Required for a deterministic Linux kernel.
export KBUILD_BUILD_USER="root"
export KBUILD_BUILD_HOST="localhost"
export KBUILD_BUILD_TIMESTAMP="$(git log --no-walk --pretty=format:%aD)"

NPROC="$(nproc)"

make_cmd() {
	make "-j${NPROC}" "ARCH=${ARCH}" "CC=${CC}" "O=${O}" "$@"
}

unpatch_item() {
	# Should always succeed.
	case "$1" in
		kernel_kconfig)
			git apply --reverse "${BASE_DIR}/kernels/0001-test-Landlock-with-UML.patch" || :
			;;
		samples_kconfig)
			git apply --reverse "${BASE_DIR}/kernels/0002-build-sandboxer-with-UML.patch" || :
			;;
		kselftest)
			sed -e '0,/^all:$/s//\0 khdr/' -i tools/testing/selftests/Makefile || :
			;;
		format)
			git cat-file -p "HEAD:.clang-format" > .clang-format
			;;
		*)
			return 1
			;;
	esac
}

PATCHES=()

unpatch_all() {
	set -- "${PATCHES[@]}"

	while [[ $# -ge 1 ]]; do
		unpatch_item "$1"
		shift
	done
}

patch_kernel_kconfig() {
	if [[ "${ARCH}" != "um" ]]; then
		return
	fi

	if git apply "${BASE_DIR}/kernels/0001-test-Landlock-with-UML.patch" 2>/dev/null; then
		PATCHES+=(kernel_kconfig)
		trap unpatch_all QUIT INT TERM EXIT
		echo "[+] Patched Landlock's Kconfig for UML support"
	fi
}

patch_samples_kconfig() {
	if [[ "${ARCH}" != "um" ]]; then
		return
	fi

	# Requires headers to be installed.
	if git apply "${BASE_DIR}/kernels/0002-build-sandboxer-with-UML.patch" 2>/dev/null; then
		PATCHES+=(samples_kconfig)
		trap unpatch_all QUIT INT TERM EXIT
		echo "[+] Patched samples' Kconfig for UML support"
	fi
}

# First argument may be:
# - light: Only build the kernel, not the sample.
# - check: Build the kernel with runtime checks.
create_config() {
	local config_arch="${BASE_DIR}/kernels/config-mini-${ARCH}"
	local config_arch_check="tools/testing/selftests/landlock/config.${ARCH}"
	local config_landlock="tools/testing/selftests/landlock/config"
	local config_all=(
		"${config_arch}"
	)

	if [[ "${1:-}" = "check" ]]; then
		config_all+=("${BASE_DIR}/kernels/config-check")
		if [[ -f "${config_arch_check}" ]]; then
			config_all+=("${config_arch_check}")
		fi
	fi

	if [[ ! -f "${config_arch}" ]]; then
		echo "ERROR: Architecture not supported" >&2
		exit 1
	fi

	if [[ -f "${config_landlock}" ]]; then
		config_all+=("${config_landlock}")
	fi

	patch_kernel_kconfig

	if [[ "${1:-}" != "light" ]]; then
		patch_samples_kconfig
	fi

	echo "[+] Creating minimal configuration"
	make_cmd \
		KCONFIG_ALLCONFIG=<(sort -u -- "${config_all[@]}") \
		allnoconfig
}

install_headers() {
	if [[ "${ARCH}" = "um" ]]; then
		# Headers not exportable for UML.
		ARCH="x86_64"
		make_cmd headers_install
		ARCH="um"
	else
		make_cmd headers_install
	fi
}

# First argument may be:
# - light: Only build the kernel, not the sample.
build_main() {
	make_cmd

	if [[ "${1:-}" != "light" ]] && [[ ! -f "${O}/samples/landlock/sandboxer" ]]; then
		echo "ERROR: Failed to build the sample"
		exit 1
	fi
}

set_source_dir() {
	SOURCE_DIR="$1/"
	MAKE_ARGS=(W=1e KCFLAGS=-Werror HOSTCFLAGS=-Werror USERCFLAGS=-Werror)

	if [[ "${SOURCE_DIR##tools/}" != "${SOURCE_DIR}" ]]; then
		if ! grep -q USERCFLAGS tools/testing/selftests/lib.mk; then
			# Hack to support -Werror without proper USERCFLAGS.
			MAKE_ARGS+=(KHDR_INCLUDES="-isystem ../../../../usr/include -Werror")
		fi
		# make O=out TARGETS=landlock -C tools/testing/selftests
		MAKE_ARGS+=(TARGETS="$(basename -- "${SOURCE_DIR}")" -C "$(dirname -- "${SOURCE_DIR}")")
	else
		MAKE_ARGS+=("${SOURCE_DIR}")
	fi
}

make_clean() {
	echo "[+] Cleaning: ${SOURCE_DIR}"
	if [[ "${SOURCE_DIR##tools/}" != "${SOURCE_DIR}" ]]; then
		# make O=out TARGETS=landlock -C tools/testing/selftests
		make_cmd -C "${SOURCE_DIR}" clean
	else
		make_cmd "M=${SOURCE_DIR}" clean
	fi
}

check_sparse() {
	echo "[+] Checking with sparse: ${SOURCE_DIR}"
	# Requires sparse with commit 0e1aae55e49c ("fix "unreplaced" warnings caused by using typeof() on inline functions")
	make_cmd C=2 CF='-Wsparse-error -fdiagnostic-prefix -D__CHECK_ENDIAN__' "${MAKE_ARGS[@]}"
}

check_warning() {
	echo "[+] Checking warnings: ${SOURCE_DIR}"
	make_cmd W=1 "${MAKE_ARGS[@]}"
}

check_smatch() {
	echo "[+] Checking with smatch: ${SOURCE_DIR}"
	if ! command -v smatch &>/dev/null; then
		echo "ERROR: Unable to find the \"smatch\" command" >&2
		exit 1
	fi

	make_cmd CHECK="smatch -p=kernel" C=1 "${MAKE_ARGS[@]}"
}

check_format() {
	if [[ -n "$(git --no-pager log --max-count=1 --grep '^landlock: Format with clang-format$' --pretty=format:%H v5.10..HEAD security/landlock)" ]]; then
		echo "[+] Checking with clang-format: ${SOURCE_DIR}"
		# Checks for commit 781121a7f6d1 ("clang-format: Fix space after for_each macros").
		local clang_format_compat="781121a7f6d11d7cae44982f174ea82adeec7db0"
		if ! git merge-base --is-ancestor "${clang_format_compat}" HEAD; then
			PATCHES+=(format)
			trap unpatch_all QUIT INT TERM EXIT
			git cat-file -p "${clang_format_compat}:.clang-format" > .clang-format
		fi
		local last_version="20"
		local first_version="14"
		local clang_format=""
		local version
		for version in $(seq "${last_version}" -1 "${first_version}"); do
			if clang-format --version 2>/dev/null | grep -qF " version ${version}."; then
				clang_format="clang-format"
				break
			elif command -v "clang-format-${version}" &>/dev/null; then
				clang_format="clang-format-${version}"
				break
			fi
		done
		if [[ -z "${clang_format}" ]]; then
			echo "ERROR: No clang-format between ${first_version} and ${last_version} found." >&2
			return 1
		fi
		echo "${clang_format}" --dry-run --Werror "${SOURCE_DIR}"/*.[ch]
		"${clang_format}" --dry-run --Werror "${SOURCE_DIR}"/*.[ch]
	else
		echo "[-] Not checking with clang-format: ${SOURCE_DIR}"
	fi
}

check_build() {
	if [[ "${ARCH}" == "um" ]]; then
		# Only Kselftest builds without warning.
		if [[ "${SOURCE_DIR##tools/}" == "${SOURCE_DIR}" ]]; then
			return
		else
			patch_kselftest
		fi
	fi

	make_clean

	check_sparse
	# Put warning check in the middle to force the next C=1 build.
	check_warning
	check_smatch
}

check_source_dir() {
	set_source_dir "$1"

	check_build

	check_format
}

patch_kselftest() {
	# Fixed with commit a52540522c95 ("selftests/landlock: Fix out-of-tree builds").
	if grep -qE '^all: khdr$' tools/testing/selftests/Makefile; then
		PATCHES+=(kselftest)
		trap unpatch_all QUIT INT TERM EXIT
		sed -e '0,/^all: khdr$/s//all:/' -i tools/testing/selftests/Makefile
		echo "[+] Patched Kselftest"
	fi
}

build_kselftest() {
	local static_build=()

	# Makes sure tests are fresh and not containing unsupported ones.
	rm -r -- "${O}/kselftest/kselftest_install/landlock" 2>/dev/null || :
	rm -r -- "${O}/kselftest/landlock" 2>/dev/null || :

	# Opportunistically build with a static library (e.g. on Debian).
	if [[ -f /usr/lib/x86_64-linux-gnu/libcap.a ]]; then
		if grep -q USERLDFLAGS tools/testing/selftests/lib.mk; then
			# commit de3ee3f63400 ("selftests: Use optional USERCFLAGS and USERLDFLAGS")
			static_build+=("USERLDFLAGS=-static")
		else
			static_build+=("LDFLAGS=-static")
		fi
	fi

	set_source_dir tools/testing/selftests/landlock
	make_cmd "${MAKE_ARGS[@]}" "${static_build[@]}" install
}

run_kselftest_uml() {
	local timeout=60

	# TODO: Use ./run_kselftest.sh --summary while catching test errors.
	timeout --signal KILL "${timeout}" </dev/null 2>&1 "${BASE_DIR}/uml-run.sh" \
		"${O}/linux" \
		-- \
		"${BASE_DIR}/guest/kselftest.sh" \
		"${O}/kselftest/kselftest_install/landlock" \
		| timeout "$((timeout + 1))" cat
}

run_kselftest() {
	case "${ARCH}" in
		um)
			run_kselftest_uml
			;;
		*)
			echo "ERROR: Architecture not supported" >&2
			exit 1
			;;
	esac
}

run_kunit() {
	if [[ -f security/landlock/.kunitconfig ]]; then
		if [[ "$O" != "." ]]; then
			echo "[+] Running KUnit tests"
			# TODO: Reuse the common build directory?
			./tools/testing/kunit/kunit.py \
				run \
				--kunitconfig security/landlock \
				--arch "${ARCH}" \
				--build_dir "${O}-kunit"
		else
			echo "WARNING: Cannot run KUnit tests" >&2
		fi
	else
		echo "[*] No KUnit tests"
	fi
}

check_doc_path() {
	local path="$1"
	local date="$(git log --no-walk '--date=format:%B %Y' --format=%ad HEAD -- "${path}")"

	if [[ -z "${date}" ]]; then
		return
	fi

	echo "[+] Checking date ${date} in ${path}"
	if ! grep -q "^:Date: ${date}\$" -- "${path}"; then
		echo "[-] Incorrect date"
		return 1
	fi
}

check_doc() {
	check_doc_path Documentation/userspace-api/landlock.rst
	check_doc_path Documentation/security/landlock.rst
	./scripts/kernel-doc -Werror -none include/uapi/linux/landlock.h security/landlock/*.h
}

check_patch() {
	./scripts/checkpatch.pl --strict --codespell --git HEAD
}

exit_usage() {
	echo "usage: $(basename -- "${BASH_SOURCE[0]}") all|build|build_light|lint|build_kselftest|kselftest|kunit|doc|patch..." >&2
	exit 1
}

run() {
	case "${1:-}" in
		all)
			run build
			run lint
			run kselftest
			run kunit
			run doc
			run patch
			;;
		build)
			create_config check
			install_headers
			build_main
			;;
		build_light)
			# Required for a deterministic Linux kernel.
			if [[ -e "${O}/.version" ]]; then
				rm "${O}/.version"
			fi
			create_config light
			install_headers
			build_main light
			if [[ "${ARCH}" = "um" ]]; then
				strip "${O}/linux"
			fi
			;;
		lint)
			install_headers
			# tools/testing/selftests must go first because of patch_kselftest()
			check_source_dir tools/testing/selftests/landlock
			check_source_dir security/landlock
			check_source_dir samples/landlock
			;;
		build_kselftest)
			install_headers
			patch_kselftest
			build_kselftest
			;;
		kselftest)
			run build_kselftest
			run_kselftest
			;;
		kunit)
			run_kunit
			;;
		doc)
			check_doc
			;;
		patch)
			check_patch
			;;
		*)
			exit_usage
			;;
	esac
}

if [[ $# -lt 1 ]]; then
	exit_usage
fi

echo "[*] Architecture: ${ARCH}"
echo "[*] Compiler: ${CC}"
echo "[*] Build directory: ${O}"

if ! command -v git &>/dev/null; then
	echo "ERROR: Unable to find the \"git\" command" >&2
	exit 1
fi

while [[ $# -ge 1 ]]; do
	run "$1"
	shift
done
