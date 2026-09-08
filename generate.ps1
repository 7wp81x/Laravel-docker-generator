<#
.SYNOPSIS
    Detects PHP / Node / DB requirements from a Laravel project and generates
    a Dockerfile plus docker/nginx.conf, docker/supervisord.conf, docker/start.sh

.USAGE
    .\generate.ps1 -ProjectDir "C:\path\to\laravel-project"
    .\generate.ps1                      # uses current folder
#>

param(
    [string]$ProjectDir = "."
)

$ErrorActionPreference = "Stop"

$ComposerJsonPath = Join-Path $ProjectDir "composer.json"
$PackageJsonPath  = Join-Path $ProjectDir "package.json"
$EnvExamplePath   = Join-Path $ProjectDir ".env.example"
$NvmrcPath        = Join-Path $ProjectDir ".nvmrc"

if (-not (Test-Path $ComposerJsonPath)) {
    Write-Error "composer.json not found in $ProjectDir - is this a Laravel project?"
    exit 1
}

Write-Host "==> Detecting project requirements..."

# ---------- PHP version ----------
$composerRaw = Get-Content $ComposerJsonPath -Raw
$phpMatch = [regex]::Match($composerRaw, '"php"\s*:\s*"([^"]*)"')
$phpConstraint = if ($phpMatch.Success) { $phpMatch.Groups[1].Value } else { "" }
$phpVerMatch = [regex]::Match($phpConstraint, '[0-9]+\.[0-9]+')
$phpVersion = if ($phpVerMatch.Success) { $phpVerMatch.Value } else { "8.3" }
Write-Host "   PHP version constraint: $(if ($phpConstraint) { $phpConstraint } else { 'none found' }) -> using php:$phpVersion"

# ---------- Laravel version ----------
$laravelMatch = [regex]::Match($composerRaw, '"laravel/framework"\s*:\s*"([^"]*)"')
$laravelConstraint = if ($laravelMatch.Success) { $laravelMatch.Groups[1].Value } else { "unknown" }
Write-Host "   Laravel version: $laravelConstraint"

# ---------- Node / npm ----------
$hasNodeBuild = $false
$nodeVersion = "20"
if (Test-Path $PackageJsonPath) {
    $hasNodeBuild = $true
    if (Test-Path $NvmrcPath) {
        $nodeVersion = (Get-Content $NvmrcPath -Raw).Trim().TrimStart("v")
    } else {
        $packageRaw = Get-Content $PackageJsonPath -Raw
        $engineMatch = [regex]::Match($packageRaw, '"engines"\s*:\s*\{[^}]*"node"\s*:\s*"([^"]*)"')
        if ($engineMatch.Success) {
            $verMatch = [regex]::Match($engineMatch.Groups[1].Value, '[0-9]+')
            if ($verMatch.Success) { $nodeVersion = $verMatch.Value }
        } else {
            $viteMatch = [regex]::Match($packageRaw, '"vite"\s*:\s*"([^"]*)"')
            if ($viteMatch.Success) {
                $viteMajorMatch = [regex]::Match($viteMatch.Groups[1].Value, '[0-9]+')
                if ($viteMajorMatch.Success -and [int]$viteMajorMatch.Value -ge 6) {
                    $nodeVersion = "20"
                } else {
                    $nodeVersion = "18"
                }
            }
        }
    }
    Write-Host "   Node build detected -> using node:$nodeVersion-alpine"
} else {
    Write-Host "   No package.json found -> skipping frontend build stage"
}

# ---------- DB driver ----------
$dbDriver = "sqlite"
if (Test-Path $EnvExamplePath) {
    $envMatch = [regex]::Match((Get-Content $EnvExamplePath -Raw), '(?m)^DB_CONNECTION=(\S+)')
    if ($envMatch.Success) { $dbDriver = $envMatch.Groups[1].Value }
}
Write-Host "   DB driver detected: $dbDriver"

switch ($dbDriver) {
    "pgsql"  { $phpExtDb = "pdo_pgsql pgsql"; $apkDb = "postgresql-dev postgresql-client" }
    "mysql"  { $phpExtDb = "pdo_mysql mysqli"; $apkDb = "mariadb-connector-c-dev" }
    "sqlite" { $phpExtDb = "pdo_sqlite"; $apkDb = "sqlite-dev" }
    default  { $phpExtDb = "pdo_mysql pdo_pgsql pdo_sqlite"; $apkDb = "postgresql-dev mariadb-connector-c-dev sqlite-dev" }
}

# ---------- Redis ----------
$usesRedis = $false
if (Test-Path $EnvExamplePath) {
    $envContent = Get-Content $EnvExamplePath -Raw
    if ($envContent -match '(?m)^(QUEUE_CONNECTION|CACHE_STORE|SESSION_DRIVER)=redis') {
        $usesRedis = $true
    }
}
if ($composerRaw -match '"predis/predis"') { $usesRedis = $true }
if ($usesRedis) { Write-Host "   Redis usage detected -> adding redis PHP extension" }

$dockerDir = Join-Path $ProjectDir "docker"
New-Item -ItemType Directory -Force -Path $dockerDir | Out-Null

# ============================================================
# Dockerfile
# ============================================================
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("# syntax=docker/dockerfile:1")
[void]$sb.AppendLine("")

if ($hasNodeBuild) {
    [void]$sb.AppendLine("# ---------- Stage 1: build frontend assets ----------")
    [void]$sb.AppendLine("FROM node:$nodeVersion-alpine AS assets")
    [void]$sb.AppendLine("WORKDIR /app")
    [void]$sb.AppendLine("COPY package*.json ./")
    [void]$sb.AppendLine("RUN npm ci")
    [void]$sb.AppendLine("COPY . .")
    [void]$sb.AppendLine("RUN npm run build")
    [void]$sb.AppendLine("")
}

[void]$sb.AppendLine("# ---------- Stage 2: PHP application ----------")
[void]$sb.AppendLine("FROM php:$phpVersion-fpm-alpine AS app")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("RUN apk add --no-cache \")
[void]$sb.AppendLine("        bash \")
[void]$sb.AppendLine("        git \")
[void]$sb.AppendLine("        curl \")
[void]$sb.AppendLine("        libpng-dev \")
[void]$sb.AppendLine("        libzip-dev \")
[void]$sb.AppendLine("        libxml2-dev \")
[void]$sb.AppendLine("        oniguruma-dev \")
[void]$sb.AppendLine("        icu-dev \")
[void]$sb.AppendLine("        nginx \")
[void]$sb.AppendLine("        supervisor \")
[void]$sb.AppendLine("        $apkDb \")
[void]$sb.AppendLine("    && docker-php-ext-configure gd \")
[void]$sb.AppendLine('    && docker-php-ext-install -j$(nproc) \')
[void]$sb.AppendLine("        $phpExtDb \")
[void]$sb.AppendLine("        gd \")
[void]$sb.AppendLine("        zip \")
[void]$sb.AppendLine("        mbstring \")
[void]$sb.AppendLine("        xml \")
[void]$sb.AppendLine("        intl \")
[void]$sb.AppendLine("        bcmath")

if ($usesRedis) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine('RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \')
    [void]$sb.AppendLine("    && pecl install redis \")
    [void]$sb.AppendLine("    && docker-php-ext-enable redis \")
    [void]$sb.AppendLine("    && apk del .build-deps")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("# Composer")
[void]$sb.AppendLine("COPY --from=composer:2 /usr/bin/composer /usr/bin/composer")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("WORKDIR /var/www/html")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("# Install PHP deps first (better layer caching)")
[void]$sb.AppendLine("COPY composer.json composer.lock ./")
[void]$sb.AppendLine("RUN composer install --no-dev --no-interaction --no-scripts --prefer-dist --no-autoloader")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("# Copy app source")
[void]$sb.AppendLine("COPY . .")

if ($hasNodeBuild) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("COPY --from=assets /app/public/build ./public/build")
}

[void]$sb.AppendLine("")
[void]$sb.AppendLine("RUN composer dump-autoload --optimize \")
[void]$sb.AppendLine("    && mkdir -p storage/framework/{cache,sessions,views} storage/logs bootstrap/cache \")
[void]$sb.AppendLine("    && mkdir -p storage/app/public \")

if ($dbDriver -eq "sqlite") {
    [void]$sb.AppendLine("    && mkdir -p database \")
    [void]$sb.AppendLine("    && touch database/database.sqlite \")
}

[void]$sb.AppendLine("    && chown -R www-data:www-data /var/www/html \")
[void]$sb.AppendLine("    && chmod -R 775 storage bootstrap/cache")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("# Nginx + PHP-FPM + supervisor config")
[void]$sb.AppendLine("COPY docker/nginx.conf /etc/nginx/http.d/default.conf")
[void]$sb.AppendLine("COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf")
[void]$sb.AppendLine("COPY docker/start.sh /usr/local/bin/start.sh")
[void]$sb.AppendLine("RUN chmod +x /usr/local/bin/start.sh")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("EXPOSE 8080")
[void]$sb.AppendLine("")
[void]$sb.AppendLine('CMD ["/usr/local/bin/start.sh"]')

$dockerfileContent = $sb.ToString() -replace "`r`n", "`n"
[System.IO.File]::WriteAllText((Join-Path $ProjectDir "Dockerfile"), $dockerfileContent)

# ============================================================
# docker/nginx.conf
# ============================================================
$nginxConf = @'
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
'@
[System.IO.File]::WriteAllText((Join-Path $dockerDir "nginx.conf"), ($nginxConf -replace "`r`n", "`n"))

# ============================================================
# docker/supervisord.conf
# ============================================================
$supervisordConf = @'
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
'@
[System.IO.File]::WriteAllText((Join-Path $dockerDir "supervisord.conf"), ($supervisordConf -replace "`r`n", "`n"))

# ============================================================
# docker/start.sh
# ============================================================
$startSh = @'
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

php artisan migrate --force || echo "WARNING: migration failed, starting anyway" >&2

exec /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
'@
# Use LF line endings so the shell script works correctly inside the Linux container
[System.IO.File]::WriteAllText((Join-Path $dockerDir "start.sh"), ($startSh -replace "`r`n", "`n"))

Write-Host ""
Write-Host "==> Done. Generated:"
Write-Host "    $(Join-Path $ProjectDir 'Dockerfile')"
Write-Host "    $(Join-Path $dockerDir 'nginx.conf')"
Write-Host "    $(Join-Path $dockerDir 'supervisord.conf')"
Write-Host "    $(Join-Path $dockerDir 'start.sh')"
