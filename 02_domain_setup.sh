# ===== 변수 =====
DOMAIN="example.com"
WDOMAIN="www.example.com"
DOCROOT="/var/www/html/${DOMAIN}"

# ===== Apache 켜기 =====
sudo systemctl enable --now httpd

# ===== 포트 80 vhost (없으면 생성) =====
if [ ! -f "/etc/httpd/conf.d/${DOMAIN}.conf" ]; then
sudo tee /etc/httpd/conf.d/${DOMAIN}.conf >/dev/null <<CONF
<VirtualHost *:80>
ServerName ${DOMAIN}
ServerAlias ${WDOMAIN}
DocumentRoot ${DOCROOT}
ErrorLog  /var/log/httpd/${DOMAIN}_error.log
CustomLog /var/log/httpd/${DOMAIN}_access.log combined
</VirtualHost>
CONF
sudo apachectl configtest && sudo systemctl reload httpd
fi

# ===== 인증서 발급 (Apache 플러그인) =====
# (DNS A레코드가 이 EC2 퍼블릭 IP를 가리키고 있어야 함)
sudo certbot-3 --apache -d "$DOMAIN" -d "$WDOMAIN"

# ===== systemd timer 설치 =====
# 서비스 파일
sudo tee /etc/systemd/system/certbot-renew.service >/dev/null <<'EOF'
[Unit]
Description=Renew Let's Encrypt certificates

[Service]
Type=oneshot
ExecStart=/usr/bin/certbot-3 renew --quiet --deploy-hook "/usr/bin/systemctl reload httpd"
EOF

# 타이머 파일
sudo tee /etc/systemd/system/certbot-renew.timer >/dev/null <<'EOF'
[Unit]
Description=Run certbot twice a day

[Timer]
OnCalendar=*-*-* 00,12:00:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

# 활성화 및 시작
sudo systemctl daemon-reload
sudo systemctl enable --now certbot-renew.timer

# ===== 갱신 시 Apache 자동 reload 훅 설치 =====
sudo mkdir -p /etc/letsencrypt/renewal-hooks/deploy
sudo tee /etc/letsencrypt/renewal-hooks/deploy/00-reload-httpd.sh >/dev/null <<'SH'
#!/bin/bash
# Let’s Encrypt 갱신 후 Apache 설정 재적용
/usr/bin/systemctl reload httpd
SH
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/00-reload-httpd.sh

# ===== systemd timer 활성화 (패키지에 따라 이름이 다를 수 있어 둘 다 처리) =====
if systemctl list-unit-files | grep -q '^certbot-renew.timer'; then
sudo systemctl enable --now certbot-renew.timer
elif systemctl list-unit-files | grep -q '^certbot.timer'; then
sudo systemctl enable --now certbot.timer
fi

# ===== 타이머 동작 확인(있으면 목록에 나옴) =====
systemctl list-timers '*certbot*' || true

# ===== 드라이런(실제 갱신 시뮬레이션) =====
sudo certbot-3 renew --dry-run

# ===== 퍼블리싱 적용 =====
sudo mkdir ${DOCROOT}
sudo vi "${DOCROOT}/index.html"