#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Copyright © 2016-2024 Mickaël Salaün <mic@digikod.net>.
#
# Build the kernel, samples, tests and check everything for Landlock.
#
# Dependencies:
# - virtme-ng (to run kselftest on x86_64)
#
# usage: [ARCH=um] [CC=gcc] [BUILD_FLAVOR=check|light] check-linux.sh <command>...

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
	if [[ "${ARCH}" = "um" ]]; then
		# clang requires CROSS_COMPILE
		export CC="gcc"
	else
		export CC="clang"
	fi
fi

# Build flavor controls config extras and build directory suffix.
# - check (default): full debug, config-check extras (KASAN/KCSAN), samples.
# - light: no debug extras, no samples, strip UML binary.
# build_variants defaults to light when BUILD_FLAVOR is not explicitly set.
if [[ -z "${BUILD_FLAVOR:-}" ]]; then
	if [[ $# -eq 1 && "${1:-}" = "build_variants" ]]; then
		BUILD_FLAVOR="light"
	else
		BUILD_FLAVOR="check"
	fi
fi

if [[ "${BUILD_FLAVOR}" != "check" && "${BUILD_FLAVOR}" != "light" ]]; then
	echo "ERROR: BUILD_FLAVOR must be 'check' or 'light', got '${BUILD_FLAVOR}'" >&2
	exit 1
fi

if [[ -z "${O:-}" ]]; then
	O_BASE="./.out-landlock-${ARCH}-${CC}"
	O="${O_BASE}-${BUILD_FLAVOR}"
else
	O_BASE="${O}"
fi
export O="$(readlink -f "${O}")"
export O_BASE="$(readlink -f "${O_BASE}")"

# Required for a deterministic Linux kernel.
export KBUILD_BUILD_USER="root"
export KBUILD_BUILD_HOST="localhost"
export KBUILD_BUILD_TIMESTAMP="$(git log --no-walk --pretty=format:%aD)"

CURRENT_COMMIT="$(git --no-pager log --no-walk --max-count=1 --pretty=format:%h HEAD)"

NPROC="$(nproc)"

# Options toggled by build_variants to test all combinations.
# Each entry is mapped to CONFIG_<NAME>=y.
VARIANT_CONFIGS=(AUDIT FTRACE)

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
		return 0
	fi

	if git apply "${BASE_DIR}/kernels/0001-test-Landlock-with-UML.patch" 2>/dev/null; then
		PATCHES+=(kernel_kconfig)
		trap unpatch_all QUIT INT TERM EXIT
		echo "[+] Patched Landlock's Kconfig for UML support"
	fi
}

patch_samples_kconfig() {
	if [[ "${ARCH}" != "um" ]]; then
		return 0
	fi

	# Requires headers to be installed.
	if git apply "${BASE_DIR}/kernels/0002-build-sandboxer-with-UML.patch" 2>/dev/null; then
		PATCHES+=(samples_kconfig)
		trap unpatch_all QUIT INT TERM EXIT
		echo "[+] Patched samples' Kconfig for UML support"
	fi
}

# Populates BASE_CONFIGS with the base config fragments
# (config-test + config-mini-${ARCH} + selftest config).
get_base_configs() {
	local config_arch="${BASE_DIR}/kernels/config-mini-${ARCH}"
	local config_landlock="tools/testing/selftests/landlock/config"

	if [[ ! -f "${config_arch}" ]]; then
		echo "ERROR: Architecture not supported" >&2
		exit 1
	fi

	BASE_CONFIGS=(
		"${BASE_DIR}/kernels/config-test"
		"${config_arch}"
	)

	if [[ -f "${config_landlock}" ]]; then
		BASE_CONFIGS+=("${config_landlock}")
	fi
}

# First argument: flavor (check or light).
# Optional second argument: sed filter applied to the merged config
# before allnoconfig (used by build_variants to disable CONFIG options).
create_config() {
	local flavor="${1:-check}"
	local filter="${2:-}"

	get_base_configs
	local config_all=("${BASE_CONFIGS[@]}")
	local config_selftests_arch="tools/testing/selftests/landlock/config.${ARCH}"

	if [[ -f "${config_selftests_arch}" ]]; then
		config_all+=("${config_selftests_arch}")
	fi

	if [[ "${flavor}" = "check" ]]; then
		local config_check_arch="${BASE_DIR}/kernels/config-check-${ARCH}"
		config_all+=("${BASE_DIR}/kernels/config-check")
		if [[ -f "${config_check_arch}" ]]; then
			config_all+=("${config_check_arch}")
		fi
	fi

	local merged
	merged=$(sort -u -- "${config_all[@]}")

	if [[ -n "${filter}" ]]; then
		merged=$(echo "${merged}" | sed "${filter}")
	fi

	patch_kernel_kconfig
	patch_samples_kconfig

	echo "[+] Creating minimal configuration"
	make_cmd \
		KCONFIG_ALLCONFIG=<(echo "${merged}") \
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

build_main() {
	make_cmd || return $?

	# The sandboxer sample only exists once Landlock is present (v5.13+).
	# Older kernels, built to exercise the unsupported-ABI case, ship no
	# samples/landlock, so require the built sample only when its source
	# is present.
	if [[ -e samples/landlock/sandboxer.c ]] &&
	   [[ ! -f "${O}/samples/landlock/sandboxer" ]]; then
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

check_uapi_cxx() {
	echo "[+] Checking UAPI C++ compatibility"
	local cxx=""

	if command -v g++ &>/dev/null; then
		cxx="g++"
	elif command -v clang++ &>/dev/null; then
		cxx="clang++"
	else
		echo "ERROR: Unable to find g++ or clang++" >&2
		exit 1
	fi

	echo '#include <linux/landlock.h>' | \
		"${cxx}" -x c++ -std=c++23 -fsyntax-only -isystem "${O}/usr/include" -
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

# Records the stack usage for the current build and compare it to the parent.
# When a parent reference is explicitly set, check_stack_landlock fails if
# stack usage cannot be computed.
check_stack_landlock() {
	local parent_ref parent_set
	local path="security/landlock/"
	local current_usage="${O}/stackusage-${CURRENT_COMMIT}.txt"

	if [[ -n "${1:-}" ]]; then
		parent_ref="$1"
		parent_set=true
	else
		parent_ref="HEAD~"
		parent_set=false
	fi

	if [[ "${CC:-}" != "gcc" ]]; then
		echo "[-] Stack usage needs CC=gcc" >&2
		if ${parent_set}; then
			exit 1
		else
			return 0
		fi
	fi

	echo "[+] Checking stack usage: ${path}"
	rm "${O}/${path}/"*.o 2>/dev/null || :
	# See make_cmd:
	./scripts/stackusage -o "${current_usage}" "-j${NPROC}" "ARCH=${ARCH}" "CC=${CC}" "O=${O}" "${path}"

	local parent_commit parent_usage
	# Pick the first parent.
	parent_commit="$(git --no-pager log --no-walk --max-count=1 --pretty=format:%h "${parent_ref}")"
	parent_usage="${O}/stackusage-${parent_commit}.txt"
	if [[ -f "${parent_usage}" ]]; then
		echo "[*] Stack delta between ${parent_commit} and ${CURRENT_COMMIT}:"
		./scripts/stackdelta "${parent_usage}" "${current_usage}" | \
			cut -f2- | \
			sort -k4,4g | \
			column -t |
			sed 's/^/  /'
	elif ${parent_set}; then
		echo "[-] Failed to find parent stack usage: ${parent_usage}" >&2
		exit 1
	fi
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
		local last_version="21"
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
			return 0
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

gcov_extract() {
	local coverage_dir="${1:-}"
	local gcov_dir

	if [[ -z "${coverage_dir}" ]]; then
		return
	fi

	gcov_dir="${coverage_dir}/gcov"
	mkdir -- "${gcov_dir}"
	tar --touch -C "${gcov_dir}" -xf "${coverage_dir}/gcov.tar.gz"

	# Creates test coverage data file.
	lcov \
		--gcov-tool "${BASE_DIR}/llvm-gcov.sh" \
		--ignore-errors inconsistent,inconsistent \
		--quiet \
		--capture \
		--directory "${gcov_dir}" \
		--output-file "${coverage_dir}/landlock.info"

	# Generates web pages.
	genhtml -q -o "${coverage_dir}/html" "${coverage_dir}/landlock.info"

	# Prints result.
	#
	# Some llvm-gcov.sh might return "  LLVM version X.Y.Z" and other
	# "Ubuntu LLVM version X.Y.Z"
	local gcov_version="$("${BASE_DIR}/llvm-gcov.sh" --version | sed -ne 's/^.*LLVM version \([0-9]\+\)\..*$/\1/p')"
	lcov --extract "${coverage_dir}/landlock.info" security/landlock \
		-o /dev/null | \
			sed -n "s#^ \+lines\.\+: \([0-9.]\+%\) ([0-9]\+ of \([0-9]\+\) lines)\$#Test coverage for security/landlock is \1 of \2 lines according to\nLLVM ${gcov_version}.#p"

	rm -- "${coverage_dir}/gcov.tar.gz"
	rm -r  -- "${gcov_dir}"

	# Symlink to the latest coverage for easy access.
	ln -srfn "${coverage_dir}" "${coverage_dir%/*}/coverage-latest"
}

run_kselftest_x86() {
	local timeout=300
	local coverage_dir=""
	local coverage_args=()
	local inc="$(date +%s)"

	if grep -q "^CONFIG_GCOV_KERNEL=y$" "${O}/.config"; then
		if grep -q "^CONFIG_CC_IS_CLANG=y$" "${O}/.config"; then
			coverage_dir="${O}/coverage-${inc}-${CURRENT_COMMIT}"
			mkdir -- "${coverage_dir}"
			coverage_args=(-c "${coverage_dir}")
			echo "[+] Testing and generating coverage in ${coverage_dir}"
		else
			# Some GCC versions don't work.
			echo "[*] No test coverage without clang"
		fi
	else
		echo "[+] Testing (without coverage)"
	fi

	timeout --signal KILL "${timeout}" </dev/null 2>&1 "${BASE_DIR}/x86-run.sh" \
		"${O}/arch/x86/boot/bzImage" \
		"${coverage_args[@]}" \
		-- \
		"${BASE_DIR}/guest/kselftest.sh" \
		"${O}/kselftest/kselftest_install/landlock" \
		${coverage_dir:+"${coverage_dir}"} \
		| timeout "$((timeout + 1))" cat

	gcov_extract "${coverage_dir}"
}

run_kselftest() {
	case "${ARCH}" in
		um)
			run_kselftest_uml
			;;
		x86_64)
			run_kselftest_x86
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
			./tools/testing/kunit/kunit.py \
				run \
				--kunitconfig security/landlock \
				--arch "${ARCH}" \
				--build_dir "${O_BASE}-kunit"
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
		return 0
	fi

	echo "[+] Checking date ${date} in ${path}"
	if ! grep -q "^:Date: ${date}\$" -- "${path}"; then
		echo "[-] Incorrect date"
		return 1
	fi
}

check_doc() {
	check_doc_path Documentation/admin-guide/LSM/landlock.rst
	check_doc_path Documentation/security/landlock.rst
	check_doc_path Documentation/userspace-api/landlock.rst
	./scripts/kernel-doc \
		-Werror \
		-Wall \
		-none \
		include/uapi/linux/landlock.h \
		security/landlock/*.h \
		security/landlock/*.c
}

check_patch() {
	./scripts/checkpatch.pl --strict --codespell --git HEAD
}

build_variants() {
	local -a options=("${VARIANT_CONFIGS[@]}")
	local n=${#options[@]}
	local total=$((1 << n))

	local saved_o="${O}"
	local mask failed=0
	for ((mask = 0; mask < total; mask++)); do
		local label="" suffix="" filter=""
		local bit
		for ((bit = 0; bit < n; bit++)); do
			local name="${options[$bit]}"
			local opt="CONFIG_${name}=y"

			if (( mask & (1 << bit) )); then
				label+="${name}=n "
				suffix+="-no${name,,}"
				filter+="/^${opt}$/d;"
			else
				label+="${name}=y "
			fi
		done

		echo "[*] Variant $((mask + 1))/${total}: ${label}"
		O="${saved_o}${suffix}"

		create_config "${BUILD_FLAVOR}" "${filter}"
		install_headers

		if build_main; then
			echo "[+] OK: ${label}"
		else
			echo "[-] FAILED: ${label}"
			failed=$((failed + 1))
		fi
	done
	O="${saved_o}"

	if [[ ${failed} -gt 0 ]]; then
		echo "[-] ${failed}/${total} variants failed"
		return 1
	fi
	echo "[+] All ${total} variants passed"
}

exit_usage() {
	echo "usage: [BUILD_FLAVOR=check|light] $(basename -- "${BASH_SOURCE[0]}") all|build|build_variants|lint|stack|build_kselftest|kselftest|kunit|doc|patch..." >&2
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
			# Required for a deterministic Linux kernel.
			if [[ -e "${O}/.version" ]]; then
				rm "${O}/.version"
			fi
			create_config "${BUILD_FLAVOR}"
			install_headers
			build_main
			if [[ "${BUILD_FLAVOR}" = "light" && "${ARCH}" = "um" ]]; then
				strip "${O}/linux"
			fi
			;;
		build_light)
			echo "ERROR: build_light is removed. Use BUILD_FLAVOR=light check-linux.sh build" >&2
			exit 1
			;;
		build_variants)
			build_variants
			;;
		stack)
			# Needs a valid kernel configuration.
			#
			# When a parent reference is explicitly set,
			# check_stack_landlock fails if stack usage cannot be
			# computed.
			check_stack_landlock ${PARENT_REF:-}
			;;
		lint)
			install_headers
			check_uapi_cxx
			# tools/testing/selftests must go first because of patch_kselftest()
			check_source_dir tools/testing/selftests/landlock
			check_source_dir security/landlock
			check_stack_landlock
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

# build_variants must be the only subcommand because its BUILD_FLAVOR
# default (light) would be inconsistent with other subcommands.
for arg in "$@"; do
	if [[ "${arg}" = "build_variants" && $# -gt 1 ]]; then
		echo "ERROR: build_variants cannot be combined with other subcommands" >&2
		exit 1
	fi
done

echo "[*] Architecture: ${ARCH}"
echo "[*] Compiler: ${CC}"
echo "[*] Build flavor: ${BUILD_FLAVOR}"
echo "[*] Build directory: ${O}"

if ls -d .out-landlock_local-* &>/dev/null; then
	echo "[!] WARNING: Old build directories detected (.out-landlock_local-*)." >&2
	echo "[!] They are no longer used and can be removed." >&2
fi

if ! command -v git &>/dev/null; then
	echo "ERROR: Unable to find the \"git\" command" >&2
	exit 1
fi

while [[ $# -ge 1 ]]; do
	run "$1"
	shift
done
