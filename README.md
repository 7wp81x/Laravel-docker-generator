# Laravel Dockerfile Generator

Point this script at any Laravel project and it will look at your project files,
figure out what versions and services you are using, and generate a working
Dockerfile for you. No manual editing needed for most projects.

It reads:

* `composer.json` to detect your PHP version and Laravel version
* `package.json` (and `.nvmrc` if you have one) to detect your Node version
* `.env.example` to detect your database driver (MySQL, Postgres, or SQLite)
* `composer.json` and `.env.example` to detect if you are using Redis

Then it generates:

* `Dockerfile` (multi stage: builds frontend assets with Node, then runs PHP with Nginx)
* `docker/nginx.conf`
* `docker/supervisord.conf`
* `docker/start.sh`

## Requirements

* A Laravel project with a `composer.json` file
* Linux or macOS: Bash (already installed by default)
* Windows: either PowerShell (built in, no install needed) or Git Bash

## Quick start (one liner, no download needed)

Run this from inside your Laravel project folder. It downloads the script and
runs it immediately, no need to save anything first.

### Linux / macOS (Bash)

```bash
curl -fsSL https://raw.githubusercontent.com/7wp81x/Laravel-docker-generator/main/generate.sh | bash -s .
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/7wp81x/Laravel-docker-generator/main/generate.ps1 | iex
```

### Windows (Git Bash)

```bash
curl -fsSL https://raw.githubusercontent.com/7wp81x/Laravel-docker-generator/main/generate.sh | bash -s .
```

Replace `7wp81x/Laravel-docker-generator` with the actual GitHub path once you publish
this. That is the only thing you need to change.

## Normal usage (download first, run later)

If you would rather download the script once and reuse it on multiple
projects, do this instead.

### 1. Get the script

```bash
git clone https://github.com/7wp81x/Laravel-docker-generator.git
cd Laravel-docker-generator
```

### 2. Run it against your Laravel project

**Linux / macOS**

```bash
chmod +x generate.sh
./generate.sh /path/to/your-laravel-project
```

**Windows, PowerShell**

```powershell
.\generate.ps1 -ProjectDir "C:\path\to\your-laravel-project"
```

If PowerShell blocks the script from running, allow it for this session first:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\generate.ps1 -ProjectDir "C:\path\to\your-laravel-project"
```

**Windows, Git Bash**

```bash
chmod +x generate.sh
./generate.sh /c/path/to/your-laravel-project
```

Git Bash uses `/c/...` style paths instead of `C:\...`.

### Running it with no path

If you are already standing inside your Laravel project folder, you can leave
the path out and it will use the current folder.

```bash
./generate.sh
```

```powershell
.\generate.ps1
```

## What gets generated

Example output for a project using PHP 8.3, Laravel 13, Node 20, and Postgres:

```
your-project/
├── Dockerfile
└── docker/
    ├── nginx.conf
    ├── supervisord.conf
    └── start.sh
```

The Dockerfile itself looks roughly like this (trimmed for readability):

```dockerfile
FROM node:20-alpine AS assets
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM php:8.3-fpm-alpine AS app
RUN apk add --no-cache bash git curl nginx supervisor postgresql-dev postgresql-client ...
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
WORKDIR /var/www/html
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-interaction --no-scripts --prefer-dist --no-autoloader
COPY . .
COPY --from=assets /app/public/build ./public/build
RUN composer dump-autoload --optimize && ...
EXPOSE 8080
CMD ["/usr/local/bin/start.sh"]
```

## Building and running the generated image

Once the files are generated, build and run it like any normal Docker image.
This part is the same on every operating system, since Docker itself handles
the differences.

```bash
docker build -t my-laravel-app .
docker run -p 8080:8080 -e APP_KEY=base64:yourkeyhere my-laravel-app
```

Then open `http://localhost:8080` in your browser.

## Detection details

| What is detected | Where it looks | Fallback if not found |
|---|---|---|
| PHP version | `composer.json` -> `require.php` | 8.3 |
| Laravel version | `composer.json` -> `require.laravel/framework` | shown for info only, does not change the Dockerfile |
| Node version | `.nvmrc`, then `package.json` -> `engines.node`, then Vite version | 20 (or 18 if using an older Vite) |
| Frontend build stage | Presence of `package.json` | skipped entirely if no `package.json` |
| Database driver | `.env.example` -> `DB_CONNECTION` | sqlite |
| Redis | `.env.example` drivers, or `predis/predis` in `composer.json` | not included |

## Customizing after generation

The generated files are a normal starting point, not a locked black box. Feel
free to open `Dockerfile`, `docker/nginx.conf`, `docker/supervisord.conf`, or
`docker/start.sh` afterward and edit them by hand for anything specific to
your project, like:

* Queue workers (`php artisan queue:work`)
* Extra PHP extensions
* A different exposed port
* Environment specific startup steps

## What this does not do

* It does not manage deployment (Render, Fly.io, AWS, etc). It only generates
  the Dockerfile and the files it needs.
* It does not create a `docker-compose.yml`. It focuses on the application
  image itself.
* It does not detect every possible Laravel setup. Uncommon or heavily
  customized projects may need manual tweaks after generation.

## License

MIT
