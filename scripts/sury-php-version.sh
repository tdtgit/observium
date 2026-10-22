#!/bin/sh
# Print the PHP 8.5 candidate version available from the sury Debian repository.
#
# Usage:
#   scripts/sury-php-version.sh <arch>      # e.g. amd64 | arm64
#   scripts/sury-php-version.sh             # all architectures, one per line
#
# sury publishes architectures independently, so the candidate can differ per
# arch for a short window after an upstream release. The version is read from
# the signed per-architecture package index, i.e. exactly what apt would
# install. Prints the version and exits 0, or exits 1 with a message on error.

set -eu

REPO="${SURY_PHP_REPO:-https://packages.sury.org/php}"
SUITE="${SURY_PHP_SUITE:-trixie}"
PACKAGE="${SURY_PHP_PACKAGE:-php8.5-cli}"
ARCHES="${SURY_PHP_ARCHES:-amd64 arm64}"

fetch() {
	# $1 = architecture; prints the candidate version of $PACKAGE
	curl -fsSL "${REPO}/dists/${SUITE}/main/binary-${1}/Packages" |
		awk -v pkg="${PACKAGE}" '
			$0 == "Package: " pkg { found = 1 }
			found && /^Version: / && !version { version = $2 }
			END { if (version) print version }
		'
}

if [ "$#" -ge 1 ]; then
	version="$(fetch "$1")"
	if [ -z "${version}" ]; then
		echo "error: ${PACKAGE} not found in ${SUITE}/main/binary-${1}/Packages" >&2
		exit 1
	fi
	echo "${version}"
	exit 0
fi

for arch in ${ARCHES}; do
	version="$(fetch "${arch}")"
	if [ -z "${version}" ]; then
		echo "error: ${PACKAGE} not found in ${SUITE}/main/binary-${arch}/Packages" >&2
		exit 1
	fi
	echo "${arch} ${version}"
done
