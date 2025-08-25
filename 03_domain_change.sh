#!/usr/bin/env bash
set -euo pipefail

# ====== 설정 ======
# 지우려는 기존 도메인(예: example.com)
OLD_DOMAIN="skawkdnsehdghk.shop"
OLD_WDOMAIN="www.${OLD_DOMAIN}"
OLD_DOCROOT="/var/www/html/${OLD_DOMAIN}"

# 80 vhost 파일명(초기에 네가 만든 그 파일)
VHOST80_CONF="/etc/httpd/conf.d/${OLD_DOMAIN}.conf"

# certbot cert-name은 대개 최초 입력한 도메인명과 동일
# (라인리지 디렉토리가 있으면 그 이름을 우선 사용)
CERT_NAME="${OLD_DOMAIN}"
if [ -d "/etc/letsencrypt/live/${OLD_DOMAIN}" ]; then
  CERT_NAME="${OLD_DOMAIN}"
elif [ -d "/etc/letsencrypt/live/${OLD_WDOMAIN}" ]; then
  CERT_NAME="${OLD_WDOMAIN}"
fi

echo ">> 타겟 인증서 이름(lineage): ${CERT_NAME}"

# ====== 0) 현재 보유 인증서 목록 확인(참고용) ======
sudo certbot-3 certificates || true

# ====== 1) (선택) 인증서 폐기(revoke)
# 키 유출/보안 사고 등 '실제 폐기'가 필요할 때만 사용.
sudo certbot-3 revoke --cert-name "${CERT_NAME}" --reason keycompromise --non-interactive || true

# ====== 2) 인증서 라인리지 삭제(delete)
# live/, archive/, renewal/*.conf 에서 해당 라인리지를 제거
sudo certbot-3 delete --cert-name "${CERT_NAME}" --non-interactive || {
  echo "certbot delete 실패 또는 해당 cert-name 미존재. 수동 확인 필요.";
}

# ====== 3) Apache SSL vhost 정리
# certbot --apache가 만든 SSL vhost는 대체로 '-le-ssl.conf'로 생성됨
SSL_CONF_CANDIDATES=(
  "/etc/httpd/conf.d/${OLD_DOMAIN}-le-ssl.conf"
  "/etc/httpd/conf.d/${CERT_NAME}-le-ssl.conf"
  "/etc/httpd/conf.d/ssl-${OLD_DOMAIN}.conf"
)
for f in "${SSL_CONF_CANDIDATES[@]}"; do
  if [ -f "$f" ]; then
    echo ">> SSL vhost 제거: $f"
    sudo rm -f "$f"
  fi
done

# ====== 4) 80 vhost 원복/정리
# certbot가 80 포트 vhost에 리다이렉트 블록을 끼워넣었다면,
# 가장 깔끔한 방법은 원하는 내용으로 재작성하는 것.
sudo tee "${VHOST80_CONF}" >/dev/null <<CONF
<VirtualHost *:80>
ServerName ${OLD_DOMAIN}
ServerAlias ${OLD_WDOMAIN}
DocumentRoot ${OLD_DOCROOT}
<Directory "${OLD_DOCROOT}">
  AllowOverride All
  Require all granted
</Directory>
ErrorLog  /var/log/httpd/${OLD_DOMAIN}_error.log
CustomLog /var/log/httpd/${OLD_DOMAIN}_access.log combined
</VirtualHost>
CONF

# ====== 5) Apache 설정 검사 및 재적용
sudo apachectl configtest
sudo systemctl reload httpd

# ====== 6) certbot 타이머 처리(선택)
# - 이 인스턴스에 다른 인증서가 하나도 없다면 타이머를 꺼도 됨
# - 다른 도메인도 갱신해야 한다면 '유지'하세요
REMAINING_CERTS=$(sudo find /etc/letsencrypt/live -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l || echo 0)
if [ "${REMAINING_CERTS}" -eq 0 ]; then
  if systemctl list-unit-files | grep -q '^certbot-renew.timer'; then
    echo ">> certbot-renew.timer 비활성화"
    sudo systemctl disable --now certbot-renew.timer || true
  elif systemctl list-unit-files | grep -q '^certbot.timer'; then
    echo ">> certbot.timer 비활성화"
    sudo systemctl disable --now certbot.timer || true
  fi
fi

# ====== 7) 상태 출력
echo
echo "==== 정리 완료 ===="
echo "- 삭제 대상 cert-name: ${CERT_NAME}"
echo "- 남아있는 인증서 수: ${REMAINING_CERTS}"
echo "- 현재 certbot 타이머:"
systemctl list-timers '*certbot*' || true
