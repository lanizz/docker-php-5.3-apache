FROM debian:jessie-slim


ENV PHP_VERSION=5.3.29
ENV PHP_INI_DIR=/usr/local/etc/php

# PHP 5.3 does not work with OpenSSL version from Debian Stretch (need to pick it from Jessie)
# https://github.com/devilbox/docker-php-fpm-5.3/issues/7
#
# https://manpages.debian.org/jessie/openssl/openssl.1ssl.en.html
# https://www.openssl.org/source/old/1.0.1/
ENV OPENSSL_VERSION=1.0.1t

ENV PHP_BUILD_DEPS \
	autoconf2.13 \
	lemon \
	libbison-dev \
	libcurl4-openssl-dev \
	libfl-dev \
	libmhash-dev \
	libmysqlclient-dev \
	libpcre3-dev \
	libreadline6-dev \
	librecode-dev \
	libsqlite3-dev \
# libssl-dev/oldoldstable 1.0.1t-1
	libssl-dev \
	libxml2-dev

ENV PHP_RUNTIME_DEPS \
	libmhash2 \
	libmysqlclient18 \
	libpcre3 \
	librecode0 \
	libsqlite3-0 \
# libssl1.0.0/oldoldstable,now 1.0.1t-1
	libssl1.0.0 \
	libxml2 \
	xz-utils

ENV BUILD_TOOLS \
	autoconf \
	bison \
	bisonc++ \
	ca-certificates \
	curl \
	dpkg-dev \
	file \
	flex \
	g++ \
	gcc \
	libc-dev \
	make \
	patch \
	pkg-config \
	re2c \
	xz-utils

ENV BUILD_TOOLS_32 \
	g++-multilib \
	gcc-multilib

ENV RUNTIME_TOOLS \
	ca-certificates \
	curl


###
### Build OpenSSL
###
RUN set -eux \
# Install Dependencies
	&& apt-get update \
	&& apt-get install -y --no-install-recommends --no-install-suggests \
		${BUILD_TOOLS} \
	&& if [ "$(dpkg-architecture --query DEB_HOST_ARCH)" = "i386" ]; then \
		apt-get install -y --no-install-recommends --no-install-suggests \
			${BUILD_TOOLS_32}; \
	fi \
# Fetch OpenSSL
	&& cd /tmp \
	&& mkdir openssl \
	&& update-ca-certificates \
	&& curl -sS -k -L --fail "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" -o openssl.tar.gz \
	&& curl -sS -k -L --fail "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz.asc" -o openssl.tar.gz.asc \
	&& tar -xzf openssl.tar.gz -C openssl --strip-components=1 \
	&& cd /tmp/openssl \
# Build OpenSSL
	&& if [ "$(dpkg-architecture  --query DEB_HOST_ARCH)" = "i386" ]; then \
		setarch i386 ./config -m32; \
	else \
		./config -fPIC; \
	fi \
	&& make depend \
	&& make -j"$(nproc)" \
	&& make install \
# Cleanup
	&& rm -rf /tmp/* \
# Ensure libs are linked to correct architecture directory
	&& debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)" \
	&& mkdir -p "/usr/local/ssl/lib/${debMultiarch}" \
	&& ln -s /usr/local/ssl/lib/* "/usr/local/ssl/lib/${debMultiarch}/" \
# Remove Dependencies
	&& if [ "$(dpkg-architecture --query DEB_HOST_ARCH)" = "i386" ]; then \
		apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false -o APT::AutoRemove::SuggestsImportant=false \
			${BUILD_TOOLS_32}; \
	fi \
	&& apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false -o APT::AutoRemove::SuggestsImportant=false \
		${BUILD_TOOLS} \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*


RUN apt-get update && apt-get install -y apache2-bin apache2-dev apache2.2-common --no-install-recommends && rm -rf /var/lib/apt/lists/*

RUN rm -rf /var/www/html && mkdir -p /var/lock/apache2 /var/run/apache2 /var/log/apache2 /var/www/html && chown -R www-data:www-data /var/lock/apache2 /var/run/apache2 /var/log/apache2 /var/www/html

# Apache + PHP requires preforking Apache for best results
RUN a2dismod mpm_event && a2enmod mpm_prefork

RUN mv /etc/apache2/apache2.conf /etc/apache2/apache2.conf.dist
COPY apache2.conf /etc/apache2/apache2.conf

COPY apache2-foreground /usr/local/bin/

###
### Setup PHP directories
###
RUN set -eux \
	&& mkdir -p ${PHP_INI_DIR}/conf.d \
	&& mkdir -p /usr/src/php


###
### Copy PHP scripts
###
COPY data/docker-php-source /usr/local/bin/
COPY data/php/php-${PHP_VERSION}.tar.xz /usr/src/php.tar.xz


###
### Build PHP
###
RUN set -eux \
# Install Dependencies
	&& apt-get update \
	&& apt-get install -y --no-install-recommends --no-install-suggests \
		${PHP_BUILD_DEPS} \
		${BUILD_TOOLS} \
	&& if [ "$(dpkg-architecture --query DEB_HOST_ARCH)" = "i386" ]; then \
		apt-get install -y --no-install-recommends --no-install-suggests \
			${BUILD_TOOLS_32}; \
	fi \
# Setup Requirements
	&& docker-php-source extract \
	&& cd /usr/src/php  \
	\
	&& gnuArch="$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)" \
	&& debMultiarch="$(dpkg-architecture --query DEB_BUILD_MULTIARCH)" \
	\
	# https://bugs.php.net/bug.php?id=74125
	&& if [ ! -d /usr/include/curl ]; then \
		ln -sT "/usr/include/${debMultiarch}/curl" /usr/local/include/curl; \
	fi \
# Build PHP
	&& ./configure \
		--host="${gnuArch}" \
		--with-libdir="/lib/${debMultiarch}/" \
		--with-config-file-path="${PHP_INI_DIR}" \
		--with-config-file-scan-dir="${PHP_INI_DIR}/conf.d" \
		--disable-cgi \
		$(command -v apxs2 > /dev/null 2>&1 && echo '--with-apxs2=/usr/bin/apxs2' || true) \
# --enable-ftp is included here because ftp_ssl_connect() needs ftp to be compiled statically (see https://github.com/docker-library/php/issues/236)
		--enable-ftp \
		--with-openssl=/usr/local/ssl \
		\
# --enable-mbstring is included here because otherwise there's no way to get pecl to use it properly (see https://github.com/docker-library/php/issues/195)
		--enable-mbstring \
		\
# --enable-mysqlnd is included here because it's harder to compile after the fact than extensions are (since it's a plugin for several extensions, not an extension in itself)
		--enable-mysqlnd \
		\
		# --enable-fpm \
		--with-fpm-user=www-data \
		--with-fpm-group=www-data \
# https://github.com/docker-library/php/issues/439
		--with-mhash \
		\
# always build against system sqlite3 (https://github.com/php/php-src/commit/6083a387a81dbbd66d6316a3a12a63f06d5f7109)
		--with-pdo-sqlite=/usr \
		--with-sqlite3=/usr \
		\
		--with-curl \
		--with-openssl=/usr/local/ssl \
		--with-readline \
		--with-recode \
		--with-zlib \
	&& make -j"$(nproc)" \
	&& make install \
# Cleanup
	&& make clean \
	&& { find /usr/local/bin /usr/local/sbin -type f -executable -exec strip --strip-all '{}' + || true; } \
	&& docker-php-source delete \
# Remove Dependencies
	&& if [ "$(dpkg-architecture --query DEB_HOST_ARCH)" = "i386" ]; then \
		apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false -o APT::AutoRemove::SuggestsImportant=false \
			${BUILD_TOOLS_32}; \
	fi \
	&& apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false -o APT::AutoRemove::SuggestsImportant=false \
		${PHP_BUILD_DEPS} \
		${BUILD_TOOLS} \
# Install Run-time requirements
	&& apt-get update \
	&& apt-get install -y --no-install-recommends --no-install-suggests \
		${PHP_RUNTIME_DEPS} \
		${RUNTIME_TOOLS} \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/* \
# Setup extension dir
	&& mkdir -p "$(php -r 'echo ini_get("extension_dir");')"

# Fix config.guess for PHP modules (adds 'aarch64' [arm64] architecture)
# The config.guess has been copied from PHP 5.5
COPY data/php/usr-local-lib-php-build-config.guess /usr/local/lib/php/build/config.guess
COPY data/php/usr-local-lib-php-build-config.sub /usr/local/lib/php/build/config.sub

COPY data/docker-php-* /usr/local/bin/

COPY data/php-fpm.conf /usr/local/etc/
COPY data/php.ini /usr/local/etc/php/php.ini


RUN set -eux \
	&& DEBIAN_FRONTEND=noninteractive apt-get update \
	&& DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-install-suggests \
		alien \
		firebird-dev \
		freetds-dev \
		libaio-dev \
		libbz2-dev \
		libc-ares-dev \
		libc-client-dev \
		libcurl4-openssl-dev \
		libenchant-dev \
		libevent-dev \
		libfbclient2 \
		libfreetype6-dev \
		libgmp-dev \
		libib-util \
		libicu-dev \
		libjpeg-dev \
		libkrb5-dev \
		libldap2-dev \
		libmcrypt-dev \
		libmemcached-dev \
		libmysqlclient-dev \
		libnghttp2-dev \
		libpcre3-dev \
		libpng-dev \
		libpq-dev \
		libpspell-dev \
		librabbitmq-dev \
		librdkafka-dev \
		libsasl2-dev \
		libsnmp-dev \
		libssl-dev \
		libtidy-dev \
		libvpx-dev \
		libwebp-dev \
		libxml2-dev \
		libxpm-dev \
		libxslt-dev \
		libyaml-dev \
		snmp \
		uuid-dev \
		zlib1g-dev \
# Build tools
		autoconf \
		bison \
		bisonc++ \
		ca-certificates \
		curl \
		dpkg-dev \
		file \
		flex \
		g++ \
		gcc \
		git \
		lemon \
		libc-client-dev \
		libc-dev \
		libcurl4-openssl-dev \
		libssl-dev \
		make \
		patch \
		pkg-config \
		re2c \
		xz-utils \
	&& rm -rf /var/lib/apt/lists/*


# Fix timezone (only required for testing to stop php -v and php-fpm -v from complaining to stderr)
RUN set -eux \
	&& echo "date.timezone=Asia/Shanghai" > /usr/local/etc/php/php.ini


###
### Install and enable PHP modules
###
# Enable ffi if it exists
RUN set -eux \
	&& if [ -f /usr/local/etc/php/conf.d/docker-php-ext-ffi.ini ]; then \
			echo "ffi.enable = 1" >> /usr/local/etc/php/conf.d/docker-php-ext-ffi.ini; \
		fi

# -------------------- Installing PHP Extension: amqp --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install amqp-1.9.3 \
	# Enabling
	&& docker-php-ext-enable amqp \
	&& true


# -------------------- Installing PHP Extension: apcu --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install apcu-4.0.11 \
	# Enabling
	&& docker-php-ext-enable apcu \
	&& true


# -------------------- Installing PHP Extension: bcmath --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) bcmath \
	&& true


# -------------------- Installing PHP Extension: bz2 --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) bz2 \
	&& true


# -------------------- Installing PHP Extension: calendar --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) calendar \
	&& true


# -------------------- Installing PHP Extension: dba --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) dba \
	&& true


# -------------------- Installing PHP Extension: enchant --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) enchant \
	&& true


# -------------------- Installing PHP Extension: exif --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) exif \
	&& true


# -------------------- Installing PHP Extension: gd --------------------
RUN set -eux \
	# Version specific pre-command
	&& ln -s /usr/lib/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/libjpeg.* /usr/lib/ && \
ln -s /usr/lib/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/libpng.* /usr/lib/ && \
ln -s /usr/lib/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/libXpm.* /usr/lib/ && \
mkdir /usr/include/freetype2/freetype && \
ln -s /usr/include/freetype2/freetype.h /usr/include/freetype2/freetype/freetype.h \
 \
	# Installation: Version specific
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure gd --with-gd --with-jpeg-dir=/usr --with-png-dir=/usr --with-zlib-dir=/usr --with-xpm-dir=/usr --with-freetype-dir=/usr --enable-gd-native-ttf \
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) gd \
	&& true


# -------------------- Installing PHP Extension: gettext --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) gettext \
	&& true


# -------------------- Installing PHP Extension: gmp --------------------
RUN set -eux \
	# Generic pre-command
	&& ln /usr/include/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/gmp.h /usr/include/ \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) gmp \
	&& true


# -------------------- Installing PHP Extension: igbinary --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install igbinary-2.0.8 \
	# Enabling
	&& docker-php-ext-enable igbinary \
	&& true


# -------------------- Installing PHP Extension: imap --------------------
RUN set -eux \
	# Generic pre-command
	&& ln -s /usr/lib/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/libkrb5* /usr/lib/ \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure imap --with-kerberos --with-imap-ssl --with-imap \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) imap \
	&& true


# -------------------- Installing PHP Extension: interbase --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) interbase \
	&& true


# -------------------- Installing PHP Extension: intl --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         Built-in extension
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) intl \
	&& true


# -------------------- Installing PHP Extension: ldap --------------------
RUN set -eux \
	# Generic pre-command
	&& ln -s /usr/lib/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/libldap* /usr/lib/ \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure ldap --with-ldap --with-ldap-sasl \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) ldap \
	&& true


# -------------------- Installing PHP Extension: mcrypt --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         Built-in extension
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) mcrypt \
	&& true


# -------------------- Installing PHP Extension: msgpack --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install msgpack-0.5.7 \
	# Enabling
	&& docker-php-ext-enable msgpack \
	&& true


# -------------------- Installing PHP Extension: memcache --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install memcache-2.2.7 \
	# Enabling
	&& docker-php-ext-enable memcache \
	&& true


# -------------------- Installing PHP Extension: memcached --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install memcached-2.2.0 \
	# Enabling
	&& docker-php-ext-enable memcached \
	&& true


# -------------------- Installing PHP Extension: mongo --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         PECL extension
	# Custom:       Pecl command
	&& yes yes | pecl install mongo \
	# Enabling
	&& docker-php-ext-enable mongo \
	&& true


# -------------------- Installing PHP Extension: mongodb --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install mongodb-0.6.3 \
	# Enabling
	&& docker-php-ext-enable mongodb \
	&& true


# -------------------- Installing PHP Extension: mysql --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure mysql --with-mysql --with-mysql-sock --with-zlib-dir=/usr --with-libdir="/lib/$(dpkg-architecture --query DEB_BUILD_MULTIARCH)" \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) mysql \
	&& true


# -------------------- Installing PHP Extension: mysqli --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         Built-in extension
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) mysqli \
	&& true


# -------------------- Installing PHP Extension: oauth --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install oauth-1.2.3 \
	# Enabling
	&& docker-php-ext-enable oauth \
	&& true


# -------------------- Installing PHP Extension: oci8 --------------------
RUN set -eux \
	# Generic pre-command
	&& ORACLE_HREF="$( curl -sS https://yum.oracle.com/repo/OracleLinux/OL7/oracle/instantclient/$(dpkg-architecture --query DEB_HOST_GNU_CPU)/ | tac | tac | grep -Eo 'href="getPackage/oracle-instantclient.+basiclite.+rpm"' | tail -1 )" \
&& ORACLE_VERSION_MAJOR="$( echo "${ORACLE_HREF}" | grep -Eo 'instantclient[.0-9]+' | sed 's/instantclient//g' )" \
&& ORACLE_VERSION_FULL="$( echo "${ORACLE_HREF}" | grep -Eo 'basiclite-[-.0-9]+' | sed -e 's/basiclite-//g' -e 's/\.$//g' )" \
\
&& rpm --import http://yum.oracle.com/RPM-GPG-KEY-oracle-ol7 \
&& curl -sS -o /tmp/oracle-instantclient${ORACLE_VERSION_MAJOR}-basiclite-${ORACLE_VERSION_FULL}.$(dpkg-architecture --query DEB_HOST_GNU_CPU).rpm \
https://yum.oracle.com/repo/OracleLinux/OL7/oracle/instantclient/$(dpkg-architecture --query DEB_HOST_GNU_CPU)/getPackage/oracle-instantclient${ORACLE_VERSION_MAJOR}-basiclite-${ORACLE_VERSION_FULL}.$(dpkg-architecture --query DEB_HOST_GNU_CPU).rpm \
&& curl -sS -o /tmp/oracle-instantclient${ORACLE_VERSION_MAJOR}-devel-${ORACLE_VERSION_FULL}.$(dpkg-architecture --query DEB_HOST_GNU_CPU).rpm \
https://yum.oracle.com/repo/OracleLinux/OL7/oracle/instantclient/$(dpkg-architecture --query DEB_HOST_GNU_CPU)/getPackage/oracle-instantclient${ORACLE_VERSION_MAJOR}-devel-${ORACLE_VERSION_FULL}.$(dpkg-architecture --query DEB_HOST_GNU_CPU).rpm \
&& alien \
  -v \
  --target=$( dpkg --print-architecture ) \
  -i /tmp/oracle-instantclient${ORACLE_VERSION_MAJOR}-basiclite-${ORACLE_VERSION_FULL}.$(dpkg-architecture \
  --query DEB_HOST_GNU_CPU).rpm \
&& alien \
  -v \
  --target=$( dpkg --print-architecture ) \
  -i /tmp/oracle-instantclient${ORACLE_VERSION_MAJOR}-devel-${ORACLE_VERSION_FULL}.$(dpkg-architecture \
  --query DEB_HOST_GNU_CPU).rpm \
&& rm -f /tmp/oracle-instantclient${ORACLE_VERSION_MAJOR}-basiclite-${ORACLE_VERSION_FULL}.$(dpkg-architecture --query DEB_HOST_GNU_CPU).rpm \
&& rm -f /tmp/oracle-instantclient${ORACLE_VERSION_MAJOR}-devel-${ORACLE_VERSION_FULL}.$(dpkg-architecture --query DEB_HOST_GNU_CPU).rpm \
 \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure oci8 --with-oci8=instantclient,/usr/lib/oracle/${ORACLE_VERSION_MAJOR}/client64/lib/,${ORACLE_VERSION_MAJOR} \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) oci8 \
	# Generic post-command
	&& ORACLE_HREF="$( curl -sS https://yum.oracle.com/repo/OracleLinux/OL7/oracle/instantclient/$(dpkg-architecture --query DEB_HOST_GNU_CPU)/ | tac | tac | grep -Eo 'href="getPackage/oracle-instantclient.+basiclite.+rpm"' | tail -1 )" \
&& ORACLE_VERSION_MAJOR="$( echo "${ORACLE_HREF}" | grep -Eo 'instantclient[.0-9]+' | sed 's/instantclient//g' )" \
&& ORACLE_VERSION_FULL="$( echo "${ORACLE_HREF}" | grep -Eo 'basiclite-[-.0-9]+' | sed -e 's/basiclite-//g' -e 's/\.$//g' )" \
&& (ln -sf /usr/lib/oracle/${ORACLE_VERSION_MAJOR}/client64/lib/*.so* /usr/lib/ || true) \
 \
	&& true


# -------------------- Installing PHP Extension: opcache --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Custom:       Pecl command
	&& pecl install zendopcache \
	# Enabling
	&& docker-php-ext-enable opcache \
	&& true


# -------------------- Installing PHP Extension: pcntl --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pcntl \
	&& true


# -------------------- Installing PHP Extension: pdo_dblib --------------------
RUN set -eux \
	# Generic pre-command
	&& ln -s /usr/lib/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/libsybdb.* /usr/lib/ \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pdo_dblib \
	&& true


# -------------------- Installing PHP Extension: pdo_firebird --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pdo_firebird \
	&& true


# -------------------- Installing PHP Extension: pdo_mysql --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         Built-in extension
	# Default:      configure command
	&& docker-php-ext-configure pdo_mysql --with-zlib-dir=/usr \
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pdo_mysql \
	&& true


# -------------------- Installing PHP Extension: pdo_pgsql --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pdo_pgsql \
	&& true


# -------------------- Installing PHP Extension: pgsql --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pgsql \
	&& true


# -------------------- Installing PHP Extension: phalcon --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         GIT extension
	&& git clone https://github.com/phalcon/cphalcon /tmp/phalcon \
	&& cd /tmp/phalcon \
	# Custom:       Branch
	&& git checkout phalcon-v2.0.9 \
	# Custom:       Install command
	&& cd build && ./install \
	# Enabling
	&& docker-php-ext-enable phalcon \
	&& true


# -------------------- Installing PHP Extension: pspell --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pspell \
	&& true


# -------------------- Installing PHP Extension: redis --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install redis-4.3.0 \
	# Enabling
	&& docker-php-ext-enable redis \
	&& true


# -------------------- Installing PHP Extension: rdkafka --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install rdkafka-3.0.5 \
	# Enabling
	&& docker-php-ext-enable rdkafka \
	&& true


# -------------------- Installing PHP Extension: shmop --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) shmop \
	&& true


# -------------------- Installing PHP Extension: snmp --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure snmp --with-openssl-dir \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) snmp \
	&& true


# -------------------- Installing PHP Extension: soap --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure soap --with-libxml-dir=/usr \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) soap \
	&& true


# -------------------- Installing PHP Extension: sockets --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) sockets \
	&& true


# -------------------- Installing PHP Extension: sysvmsg --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) sysvmsg \
	&& true


# -------------------- Installing PHP Extension: sysvsem --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) sysvsem \
	&& true


# -------------------- Installing PHP Extension: sysvshm --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) sysvshm \
	&& true


# -------------------- Installing PHP Extension: tidy --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         Built-in extension
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) tidy \
	&& true


# -------------------- Installing PHP Extension: uploadprogress --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install uploadprogress-1.1.4 \
	# Enabling
	&& docker-php-ext-enable uploadprogress \
	&& true


# -------------------- Installing PHP Extension: uuid --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install uuid-1.0.5 \
	# Enabling
	&& docker-php-ext-enable uuid \
	&& true


# -------------------- Installing PHP Extension: wddx --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure wddx --with-libxml-dir=/usr \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) wddx \
	&& true


# -------------------- Installing PHP Extension: xdebug --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install xdebug-2.2.7 \
	# Enabling
	&& docker-php-ext-enable xdebug \
	&& true


# -------------------- Installing PHP Extension: xmlrpc --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure xmlrpc --with-libxml-dir=/usr --with-iconv-dir=/usr \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) xmlrpc \
	&& true


# -------------------- Installing PHP Extension: xsl --------------------
RUN set -eux \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) xsl \
	&& true


# -------------------- Installing PHP Extension: yaml --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install yaml-1.3.2 \
	# Enabling
	&& docker-php-ext-enable yaml \
	&& true


# -------------------- Installing PHP Extension: zip --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure zip --with-zlib-dir=/usr --with-pcre-dir=/usr \
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) zip \
	&& true


# -------------------- Installing PHP Extension: swoole --------------------
RUN set -eux \
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install swoole-1.9.23 \
	# Enabling
	&& docker-php-ext-enable swoole \
	&& true 

RUN set -eux \
	&& rm -rf /tmp/*

WORKDIR /var/www/html

EXPOSE 80
CMD ["apache2-foreground"]

