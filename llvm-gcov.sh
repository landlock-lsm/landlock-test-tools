#!/usr/bin/env bash

set -u -e -o pipefail

if command -v llvm-cov >/dev/null; then
	LLVM_COV="llvm-cov"
else
	# Some clang might return "clang version X.Y.Z" and other
	# "Ubuntu clang version X.Y.Z (1ubuntu1)"
	VERSION="$(clang --version | sed -ne 's/^.*clang version \([0-9]\+\)\..*$/\1/p')"
	LLVM_COV="llvm-cov-${VERSION}"
fi

exec "${LLVM_COV}" gcov "$@"
