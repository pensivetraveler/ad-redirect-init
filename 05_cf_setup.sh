CF_DOMAIN="example.com"
DOC_ROOT="/var/www/html/${CF_DOMAIN}"

######## 1. pem, key 파일 생성
sudo mkdir -p /etc/ssl/cf-origin
sudo vi "/etc/ssl/cf-origin/${CF_DOMAIN}.pem"
sudo vi "/etc/ssl/cf-origin/${CF_DOMAIN}.key"
sudo chmod 600 "/etc/ssl/cf-origin/${CF_DOMAIN}.key"

######## 2. mod_ssl 활성화
sudo dnf -y install mod_ssl
sudo sed -n '1,120p' /etc/httpd/conf.modules.d/00-base.conf >/dev/null 2>&1 || true
# 보통 mod_rewrite, mod_headers는 기본 포함. 부족하면 아래 활성화.
# (배포판에 따라 a2enmod가 아닌 수동 로드로 이미 활성화되어 있음)
sudo systemctl restart httpd

######## 3. vhost 수정
sudo tee "/etc/httpd/conf.d/${CF_DOMAIN}.conf" >/dev/null <<CONF
<VirtualHost *:80>
ServerName ${CF_DOMAIN}
ServerAlias www.${CF_DOMAIN}
DocumentRoot /var/www/html/${CF_DOMAIN}
ErrorLog  /var/log/httpd/${CF_DOMAIN}_error.log
CustomLog /var/log/httpd/${CF_DOMAIN}_access.log combined
RewriteEngine on
RewriteCond %{SERVER_NAME} =www.${CF_DOMAIN}.shop [OR]
RewriteCond %{SERVER_NAME} =${CF_DOMAIN}
RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
</VirtualHost>
CONF

######## 4. ssl vhost 수정
sudo tee "/etc/httpd/conf.d/${CF_DOMAIN}-le-ssl.conf" >/dev/null <<CONF
<IfModule mod_ssl.c>
<VirtualHost *:443>
ServerName ${CF_DOMAIN}
ServerAlias www.${CF_DOMAIN}
DocumentRoot /var/www/html/${CF_DOMAIN}

SSLEngine on
SSLCertificateFile      /etc/ssl/cf-origin/${CF_DOMAIN}.pem
SSLCertificateKeyFile   /etc/ssl/cf-origin/${CF_DOMAIN}.key

# (선택) 보안 헤더
Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
</VirtualHost>
</IfModule>
CONF

######## 5. conf.d 에 추가 conf 생성
sudo tee "/etc/httpd/conf.d/remoteip-cloudflare.conf" >/dev/null <<CONF
RemoteIPHeader CF-Connecting-IP

# Cloudflare 공개 CIDR 추가(정기 업데이트 필요)
# 예시:
# RemoteIPTrustedProxy 173.245.48.0/20
# RemoteIPTrustedProxy 103.21.244.0/22
# RemoteIPTrustedProxy 103.22.200.0/22
# ... (Cloudflare가 공개하는 모든 범위)

sudo apachectl configtest
sudo systemctl restart httpd
CONF