# syntax=docker/dockerfile:1.7

# PHP comes from the official image: each patch release is published as one
# index covering amd64, arm64 and arm/v7, so the platforms cannot drift within a
# tag. The tag follows the 8.5 minor line, so the next build picks up the next
# patch; the release workflow records which patch in org.observium.php.version.
FROM php:8.5-fpm-trixie AS php

ARG DEBIAN_FRONTEND=noninteractive

# Extensions the Debian php8.5-* packages provided and the official image does not.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      libfreetype6-dev \
      libjpeg62-turbo-dev \
      libonig-dev \
      libpng-dev \
      libzip-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
      bcmath \
      gd \
      mbstring \
      mysqli \
      pdo_mysql \
      shmop \
      sockets; \
    rm -rf /tmp/pear

# sockets and shmop are reachable from the application and fail loudly without
# them: messagebus_send() calls socket_create() unguarded
# (includes/functions.inc.php), and PEAR's Net_DNS2 cache can use shmop.

# Fixed URL plus a checksum: `pecl install` resolved a truncated tarball once
# (15 KB of 94 KB) and would change silently between builds.
ARG APCU_VERSION=5.1.28
ARG APCU_SHA256=ca9c1820810a168786f8048a4c3f8c9e3fd941407ad1553259fb2e30b5f057bf

RUN set -eux; \
    curl -fsSL --retry 5 --retry-all-errors \
      -o "/tmp/apcu-${APCU_VERSION}.tgz" "https://pecl.php.net/get/apcu-${APCU_VERSION}.tgz"; \
    echo "${APCU_SHA256}  /tmp/apcu-${APCU_VERSION}.tgz" | sha256sum -c -; \
    mkdir -p /tmp/apcu; \
    tar -xzf "/tmp/apcu-${APCU_VERSION}.tgz" -C /tmp/apcu; \
    cd "/tmp/apcu/apcu-${APCU_VERSION}"; \
    phpize; \
    ./configure --enable-apcu; \
    make -j"$(nproc)"; \
    make install; \
    docker-php-ext-enable apcu; \
    rm -rf /tmp/apcu "/tmp/apcu-${APCU_VERSION}.tgz"

# Build-only leftovers: unused at runtime, and the tree is copied below.
RUN set -eux; \
    rm -rf /usr/local/lib/php/build \
           /usr/local/lib/php/test \
           /usr/local/include \
           /usr/local/bin/phpize \
           /usr/local/bin/php-config \
           /usr/local/bin/pear \
           /usr/local/bin/pecl \
           /usr/local/lib/php/PEAR*


FROM debian:13-slim AS base

ARG DEBIAN_FRONTEND=noninteractive
ARG OBSERVIUM_DOWNLOAD_URL="https://www.observium.org/observium-community-latest.tar.gz"

# PHP version resolved by the release workflow from the base image. The build
# fails when the copied PHP disagrees, so the label cannot drift.
ARG PHP_VERSION=""

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
    && apt-get -y dist-upgrade \
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
      procps \
      python-is-python3 \
      python3-mysqldb \
      python3-pymysql \
      rrdtool \
      rsync \
      snmp \
      tini \
      tzdata \
      whois \
      libargon2-1 \
      libcurl4t64 \
      libfreetype6 \
      libjpeg62-turbo \
      libonig5 \
      libpng16-16t64 \
      libreadline8t64 \
      libsodium23 \
      libsqlite3-0 \
      libssl3t64 \
      libxml2 \
      zlib1g \
    && rm -rf /var/lib/apt/lists/*

# PHP from the stage above. The libraries it links against are apt packages, so
# they stay under dpkg control; libcurl4t64 pulls gnutls, krb5, ldap, nghttp2...
COPY --from=php /usr/local /usr/local

# docker/observium.nginx.conf expects /run/php/php8.5-fpm.sock, the path the
# Debian package used; point the official pool there and the nginx file is unchanged.
RUN set -eux; \
    mkdir -p /run/php; \
    sed -ri 's#^;*listen = .*#listen = /run/php/php8.5-fpm.sock#; s#^;listen\.owner = .*#listen.owner = www-data#; s#^;listen\.group = .*#listen.group = www-data#; s#^;listen\.mode = .*#listen.mode = 0660#' \
        /usr/local/etc/php-fpm.d/*.conf; \
    php-fpm -t

# The official image ships no active php.ini; the Debian package installed the
# production one, so do the same.
RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

RUN set -eux; \
    installed="$(php -r 'echo PHP_VERSION;')"; \
    printf '%s\n' "${installed}" > /etc/php-version; \
    printf 'debian\t%s\n' "$(cat /etc/debian_version)" > /etc/observium-components; \
    printf 'php\t%s\n' "${installed}" >> /etc/observium-components; \
    dpkg-query -W -f='${Package}\t${Version}\n' \
         fping \
         graphviz \
         imagemagick \
         ipmitool \
         libvirt-clients \
         mariadb-client \
         mtr-tiny \
         nginx \
         rrdtool \
         snmp \
         whois \
         >> /etc/observium-components; \
    if [ -n "${PHP_VERSION}" ] && [ "${installed}" != "${PHP_VERSION}" ]; then \
      echo "ERROR: the base image ships PHP ${installed} but PHP_VERSION=${PHP_VERSION} was requested" >&2; \
      exit 1; \
    fi; \
    php -m > /dev/null

FROM base AS observium-src

ARG OBSERVIUM_DOWNLOAD_URL="https://www.observium.org/observium-community-latest.tar.gz"

# ~200 MB from a rolling URL, cached per resolved release so rebuilds on this
# builder (any platform) skip the download and a new release still fetches once.
ARG OBSERVIUM_VERSION="latest"

RUN --mount=type=cache,target=/var/cache/observium,sharing=locked \
    set -eux; \
    src="/var/cache/observium/observium-${OBSERVIUM_VERSION}.tar.gz"; \
    if [ -s "${src}" ]; then \
      echo "using cached ${src}"; \
    else \
      echo "downloading ${OBSERVIUM_DOWNLOAD_URL}"; \
      curl -fsSL --retry 5 --retry-all-errors -o "${src}.part" "${OBSERVIUM_DOWNLOAD_URL}"; \
      mv "${src}.part" "${src}"; \
    fi; \
    mkdir -p "${OBSERVIUM_HOME}"; \
    tar -xzf "${src}" --strip-components=1 -C "${OBSERVIUM_HOME}"; \
    ls -lh "${src}"

FROM base

# Re-declared because an ARG does not cross a FROM boundary; the base stage
# already verifies this value against the binary it copied.
ARG PHP_VERSION=""
LABEL org.observium.php.version="${PHP_VERSION}"

# Upstream Observium release contained in this image, resolved by the release
# workflow from the tarball it downloads. Re-declared here because an ARG does
# not cross a FROM boundary, and referenced by the layer below so a new release
# invalidates it instead of being served from the build cache. Local and pull
# request builds pass no value: they are not releases, so the label stays empty
# and /etc/observium-components gains no observium line.
ARG OBSERVIUM_VERSION=""
LABEL org.observium.version="${OBSERVIUM_VERSION}"

COPY --from=observium-src /opt/observium /opt/observium

RUN mkdir -p "${OBSERVIUM_HOME}" \
    && mkdir -p "${OBSERVIUM_HOME}/logs" "${OBSERVIUM_HOME}/rrd" \
    && chown -R www-data:www-data "${OBSERVIUM_HOME}/logs" "${OBSERVIUM_HOME}/rrd" \
    && sed -i 's|^mibs :$|mibs : /opt/observium/mibs/rfc:/opt/observium/mibs/net-snmp|' /etc/snmp/snmp.conf \
    && rm -f /etc/nginx/sites-enabled/default \
    && if [ -n "${OBSERVIUM_VERSION}" ]; then \
         printf 'observium\t%s\n' "${OBSERVIUM_VERSION}" >> /etc/observium-components; \
       fi

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
