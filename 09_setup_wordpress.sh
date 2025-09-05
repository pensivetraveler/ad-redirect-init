#!/usr/bin/env bash
set -euo pipefail

# ==========================
# Config (필요시 수정)
# ==========================
WP_DIR="/var/www/wordpress"
WP_DB_NAME="wpdb"
WP_DB_USER="wpuser"
WP_DB_PASS="$(openssl rand -base64 24 | tr -d '\n=')"
# 도메인을 쓰면 ServerName/로그파일 이름에 반영됨(없으면 공백)
WP_DOMAIN="${1:-}"   # 사용: sudo ./setup-wordpress-aws.sh example.com  (없어도 됨)
PHP_TZ="Asia/Seoul"

# ==========================
# OS/패키지 준비
# ==========================
echo "[*] Detecting OS..."
OS_RELEASE="$(cat /etc/os-release || true)"
if echo "$OS_RELEASE" | grep -qi "Amazon Linux 2023"; then
  OS_FAMILY="AL2023"
elif echo "$OS_RELEASE" | grep -qi "Amazon Linux 2"; then
  OS_FAMILY="AL2"
else
  echo "[-] Amazon Linux 2023/2 외 OS 입니다. 중단합니다."
  exit 1
fi
echo "[*] OS detected: $OS_FAMILY"

echo "[*] Updating packages..."
if [ "$OS_FAMILY" = "AL2023" ]; then
  sudo dnf -y update
  sudo dnf -y install httpd mariadb105-server php php-cli php-mysqlnd php-fpm php-gd php-xml php-mbstring php-json unzip tar
else
  # AL2
  sudo yum -y update
  # PHP 최신 채널 활성화(필요 시 버전 변경 가능)
  sudo amazon-linux-extras enable php8.2 2>/dev/null || sudo amazon-linux-extras enable php8.1 2>/dev/null || true
  sudo yum clean metadata
  sudo yum -y install httpd mariadb-server php php-cli php-mysqlnd php-fpm php-gd php-xml php-mbstring php-json unzip tar
fi

# ==========================
# 서비스 활성화/시작
# ==========================
echo "[*] Enabling services..."
sudo systemctl enable --now mariadb
sudo systemctl enable --now httpd

# ==========================
# MariaDB 초기 보안 & DB/USER 생성
# ==========================
echo "[*] Securing MariaDB and creating DB/user..."
# 루트 계정은 소켓 인증으로 접근 가능(초기 비번 없음)
# mysql_secure_installation 비대화 모드와 유사 로직 적용
mysql --protocol=socket -uroot <<'SQL'
-- 현재 사용자 목록 확인(참고)
SELECT user, host FROM mysql.user ORDER BY user, host;

-- 1) 익명 사용자 제거 (있을 때만)
DROP USER IF EXISTS ''@'localhost', ''@'%', ''@'127.0.0.1', ''@'::1';

-- 2) 원격 root 비활성화: 원격 root 계정 자체를 제거
DROP USER IF EXISTS 'root'@'%', 'root'@'::1';

-- 3) test DB 제거
DROP DATABASE IF EXISTS test;
SQL

# 워드프레스용 DB/유저 생성
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS \`$WP_DB_NAME\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$WP_DB_USER'@'localhost' IDENTIFIED BY '$WP_DB_PASS';
GRANT ALL PRIVILEGES ON \`$WP_DB_NAME\`.* TO '$WP_DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL

# 비밀번호 저장
sudo mkdir -p /root/.wp
echo "DB_NAME=$WP_DB_NAME
DB_USER=$WP_DB_USER
DB_PASS=$WP_DB_PASS" | sudo tee /root/.wp/wp-db.env >/dev/null
sudo chmod 600 /root/.wp/wp-db.env

# ==========================
# PHP 기본 설정 (타임존)
# ==========================
PHP_INI="$(php -i | grep -i 'Loaded Configuration File' | awk '{print $5}')"
if [ -z "$PHP_INI" ] || [ ! -f "$PHP_INI" ]; then
  # AL 기본 위치
  if [ -f /etc/php.ini ]; then
    PHP_INI="/etc/php.ini"
  fi
fi
if [ -f "$PHP_INI" ]; then
  echo "[*] Setting PHP timezone to $PHP_TZ in $PHP_INI"
  sudo sed -i "s~^;*date.timezone =.*~date.timezone = $PHP_TZ~" "$PHP_INI"
fi

# ==========================
# 워드프레스 다운로드 & 배치
# ==========================
echo "[*] Downloading WordPress..."
TMPDIR="$(mktemp -d)"
curl -sSL https://wordpress.org/latest.tar.gz -o "$TMPDIR/wp.tgz"
tar -xzf "$TMPDIR/wp.tgz" -C "$TMPDIR"

echo "[*] Deploying to $WP_DIR ..."
sudo mkdir -p "$WP_DIR"
sudo rsync -a "$TMPDIR/wordpress/" "$WP_DIR/"
sudo chown -R apache:apache "$WP_DIR"
sudo find "$WP_DIR" -type d -exec chmod 755 {} \;
sudo find "$WP_DIR" -type f -exec chmod 644 {} \;

# ==========================
# wp-config.php 생성
# ==========================
echo "[*] Creating wp-config.php ..."
sudo cp "$WP_DIR/wp-config-sample.php" "$WP_DIR/wp-config.php"
sudo sed -i "s/database_name_here/$WP_DB_NAME/" "$WP_DIR/wp-config.php"
sudo sed -i "s/username_here/$WP_DB_USER/" "$WP_DIR/wp-config.php"
sudo sed -i "s/password_here/$WP_DB_PASS/" "$WP_DIR/wp-config.php"

# 고유 키/솔트 주입
SALT="$(curl -s https://api.wordpress.org/secret-key/1.1/salt/ || true)"
if [ -n "$SALT" ]; then
  # 기존 placeholder 라인 전체 대체
  sudo awk -v RS= -v ORS= -v SALT="$SALT" '
    {gsub(/define\(.+AUTH_KEY.+\);[\s\S]+?define\(.+NONCE_SALT.+\);/, SALT)}
    {print}
  ' "$WP_DIR/wp-config.php" | sudo tee "$WP_DIR/wp-config.php" >/dev/null
fi
sudo chown apache:apache "$WP_DIR/wp-config.php"
sudo chmod 640 "$WP_DIR/wp-config.php"

# ==========================
# Apache 가상호스트 설정
# ==========================
echo "[*] Configuring Apache vhost ..."
VHOST_FILE="/etc/httpd/conf.d/wordpress.conf"
sudo bash -c "cat > $VHOST_FILE" <<CONF
<VirtualHost *:80>
    $( [ -n "$WP_DOMAIN" ] && echo "ServerName $WP_DOMAIN" )
    DocumentRoot $WP_DIR

    <Directory $WP_DIR>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog /var/log/httpd/wordpress_error.log
    CustomLog /var/log/httpd/wordpress_access.log combined
</VirtualHost>
CONF

# .htaccess용 mod_rewrite 보장
if ! sudo httpd -M 2>/dev/null | grep -q rewrite_module; then
  echo "LoadModule rewrite_module modules/mod_rewrite.so" | sudo tee /etc/httpd/conf.modules.d/rewrite.load >/dev/null
fi

# SELinux 기본 비활성 상태가 일반적이지만, 혹시 대비(무시 가능)
if command -v setsebool >/dev/null 2>&1; then
  sudo setsebool -P httpd_can_network_connect 1 || true
fi

# 방화벽은 EC2 보안그룹에서 처리하는게 일반적이므로 생략

# ==========================
# WP-CLI (선택) 배포
# ==========================
if ! command -v wp >/dev/null 2>&1; then
  echo "[*] Installing WP-CLI ..."
  curl -sSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /tmp/wp-cli.phar
  php /tmp/wp-cli.phar --info >/dev/null
  sudo mv /tmp/wp-cli.phar /usr/local/bin/wp
  sudo chmod +x /usr/local/bin/wp
fi

# 퍼미션 재조정
sudo chown -R apache:apache "$WP_DIR"

echo "[*] Restarting Apache..."
sudo systemctl restart httpd

# ==========================
# 요약 출력
# ==========================
PUB_IP="$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || curl -s ifconfig.me || echo 'EC2-PUBLIC-IP')"
echo ""
echo "=============================================================="
echo " WordPress 설치 완료!"
echo "--------------------------------------------------------------"
echo " Site URL : http://${WP_DOMAIN:-$PUB_IP}/"
echo " DB Name  : $WP_DB_NAME"
echo " DB User  : $WP_DB_USER"
echo " DB Pass  : (아래 파일에 저장) /root/.wp/wp-db.env"
echo " DocumentRoot: $WP_DIR"
[ -n "$WP_DOMAIN" ] && echo " Apache vhost: /etc/httpd/conf.d/wordpress.conf (ServerName $WP_DOMAIN)"
echo " PHP timezone: $PHP_TZ"
echo " 로그: /var/log/httpd/wordpress_error.log , wordpress_access.log"
echo "=============================================================="