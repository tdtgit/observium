# Observium Docker (Debian 13)

Unofficial Docker image for **Observium Community Edition** using:
- Debian 13
- Nginx
- PHP 8.5-FPM
- MariaDB (in `compose.yaml`)

Docker Hub image:
- `tuantuantuantuantuan/observium:latest`

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

You can override settings with environment variables when starting Compose.

Example (custom admin credentials):

```bash
OBSERVIUM_ADMIN_USER=netops \
OBSERVIUM_ADMIN_PASSWORD='strong-password' \
docker compose up -d
```

Example (enable RAM-disk RRD mode):

```bash
OBSERVIUM_ENABLE_RAMDISK=true \
OBSERVIUM_SHM_SIZE=8g \
OBSERVIUM_RAMDISK_SYNC_INTERVAL=300 \
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

## CI/CD

- Monthly image build workflow: `.github/workflows/monthly-release.yml`
- Primary public tag used for manual build/push in this repo: `latest`
- Versioned tags are handled by CI workflow
