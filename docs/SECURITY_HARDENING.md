# Security hardening

This document describes the gaps that are built into the packaging on purpose
(to keep `docker compose up -d` working out of the box) and the concrete steps
that close them. Everything below was checked against `Dockerfile`,
`compose.yaml`, `docker/entrypoint.sh` and `docker/observium.nginx.conf` in this
repository.

If you only do one thing: **do not publish this stack on a public interface
without a TLS-terminating reverse proxy in front of it, and with the default
database passwords replaced.**

## What the image and the Compose file do not do

| Gap | Detail | Where |
| --- | --- | --- |
| No TLS | Nginx listens on plain HTTP port 80 in the container. There is no certificate handling, no HSTS, no redirect from HTTP. `compose.yaml` publishes that port on every host interface. | `docker/observium.nginx.conf`, `compose.yaml` |
| Process runs as root | The `Dockerfile` has no `USER`, so the entrypoint, the Nginx master process, the PHP-FPM master process and cron run as root. Only the workers drop to `www-data`. The entrypoint needs root to write `/etc/php/8.5/fpm/conf.d/99-observium-tuning.ini` and to `chown` `logs/` and `rrd/`. | `Dockerfile`, `docker/entrypoint.sh` |
| Default database passwords | `compose.yaml` sets `MARIADB_PASSWORD: observium`, `MARIADB_ROOT_PASSWORD: observium-root` and `OBSERVIUM_DB_PASSWORD: observium`. These are literals in a public repository, and the MariaDB health check even puts `observium-root` on the command line of `mariadb-admin`. | `compose.yaml` |
| The database port is not published here, but the credentials are still weak | The `db` service has no `ports:` entry, so it is only reachable from the Compose network. Do not add a published port for it; if you need external access, tunnel it. | `compose.yaml` |
| No initial administrator password | With `OBSERVIUM_ADMIN_PASSWORD` empty the entrypoint generates a random one (24 alphanumeric characters) and prints it **once** in the container log. That log line is the only copy: `docker compose logs` and anything that ships those logs (journald, a log collector, `docker inspect` output pasted into a ticket) contains a working administrator password until you change it. | `docker/entrypoint.sh` |
| Credentials are environment variables | `OBSERVIUM_DB_PASSWORD` and `OBSERVIUM_ADMIN_PASSWORD` arrive as environment variables, so they are visible to every process in the container and in `docker inspect`. The entrypoint writes the database password into `/opt/observium/config.php` (plaintext) on every start. | `docker/entrypoint.sh` |
| Administrator level | The account the entrypoint creates is inserted with `level` from `OBSERVIUM_ADMIN_LEVEL` (default `10`, the highest level). It is passed through as-is when numeric; a non-numeric value falls back to `10`. | `docker/entrypoint.sh` |
| No MFA, no session hardening, no built-in audit log | These are application features (or their absence) upstream in Observium, not something this image adds. | upstream code in `/opt/observium` |
| Container is not confined | No `read_only`, no `cap_drop`, no custom seccomp profile, no `no-new-privileges`. The entrypoint needs write access to `/opt/observium`, `/etc/php` and `/tmp`. | `compose.yaml`, `Dockerfile` |

## Before you expose the stack

Use this as a checklist. Each item is expanded below.

1. Put a TLS-terminating reverse proxy in front, and keep the app port off the
   public interface.
2. Replace the database passwords and keep them in a `.env` file with `0600`
   permissions (or in a real secret store).
3. Change the generated administrator password after the first login, and give
   day-to-day accounts a lower level.
4. Back up `./data` before every upgrade.
5. Pin the image to a digest you have scanned.
6. Keep the stack patched: `docker compose pull && docker compose up -d`.

## 1. Put a TLS-terminating reverse proxy in front

The container serves HTTP only. Terminate TLS in front of it and let the proxy
talk plain HTTP to the container over the loopback interface or the Compose
network.

`compose.override.yaml` (keeps the published port on the loopback interface
only, so only a proxy on the same host can reach it; `!override` requires Docker
Compose 2.24 or newer):

```yaml
services:
  observium:
    ports: !override
      - "127.0.0.1:8080:80"
```

On older Compose versions, edit the `ports:` entry of the `observium` service in
`compose.yaml` to `127.0.0.1:8080:80` instead. Alternatively, remove `ports:`
entirely and run the proxy as a container in the same Compose project, so it
reaches the app as `http://observium:80` and no host port is published at all.

Nginx example (host install):

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name observium.example.com;

    ssl_certificate     /etc/letsencrypt/live/observium.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/observium.example.com/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options    "nosniff" always;
    add_header X-Frame-Options           "SAMEORIGIN" always;
    add_header Referrer-Policy           "same-origin" always;

    client_max_body_size 32m;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 300s;
    }
}

server {
    listen 80;
    server_name observium.example.com;
    return 301 https://$host$request_uri;
}
```

Caddy equivalent, if you prefer automatic certificates:

```caddyfile
observium.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

Two things to know about running behind a proxy:

- The container's Nginx only listens on HTTP, so PHP never sees
  `$_SERVER['HTTPS']` set by a TLS handshake. The entrypoint therefore also
  treats a forwarded `X-Forwarded-Proto: https` as HTTPS when it computes
  `$config['base_url']`, which Observium uses for absolute URLs (login
  redirects, graph images). Forward that header, as in the examples above, and
  the pages carry `https://...` URLs instead of `http://...` ones. With a
  proxy that does not send it, the pages link to themselves over plain HTTP and
  browsers block them as mixed content.
- `OBSERVIUM_BASE_URL` sets `$config['web_url']`, which upstream uses for
  links generated outside a web request (CLI, alert e-mails). Set it if those
  links must point at the public URL.
- Access logs inside the container record the proxy's address, and Observium
  sees the same client address for every user. `X-Real-IP` and
  `X-Forwarded-For` are forwarded for anything that reads them, but the app
  does not rewrite its own client IP handling.

Whatever you do, **do not** simply map the container to port 80 or 443 on a
public interface and point clients at it: that publishes the login form and the
session cookie in cleartext.

## 2. Keep the app port unpublished (or loopback-only)

`compose.yaml` publishes `"${OBSERVIUM_HTTP_PORT:-8080}:80"`, which binds
`0.0.0.0` (and `[::]`). Verify what is actually exposed:

```bash
docker compose ps                      # published ports, as configured
ss -ltnp | grep -E ':(8080|80)\b'      # Linux: what the host is listening on
lsof -nP -iTCP:8080 -sTCP:LISTEN       # macOS: same question
```

Two safe options:

- proxy on the same host: bind to loopback, as in the override file above;
- proxy in the same Compose project: delete the `ports:` entry from the
  `observium` service.

## 3. Database passwords from an `.env` file, not from literals

Docker Compose reads a `.env` file from the project directory and substitutes
it into `compose.yaml`. Create it once, with restrictive permissions:

```bash
umask 077
cat > .env <<'EOF'
MARIADB_PASSWORD=REPLACE_WITH_A_LONG_RANDOM_VALUE
MARIADB_ROOT_PASSWORD=REPLACE_WITH_ANOTHER_LONG_RANDOM_VALUE
OBSERVIUM_DB_PASSWORD=REPLACE_WITH_THE_SAME_VALUE_AS_MARIADB_PASSWORD
OBSERVIUM_ADMIN_USER=admin
OBSERVIUM_ADMIN_PASSWORD=REPLACE_WITH_A_LONG_RANDOM_VALUE
EOF
chmod 600 .env
```

Then edit the `db` service so it consumes those values instead of the literals
(the file in this repository ships the weak defaults on purpose, so a fresh
clone still boots):

```yaml
    environment:
      MARIADB_DATABASE: observium
      MARIADB_USER: observium
      MARIADB_PASSWORD: ${MARIADB_PASSWORD:?set MARIADB_PASSWORD in .env}
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD:?set MARIADB_ROOT_PASSWORD in .env}
    healthcheck:
      test: ["CMD", "mariadb-admin", "ping", "-h", "127.0.0.1", "-uroot", "-p${MARIADB_ROOT_PASSWORD:?}"]
```

and make the app follow: `OBSERVIUM_DB_PASSWORD: ${OBSERVIUM_DB_PASSWORD:?set
OBSERVIUM_DB_PASSWORD in .env}`.

Notes:

- `:?` makes Compose fail loudly when the value is missing, instead of quietly
  starting with a blank password.
- `.env` is **not** in this repository's `.gitignore`. Add it (or an
  equivalent `*.env` rule) before you create it, so a `git add .` cannot commit
  the passwords.
- The passwords end up in `/opt/observium/config.php` inside the container
  regardless, and in the container environment. This packaging has no
  `*_FILE` support, so there is no way to pass them without putting them in the
  container's environment.
- Changing `MARIADB_PASSWORD` on an existing data directory does **not** change
  the password of the existing database user; MariaDB only applies it when the
  data directory is initialised. On an existing deployment, change it in SQL
  and in `.env` together, or recreate the database and re-add your devices.
- If you have a secret store, the same values can come from it (for example
  `docker compose run` with an env file generated by your secret tooling); this
  image reads plain environment variables only.

## 4. Administrator credentials

- With `OBSERVIUM_ADMIN_PASSWORD` empty (the default in `compose.yaml`), the
  entrypoint generates a random password when it creates the account and prints
  it once:

  ```
  ===============================================================================
   OBSERVIUM INITIAL ADMINISTRATOR CREDENTIALS

     username: admin
     password: <24 random alphanumeric characters>

   A random password was generated because OBSERVIUM_ADMIN_PASSWORD was empty.
   ...
  ===============================================================================
  ```

  Read it with `docker compose logs observium | grep -A6 'INITIAL ADMINISTRATOR'`
  and change it after the first login (Preferences → Change Password).
- An existing account is never touched on restart, so the banner appears exactly
  once per deployment. Setting `OBSERVIUM_CREATE_ADMIN=false` after the first
  start keeps the entrypoint from creating accounts at all; do that once your
  real accounts exist.
- Keep `OBSERVIUM_ADMIN_USER`/`OBSERVIUM_ADMIN_PASSWORD` out of shell history
  and CI logs; they are only needed for the very first start.
- After the account exists, delete the password from `.env` (or leave it empty)
  so the only credential material is the bcrypt hash in the database.

Restrict the level: `OBSERVIUM_ADMIN_LEVEL` (default `10`, the highest level) is
written to the created user's `level` column and is the only privilege knob the
entrypoint has. Set it as low as your bootstrap work allows and create
day-to-day accounts through Observium's own user administration, with the
levels described in the Observium documentation. Check what exists:

```bash
docker compose exec -T db \
  mariadb -uobservium -pobservium observium \
  -e "SELECT user_id, username, level FROM users ORDER BY user_id;"
```

Images built before the default password was removed created `admin`/`admin`.
An upgrade does not change that account, so change its password if it is still
the default.

## 5. Back up before every upgrade

The database upgrade scripts run automatically at container start
(`OBSERVIUM_INIT_DB_SCHEMA=true` in `compose.yaml`). A backup taken after the
upgrade cannot undo a bad schema migration.

```bash
# Stop the app so nothing writes while the data directories are copied.
docker compose stop observium

# Database dump. The db container has MARIADB_ROOT_PASSWORD in its environment,
# so the password does not end up on your shell's command line history.
docker compose exec -T db sh -c \
  'exec mariadb-dump --all-databases --single-transaction -uroot -p"$MARIADB_ROOT_PASSWORD"' \
  > "observium-db-$(date -u +%Y%m%d-%H%M%S).sql"
chmod 600 observium-db-*.sql

# RRD files and logs are bind mounts; copy them while the app is stopped.
tar -C ./data/rrd  -czf "observium-rrd-$(date -u +%Y%m%d).tar.gz" .
tar -C ./data/logs -czf "observium-logs-$(date -u +%Y%m%d).tar.gz" .

docker compose start observium
```

`./data/db` can be copied too (with the whole stack stopped), but a
`mariadb-dump` is the portable option and is what you restore from:

```bash
docker compose stop observium
docker compose exec -T db sh -c 'exec mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' < observium-db-....sql
docker compose start observium
```

Upgrade:

```bash
docker compose pull
docker compose up -d
docker compose logs -f observium    # watch the schema update finish
```

## 6. Pin the image you have scanned

`:latest` and the upstream version tags (`:26.1.14545`) move on every weekly
rebuild, so a `pull` can change what you run. Pin the immutable dated build tag
or, better, the digest that `.github/workflows/image-scan.yml` reported as
clean:

```yaml
services:
  observium:
    image: tuantuantuantuantuan/observium@sha256:<digest>
```

```bash
# Resolve the digest of a tag you have reviewed
docker buildx imagetools inspect tuantuantuantuantuan/observium:latest --format '{{.Manifest.Digest}}'

# Verify what is running
docker image inspect --format '{{index .RepoDigests 0}}' tuantuantuantuantuan/observium:latest
```

The GitHub release for each build lists the per-platform digests and the
component versions that went into it.

## 7. Verify the deployment

```bash
# Only the port you expect is published, on the interface you expect
docker compose ps
ss -ltnp | grep -E ':(8080|443)\b'      # Linux
lsof -nP -iTCP -sTCP:LISTEN | grep -E ':(8080|443)\b'   # macOS

# The login page answers over HTTPS and redirects from HTTP
curl -sI http://observium.example.com/ | head -1      # 301
curl -sI https://observium.example.com/ | head -1     # 200

# Absolute URLs in the UI use https (requires the proxy to forward
# X-Forwarded-Proto; log in first and check a rendered page)
curl -s -b cookies.txt https://observium.example.com/ | grep -o 'http://[^"< ]*' | head

# The account the entrypoint created, and its level
docker compose exec -T db mariadb -uobservium -pobservium observium \
  -e "SELECT user_id, username, level FROM users ORDER BY user_id;"

# The old public default must not work any more
curl -s -o /dev/null -w '%{http_code}\n' --data 'username=admin&password=admin' \
  https://observium.example.com/          # 200 means rejected, 302 means it logged in

# The generated password has been changed: the banner appears once only
docker compose logs observium | grep -c 'INITIAL ADMINISTRATOR CREDENTIALS'

# Scan the image you actually run
trivy image tuantuantuantuantuan/observium:latest
```

## What still is not covered

Hardening the surrounding host is out of scope for this repository: keep Docker
itself patched, restrict who is in the `docker` group (membership is equivalent
to root), keep `./data` readable only by root and the container, and do not run
this stack next to other untrusted containers without network separation.

Application-level concerns — MFA, password policy, session timeouts, audit
logging — come from upstream Observium. Report gaps there to
<https://www.observium.org/>; report problems in this packaging as described in
[SECURITY.md](../SECURITY.md).
