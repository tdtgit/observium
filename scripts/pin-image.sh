#!/usr/bin/env bash
# Pin the deployment to exact image references.
#
# Usage: scripts/pin-image.sh <tag-or-digest-reference> [options]
#        scripts/pin-image.sh <observium-reference> <database-reference> --all
#        scripts/pin-image.sh --db <tag-or-digest-reference> [options]
#
# Options:
#   --file <path>     env file to update (default: .env)
#   --db <reference>  pin MARIADB_IMAGE too, or on its own
#   --all             pin both images: OBSERVIUM_IMAGE and MARIADB_IMAGE
#   --digest          resolve the tag to its manifest digest and pin that
#   --allow-latest    permit a :latest pin, which is otherwise refused
#
# Writes a single OBSERVIUM_IMAGE=<reference> and/or MARIADB_IMAGE=<reference>
# line into the env file that `docker compose` reads, so compose.yaml's
# `image:` picks it up. Other lines and comments in the file are preserved, and
# running the same command twice leaves the file unchanged.
#
# See docs/PINNING.md for why pinning matters and how to find a digest.
set -euo pipefail

usage() {
  cat <<'EOF'
usage: pin-image.sh <tag-or-digest-reference> [--file <path>] [--digest] [--allow-latest]
       pin-image.sh <observium-reference> <database-reference> --all [--digest]
       pin-image.sh --db <tag-or-digest-reference> [--file <path>] [--digest]

  <tag-or-digest-reference>  e.g. tuantuantuantuantuan/observium:2026.10.26
                                  mariadb:11.8.9
                                  mariadb@sha256:<64 hex>
  --file <path>              env file to write (default: .env)
  --db <reference>           pin MARIADB_IMAGE as well (or without an
                             observium reference)
  --all                      pin both images; needs an observium reference and
                             a database reference (second argument or --db)
  --digest                   resolve tags and pin repo@sha256:<digest> instead
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
pin_all=false
db_reference=""
positional=()

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
    --db)
      [ "$#" -ge 2 ] || die "--db needs a reference"
      [ -z "$db_reference" ] || die "database reference given twice"
      db_reference="$2"
      shift 2
      ;;
    --db=*)
      [ -z "$db_reference" ] || die "database reference given twice"
      db_reference="${1#*=}"
      shift
      ;;
    --all)
      pin_all=true
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
      positional+=("$1")
      shift
      ;;
  esac
done

app_reference=""
if [ "$pin_all" = true ]; then
  if [ "${#positional[@]}" -eq 1 ]; then
    app_reference="${positional[0]}"
    [ -n "$db_reference" ] ||
      die "--all needs a database reference as the second argument, or via --db"
  elif [ "${#positional[@]}" -eq 2 ]; then
    app_reference="${positional[0]}"
    [ -z "$db_reference" ] ||
      die "database reference given twice (second argument and --db)"
    db_reference="${positional[1]}"
  else
    die "--all takes exactly two references: <observium-reference> <database-reference>"
  fi
else
  [ "${#positional[@]}" -le 1 ] || die "only one image reference may be given"
  if [ "${#positional[@]}" -eq 1 ]; then
    app_reference="${positional[0]}"
  fi
fi

[ -n "$app_reference" ] || [ -n "$db_reference" ] || {
  usage >&2
  exit 2
}

# Validate one repo[:tag][@sha256:...] reference and print the reference to
# write: the digest form when one was given or resolved, the tag form
# otherwise. Dies on anything that is not an immutable-enough pin.
resolve_reference() {
  local reference name digest tag hex target resolved
  reference="$1"
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
  printf '%s\n' "$resolved"
}

app_resolved=""
db_resolved=""
if [ -n "$app_reference" ]; then
  app_resolved="$(resolve_reference "$app_reference")"
fi
if [ -n "$db_reference" ]; then
  db_resolved="$(resolve_reference "$db_reference")"
fi

env_dir="."
case "$env_file" in
  */*) env_dir="${env_file%/*}" ;;
esac
[ -d "$env_dir" ] || die "no such directory for $env_file: $env_dir"
[ ! -e "$env_file" ] || [ -f "$env_file" ] || die "$env_file is not a regular file"

# Collect the lines to write, observium first so a fresh file reads the same
# way compose.yaml orders the two services.
lines="$(mktemp "${TMPDIR:-/tmp}/pin-image-lines.XXXXXX")"
tmp="$(mktemp "${env_file}.XXXXXX")"
trap 'rm -f "$tmp" "$lines"' EXIT

if [ -n "$app_resolved" ]; then
  printf 'OBSERVIUM_IMAGE=%s\n' "$app_resolved" >>"$lines"
fi
if [ -n "$db_resolved" ]; then
  printf 'MARIADB_IMAGE=%s\n' "$db_resolved" >>"$lines"
fi

if [ -f "$env_file" ]; then
  # Replace each existing pin line where it stands, drop any further copies,
  # and append the lines the file does not have yet.
  awk -v lines_file="$lines" '
    BEGIN {
      while ((getline ln < lines_file) > 0) {
        if (ln == "") continue
        key = ln
        sub(/=.*/, "", key)
        n++
        order[n] = key
        wanted[key] = ln
      }
      close(lines_file)
    }
    {
      for (i = 1; i <= n; i++) {
        key = order[i]
        if ($0 ~ ("^[[:space:]]*" key "=")) {
          if (!done[key]) { print wanted[key]; done[key] = 1 }
          next
        }
      }
      print
    }
    END {
      for (i = 1; i <= n; i++) {
        key = order[i]
        if (!done[key]) print wanted[key]
      }
    }
  ' "$env_file" >"$tmp"
  # Write back through the existing file so its permissions are kept.
  cat "$tmp" >"$env_file"
else
  cat "$lines" >"$tmp"
  install -m 600 "$tmp" "$env_file"
fi

cat "$lines"
printf 'pin-image: wrote %s - run "docker compose up -d" to apply it\n' "$env_file"
