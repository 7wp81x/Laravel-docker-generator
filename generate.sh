#!/usr/bin/env bash
#
# generate-laravel-dockerfile.sh
#
# Detects PHP / Node / DB requirements from a Laravel project and generates:
#   - Dockerfile
#   - docker/nginx.conf
#   - docker/supervisord.conf
#   - docker/start.sh
#
# Usage:
#   ./generate.sh /path/to/laravel-project
#
set -euo pipefail

PROJECT_DIR="${1:-.}"
COMPOSER_JSON="$PROJECT_DIR/composer.json"
PACKAGE_JSON="$PROJECT_DIR/package.json"

if [ ! -f "$COMPOSER_JSON" ]; then
    echo "ERROR: composer.json not found in $PROJECT_DIR — is this a Laravel project?" >&2
    exit 1
fi

echo "==> Detecting project requirements..."

# ---------- PHP version ----------
# Pulls the constraint from composer.json's require.php, ex. "^8.3" -> 8.3
PHP_CONSTRAINT=$(grep -o '"php"[[:space:]]*:[[:space:]]*"[^"]*"' "$COMPOSER_JSON" | head -1 | sed -E 's/.*:\s*"([^"]*)"/\1/')
PHP_VERSION=$(echo "$PHP_CONSTRAINT" | grep -oE '[0-9]+\.[0-9]+' | head -1)
PHP_VERSION="${PHP_VERSION:-8.3}"
echo "   PHP version constraint: ${PHP_CONSTRAINT:-none found} -> using php:${PHP_VERSION}"

# ---------- Laravel version ----------
LARAVEL_CONSTRAINT=$(grep -o '"laravel/framework"[[:space:]]*:[[:space:]]*"[^"]*"' "$COMPOSER_JSON" | sed -E 's/.*:\s*"([^"]*)"/\1/')
LARAVEL_MAJOR=$(echo "$LARAVEL_CONSTRAINT" | grep -oE '[0-9]+' | head -1)
echo "   Laravel version: ${LARAVEL_CONSTRAINT:-unknown} (major: ${LARAVEL_MAJOR:-unknown})"

# ---------- Node / npm ----------
HAS_NODE_BUILD="false"
NODE_VERSION="20"
if [ -f "$PACKAGE_JSON" ]; then
    HAS_NODE_BUILD="true"
    # .nvmrc takes priority if present
    if [ -f "$PROJECT_DIR/.nvmrc" ]; then
        NODE_VERSION=$(tr -d 'v \n' < "$PROJECT_DIR/.nvmrc")
    else
        ENGINE_NODE=$(grep -A3 '"engines"' "$PACKAGE_JSON" 2>/dev/null | grep -o '"node"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*:\s*"([^"]*)"/\1/' || true)
        if [ -n "${ENGINE_NODE:-}" ]; then
            NODE_VERSION=$(echo "$ENGINE_NODE" | grep -oE '[0-9]+' | head -1)
        else
            # Infer from Vite major version: Vite 6+/8+ needs Node 20+
            VITE_CONSTRAINT=$(grep -o '"vite"[[:space:]]*:[[:space:]]*"[^"]*"' "$PACKAGE_JSON" | sed -E 's/.*:\s*"([^"]*)"/\1/')
            VITE_MAJOR=$(echo "$VITE_CONSTRAINT" | grep -oE '[0-9]+' | head -1)
            if [ -n "${VITE_MAJOR:-}" ] && [ "$VITE_MAJOR" -ge 6 ]; then
                NODE_VERSION="20"
            else
                NODE_VERSION="18"
            fi
        fi
    fi
    echo "   Node build detected -> using node:${NODE_VERSION}-alpine"
else
    echo "   No package.json found -> skipping frontend build stage"
fi

# ---------- DB driver ----------
DB_DRIVER="sqlite"
if [ -f "$PROJECT_DIR/.env.example" ]; then
    ENV_DB=$(grep -E '^DB_CONNECTION=' "$PROJECT_DIR/.env.example" | head -1 | cut -d= -f2 | tr -d '\r')
    if [ -n "${ENV_DB:-}" ]; then
        DB_DRIVER="$ENV_DB"
    fi
fi
echo "   DB driver detected: ${DB_DRIVER}"

case "$DB_DRIVER" in
    pgsql)  PHP_EXT_DB="pdo_pgsql pgsql"; APK_DB="postgresql-dev postgresql-client" ;;
    mysql)  PHP_EXT_DB="pdo_mysql mysqli"; APK_DB="mariadb-connector-c-dev" ;;
    sqlite) PHP_EXT_DB="pdo_sqlite"; APK_DB="sqlite-dev" ;;
    *)      PHP_EXT_DB="pdo_mysql pdo_pgsql pdo_sqlite"; APK_DB="postgresql-dev mariadb-connector-c-dev sqlite-dev" ;;
esac

# ---------- Redis (queue/cache) ----------
USES_REDIS="false"
if grep -qE '^(QUEUE_CONNECTION|CACHE_STORE|SESSION_DRIVER)=redis' "$PROJECT_DIR/.env.example" 2>/dev/null \
   || grep -q '"predis/predis"' "$COMPOSER_JSON" 2>/dev/null; then
    USES_REDIS="true"
    echo "   Redis usage detected -> adding redis PHP extension"
fi

mkdir -p "$PROJECT_DIR/docker"

# ============================================================
# Dockerfile
# ============================================================
{
if [ "$HAS_NODE_BUILD" = "true" ]; then
cat <<EOF
# syntax=docker/dockerfile:1

# ---------- Stage 1: build frontend assets ----------
FROM node:${NODE_VERSION}-alpine AS assets
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

EOF
else
cat <<'EOF'
# syntax=docker/dockerfile:1

EOF
fi

cat <<EOF
# ---------- Stage 2: PHP application ----------
FROM php:${PHP_VERSION}-fpm-alpine AS app

RUN apk add --no-cache \\
        bash \\
        git \\
        curl \\
        libpng-dev \\
        libzip-dev \\
        libxml2-dev \\
        oniguruma-dev \\
        icu-dev \\
        nginx \\
        supervisor \\
        ${APK_DB} \\
    && docker-php-ext-configure gd \\
    && docker-php-ext-install -j\$(nproc) \\
        ${PHP_EXT_DB} \\
        gd \\
        zip \\
        mbstring \\
        xml \\
        intl \\
        bcmath
EOF

if [ "$USES_REDIS" = "true" ]; then
cat <<'EOF'

RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps
EOF
fi

cat <<'EOF'

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

WORKDIR /var/www/html

# Install PHP deps first (better layer caching)
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --no-scripts --prefer-dist --no-autoloader

# Copy app source
COPY . .
EOF

if [ "$HAS_NODE_BUILD" = "true" ]; then
cat <<'EOF'

COPY --from=assets /app/public/build ./public/build
EOF
fi

cat <<EOF

RUN composer dump-autoload --optimize \\
    && mkdir -p storage/framework/{cache,sessions,views} storage/logs bootstrap/cache \\
    && mkdir -p storage/app/public \\
EOF

if [ "$DB_DRIVER" = "sqlite" ]; then
cat <<'EOF'
    && mkdir -p database \
    && touch database/database.sqlite \
EOF
fi

cat <<'EOF'
    && chown -R www-data:www-data /var/www/html \
    && chmod -R 775 storage bootstrap/cache

# Nginx + PHP-FPM + supervisor config
COPY docker/nginx.conf /etc/nginx/http.d/default.conf
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY docker/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

EXPOSE 8080

CMD ["/usr/local/bin/start.sh"]
EOF
} > "$PROJECT_DIR/Dockerfile"

# ============================================================
# docker/nginx.conf
# ============================================================
cat > "$PROJECT_DIR/docker/nginx.conf" <<'EOF'
server {
    listen PORT_PLACEHOLDER;
    server_name _;
    root /var/www/html/public;
    index index.php index.html;

    client_max_body_size 20M;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass 127.0.0.1:9000;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location ~* \.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf)$ {
        expires 7d;
        access_log off;
    }
}
EOF

# ============================================================
# docker/supervisord.conf
# ============================================================
cat > "$PROJECT_DIR/docker/supervisord.conf" <<'EOF'
[supervisord]
nodaemon=true
user=root

[program:php-fpm]
command=php-fpm -F
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:nginx]
command=nginx -g "daemon off;"
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0

[program:scheduler]
command=php artisan schedule:work
directory=/var/www/html
autostart=true
autorestart=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
EOF

# ============================================================
# docker/start.sh
# ============================================================
cat > "$PROJECT_DIR/docker/start.sh" <<'EOF'
#!/bin/bash
set -e

PORT="${PORT:-8080}"
sed -i "s/PORT_PLACEHOLDER/${PORT}/" /etc/nginx/http.d/default.conf

cd /var/www/html
chown -R www-data:www-data storage bootstrap/cache 2>/dev/null || true

if [ -z "$APP_KEY" ]; then
    echo "WARNING: APP_KEY not set. Generating a temporary one for this run."
    echo "         Set a permanent APP_KEY in your host environment variables!"
    export APP_KEY=$(php artisan key:generate --show --no-interaction 2>/dev/null | tr -d '\r\n')
fi

php artisan config:cache || true
php artisan route:cache  || true
php artisan view:cache   || true

php artisan migrate --force || echo "WARNING: migration failed — starting anyway" >&2

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
EOF
chmod +x "$PROJECT_DIR/docker/start.sh"

echo ""
echo "==> Done. Generated:"
echo "    $PROJECT_DIR/Dockerfile"
echo "    $PROJECT_DIR/docker/nginx.conf"
echo "    $PROJECT_DIR/docker/supervisord.conf"
echo "    $PROJECT_DIR/docker/start.sh"
