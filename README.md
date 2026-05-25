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
