# Observium Docker (Debian 13)

[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-tuantuantuantuantuan%2Fobservium-2496ED?logo=docker&logoColor=white)](https://hub.docker.com/r/tuantuantuantuantuan/observium)
[![Base](https://img.shields.io/badge/Base-Debian%2013-A81D33)](#)
[![Web](https://img.shields.io/badge/Web-Nginx%20%2B%20PHP--FPM-009639)](#)
[![DB](https://img.shields.io/badge/DB-MariaDB%2011-003545)](#)

Weekly workflow automation keeps Docker Hub up to date with both `:latest` and stable version tags like `:25.4.0`.

Unofficial Docker image for **Observium Community Edition** with a simple local stack:
- `observium` container: Nginx + PHP 8.5-FPM
- `db` container: MariaDB 11
- persistent data via local bind mounts

## Quick Links

- Docker Hub: [tuantuantuantuantuan/observium](https://hub.docker.com/r/tuantuantuantuantuan/observium)
- Image tag used by default in `compose.yaml`: `tuantuantuantuantuan/observium:latest`
- Stable version tags are also available: `tuantuantuantuantuan/observium:{version}`

## Quick Start

### 1. Start with Docker Compose

```bash
git clone https://github.com/tdtgit/observium.git
cd observium
docker compose up -d
```

Open:
- `http://localhost:8080`

Default login:
- Username: `admin`
- Password: `admin`

### 2. Data Persistence

This project uses bind mounts (host folders):
- `./data/db` -> MariaDB data
- `./data/rrd` -> Observium RRD data
- `./data/logs` -> Observium logs

## Common Operations

### Update to the latest image

```bash
docker compose pull
docker compose up -d
```

### Stop services

```bash
docker compose down
```

### Reset all local data

```bash
docker compose down
rm -rf ./data/db ./data/rrd ./data/logs
mkdir -p ./data/db ./data/rrd ./data/logs
```

## Configuration

Prefer editing env vars in `compose.yaml` (and optional `.env` values consumed by Compose), instead of injecting env vars directly into commands.

Example in `compose.yaml` (`services.observium.environment`):

```yaml
services:
  observium:
    environment:
      OBSERVIUM_ADMIN_USER: ${OBSERVIUM_ADMIN_USER:-netops}
      OBSERVIUM_ADMIN_PASSWORD: ${OBSERVIUM_ADMIN_PASSWORD:-strong-password}
      OBSERVIUM_ENABLE_RAMDISK: ${OBSERVIUM_ENABLE_RAMDISK:-true}
      OBSERVIUM_SHM_SIZE: ${OBSERVIUM_SHM_SIZE:-8g}
      OBSERVIUM_RAMDISK_SYNC_INTERVAL: ${OBSERVIUM_RAMDISK_SYNC_INTERVAL:-300}
```

Apply changes:

```bash
docker compose up -d
```

## Customize Cron and Nginx

If you want to keep using the public image but provide your own scheduler or web config, add a `compose.override.yaml` file.

Example `compose.override.yaml`:

```yaml
services:
  observium:
    volumes:
      - ./custom/observium.cron:/etc/cron.d/observium:ro
      - ./custom/observium.nginx.conf:/etc/nginx/conf.d/observium.conf:ro
```

Then restart:

```bash
docker compose up -d
```

Notes:
- Cron file format should follow `/etc/cron.d` style (include user field, usually `www-data`).
- Keep your nginx config listening on port `80` inside the container.

## Important Environment Variables

### Observium app
| Variable | Default | Notes |
|---|---|---|
| `OBSERVIUM_DB_HOST` | `db` | Database host |
| `OBSERVIUM_DB_NAME` | `observium` | Database name |
| `OBSERVIUM_DB_USER` | `observium` | Database user |
| `OBSERVIUM_DB_PASSWORD` | `observium` | Database password |
| `OBSERVIUM_CREATE_ADMIN` | `true` (compose) | Create initial admin user |
| `OBSERVIUM_ADMIN_USER` | `admin` | Initial admin username |
| `OBSERVIUM_ADMIN_PASSWORD` | `admin` | Initial admin password |
| `OBSERVIUM_ADMIN_LEVEL` | `10` | Admin privilege level |
| `OBSERVIUM_INIT_DB_SCHEMA` | `true` (compose) | Initialize/update DB schema on startup |
| `OBSERVIUM_ENABLE_CRON` | `true` | Enable poller/discovery cron |

### Performance tuning
| Variable | Default | Notes |
|---|---|---|
| `OBSERVIUM_ENABLE_FASTCACHE` | `true` | Enable Observium fast cache |
| `OBSERVIUM_CACHE_DRIVER` | `apcu` | Cache backend |
| `OBSERVIUM_PHP_MEMORY_LIMIT` | `512M` | PHP memory limit |
| `OBSERVIUM_APCU_SHM_SIZE` | `128M` | APCu shared memory size |

### RAM-disk RRD mode (optional)
| Variable | Default | Notes |
|---|---|---|
| `OBSERVIUM_ENABLE_RAMDISK` | `false` | Enable RRD writes to RAM disk |
| `OBSERVIUM_RAMDISK_PATH` | `/dev/shm/observium-rrd` | In-container RAM-disk path |
| `OBSERVIUM_RAMDISK_SYNC_INTERVAL` | `300` | Seconds between RAM -> persistent sync |
| `OBSERVIUM_SHM_SIZE` | `256m` (compose) | Container shared memory size |

### MariaDB binary log toggle (compose)
| Variable | Default | Notes |
|---|---|---|
| `MARIADB_BINLOG_OPTION` | `--skip-log-bin` | Set to `--log-bin` to enable binary log |

## Verify Runtime Status

### Container health

```bash
docker compose ps
```

### Check PHP memory/cache from UI
In Observium web UI footer you should see similar to:
- `FastCache: Yes`
- `OPcache: Yes`
- `Memory: 512MB`

### Verify RAM-disk RRD path

```bash
docker compose exec -T observium grep "rrd_dir" /opt/observium/config.php
```

Expected when enabled:
- `$config['rrd_dir'] = '/dev/shm/observium-rrd';`

### Check the PHP version

Each architecture may be on a different PHP patch release for a short window after an upstream release (the PHP repository publishes architectures independently), so check the version you actually run.

One-shot, without starting the stack:

```bash
docker run --rm --entrypoint php tuantuantuantuantuan/observium:latest -v
```

Exact package version, including the repository build suffix:

```bash
docker run --rm --entrypoint sh tuantuantuantuantuan/observium:latest -c \
  'dpkg-query -W php8.5-cli php8.5-fpm php8.5-apcu'
```

The build also records the resolved version in a file:

```bash
docker run --rm --entrypoint cat tuantuantuantuantuan/observium:latest /etc/php-version
```

Running container:

```bash
docker compose exec observium php -v
docker exec <container> php-fpm8.5 -v
```

To see which architecture your host pulled, and compare both:

```bash
for p in linux/amd64 linux/arm64; do
  printf '%-14s ' "$p"
  docker run --rm --platform "$p" --entrypoint php \
    tuantuantuantuantuan/observium:latest -r 'echo PHP_VERSION, PHP_EOL;'
done
```

### Check installed component versions

The image also records the versions of the main components it ships:

```bash
docker run --rm --entrypoint cat tuantuantuantuantuan/observium:latest /etc/observium-components
```

Running container:

```bash
docker compose exec observium cat /etc/observium-components
```

## Release Automation

Two workflows keep the published image current.

| Workflow | Trigger | Purpose |
|---|---|---|
| `upstream-release.yml` | weekly schedule, or manual dispatch | Resolves the upstream Observium version, builds `linux/amd64` and `linux/arm64`, pushes both by digest, and creates the Docker tags plus the GitHub release |
| `php-refresh.yml` | daily schedule, or manual dispatch | Compares the PHP version published in the image against the versions currently offered by the PHP repository, and triggers a release rebuild when they differ |

### Tags and releases

Releases are identified by **build date**, not by the upstream Observium version, so every publication shows up as new activity even when the Observium version itself has not changed. A second build on the same day gets a numeric suffix (`2026.10.22-2`).

| Docker tag | Meaning |
|---|---|
| `:{date}` | immutable, one per build — use this to pin |
| `:{version}` | current Observium version, moves when the image is rebuilt |
| `:latest` | rolling |

A release is created when the Observium version is new, or when a rebuild is triggered because the PHP version changed. Nothing is published when neither has changed.

### Release token

Creating a release also creates its git tag. GitHub will not let a workflow create a tag that points at a commit changing `.github/workflows/`, because the built-in token cannot carry the `workflows` scope. Add a fine-grained personal access token with **contents: write** and **workflows: write** as the `RELEASE_TOKEN` secret to cover that case:

- with the secret, releases work from any commit;
- without it, releases still work, except for a commit that modifies workflow files (the job fails with an explicit message).



### PHP version per architecture

The image installs PHP from the [sury](https://packages.sury.org/php) repository, which publishes each architecture independently. A newly released PHP patch therefore reaches `amd64` roughly two days before `arm64`, and during that window the multi-arch tag is intentionally not version-identical across architectures: each architecture gets the newest release available for it.

Each build records the version it resolved:

```bash
docker run --rm --entrypoint sh tuantuantuantuantuan/observium:latest -c \
  'dpkg-query -W -f="\${binary:Package} \${Version}\n" "php8.5-*"'
```

The same value is stored in the image label `org.observium.php.version`, which is what `php-refresh.yml` compares against the repository. Once the slower architecture catches up, the daily check detects the difference and rebuilds, so the tags converge automatically.

### Release note contents

Each GitHub release is generated from the published image, and always contains:

- the image tags, the multi-arch manifest digest, and each platform's image digest and compressed size,
- a table of installed component versions per architecture — Debian, Nginx, PHP, MariaDB client, RRDtool, Net-SNMP, and the bundled diagnostic utilities,
- the commands to inspect the installed versions in a deployment.

The component versions are read back from the published image itself
(`/etc/observium-components`, with `/etc/php-version` still verified for PHP),
so the note always describes the bytes that users pull.

### Overriding the release note

When a release is not the usual automated one — for example an image rebuilt
because the PHP repository published a new patch release for one architecture
only — the prose part of the note can be overridden. A reason is mandatory and
is rendered in the release, so the deviation is always explained. See
[`release-notes/README.md`](release-notes/README.md).

```bash
gh workflow run upstream-release.yml --ref main \
  -f release_notes="This image was rebuilt to pick up the arm64 PHP build." \
  -f release_notes_reason="Republished to pick up the arm64 build of PHP 8.5.12."
```

## Build Locally (optional)

The provided compose file is for using the published image.

Build local image:

```bash
docker build -t observium:debian13 .
```

Run compose with local image:

```bash
OBSERVIUM_IMAGE=observium:debian13 docker compose up -d
```
