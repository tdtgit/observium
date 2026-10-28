#!/usr/bin/env bash
# Pin the deployment to one exact image reference.
#
# Usage: scripts/pin-image.sh <tag-or-digest-reference> [options]
#
# Options:
#   --file <path>    env file to update (default: .env)
#   --digest         resolve the tag to its manifest digest and pin that
#   --allow-latest   permit a :latest pin, which is otherwise refused
#
# Writes a single OBSERVIUM_IMAGE=<reference> line into the env file that
# `docker compose` reads, so compose.yaml's `image:` picks it up. Other lines
# and comments in the file are preserved, and running the same command twice
# leaves the file unchanged.
#
# See docs/PINNING.md for why pinning matters and how to find a digest.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: pin-image.sh <tag-or-digest-reference> [--file <path>] [--digest] [--allow-latest]

  <tag-or-digest-reference>  e.g. tuantuantuantuantuan/observium:2026.10.26
                                  tuantuantuantuantuan/observium@sha256:<64 hex>
  --file <path>              env file to write (default: .env)
  --digest                   resolve the tag and pin repo@sha256:<digest> instead
  --allow-latest             allow a :latest pin (refused by default)
EOF
}

die() {
  printf 'pin-image: %s\n' "$*" >&2
  exit 1
}

# A tag is [A-Za-z0-9_][A-Za-z0-9_.-]{0,127}; a repository name is lower case
# components, with a registry host and port allowed in front.
tag_re='^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$'
name_re='^[a-z0-9]+([._-][a-z0-9]+)*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)*$'

env_file=".env"
want_digest=false
allow_latest=false
reference=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --file)
      [ "$#" -ge 2 ] || die "--file needs a path"
      env_file="$2"
      shift 2
      ;;
    --file=*)
      env_file="${1#*=}"
      shift
      ;;
    --digest)
      want_digest=true
      shift
      ;;
    --allow-latest)
      allow_latest=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *)
      [ -z "$reference" ] || die "only one image reference may be given"
      reference="$1"
      shift
      ;;
  esac
done

[ -n "$reference" ] || {
  usage >&2
  exit 2
}

# Split repo[:tag][@sha256:...] into its parts and validate each one.
name="$reference"
digest=""
case "$reference" in
  *@*)
    digest="${reference##*@}"
    name="${reference%@*}"
    case "$digest" in
      sha256:*) ;;
      *) die "only sha256 digests are supported, got: $digest" ;;
    esac
    hex="${digest#sha256:}"
    [ -n "$hex" ] || die "empty digest: $digest"
    case "$hex" in
      *[!0-9a-f]*) die "digest is not lower case hex: $digest" ;;
    esac
    [ "${#hex}" -eq 64 ] || die "a sha256 digest is 64 hex characters, got ${#hex}: $digest"
    digest="sha256:${hex}"
    ;;
esac

tag=""
case "${name##*:}" in
  */* | "$name") ;;
  *)
    tag="${name##*:}"
    name="${name%:*}"
    ;;
esac

[[ $name =~ $name_re ]] || die "not a valid image repository: $name"
[ -z "$tag" ] || [[ $tag =~ $tag_re ]] || die "not a valid image tag: $tag"

if [ "$want_digest" = true ] && [ -z "$digest" ]; then
  command -v docker >/dev/null 2>&1 ||
    die "--digest needs docker to resolve a tag; pin an explicit repo@sha256:... reference instead"
  target="$name${tag:+:$tag}"
  digest="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$target")" ||
    die "could not resolve $target to a digest (wrong tag, or registry unreachable?)"
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || die "unexpected digest from docker: $digest"
fi

if [ -n "$digest" ]; then
  # A digest names exact bytes, so the tag (if any) is dropped.
  resolved="${name}@${digest}"
else
  resolved="$name${tag:+:$tag}"
  if [ -z "$tag" ] || [ "$tag" = "latest" ]; then
    [ "$allow_latest" = true ] ||
      die "refusing to pin :latest, which is exactly what pinning should prevent; use a {date} tag, a digest, or --allow-latest"
  fi
fi

line="OBSERVIUM_IMAGE=${resolved}"

env_dir="."
case "$env_file" in
  */*) env_dir="${env_file%/*}" ;;
esac
[ -d "$env_dir" ] || die "no such directory for $env_file: $env_dir"
[ ! -e "$env_file" ] || [ -f "$env_file" ] || die "$env_file is not a regular file"

tmp="$(mktemp "${env_file}.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

if [ -f "$env_file" ]; then
  # Replace the existing OBSERVIUM_IMAGE line where it stands, drop any further
  # copies, and append the line when the file does not have one yet.
  awk -v line="$line" '
    /^[[:space:]]*OBSERVIUM_IMAGE=/ {
      if (!done) { print line; done = 1 }
      next
    }
    { print }
    END { if (!done) print line }
  ' "$env_file" >"$tmp"
  # Write back through the existing file so its permissions are kept.
  cat "$tmp" >"$env_file"
else
  printf '%s\n' "$line" >"$tmp"
  install -m 600 "$tmp" "$env_file"
fi

printf '%s\n' "$line"
printf 'pin-image: wrote %s - run "docker compose up -d" to apply it\n' "$env_file"
