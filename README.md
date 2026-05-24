# Observium Docker (Debian 13)

Unofficial Docker image for **Observium Community Edition** built on **Debian 13**.

This project includes:
- `Dockerfile` for Observium + Nginx + PHP 8.5-FPM + poller/discovery cron
- `compose.yaml` for local run with MariaDB
- GitHub Actions workflow for monthly image publishing to Docker Hub

## Build locally

```bash
docker build -t observium:debian13 .
```

## Run locally with Docker Compose

```bash
docker compose up -d --build
```

Then open `http://localhost:8080`.

Default compose credentials:
- Observium admin: `admin` / `admin`
- DB user: `observium` / `observium`

## Runtime environment variables

- `OBSERVIUM_DB_HOST` (default: `db`)
- `OBSERVIUM_DB_NAME` (default: `observium`)
- `OBSERVIUM_DB_USER` (default: `observium`)
- `OBSERVIUM_DB_PASSWORD` (default: `observium`)
- `OBSERVIUM_DB_EXTENSION` (default: `mysqli`)
- `OBSERVIUM_BASE_URL` (optional)
- `OBSERVIUM_ENABLE_CRON` (default: `true`)
- `OBSERVIUM_INIT_DB_SCHEMA` (default: `false`)
- `OBSERVIUM_CREATE_ADMIN` (default: `false`)
- `OBSERVIUM_ADMIN_USER` / `OBSERVIUM_ADMIN_PASSWORD` / `OBSERVIUM_ADMIN_LEVEL`
- `OBSERVIUM_CREATE_DEFAULT_DASHBOARD` (default: `true`)
- `OBSERVIUM_DASHBOARD_USER` (default: value of `OBSERVIUM_ADMIN_USER`)

When `OBSERVIUM_CREATE_DEFAULT_DASHBOARD=true`, startup seeds a classic dashboard layout for the target user if no dashboard widgets exist yet (`map`, `alert_boxes`, `status_summary`, `eventlog`, `alertlog`, `welcome`).

## CI/CD monthly release

Workflow: `.github/workflows/monthly-release.yml`

Triggers:
- Monthly schedule: `0 2 1 * *` (02:00 UTC on day 1)
- Manual dispatch
- Pushes to `main` that modify Docker or workflow files

Published tags:
- `tuantuantuantuantuan/observium:latest`
- `tuantuantuantuantuan/observium:<OBSERVIUM_VERSION_LONG>`

## Notes

- This image tracks `https://www.observium.org/observium-community-latest.tar.gz`.
- CI derives the exact version tag from `observium/includes/definitions/version.inc.php` inside the upstream tarball.
- PHP 8.5 packages are installed from `packages.sury.org` on Debian 13.
- Community Edition upstream releases are not monthly; the monthly workflow helps keep your image current with upstream/community and base image security updates.
- Subscription Edition support (SVN `stable` / `trunk`) can be added later with build-time credentials or external source sync.

GitHub Actions secrets required:
- `DOCKERHUB_USERNAME`
- `DOCKERHUB_TOKEN` (Docker Hub access token)
