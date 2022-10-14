FROM debian:jessie-slim

# PHP config ini directory
ENV PHP_INI_DIR=/usr/local/etc/php
# PHP buid dependencies
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
	libssl-dev \
	libxml2-dev
# Build Tools
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

###
### Build OpenSSL
###
RUN set -eux \
# Install Dependencies
	&& apt-get update \
	&& apt-get install -y --no-install-recommends --no-install-suggests \
		${BUILD_TOOLS} \
# Fetch OpenSSL
	&& cd /tmp \
	&& mkdir openssl \
	&& update-ca-certificates \
	&& curl -sS -k -L --fail "https://www.openssl.org/source/openssl-1.0.1t.tar.gz" -o openssl.tar.gz \
	&& curl -sS -k -L --fail "https://www.openssl.org/source/openssl-1.0.1t.tar.gz.asc" -o openssl.tar.gz.asc \
	&& tar -xzf openssl.tar.gz -C openssl --strip-components=1 \
	&& cd /tmp/openssl \
# Build OpenSSL
	&& ./config -fPIC \
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
	&& apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false -o APT::AutoRemove::SuggestsImportant=false \
		${BUILD_TOOLS} \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/* \
# Setup PHP directories	
	&& mkdir -p ${PHP_INI_DIR}/conf.d \
	&& mkdir -p /usr/src/php

# Install Apache
RUN set -eux \
	&& apt-get update \
	&& apt-get install -y apache2-bin apache2-dev apache2.2-common --no-install-recommends \
	&& rm -rf /var/lib/apt/lists/* \
	&& rm -rf /var/www/html \
	&& mkdir -p /var/lock/apache2 /var/run/apache2 /var/log/apache2 /var/www/html \
	&& chown -R www-data:www-data /var/lock/apache2 /var/run/apache2 /var/log/apache2 /var/www/html \
# Apache + PHP requires preforking Apache for best results
	&& a2dismod mpm_event \
	&& a2enmod mpm_prefork \
	&& mv /etc/apache2/apache2.conf /etc/apache2/apache2.conf.dist

COPY apache2.conf /etc/apache2/apache2.conf
COPY apache2-foreground /usr/local/bin/
# Copy PHP scripts
COPY data/docker-php-source /usr/local/bin/
COPY data/php/php-5.3.29.tar.xz /usr/src/php.tar.xz

# Fix config.guess for PHP modules (adds 'aarch64' [arm64] architecture)
# The config.guess has been copied from PHP 5.5
COPY data/php/usr-local-lib-php-build-config.guess /usr/local/lib/php/build/config.guess
COPY data/php/usr-local-lib-php-build-config.sub /usr/local/lib/php/build/config.sub
COPY data/docker-php-* /usr/local/bin/
# COPY data/php-fpm.conf /usr/local/etc/
COPY data/php.ini ${PHP_INI_DIR}/php.ini
COPY ZendGuardLoader.so ${PHP_INI_DIR}/ZendGuardLoader.so
###
### Build PHP
###
RUN set -eux \
# Install Dependencies
	&& apt-get update \
	&& apt-get install -y --no-install-recommends --no-install-suggests \
		${PHP_BUILD_DEPS} \
		${BUILD_TOOLS} \	
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
# apache perfork mod not available
		–-enable-maintainer-zts \
		--enable-safe-mode \
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
	&& apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false -o APT::AutoRemove::SuggestsImportant=false \
		${PHP_BUILD_DEPS} \
		${BUILD_TOOLS} \
# Install Run-time requirements
	&& apt-get update \
	&& apt-get install -y --no-install-recommends --no-install-suggests \
		libmhash2 \
		libmysqlclient18 \
		libpcre3 \
		librecode0 \
		libsqlite3-0 \
		libssl1.0.0 \
		libxml2 \
		xz-utils \
		ca-certificates \
		curl \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/* \
# Setup extension dir
	&& mkdir -p "$(php -r 'echo ini_get("extension_dir");')" \	
	&& echo "[Zend.loader]" >> ${PHP_INI_DIR}/php.ini \ 
	&& echo "zend_extension=${PHP_INI_DIR}/ZendGuardLoader.so" >> ${PHP_INI_DIR}/php.ini \ 
	&& echo "zend_loader.enable=1" >> ${PHP_INI_DIR}/php.ini \ 
	&& echo "zend_loader.disable_licensing=1" >> ${PHP_INI_DIR}/php.ini \ 
	&& echo "zend_loader.obfuscation_level_support=3" >> ${PHP_INI_DIR}/php.ini \
	&& echo "[xdebug]" >> ${PHP_INI_DIR}/php.ini \
	&& echo "xdebug.start_with_request=yes" >> ${PHP_INI_DIR}/php.ini \
	&& echo "xdebug.remote_enable=1" >> ${PHP_INI_DIR}/php.ini \
	&& echo "xdebug.remote_port=9001" >> ${PHP_INI_DIR}/php.ini \
	&& echo "xdebug.remote_host=host.docker.internal" >> ${PHP_INI_DIR}/php.ini \
	&& echo "xdebug.idekey=PHPSTORM" >> ${PHP_INI_DIR}/php.ini \
	&& echo "xdebug.remote_log=/var/log/xdebug.log" >> ${PHP_INI_DIR}/php.ini \
	&& echo "xdebug.mode=debug" >> ${PHP_INI_DIR}/php.ini \
	&& echo "xdebug.remote_connect_back=1" >> ${PHP_INI_DIR}/php.ini 

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
	&& rm -rf /var/lib/apt/lists/* 	\	
###
### Install and enable PHP modules
###
# Enable ffi if it exists
	&& if [ -f ${PHP_INI_DIR}/conf.d/docker-php-ext-ffi.ini ]; then \
			echo "ffi.enable = 1" >> ${PHP_INI_DIR}/conf.d/docker-php-ext-ffi.ini; \
		fi \
# -------------------- Installing PHP Extension: amqp --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install amqp-1.9.3 \
	# Enabling
	&& docker-php-ext-enable amqp \
# -------------------- Installing PHP Extension: apcu --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install apcu-4.0.11 \
	# Enabling
	&& docker-php-ext-enable apcu \
# -------------------- Installing PHP Extension: bcmath --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) bcmath \
# -------------------- Installing PHP Extension: bz2 --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) bz2 \
# -------------------- Installing PHP Extension: calendar --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) calendar \
# -------------------- Installing PHP Extension: dba --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) dba \
# -------------------- Installing PHP Extension: enchant --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) enchant \
# -------------------- Installing PHP Extension: exif --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) exif \
# -------------------- Installing PHP Extension: gd --------------------
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
# -------------------- Installing PHP Extension: gettext --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) gettext \
# -------------------- Installing PHP Extension: gmp --------------------
	# Generic pre-command
	&& ln /usr/include/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/gmp.h /usr/include/ \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) gmp \
# -------------------- Installing PHP Extension: igbinary --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install igbinary-2.0.8 \
	# Enabling
	&& docker-php-ext-enable igbinary \
# -------------------- Installing PHP Extension: imap --------------------
	# Generic pre-command
	&& ln -s /usr/lib/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/libkrb5* /usr/lib/ \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure imap --with-kerberos --with-imap-ssl --with-imap \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) imap \
# -------------------- Installing PHP Extension: interbase --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) interbase \
# -------------------- Installing PHP Extension: intl --------------------
	# Installation: Version specific
	# Type:         Built-in extension
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) intl \
# -------------------- Installing PHP Extension: ldap --------------------
	# Generic pre-command
	&& ln -s /usr/lib/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/libldap* /usr/lib/ \
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure ldap --with-ldap --with-ldap-sasl \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) ldap \
# -------------------- Installing PHP Extension: mcrypt --------------------
	# Installation: Version specific
	# Type:         Built-in extension
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) mcrypt \
# -------------------- Installing PHP Extension: msgpack --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install msgpack-0.5.7 \
	# Enabling
	&& docker-php-ext-enable msgpack \
# -------------------- Installing PHP Extension: memcache --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install memcache-2.2.7 \
	# Enabling
	&& docker-php-ext-enable memcache \
# -------------------- Installing PHP Extension: memcached --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install memcached-2.2.0 \
	# Enabling
	&& docker-php-ext-enable memcached \
# -------------------- Installing PHP Extension: mongo --------------------
	# Installation: Generic
	# Type:         PECL extension
	# Custom:       Pecl command
	&& yes yes | pecl install mongo \
	# Enabling
	&& docker-php-ext-enable mongo \
# -------------------- Installing PHP Extension: mongodb --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install mongodb-0.6.3 \
	# Enabling
	&& docker-php-ext-enable mongodb \
# -------------------- Installing PHP Extension: mysql --------------------
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure mysql --with-mysql --with-mysql-sock --with-zlib-dir=/usr --with-libdir="/lib/$(dpkg-architecture --query DEB_BUILD_MULTIARCH)" \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) mysql \
# -------------------- Installing PHP Extension: mysqli --------------------
	# Installation: Version specific
	# Type:         Built-in extension
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) mysqli \
# -------------------- Installing PHP Extension: oauth --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install oauth-1.2.3 \
	# Enabling
	&& docker-php-ext-enable oauth \
# -------------------- Installing PHP Extension: oci8 --------------------
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
# -------------------- Installing PHP Extension: opcache --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Custom:       Pecl command
	&& pecl install zendopcache \
	# Enabling
	&& docker-php-ext-enable opcache \
# -------------------- Installing PHP Extension: pcntl --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pcntl \
# -------------------- Installing PHP Extension: pdo_dblib --------------------
	# Generic pre-command
	&& ln -s /usr/lib/$(dpkg-architecture --query DEB_BUILD_GNU_TYPE)/libsybdb.* /usr/lib/ \
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pdo_dblib \
# -------------------- Installing PHP Extension: pdo_firebird --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pdo_firebird \
# -------------------- Installing PHP Extension: pdo_mysql --------------------
	# Installation: Version specific
	# Type:         Built-in extension
	# Default:      configure command
	&& docker-php-ext-configure pdo_mysql --with-zlib-dir=/usr \
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pdo_mysql \
# -------------------- Installing PHP Extension: pdo_pgsql --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pdo_pgsql \
# -------------------- Installing PHP Extension: pgsql --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pgsql \
# -------------------- Installing PHP Extension: phalcon --------------------
	# Installation: Version specific
	# Type:         GIT extension
	&& git clone https://github.91chi.fun/https://github.com/phalcon/cphalcon /tmp/phalcon \
	&& cd /tmp/phalcon \
	# Custom:       Branch
	&& git checkout phalcon-v2.0.9 \
	# Custom:       Install command
	&& cd build && ./install \
	# Enabling
	&& docker-php-ext-enable phalcon \
# -------------------- Installing PHP Extension: pspell --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) pspell \
# -------------------- Installing PHP Extension: redis --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install redis-4.3.0 \
	# Enabling
	&& docker-php-ext-enable redis \
# -------------------- Installing PHP Extension: rdkafka --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install rdkafka-3.0.5 \
	# Enabling
	&& docker-php-ext-enable rdkafka \
# -------------------- Installing PHP Extension: shmop --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) shmop \
# -------------------- Installing PHP Extension: snmp --------------------
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure snmp --with-openssl-dir \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) snmp \
# -------------------- Installing PHP Extension: soap --------------------
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure soap --with-libxml-dir=/usr \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) soap \
# -------------------- Installing PHP Extension: sockets --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) sockets \
# -------------------- Installing PHP Extension: sysvmsg --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) sysvmsg \
# -------------------- Installing PHP Extension: sysvsem --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) sysvsem \
# -------------------- Installing PHP Extension: sysvshm --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) sysvshm \
# -------------------- Installing PHP Extension: tidy --------------------
	# Installation: Version specific
	# Type:         Built-in extension
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) tidy \
# -------------------- Installing PHP Extension: uploadprogress --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install uploadprogress-1.1.4 \
	# Enabling
	&& docker-php-ext-enable uploadprogress \
# -------------------- Installing PHP Extension: uuid --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install uuid-1.0.5 \
	# Enabling
	&& docker-php-ext-enable uuid \
# -------------------- Installing PHP Extension: wddx --------------------
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure wddx --with-libxml-dir=/usr \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) wddx \
# -------------------- Installing PHP Extension: xdebug --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install xdebug-2.0.5 \
	# Enabling
	&& docker-php-ext-enable xdebug \
# -------------------- Installing PHP Extension: xmlrpc --------------------
	# Installation: Generic
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure xmlrpc --with-libxml-dir=/usr --with-iconv-dir=/usr \
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) xmlrpc \
# -------------------- Installing PHP Extension: xsl --------------------
	# Installation: Generic
	# Type:         Built-in extension
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) xsl \
# -------------------- Installing PHP Extension: yaml --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install yaml-1.3.2 \
	# Enabling
	&& docker-php-ext-enable yaml \
# -------------------- Installing PHP Extension: zip --------------------
	# Installation: Version specific
	# Type:         Built-in extension
	# Custom:       configure command
	&& docker-php-ext-configure zip --with-zlib-dir=/usr --with-pcre-dir=/usr \
	# Installation
	&& docker-php-ext-install -j$(getconf _NPROCESSORS_ONLN) zip \
# -------------------- Installing PHP Extension: swoole --------------------
	# Installation: Version specific
	# Type:         PECL extension
	# Default:      Pecl command
	&& pecl install swoole-1.9.23 \
	# Enabling
	&& docker-php-ext-enable swoole \
	&& rm -rf /tmp/* \
	&& true 
# fixed index.php	
COPY dir.conf /etc/apache2/mods-enabled/dir.conf
WORKDIR /var/www/html
EXPOSE 80
CMD ["apache2-foreground"]

