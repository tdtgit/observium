# syntax=docker/dockerfile:1.7

FROM debian:13-slim AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG OBSERVIUM_DOWNLOAD_URL="https://www.observium.org/observium-community-latest.tar.gz"

ENV OBSERVIUM_HOME=/opt/observium \
    OBSERVIUM_DB_HOST=db \
    OBSERVIUM_DB_NAME=observium \
    OBSERVIUM_DB_USER=observium \
    OBSERVIUM_DB_PASSWORD=observium \
    OBSERVIUM_DB_EXTENSION=mysqli \
    OBSERVIUM_ENABLE_FASTCACHE=true \
    OBSERVIUM_CACHE_DRIVER=apcu \
    OBSERVIUM_PHP_MEMORY_LIMIT=512M \
    OBSERVIUM_APCU_SHM_SIZE=128M \
    OBSERVIUM_ENABLE_RAMDISK=false \
    OBSERVIUM_RAMDISK_PATH=/dev/shm/observium-rrd \
    OBSERVIUM_RAMDISK_SYNC_INTERVAL=300 \
    OBSERVIUM_ENABLE_CRON=true \
    OBSERVIUM_INIT_DB_SCHEMA=false \
    OBSERVIUM_CREATE_ADMIN=false \
    OBSERVIUM_CREATE_DEFAULT_DASHBOARD=true

RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      gnupg \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://packages.sury.org/php/apt.gpg | gpg --dearmor -o /etc/apt/keyrings/sury-php.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/sury-php.gpg] https://packages.sury.org/php/ trixie main" > /etc/apt/sources.list.d/sury-php.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      cron \
      fping \
      graphviz \
      imagemagick \
      ipmitool \
      libvirt-clients \
      mariadb-client \
      mtr-tiny \
      nginx \
      php-pear \
      php8.5-apcu \
      php8.5-bcmath \
      php8.5-cli \
      php8.5-curl \
      php8.5-fpm \
      php8.5-gd \
      php8.5-mbstring \
      php8.5-mysql \
      procps \
      python-is-python3 \
      python3-mysqldb \
      python3-pymysql \
      rrdtool \
      rsync \
      snmp \
      subversion \
      tini \
      tzdata \
      whois \
    && rm -rf /var/lib/apt/lists/*

FROM base AS observium-src

ARG OBSERVIUM_DOWNLOAD_URL="https://www.observium.org/observium-community-latest.tar.gz"

RUN mkdir -p "${OBSERVIUM_HOME}" \
    && curl -fsSL "${OBSERVIUM_DOWNLOAD_URL}" | tar -xz --strip-components=1 -C "${OBSERVIUM_HOME}"

FROM base

COPY --from=observium-src /opt/observium /opt/observium

RUN mkdir -p "${OBSERVIUM_HOME}" \
    && mkdir -p "${OBSERVIUM_HOME}/logs" "${OBSERVIUM_HOME}/rrd" \
    && chown -R www-data:www-data "${OBSERVIUM_HOME}/logs" "${OBSERVIUM_HOME}/rrd" \
    && sed -i 's|^mibs :$|mibs : /opt/observium/mibs/rfc:/opt/observium/mibs/net-snmp|' /etc/snmp/snmp.conf \
    && rm -f /etc/nginx/sites-enabled/default

COPY docker/observium.nginx.conf /etc/nginx/conf.d/observium.conf
COPY docker/observium.cron /etc/cron.d/observium
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && chmod 0644 /etc/cron.d/observium

WORKDIR /opt/observium

VOLUME ["/opt/observium/rrd", "/opt/observium/logs"]

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -fsS http://127.0.0.1/ >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
