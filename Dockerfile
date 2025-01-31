# syntax=docker/dockerfile:1
FROM php:8.1-apache-bookworm AS cdash-common
LABEL MAINTAINER="Kitware, Inc. <cdash@public.kitware.com>"

# Designates as dev build, adds testing infrastructure, et al.
ARG DEVELOPMENT_BUILD

# make sure it's set in the ENV for reference in docker-entrypoint.sh
# TODO: rename CDASH_DEVELOPMENT_BUILD ?
ENV DEVELOPMENT_BUILD=$DEVELOPMENT_BUILD

RUN apt-get update                                                         \
 && apt-get install -y ca-certificates curl gnupg                          \
 && mkdir -p /etc/apt/keyrings                                             \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key   \
     | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg              \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
     | tee /etc/apt/sources.list.d/nodesource.list                         \
 && apt-get update                                                         \
 && apt-get install -y apt-utils git libbz2-dev libfreetype6-dev           \
    libjpeg62-turbo-dev libldap2-dev libmcrypt-dev libpng-dev libpq-dev    \
    libxslt-dev libxss1 nodejs unzip vim wget zip                          \
 && docker-php-ext-configure pgsql --with-pgsql=/usr/local/pgsql           \
 && docker-php-ext-configure gd --with-freetype=/usr/include/              \
                                --with-jpeg=/usr/include/                  \
 && docker-php-ext-install -j$(nproc) bcmath bz2 gd ldap                   \
    pdo_mysql pdo_pgsql xsl                                                \
 && wget -q -O checksum https://composer.github.io/installer.sha384sum     \
 && wget -q -O composer-setup.php https://getcomposer.org/installer        \
 && sha384sum -c checksum                                                  \
 && php composer-setup.php                                                 \
    --install-dir=/usr/local/bin --filename=composer                       \
 && php -r "unlink('composer-setup.php');"                                 \
 && composer self-update --no-interaction

# Install xdebug and newer version of CMake for development builds
RUN if [ "$DEVELOPMENT_BUILD" = '1' ]; then                                \
  apt-get update                                                           \
  && apt-get install -y cmake rsync                                        \
  `# Cypress dependencies`                                                 \
  && apt-get install -y libgtk2.0-0 libgtk-3-0 libgbm-dev libnotify-dev    \
          libgconf-2-4 libnss3 libxss1 libasound2 libxtst6 xauth xvfb      \
  && mkdir /tmp/.X11-unix                                                  \
  && chmod 1777 /tmp/.X11-unix                                             \
  && chown root /tmp/.X11-unix/                                            \
  && mkdir -p /var/www/.cache/mesa_shader_cache                            \
  && pecl install xdebug                                                   \
  && docker-php-ext-enable xdebug;                                         \
fi

# Create an npm cache directory for www-data
RUN mkdir -p /var/www/.npm                                                 \
  && chown -R www-data:www-data /var/www/.npm

# Create /cdash
RUN mkdir -p /cdash                                                        \
  && chown www-data:www-data /cdash

# Copy Apache site-available config files into the image.
COPY ./docker/cdash-site.conf                                              \
     /etc/apache2/sites-available/cdash-site.conf
COPY ./docker/cdash-site-ssl.conf                                          \
     /etc/apache2/sites-available/cdash-site-ssl.conf

# Change apache config to listen on port 8080 instead of port 80
RUN sed -i 's/Listen 80/Listen 8080/g' /etc/apache2/ports.conf

# Remove default site, add cdash-site, enable mod_rewrite, enable php
RUN a2dissite 000-default                                                  \
 && a2ensite cdash-site                                                    \
 && a2enmod rewrite                                                        \
 && a2enmod php

# Enable https site if we're not doing a development build.
RUN if [ "$DEVELOPMENT_BUILD" != '1' ]; then                               \
  a2enmod ssl                                                              \
  && a2enmod socache_shmcb                                                 \
  && a2ensite cdash-site-ssl;                                              \
fi

# Assign www-data ownership of apache2 configuration files
RUN chown -R www-data:www-data /etc/apache2

# Disable git repo ownership check system wide
RUN git config --system --add safe.directory '*'

RUN if [ "$DEVELOPMENT_BUILD" = '1' ]; then                                \
  echo "alias cdash_copy_source='rsync -r -l --exclude-from /cdash_src/.rsyncignore /cdash_src/ /cdash'" >> /etc/bash.bashrc; \
  echo "alias cdash_install='cdash_copy_source && bash /cdash/install.sh'" >> /etc/bash.bashrc; \
else                                                                       \
  echo "alias cdash_install='bash /cdash/install.sh'" >> /etc/bash.bashrc; \
fi

# Run the rest of the commands as www-data
USER www-data

# Copy CDash (current folder) into /cdash
COPY --chown=www-data:www-data . /cdash

WORKDIR /cdash

COPY ./php.ini /usr/local/etc/php/conf.d/cdash.ini

# Install PHP dependencies with composer
# Set up testing environment if this is a development build
RUN if [ "$DEVELOPMENT_BUILD" = '1' ]; then                                \
 composer install --no-interaction --no-progress --prefer-dist             \
 && mkdir _build && cd _build                                              \
 && cmake                                                                  \
  -DCDASH_DIR_NAME=                                                        \
  -DCDASH_SERVER=localhost:8080                                            \
  -DCTEST_UPDATE_VERSION_ONLY=1 ..                                         \
 && export CYPRESS_CACHE_FOLDER=/cdash/cypress_cache                       \
 && npm install                                                            \
 && cp /cdash/.env.dev /cdash/.env;                                        \
else                                                                       \
 composer install --no-interaction --no-progress --prefer-dist --no-dev    \
                  --optimize-autoloader                                    \
 && npm install --omit=dev;                                                 \
fi

ENTRYPOINT ["/bin/bash", "/cdash/docker/docker-entrypoint.sh"]

###############################################################################

FROM cdash-common AS cdash

CMD ["start-website"]

###############################################################################

FROM cdash-common AS cdash-worker

CMD ["start-worker"]
