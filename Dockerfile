ARG PHP_VERSION
ARG PHP_IMAGE_VERSION
ARG IMAGE_REPO
FROM ${IMAGE_REPO:-amazeeio}/commons:v1.1.4 as commons
FROM php:${PHP_IMAGE_VERSION}-fpm-alpine

LABEL maintainer="amazee.io"
ENV LAGOON=php

# Copy commons files
COPY --from=commons /lagoon /lagoon
COPY --from=commons /bin/fix-permissions /bin/ep /bin/docker-sleep /bin/
COPY --from=commons /sbin/tini /sbin/
COPY --from=commons /home /home

RUN chmod g+w /etc/passwd \
    && mkdir -p /home

ENV TMPDIR=/tmp \
    TMP=/tmp \
    HOME=/home \
    # When Bash is invoked via `sh` it behaves like the old Bourne Shell and sources a file that is given in `ENV`
    ENV=/home/.bashrc \
    # When Bash is invoked as non-interactive (like `bash -c command`) it sources a file that is given in `BASH_ENV`
    BASH_ENV=/home/.bashrc \
    DRUSH_LAUNCHER_VERSION=0.6.0

COPY check_fcgi /usr/sbin/
COPY entrypoints/70-php-config.sh entrypoints/50-ssmtp.sh entrypoints/71-php-newrelic.sh /lagoon/entrypoints/

COPY php.ini /usr/local/etc/php/
COPY 00-lagoon-php.ini.tpl /usr/local/etc/php/conf.d/
COPY php-fpm.d/www.conf /usr/local/etc/php-fpm.d/www.conf
COPY ssmtp.conf /etc/ssmtp/ssmtp.conf

# Defining Versions - https://docs.newrelic.com/docs/release-notes/agent-release-notes/php-release-notes/ / https://docs.newrelic.com/docs/agents/php-agent/getting-started/php-agent-compatibility-requirements
ENV NEWRELIC_VERSION=9.3.0.248

RUN apk add --no-cache fcgi \
        ssmtp \
        libzip libzip-dev \
        # for gd
        libpng-dev \
        libjpeg-turbo-dev \
        # for gettext
        gettext-dev \
        # for mcrypt
        libmcrypt-dev \
        # for soap
        libxml2-dev \
        # for xsl
        libxslt-dev \
        libgcrypt-dev \
        # for webp
        libwebp-dev \
    && apk add --no-cache --virtual .phpize-deps $PHPIZE_DEPS \
    && if [ ${PHP_VERSION%.*} == "7.3" ]; then \
        yes '' | pecl install -f apcu; \
       elif [ ${PHP_VERSION%.*.*} == "7" ]; then \
        yes '' | pecl install -f apcu; \
       fi \
    && if [ ${PHP_VERSION%.*.*} == "5" ]; then \
        yes '' | pecl install -f apcu-4.0.11; \
       fi \
    && docker-php-ext-enable apcu \
    && docker-php-ext-configure gd --with-webp-dir=/usr/include/ --with-jpeg-dir=/usr/include/ \
    && docker-php-ext-install -j4 bcmath gd gettext pdo_mysql mysqli shmop soap sockets opcache xsl zip \
    && if [ ${PHP_VERSION%.*} == "7.1" ] || [ ${PHP_VERSION%.*} == "7.0" ] || [ ${PHP_VERSION%.*.*} == "5" ]; then \
        docker-php-ext-install mcrypt; \
       fi \
    && rm -rf /var/cache/apk/* /tmp/pear/ \
    && apk del .phpize-deps \
    && if [ ${PHP_VERSION%.*} != "7.4" ]; then \
    mkdir -p /tmp/newrelic && cd /tmp/newrelic \
    && wget https://download.newrelic.com/php_agent/archive/${NEWRELIC_VERSION}/newrelic-php5-${NEWRELIC_VERSION}-linux-musl.tar.gz \
    && gzip -dc newrelic-php5-${NEWRELIC_VERSION}-linux-musl.tar.gz | tar --strip-components=1 -xf - \
    && NR_INSTALL_USE_CP_NOT_LN=1 NR_INSTALL_SILENT=1 ./newrelic-install install \
    && sed -i -e "s/newrelic.appname = .*/newrelic.appname = \"\${LAGOON_PROJECT:-noproject}-\${LAGOON_GIT_SAFE_BRANCH:-nobranch}\"/" /usr/local/etc/php/conf.d/newrelic.ini \
    && sed -i -e "s/;newrelic.enabled = .*/newrelic.enabled = \${NEWRELIC_ENABLED:-false}/" /usr/local/etc/php/conf.d/newrelic.ini \
    && sed -i -e "s/newrelic.license = .*/newrelic.license = \"\${NEWRELIC_LICENSE:-}\"/" /usr/local/etc/php/conf.d/newrelic.ini \
    && sed -i -e "s/;newrelic.loglevel = .*/newrelic.loglevel = \"\${NEWRELIC_LOG_LEVEL:-warning}\"/" /usr/local/etc/php/conf.d/newrelic.ini \
    && sed -i -e "s/;newrelic.daemon.loglevel = .*/newrelic.daemon.loglevel = \"\${NEWRELIC_DAEMON_LOG_LEVEL:-warning}\"/" /usr/local/etc/php/conf.d/newrelic.ini \
    && sed -i -e "s/newrelic.logfile = .*/newrelic.logfile = \"\/dev\/stdout\"/" /usr/local/etc/php/conf.d/newrelic.ini \
    && sed -i -e "s/newrelic.daemon.logfile = .*/newrelic.daemon.logfile = \"\/dev\/stdout\"/" /usr/local/etc/php/conf.d/newrelic.ini \
    && mv /usr/local/etc/php/conf.d/newrelic.ini /usr/local/etc/php/conf.d/newrelic.disable \
    && cd / && rm -rf /tmp/newrelic; \
    fi \
    && mkdir -p /app \
    && fix-permissions /usr/local/etc/ \
    && fix-permissions /app \
    && fix-permissions /etc/ssmtp/ssmtp.conf \
    # Backwards-compatibility for projects using an older location.
    && mkdir -p /var/www/html && ln -s /var/www/html /app \
    && set -ex \
    # Install mysql client
    && apk add mysql-client \
    # Install GNU version of utilities
    && apk add findutils coreutils \
    # Install Drush launcher
    && curl -OL https://github.com/drush-ops/drush-launcher/releases/download/${DRUSH_LAUNCHER_VERSION}/drush.phar \
    && chmod +x drush.phar \
    && mv drush.phar /usr/local/bin/drush \
    # Create directory for shared files
    && mkdir -p -m +w /app/web/sites/default/files \
    && mkdir -p -m +w /app/private \
    && mkdir -p -m +w /app/reference-data \
    && chown -R www-data:www-data /app;

# Add composer executables to our path.
ENV PATH="/app/vendor/bin:/home/.composer/vendor/bin:${PATH}"

EXPOSE 9000

ENV LAGOON_ENVIRONMENT_TYPE=development

WORKDIR /app

ENTRYPOINT ["/sbin/tini", "--", "/lagoon/entrypoints.sh"]
CMD ["/usr/local/sbin/php-fpm", "-F", "-R"]
