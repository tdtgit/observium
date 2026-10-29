# Pin a deployment to an exact image

`compose.yaml` deploys `${OBSERVIUM_IMAGE:-tuantuantuantuantuan/observium}` and
`${MARIADB_IMAGE:-mariadb:11}`. With nothing set, those are
`tuantuantuantuantuan/observium:latest` and `mariadb:11`, and the image
references are the one part of the stack that is not pinned: every setting in
the file has a default you can review, the image tags move.

This guide covers how to replace those tags with immutable references, how to
verify what is actually running, and what a pin still does not guarantee.

## Why `latest` is not reproducible

The tags published by `upstream-release.yml` have different lifetimes (see
"Tags and releases" in the [README](../README.md#tags-and-releases)):

| Tag | Lifetime | Good for pinning? |
|---|---|---|
| `:{date}` (e.g. `2026.10.26`) | immutable, one per build | yes, until the tag is deleted |
| `:{version}` (e.g. `26.1.14545`) | moves whenever the image is rebuilt | no |
| `:latest` | rolls to every new publication | no |

Two things move underneath `latest`:

- **New publications.** The release workflow runs weekly and is also triggered
  by `php-refresh.yml` whenever the [sury](https://packages.sury.org/php) PHP
  repository publishes a new patch level for any architecture. A deployment
  that pulls `latest` upgrades itself the next time anyone runs
  `docker compose pull`.
- **Moving tags.** `:{version}` is repointed on every rebuild, so even pinning
  `26.1.14545` does not stay on the bytes you tested. As of this writing
  (2026-10-28) all three tags (`2026.10.26`, `26.1.14545`, `latest`) resolved
  to the same multi-arch digest `sha256:dc88b91c…`; that coincidence ends with
  the next rebuild.

A rebuild does not reproduce the previous bytes even from the same commit: the
base image (`debian:13-slim`) moves, the build runs `apt-get dist-upgrade`
against the live Debian and sury repositories, and the application is downloaded
from `https://www.observium.org/observium-community-latest.tar.gz`, a name that
has no version and no checksum in it.

So there is no "rebuild it later and compare" story. The only thing that
identifies the bytes is the **digest**, and the only way to keep the bytes is to
pin the digest.

## Read the digest

A multi-arch image is published as a manifest **index**: one digest for the
index (the thing you pin), and one digest per platform inside it.

```console
$ docker buildx imagetools inspect tuantuantuantuantuan/observium:2026.10.26
Name:      docker.io/tuantuantuantuantuan/observium:2026.10.26
MediaType: application/vnd.oci.image.index.v1+json
Digest:    sha256:dc88b91cc7b85599334fc3176cfc98a4a82b326a716e544501d3c81f577cb2ed

Manifests:
  Name:        docker.io/tuantuantuantuantuan/observium:2026.10.26@sha256:65faeb3d…a64ff
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    linux/amd64

  Name:        docker.io/tuantuantuantuantuan/observium:2026.10.26@sha256:87760a75…8a4df
  MediaType:   application/vnd.oci.image.manifest.v1+json
  Platform:    unknown/unknown
  Annotations:
    vnd.docker.reference.digest: sha256:65faeb3d…a64ff
    vnd.docker.reference.type:   attestation-manifest

  … linux/arm/v7, linux/arm64, plus one attestation manifest per platform …
```

The values change with every release; read them yourself instead of copying the
abbreviated ones above.

- **`Digest:` at the top** is the index digest. **Pin this one.** Docker picks
  the manifest matching the host architecture, so the same reference works on
  `linux/amd64`, `linux/arm64` and `linux/arm/v7`.
- **`Manifests:` entries** are the per-platform manifests. A per-platform
  digest runs only on that architecture; pin one only if the deployment is
  single-architecture and you want the strongest possible lock.
- **`unknown/unknown`** entries are build attestations (provenance and SBOM
  manifests added by BuildKit). They are covered by the index digest, so
  pinning the index pins them too. Nothing in this repository verifies them
  (see [What pinning does not fix](#what-pinning-does-not-fix)).

Just the index digest, without the table:

```bash
docker buildx imagetools inspect --format '{{.Manifest.Digest}}' \
  tuantuantuantuantuan/observium:2026.10.26
# sha256:dc88b91cc7b85599334fc3176cfc98a4a82b326a716e544501d3c81f577cb2ed
```

This works without pulling the image, and it fails (exit status 1) on a tag
that does not exist, which is why `scripts/pin-image.sh --digest` uses it.

### From an image you already pulled

```bash
docker image inspect --format '{{index .RepoDigests 0}}' \
  tuantuantuantuantuan/observium:2026.10.26
# tuantuantuantuantuan/observium@sha256:dc88b91c…b2ed
```

`RepoDigests` only exists after the image was pulled or built locally, and what
it records depends on the Docker version: with Docker 29.8.2 (the version this
was checked on) it is the index digest, identical to
`docker buildx imagetools inspect`. Older Docker and containerd setups can
record the per-platform manifest digest instead. Compare with
`imagetools inspect` before you pin anything that is deployed on more than one
architecture.

### From the Docker Hub API

No pull and no Docker needed:

```bash
curl -s 'https://hub.docker.com/v2/repositories/tuantuantuantuantuan/observium/tags?page_size=100&ordering=last_updated' |
  python3 -c 'import json,sys; [print(t["name"], t["digest"]) for t in json.load(sys.stdin)["results"]]'
# 2026.10.26 sha256:dc88b91c…b2ed
# 26.1.14545 sha256:dc88b91c…b2ed
# latest     sha256:dc88b91c…b2ed
# 2026.10.22-3 sha256:b698aee3…ea44
# …
```

`scripts/image-php-labels.py` in this repository reads the same registry, and is
the way to see the PHP version stored per architecture (see below).

## Pin the image

### Option A: `.env` (recommended)

`docker compose` reads `.env` from the project directory (next to
`compose.yaml` by default) and substitutes `${OBSERVIUM_IMAGE}` from it, so the
pin lives in one line outside of the tracked compose file.

```bash
# pin a date tag …
scripts/pin-image.sh tuantuantuantuantuan/observium:2026.10.26

# … or resolve the tag to its index digest and pin that instead
scripts/pin-image.sh tuantuantuantuantuan/observium:2026.10.26 --digest
```

The `--digest` form writes:

```console
OBSERVIUM_IMAGE=tuantuantuantuantuan/observium@sha256:dc88b91cc7b85599334fc3176cfc98a4a82b326a716e544501d3c81f577cb2ed
pin-image: wrote .env - run "docker compose up -d" to apply it
```

The script:

- validates the reference (`repo[:tag][@sha256:<64 hex>]`) before writing
  anything;
- refuses `:latest` and a bare repository name, because "pin to whatever is
  newest" is what this is supposed to stop — `--allow-latest` overrides that
  deliberately;
- replaces the existing `OBSERVIUM_IMAGE` (and `MARIADB_IMAGE` when `--db` or
  `--all` is used) line in place, keeps comments and every other line, never
  writes a second copy, and is idempotent;
- creates the file with mode `600` when it does not exist, so credentials you
  keep in the same file are not world readable;
- `--db <reference>` pins the database image instead of, or as well as, the
  application image, and refuses `:latest` and a bare repository name for the
  same reason;
- `--all <observium-reference> <database-reference>` pins both in one run
  (`--all` also accepts the database reference via `--db`), and resolves both
  tags to digests when combined with `--digest`;
- `--file <path>` writes to another file (e.g. `.env.production`);
- `--digest` needs `docker buildx` and fails instead of silently falling back
  to the tag when resolution fails.

`.env` is deployment-local: do not commit it. It is listed in `.gitignore`, so
`git add -A` will not stage your pins or the credentials kept in the same file.

### Option B: a compose override

Copy [`compose.pinned.example.yaml`](../compose.pinned.example.yaml) — it pins
`observium` by digest and changes nothing else (it also carries a commented
`db` pin; uncomment that to pin the database image from the same file):

```bash
cp compose.pinned.example.yaml compose.pinned.yaml
# replace the zeroed placeholder digest with the one you resolved
docker compose -f compose.yaml -f compose.pinned.yaml pull
docker compose -f compose.yaml -f compose.pinned.yaml up -d
```

The placeholder digest is all zeros on purpose: it does not exist, so a pull
fails loudly with `not found` instead of quietly deploying something else.
An override wins over the `.env` value, so remove the pin from one of the two
places rather than keeping both.

Both files pass validation on their own and merged:

```bash
docker compose -f compose.pinned.example.yaml config -q      # exit 0
docker compose -f compose.yaml -f compose.pinned.example.yaml config -q   # exit 0
```

### Verify the pin was picked up

```bash
docker compose config --images
# tuantuantuantuantuan/observium@sha256:dc88b91c…b2ed
# mariadb:11
```

`docker compose config --images` prints what Compose resolved from
`compose.yaml` plus `.env` plus any `-f` overrides. Without a pin the observium
line is just `tuantuantuantuantuan/observium` (no `:latest` appended, no
digest) — that bare name is the reproduction of the bug. Use the same `-f`
flags here that you use for `up`.

## Prove which image is actually running

`config --images` says what Compose would use; these say what is running:

```bash
# reference the container was created from, and the local image ID behind it
docker compose ps -q observium | xargs docker inspect \
  --format '{{.Config.Image}} image_id={{.Image}}'

# PHP version this image was built with, from the image label
docker compose ps -q observium | xargs docker inspect \
  --format '{{index .Config.Labels "org.observium.php.version"}}'

# component versions recorded at build time
docker compose exec -T observium cat /etc/observium-components

# PHP package version recorded at build time
docker compose exec -T observium cat /etc/php-version
```

`org.observium.php.version` is set by the final Dockerfile stage
(`LABEL org.observium.php.version`) and records the `php8.5-cli` package
version for **that architecture**, e.g.

```console
$ python3 scripts/image-php-labels.py tuantuantuantuantuan/observium 2026.10.26 org.observium.php.version
amd64	8.5.12-1+0~20261021.27+debian13~1.gbp1a3e8a
arm	8.5.12-1+0~20261021.27+debian13~1.gbp1a3e8a
arm64	8.5.12-1+0~20261021.27+debian13~1.gbp1a3e8a
```

The image also carries `org.observium.version`, the Observium release the build
was stamped with, and records the same value as a final `observium\t<version>`
line in `/etc/observium-components`:

```bash
docker inspect -f '{{index .Config.Labels "org.observium.version"}}' \
  tuantuantuantuantuan/observium:<date-tag>
# 25.4.0   (the empty string on a local or pull request build)

docker run --rm --entrypoint cat \
  tuantuantuantuantuan/observium:<date-tag> /etc/observium-components
# … one component per line, then: observium	25.4.0
```

`upstream-release.yml` stamps both from the release-gate version. Local and
pull request builds are deliberately unstamped: the label is the empty string
and the components file has no `observium` line, so empty means "not a
release", not "unknown version". Checking the label is how a human confirms a
digest is the release it claims to be without a signature; see
[What pinning does not fix](#what-pinning-does-not-fix) for what that does and
does not prove.

If the digest in `config --images` and the image ID of the running container do
not match what you pinned, the container was not recreated yet:
`docker compose up -d` recreates it once the pinned image is present locally.

## Upgrade and roll back while pinned

A pin turns "upgrade" into an explicit two-step: change the reference, then
recreate. The previous digest is your rollback, so record it before you change
it.

```bash
# 0. what runs today (this is the value you keep for rollback)
docker compose config --images | grep observium
# tuantuantuantuantuan/observium@sha256:dc88b91c…b2ed

# 1. resolve the target
docker buildx imagetools inspect --format '{{.Manifest.Digest}}' \
  tuantuantuantuantuan/observium:2026.10.29

# 2. pin it (or edit compose.pinned.yaml when you pinned that way)
scripts/pin-image.sh tuantuantuantuantuan/observium@sha256:<new digest>

# 3. pull and recreate
docker compose pull
docker compose up -d

# 4. verify: reference, label, component list, and the UI
docker compose config --images | grep observium
docker compose ps
curl -fsS -o /dev/null -w '%{http_code}\n' http://localhost:8080/   # OBSERVIUM_HTTP_PORT default
```

Rollback is the same procedure with the old digest. The previous image is still
in the local image store unless it was pruned, so a rollback does not need a
pull:

```bash
scripts/pin-image.sh tuantuantuantuantuan/observium@sha256:<previous digest>
docker compose up -d
```

For what an upgrade does to the database, the entrypoint's migration behaviour
and the schema checks to run afterwards, see
[`docs/UPGRADE_ROLLBACK.md`](UPGRADE_ROLLBACK.md).

## What pinning does not fix

Pinning fixes exactly one thing: which bytes your host runs. It does not make
this repository's build reproducible, and it is worth being blunt about that.

- **The build is not bit-for-bit reproducible.** Nothing about the pipeline
  produces the same digest twice: `FROM debian:13-slim` is a moving tag,
  `apt-get -y dist-upgrade` runs against live mirrors, the sury repository is
  not a pinned snapshot, and the application is fetched from
  `observium-community-latest.tar.gz` with no version and no checksum. Rebuild
  the same commit tomorrow and you get a different digest with different
  package versions inside. A pin therefore cannot be "verified by rebuilding";
  the digest *is* the record.
- **Base image and apt repositories move.** A rebuild picks up whatever
  `debian:13-slim` and the two repositories contain at that moment. Those are
  code changes you did not review, delivered under a new digest.
- **PHP patch level differs per architecture, by design.** The sury repository
  publishes architectures independently, so a fresh multi-arch build can ship
  `arm64` or `armhf` a patch behind `amd64` under the *same* index digest. The
  daily `php-refresh.yml` rebuild converges them later — as a new digest. If
  version-identical PHP across architectures matters, pin a digest and check
  `org.observium.php.version` per platform with `scripts/image-php-labels.py`
  before rolling it out.
- **The database image drifts unless you pin it too.** `compose.yaml` reads
  `MARIADB_IMAGE` (default `mariadb:11`, a moving tag), so pin it alongside the
  application image:

  ```bash
  # both at once, from two references
  scripts/pin-image.sh --all tuantuantuantuantuan/observium:2026.10.26 mariadb:11.8.9

  # both tags resolved to their index digests
  scripts/pin-image.sh --all tuantuantuantuantuan/observium:2026.10.26 mariadb:11.8.9 --digest

  # database only
  scripts/pin-image.sh --db mariadb:11.8.9
  ```

  `--all` writes one `OBSERVIUM_IMAGE=` and one `MARIADB_IMAGE=` line into the
  same `.env`, and `--db` writes only `MARIADB_IMAGE`, with the same in-place,
  idempotent, mode-`600` behaviour as the application pin. `--db` refuses
  `:latest` and a bare repository name for the same reason. An override file
  that sets `db.image` pins it the same way.
- **Pinning is not provenance verification.** Digests are content addressed, so
  a digest cannot be repointed at different bytes, but nothing here verifies
  *who* built those bytes: there is no signature check and no verification of
  the build attestation manifests in the index. The `org.observium.version`
  label makes the manual check cheap — inspect it and compare it with the
  release you meant to run — but it is stamped by the same pipeline that built
  the image, so it records intent, not proof. Anyone who can push to the
  repository can publish a new digest with any label; comparing the label, the
  release page and the digest is still a human step.
- **A pinned tag can still be deleted.** `:{date}` tags are immutable in the
  sense that they are never repointed, not that they are guaranteed to exist
  forever. The digest stays pullable as long as the registry keeps the blobs.

## See also

- [README: Tags and releases](../README.md#tags-and-releases) — what each tag means.
- [README: Release Automation](../README.md#release-automation) — when a new image is published.
- [`docs/UPGRADE_ROLLBACK.md`](UPGRADE_ROLLBACK.md) — upgrading and rolling back the stack, including the database.
- [`scripts/smoke-compose.sh`](../scripts/smoke-compose.sh) — boot a candidate image (`scripts/smoke-compose.sh tuantuantuantuantuan/observium@sha256:…`) in a throwaway directory before you pin it.
- [`scripts/check-static.sh`](../scripts/check-static.sh) — section 6 self-tests `scripts/pin-image.sh` in a temp directory (create, in-place update, idempotency, refusals, compose override merge) on every static run.
