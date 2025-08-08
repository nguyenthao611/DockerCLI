#!/usr/bin/env bash
set -euo pipefail

# ======== CLI ARGS ========
DOMAIN=""
LE_EMAIL=""
WITH_PHPMYADMIN="no"   # yes|no
DB_ROOT_PASSWORD=""
DB_NAME="mydb"
DB_USER="myuser"
DB_PASSWORD="mypassword"

usage() {
  cat <<EOF
Usage:
  bash $0 --domain example.com --email you@example.com [--with-pma yes] [--db-name mydb] [--db-user myuser] [--db-password mypass] [--db-root rootpass]

Options:
  --domain        (bắt buộc) Domain chính cho site PHP
  --email         (bắt buộc) Email nhận cảnh báo SSL (Let's Encrypt)
  --with-pma      Bật phpMyAdmin cho pma.<domain> (mặc định: no)
  --db-name       Tên database (mặc định: mydb)
  --db-user       User DB (mặc định: myuser)
  --db-password   Password DB (mặc định: mypassword)
  --db-root       Root password MySQL (mặc định: random nếu để trống)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) LE_EMAIL="${2:-}"; shift 2 ;;
    --with-pma) WITH_PHPMYADMIN="${2:-no}"; shift 2 ;;
    --db-name) DB_NAME="${2:-mydb}"; shift 2 ;;
    --db-user) DB_USER="${2:-myuser}"; shift 2 ;;
    --db-password) DB_PASSWORD="${2:-mypassword}"; shift 2 ;;
    --db-root) DB_ROOT_PASSWORD="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

[[ -z "$DOMAIN" || -z "$LE_EMAIL" ]] && { usage; exit 1; }

if [[ -z "${DB_ROOT_PASSWORD}" ]]; then
  DB_ROOT_PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20)"
  echo "[INFO] Auto-generated DB_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}"
fi

slug() { echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g'; }
DOMAIN_SLUG="$(slug "$DOMAIN")"

info(){ echo -e "\033[1;32m[INFO]\033[0m $*"; }
warn(){ echo -e "\033[1;33m[WARN]\033[0m $*"; }
err(){  echo -e "\033[1;31m[ERR]\033[0m  $*"; }

# ======== INSTALL DOCKER (if missing) ========
if ! command -v docker >/dev/null 2>&1; then
  info "Cài Docker (official repo)…"
  sudo apt update
  sudo apt install -y ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
  info "Docker đã cài xong."
else
  info "Docker đã có: $(docker --version)"
fi

# ======== GLOBAL NETWORK & REVERSE PROXY ========
if ! docker network inspect nginx-proxy >/dev/null 2>&1; then
  info "Tạo docker network 'nginx-proxy'…"
  docker network create nginx-proxy
else
  info "Network 'nginx-proxy' đã tồn tại."
fi

mkdir -p ~/reverse-proxy
cd ~/reverse-proxy

# Compose V2 (không cần version:)
cat > docker-compose.yml <<'YML'
services:
  nginx-proxy:
    image: jwilder/nginx-proxy:latest
    container_name: nginx-proxy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/tmp/docker.sock:ro
      - certs:/etc/nginx/certs:ro
      - vhost:/etc/nginx/vhost.d
      - html:/usr/share/nginx/html
    networks:
      - nginx-proxy

  letsencrypt:
    image: jrcs/letsencrypt-nginx-proxy-companion:latest
    container_name: letsencrypt-nginx
    restart: unless-stopped
    environment:
      - NGINX_PROXY_CONTAINER=nginx-proxy
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - certs:/etc/nginx/certs
      - vhost:/etc/nginx/vhost.d
      - html:/usr/share/nginx/html
    networks:
      - nginx-proxy

volumes:
  certs:
  vhost:
  html:

networks:
  nginx-proxy:
    external: true
YML

# Up reverse proxy (idempotent)
docker compose up -d
info "Reverse proxy chạy OK."

# ======== APP STACK (per domain) ========
APP_DIR=~/"${DOMAIN}"
mkdir -p "${APP_DIR}/src"
cd "${APP_DIR}"

cat > .env <<ENV
LE_EMAIL=${LE_EMAIL}
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
MYSQL_DATABASE=${DB_NAME}
MYSQL_USER=${DB_USER}
MYSQL_PASSWORD=${DB_PASSWORD}
VIRTUAL_HOST=${DOMAIN}
LETSENCRYPT_HOST=${DOMAIN}
ENV

# PHP sample
cat > src/index.php <<'PHP'
<?php
$host = "mysql";
$user = getenv("MYSQL_USER") ?: "myuser";
$pass = getenv("MYSQL_PASSWORD") ?: "mypassword";
$db   = getenv("MYSQL_DATABASE") ?: "mydb";

$mysqli = @new mysqli($host, $user, $pass, $db);
if ($mysqli->connect_errno) {
    http_response_code(500);
    echo "❌ Kết nối MySQL thất bại: " . $mysqli->connect_error;
    exit;
}
echo "✅ Kết nối MySQL thành công!<br>";
$res = $mysqli->query("SELECT NOW() AS server_time");
$row = $res->fetch_assoc();
echo "Server time: " . $row['server_time'];
PHP

# container_name theo domain để tránh trùng
PHP_NAME="php-${DOMAIN_SLUG}"
MYSQL_NAME="mysql-${DOMAIN_SLUG}"
PMA_NAME="pma-${DOMAIN_SLUG}"

# Dockerfile để cài mysqli + pdo_mysql
cat > Dockerfile <<'DOCKER'
FROM php:8.2-apache
# Cài extensions cần cho MySQL
RUN docker-php-ext-install mysqli pdo pdo_mysql \
 && docker-php-ext-enable mysqli pdo_mysql
# (tuỳ chọn) Bật mod_rewrite nếu cần cho frameworks
RUN a2enmod rewrite
DOCKER

# docker-compose.yml với build từ Dockerfile trên
if [[ "${WITH_PHPMYADMIN}" == "yes" ]]; then
  PMA_DOMAIN="pma.${DOMAIN}"
  info "Bật phpMyAdmin tại https://${PMA_DOMAIN}"

  cat > docker-compose.yml <<YML
services:
  php:
    build: .
    container_name: ${PHP_NAME}
    restart: unless-stopped
    environment:
      VIRTUAL_HOST: \${VIRTUAL_HOST}
      LETSENCRYPT_HOST: \${LETSENCRYPT_HOST}
      LETSENCRYPT_EMAIL: \${LE_EMAIL}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
    volumes:
      - ./src:/var/www/html
    networks:
      - nginx-proxy
      - backend
    depends_on:
      - mysql

  mysql:
    image: mysql:8.0
    container_name: ${MYSQL_NAME}
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - dbdata:/var/lib/mysql
    networks:
      - backend

  pma:
    image: phpmyadmin:latest
    container_name: ${PMA_NAME}
    restart: unless-stopped
    environment:
      PMA_HOST: mysql
      VIRTUAL_HOST: ${PMA_DOMAIN}
      LETSENCRYPT_HOST: ${PMA_DOMAIN}
      LETSENCRYPT_EMAIL: \${LE_EMAIL}
    networks:
      - nginx-proxy
      - backend

volumes:
  dbdata:

networks:
  nginx-proxy:
    external: true
  backend:
    driver: bridge
YML

else
  cat > docker-compose.yml <<YML
services:
  php:
    build: .
    container_name: ${PHP_NAME}
    restart: unless-stopped
    environment:
      VIRTUAL_HOST: \${VIRTUAL_HOST}
      LETSENCRYPT_HOST: \${LETSENCRYPT_HOST}
      LETSENCRYPT_EMAIL: \${LE_EMAIL}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
    volumes:
      - ./src:/var/www/html
    networks:
      - nginx-proxy
      - backend
    depends_on:
      - mysql

  mysql:
    image: mysql:8.0
    container_name: ${MYSQL_NAME}
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${MYSQL_DATABASE}
      MYSQL_USER: \${MYSQL_USER}
      MYSQL_PASSWORD: \${MYSQL_PASSWORD}
    volumes:
      - dbdata:/var/lib/mysql
    networks:
      - backend

volumes:
  dbdata:

networks:
  nginx-proxy:
    external: true
  backend:
    driver: bridge
YML
fi

# Build lại PHP image (có mysqli/pdo_mysql) và chạy stack
docker compose build --no-cache
docker compose up -d
info "Stack cho ${DOMAIN} đã chạy."

cat <<DNS

==============================================
📌 TRỎ DNS (A records) về IP server này:
  - ${DOMAIN}
  - pma.${DOMAIN} (nếu --with-pma yes)

Đợi vài phút để Let's Encrypt cấp SSL, rồi truy cập:
  - https://${DOMAIN}
  - https://pma.${DOMAIN}  (user/pass: ${DB_USER} / ${DB_PASSWORD})

Kiểm tra nhanh:
  cd ~/${DOMAIN} && docker compose config   # validate YAML
  docker logs -f nginx-proxy
  docker logs -f letsencrypt-nginx

Quản trị stack domain:
  cd ~/${DOMAIN} && docker compose ps
  cd ~/${DOMAIN} && docker compose restart
  cd ~/${DOMAIN} && docker compose down -v   # (xóa cả DB)
==============================================
DNS
