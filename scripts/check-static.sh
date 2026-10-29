#!/usr/bin/env bash
# Static checks for this repository. Never builds or runs the image, so it is
# fast enough to gate the pull request workflow before the Docker build.
#
# Usage: scripts/check-static.sh
#
# Checks, each reported as one PASS/SKIP/FAIL line:
#   bash -n     syntax of every *.sh in the repository
#   ShellCheck  static analysis of every *.sh (skipped when not installed)
#   actionlint  analysis of .github/workflows/*.yml (downloaded hermetically
#               into a temp dir at the pinned ACTIONLINT_VERSION and removed
#               again; skipped with a warning when it cannot be obtained)
#   yaml        YAML parse of every workflow, .github/dependabot.yml, and
#               compose.yaml
#   compose     `docker compose config -q` when a Docker CLI is available
#   pin-image   self-test of scripts/pin-image.sh in a temp directory (create,
#               in-place update, idempotency, refusal of :latest and of a bare
#               repository name) plus, when docker compose is available, that
#               compose.pinned.example.yaml merges to the pinned digest
#
# Exits non-zero when any check fails. Skips are never a failure, so a laptop
# without ShellCheck still gets a useful answer.
#
# Environment:
#   ACTIONLINT_VERSION   version to download (default: 1.7.7); set to "none"
#                        to never download
#   SHELLCHECK_SEVERITY  minimum severity to report (default: warning, so
#                        style-level info findings in older scripts do not
#                        block a build)
#   NO_DOWNLOAD=1        never download anything; missing tools are skipped
set -o pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

actionlint_version="${ACTIONLINT_VERSION:-1.7.7}"
shellcheck_severity="${SHELLCHECK_SEVERITY:-warning}"

failures=0
skips=0

pass() { printf 'PASS  %s\n' "$*"; }
skip() {
  printf 'SKIP  %s\n' "$*"
  skips=$((skips + 1))
}
fail() {
  printf 'FAIL  %s\n' "$*"
  failures=$((failures + 1))
}

# Newline separated list; macOS ships bash 3.2, so no mapfile and no
# associative arrays in this script.
shell_files="$(find . -name '*.sh' -not -path './.git/*' -not -path '*/node_modules/*' | sort)"
workflow_files="$(find .github/workflows -maxdepth 1 -name '*.yml' | sort)"
yaml_files="$(printf '%s\n%s\n' "$workflow_files" "$(ls .github/dependabot.yml compose.yaml 2>/dev/null | sort | sed 's|^\./||')")"

count_of() { printf '%s\n' "$1" | grep -c . || true; }

printf 'repository: %s\n\n' "$repo_root"

# --- 1. bash -n -------------------------------------------------------------
if [ -z "$shell_files" ]; then
  fail "bash -n: no *.sh files found"
else
  syntax_ok=1
  while IFS= read -r script; do
    [ -n "$script" ] || continue
    if ! out="$(bash -n "$script" 2>&1)"; then
      syntax_ok=0
      printf '%s\n' "$out"
      fail "bash -n: ${script}"
    fi
  done <<EOF
$shell_files
EOF
  [ "$syntax_ok" = "1" ] && pass "bash -n: $(count_of "$shell_files") script(s)"
fi

# --- 2. shellcheck ----------------------------------------------------------
if ! command -v shellcheck >/dev/null 2>&1; then
  skip "shellcheck: not installed (brew install shellcheck / apt-get install shellcheck)"
else
  # ShellCheck parses the POSIX scripts in this repository too, so pass every
  # file at once. The list is expanded word-split on purpose: it only contains
  # repository paths, and the count is checked above.
  # shellcheck disable=SC2046
  if out="$(shellcheck --severity="$shellcheck_severity" --format=gcc $shell_files 2>&1)"; then
    pass "shellcheck ($shellcheck_severity): $(count_of "$shell_files") script(s)"
  else
    printf '%s\n' "$out"
    fail "shellcheck ($shellcheck_severity)"
  fi
fi

# --- 3. actionlint ----------------------------------------------------------
actionlint_bin=""
if command -v actionlint >/dev/null 2>&1; then
  actionlint_bin="actionlint"
elif [ "$actionlint_version" = "none" ] || [ "${NO_DOWNLOAD:-0}" = "1" ]; then
  skip "actionlint: not installed and download disabled"
else
  case "$(uname -s)" in
    Darwin) al_os="darwin" ;;
    Linux) al_os="linux" ;;
    *) al_os="" ;;
  esac
  case "$(uname -m)" in
    x86_64 | amd64) al_arch="x86_64" ;;
    arm64 | aarch64) al_arch="arm64" ;;
    *) al_arch="" ;;
  esac

  if [ -z "$al_os" ] || [ -z "$al_arch" ]; then
    skip "actionlint: no prebuilt binary for $(uname -s)/$(uname -m); install it manually"
  elif ! command -v curl >/dev/null 2>&1; then
    skip "actionlint: not installed and curl is unavailable to download it"
  else
    al_dir="$(mktemp -d "${TMPDIR:-/tmp}/check-static-actionlint.XXXXXX")"
    al_url="https://github.com/rhysd/actionlint/releases/download/v${actionlint_version}/actionlint_${actionlint_version}_${al_os}_${al_arch}.tar.gz"
    printf 'note  actionlint: downloading %s\n' "$al_url"
    if curl -fsSL "$al_url" | tar -xz -C "$al_dir" actionlint 2>/dev/null && [ -x "$al_dir/actionlint" ]; then
      actionlint_bin="$al_dir/actionlint"
      printf 'note  actionlint: pinned %s in %s (removed on exit)\n' "$actionlint_version" "$al_dir"
      # shellcheck disable=SC2064 # expand the path now, not at trap time
      trap "rm -rf '$al_dir'" EXIT
    else
      rm -rf "$al_dir"
      skip "actionlint: download of ${actionlint_version} failed (offline?); install actionlint to enable"
    fi
  fi
fi

if [ -n "$actionlint_bin" ]; then
  if [ -z "$workflow_files" ]; then
    fail "actionlint: no workflow files found"
  elif out="$("$actionlint_bin" $workflow_files 2>&1)"; then
    pass "actionlint: $(count_of "$workflow_files") workflow(s) [$("$actionlint_bin" --version | sed -n '1p')]"
  else
    printf '%s\n' "$out"
    fail "actionlint: workflow problems above"
  fi
fi

# --- 4. YAML parse ----------------------------------------------------------
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
  yaml_ok=1
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if ! out="$(python3 - "$file" <<'PY' 2>&1
import sys

import yaml

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        document = yaml.safe_load(handle)
except Exception as error:  # noqa: BLE001 - report anything the parser raises
    print(f"{path}: {error}")
    raise SystemExit(1)
if document is None:
    print(f"{path}: parsed as an empty document")
    raise SystemExit(1)
PY
    )"; then
      printf '%s\n' "$out"
      yaml_ok=0
      fail "yaml: ${file}"
    fi
  done <<EOF
$yaml_files
EOF
  [ "$yaml_ok" = "1" ] && pass "yaml: $(count_of "$yaml_files") file(s) parse with python3/yaml.safe_load"
elif command -v ruby >/dev/null 2>&1; then
  yaml_ok=1
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if ! out="$(ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0]), aliases: true)' "$file" 2>&1)"; then
      printf '%s\n' "$out"
      yaml_ok=0
      fail "yaml: ${file}"
    fi
  done <<EOF
$yaml_files
EOF
  [ "$yaml_ok" = "1" ] && pass "yaml: $(count_of "$yaml_files") file(s) parse with ruby/YAML"
else
  skip "yaml: neither python3+pyyaml nor ruby is available"
fi

# --- 5. compose -------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  skip "compose: docker compose not available"
elif out="$(docker compose config -q 2>&1)"; then
  pass "compose: docker compose config -q"
else
  printf '%s\n' "$out"
  fail "compose: docker compose config -q"
fi

# --- 6. pin-image self-test -------------------------------------------------
# scripts/pin-image.sh and compose.pinned.example.yaml are the sanctioned way to
# pin a deployment, and nothing here exercised them. Everything below runs in a
# temp directory and never touches the network.
pin_dir="$(mktemp -d "${TMPDIR:-/tmp}/check-static-pin.XXXXXX")"
pin_problems=0
pin_note() {
  printf 'note  pin-image: %s\n' "$*"
  pin_problems=$((pin_problems + 1))
}

# run_pin <args...> runs the tool from the temp directory, so a relative --file
# behaves the way it does for an operator running it in their deployment copy.
run_pin() { (cd "$pin_dir" && "$repo_root/scripts/pin-image.sh" "$@"); }

pin_ref="tuantuantuantuantuan/observium:2026.10.26"
pin_env="$pin_dir/.env"
pin_checks="create, in-place update, idempotency, refusal of :latest and of a bare repository name"

# 1. create: a fresh env file holds exactly the pinned line.
if ! out="$(run_pin "$pin_ref" --file "$pin_env" 2>&1)"; then
  pin_note "create failed: ${out}"
elif [ "$(cat "$pin_env")" != "OBSERVIUM_IMAGE=${pin_ref}" ]; then
  pin_note "create wrote '$(cat "$pin_env")' instead of OBSERVIUM_IMAGE=${pin_ref}"
fi

# 2. in-place update: the line is replaced where it stands, comments and other
# variables survive, and duplicates are dropped.
cat >"$pin_env" <<'EOF'
# deployment settings
OBSERVIUM_HTTP_PORT=8080
OBSERVIUM_IMAGE=stale/image:2025.1
OBSERVIUM_ADMIN_USER=admin
OBSERVIUM_IMAGE=duplicate/image:2025.1
EOF
pin_expected="$pin_dir/expected"
printf '# deployment settings\nOBSERVIUM_HTTP_PORT=8080\nOBSERVIUM_IMAGE=%s\nOBSERVIUM_ADMIN_USER=admin\n' \
  "$pin_ref" >"$pin_expected"
if ! run_pin "$pin_ref" --file "$pin_env" >/dev/null 2>&1; then
  pin_note "in-place update failed"
elif ! cmp -s "$pin_env" "$pin_expected"; then
  pin_note "in-place update did not preserve the file: $(tr '\n' '|' <"$pin_env")"
fi

# 3. idempotency: a second identical run leaves the file byte-identical.
cp "$pin_env" "$pin_dir/first-run"
if ! run_pin "$pin_ref" --file "$pin_env" >/dev/null 2>&1; then
  pin_note "second run failed"
elif ! cmp -s "$pin_env" "$pin_dir/first-run"; then
  pin_note "a second identical run changed the file: $(tr '\n' '|' <"$pin_env")"
fi

# 4. refusals: a :latest pin and a bare repository name (no tag, so :latest) are
# both rejected, and a rejected pin must not rewrite the file.
cp "$pin_env" "$pin_dir/before-refusals"
if run_pin "tuantuantuantuantuan/observium:latest" --file "$pin_env" >/dev/null 2>&1; then
  pin_note "a :latest pin was accepted"
fi
if run_pin "tuantuantuantuantuan/observium" --file "$pin_env" >/dev/null 2>&1; then
  pin_note "a bare repository name (implicit :latest) was accepted"
fi
if ! cmp -s "$pin_env" "$pin_dir/before-refusals"; then
  pin_note "a refused pin still rewrote the env file"
fi

# 5. a digest reference drops its tag: the digest alone decides which bytes run.
pin_digest="sha256:$(printf '%064d' 0)"
if ! run_pin "tuantuantuantuantuan/observium:2026.10.26@${pin_digest}" --file "$pin_env" >/dev/null 2>&1; then
  pin_note "a repo:tag@sha256 reference was rejected"
elif [ "$(sed -n 's/^OBSERVIUM_IMAGE=//p' "$pin_env")" != "tuantuantuantuantuan/observium@${pin_digest}" ]; then
  pin_note "a digest reference did not drop its tag: $(sed -n 's/^OBSERVIUM_IMAGE=//p' "$pin_env")"
fi

# 6. compose.pinned.example.yaml must merge over compose.yaml and win, i.e. the
# service the stack runs is the pinned repo@sha256 reference from that file.
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  skip "pin-image: compose.pinned.example.yaml not verified (docker compose not available)"
else
  pin_checks="${pin_checks}, compose override"
  pinned_ref="$(awk '/^[[:space:]]+image:/ { print $2; exit }' compose.pinned.example.yaml)"
  case "$pinned_ref" in
    *@sha256:*) ;;
    *) pin_note "compose.pinned.example.yaml does not pin by digest: '${pinned_ref}'" ;;
  esac
  if ! out="$(docker compose -f compose.yaml -f compose.pinned.example.yaml config -q 2>&1)"; then
    pin_note "docker compose config -q with the pinned override failed: ${out}"
  else
    merged_image="$(docker compose -f compose.yaml -f compose.pinned.example.yaml config 2>/dev/null |
      awk '/^  [A-Za-z0-9_.-]+:$/ { service = $1; sub(/:$/, "", service) }
           service == "observium" && $1 == "image:" { print $2; exit }')"
    if [ "$merged_image" != "$pinned_ref" ]; then
      pin_note "the merged compose config runs '${merged_image}' instead of the pinned '${pinned_ref}'"
    fi
  fi
fi

rm -rf "$pin_dir"
if [ "$pin_problems" -ne 0 ]; then
  fail "pin-image: self-test (${pin_problems} problem(s) above)"
else
  pass "pin-image: self-test (${pin_checks})"
fi

printf '\n%d failure(s), %d skipped\n' "$failures" "$skips"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
printf 'PASS: static checks\n'
