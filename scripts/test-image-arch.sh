#!/usr/bin/env bash
# Execute an image of one architecture and assert that the binaries that make
# the image useful actually run on that architecture.
#
# Usage: scripts/test-image-arch.sh <image-ref> <platform> [expected-php-version]
#
# Example:
#   scripts/test-image-arch.sh tuantuantuantuantuan/observium@sha256:... linux/arm64 8.5.14-1+0~20241024.39+debian13~1.gbp1fb848
#
# The image must already be present locally for <platform> (the release
# workflow pulls it with `docker pull --platform`, or loads it with
# `docker buildx build --load`). On a non-native host the platform runs under
# QEMU via binfmt_misc; the script fails with a clear message when that is not
# available instead of reporting a misleading PHP error.
#
# What is asserted:
#   - `php -v` runs and reports a version;
#   - that version matches the org.observium.php.version label baked into the
#     image and, when given, the expected version passed as the third argument
#     (each source is compared when it is available; an image without the label
#     still checks the argument, and vice versa);
#   - the PHP-FPM binary exists and is executable;
#   - `nginx -t` passes with the configuration baked into the image;
#   - the container entrypoint (/usr/local/bin/entrypoint.sh, from
#     docker/entrypoint.sh) is executable;
#   - PHP_INT_SIZE matches the platform (8 on amd64/arm64, 4 on linux/arm/v7);
#   - the kernel architecture seen by PHP matches the requested platform, so a
#     silently ignored --platform cannot pass as a success.
#
# Environment:
#   EXPECTED_PHP_VERSION   same as the third argument; the argument wins.
#
# Exits 0 when every assertion holds, 1 on a failed assertion, 2 on usage or an
# unsupported platform.
set -uo pipefail

usage() {
  printf 'usage: %s <image-ref> <platform> [expected-php-version]\n' "${0##*/}" >&2
  exit 2
}

[ "$#" -ge 2 ] || usage
image="$1"
platform="$2"
expected_version="${3:-${EXPECTED_PHP_VERSION:-}}"
FAILURES=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*" >&2
  FAILURES=$((FAILURES + 1))
}

# platform -> expected PHP_INT_SIZE and the architecture name PHP must report.
# The machine patterns are globs, because arm variants report armv7l/armv6l.
case "$platform" in
  linux/amd64)
    want_int=8
    want_machine="x86_64 amd64"
    ;;
  linux/arm64 | linux/arm64/v8)
    want_int=8
    want_machine="aarch64 arm64"
    ;;
  linux/arm/v7 | linux/arm)
    want_int=4
    want_machine="armv7*"
    ;;
  linux/arm/v6)
    want_int=4
    want_machine="armv6*"
    ;;
  linux/386)
    want_int=4
    want_machine="i?86"
    ;;
  *)
    printf 'error: unsupported platform %s (add it to the table in %s)\n' \
      "$platform" "${0##*/}" >&2
    exit 2
    ;;
esac

if ! command -v docker >/dev/null 2>&1; then
  printf 'error: docker is not available\n' >&2
  exit 2
fi

printf 'image:    %s\nplatform: %s\n\n' "$image" "$platform"

# One container for the whole probe: every extra `docker run` costs another
# QEMU boot on the emulated platforms.
probe="$(cat <<'PROBE'
set -u
if php -v >/tmp/php-v.log 2>&1; then
  printf 'php-cli=ok\n'
  printf 'php-v-first-line=%s\n' "$(sed -n '1p' /tmp/php-v.log)"
else
  printf 'php-cli=fail:%s\n' "$(tr '\n' ' ' < /tmp/php-v.log)"
fi
printf 'php-version=%s\n' "$(php -r 'echo PHP_VERSION;' 2>&1 | tr -d '\n')"
printf 'php-int-size=%s\n' "$(php -r 'echo PHP_INT_SIZE;' 2>&1 | tr -d '\n')"
printf 'php-machine=%s\n' "$(php -r 'echo php_uname("m");' 2>&1 | tr -d '\n')"

if nginx -t >/tmp/nginx-t.log 2>&1; then
  printf 'nginx-test=ok\n'
else
  printf 'nginx-test=fail:%s\n' "$(tr '\n' ' ' < /tmp/nginx-t.log)"
fi

fpm=''
for candidate in /usr/sbin/php-fpm8.5 /usr/sbin/php-fpm /usr/local/sbin/php-fpm8.5; do
  if [ -x "${candidate}" ]; then
    fpm="${candidate}"
    break
  fi
done
if [ -z "${fpm}" ]; then
  fpm="$(command -v php-fpm 2>/dev/null || true)"
fi
if [ -n "${fpm}" ] && [ -x "${fpm}" ]; then
  printf 'php-fpm=%s\n' "${fpm}"
else
  printf 'php-fpm=none\n'
fi

if [ -x /usr/local/bin/entrypoint.sh ]; then
  printf 'entrypoint-executable=yes\n'
else
  printf 'entrypoint-executable=no\n'
fi
PROBE
)"

stderr_file="$(mktemp "${TMPDIR:-/tmp}/test-image-arch.XXXXXX")"
# shellcheck disable=SC2064 # expand the path now, not at trap time
trap "rm -f '$stderr_file'" EXIT

if ! out="$(docker run --rm --platform "$platform" --entrypoint sh \
  "$image" -c "$probe" 2>"$stderr_file")"; then
  printf '%s\n' "$(cat "$stderr_file")" >&2
  local_platform="$(docker image inspect --format \
    '{{.Os}}/{{.Architecture}}{{if .Variant}}/{{.Variant}}{{end}}' "$image" 2>/dev/null || true)"
  if [ -n "$local_platform" ]; then
    fail "could not run ${image} with --platform ${platform}: the local image is ${local_platform}. Pull or build the image for ${platform}, and register QEMU/binfmt when it is not the native platform."
  else
    fail "could not run ${image} with --platform ${platform}: the image is not available locally and could not be pulled"
  fi
  printf '\n%d assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi
if [ -s "$stderr_file" ]; then
  # tini or nginx may warn on the way out; keep it visible without failing.
  printf 'note: docker run stderr:\n%s\n' "$(cat "$stderr_file")"
fi

# key=value lines -> shell variables of the same name with dashes replaced.
value_of() {
  printf '%s\n' "$out" | sed -n "s/^$1=//p" | sed -n '1p'
}

php_cli="$(value_of php-cli)"
php_version="$(value_of php-version)"
php_int_size="$(value_of php-int-size)"
php_machine="$(value_of php-machine)"
nginx_test="$(value_of nginx-test)"
php_fpm="$(value_of php-fpm)"
entrypoint_executable="$(value_of entrypoint-executable)"

# --- php -v -----------------------------------------------------------------
case "$php_cli" in
  ok) pass "php -v runs ($(value_of php-v-first-line))" ;;
  *) fail "php -v failed: ${php_cli#fail:}" ;;
esac

# --- PHP version matches the label / the requested version ------------------
label=""
container="$(docker create --platform "$platform" --entrypoint /bin/true "$image" 2>/dev/null || true)"
if [ -n "$container" ]; then
  label="$(docker inspect --format '{{index .Config.Labels "org.observium.php.version"}}' \
    "$container" 2>/dev/null || true)"
  docker rm -f "$container" >/dev/null 2>&1 || true
fi

# Two sources of truth: the label baked into the image and the version the
# release workflow resolved for this platform. The image must agree with both.
case "$php_version" in
  '' | *[!0-9.]*)
    fail "could not read the PHP version from the image (got '${php_version}')"
    ;;
  *)
    expectations="$(printf '%s\n%s\n' "$label" "$expected_version" | grep . | awk '!seen[$0]++')"
    if [ -z "$expectations" ]; then
      skip "PHP version ${php_version}: no org.observium.php.version label and no expected version (the Debian package version, e.g. 8.5.12-1+0~..., cannot be derived from PHP_VERSION alone)"
    else
      while IFS= read -r expectation; do
        # The expected value is the full Debian version (8.5.12-1+0~...);
        # PHP_VERSION is the upstream part. Accept an exact match or a prefix.
        case "$expectation" in
          "$php_version" | "$php_version"-* | "$php_version"+*)
            pass "PHP version ${php_version} matches ${expectation}"
            ;;
          *)
            fail "PHP version mismatch: image runs ${php_version}, expected ${expectation}"
            ;;
        esac
      done <<EOF
$expectations
EOF
    fi
    ;;
esac

# --- PHP_INT_SIZE -----------------------------------------------------------
if [ "$php_int_size" = "$want_int" ]; then
  pass "PHP_INT_SIZE is ${want_int} on ${platform}"
else
  fail "PHP_INT_SIZE is '${php_int_size}' on ${platform}, expected ${want_int}"
fi

# --- the right architecture actually ran ------------------------------------
machine_ok=0
for pattern in $want_machine; do
  # shellcheck disable=SC2254 # glob patterns are intentional
  case "$php_machine" in
    $pattern) machine_ok=1 ;;
  esac
done
if [ "$machine_ok" = "1" ]; then
  pass "kernel architecture ${php_machine} matches ${platform}"
else
  fail "PHP reports architecture '${php_machine}' but ${platform} was requested (expected ${want_machine})"
fi

# --- php-fpm ----------------------------------------------------------------
if [ "$php_fpm" = "none" ]; then
  fail "no php-fpm binary found in the image"
else
  pass "php-fpm present: ${php_fpm}"
fi

# --- nginx -t ---------------------------------------------------------------
case "$nginx_test" in
  ok) pass "nginx -t passes" ;;
  *) fail "nginx -t failed: ${nginx_test#fail:}" ;;
esac

# --- entrypoint -------------------------------------------------------------
if [ "$entrypoint_executable" = "yes" ]; then
  pass "entrypoint /usr/local/bin/entrypoint.sh is executable"
else
  fail "/usr/local/bin/entrypoint.sh is missing or not executable"
fi

if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d assertion(s) failed for %s on %s\n' "$FAILURES" "$image" "$platform" >&2
  exit 1
fi
printf '\nPASS: %s runs correctly on %s\n' "$image" "$platform"
