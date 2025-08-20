#!/usr/bin/env bash
# Apache (httpd) 재시작 실패 원인 자동 진단
# - 설정 문법/라인, 인증서 파일/키 매칭, mTLS(SSLVerifyClient) 구성, 모듈, 포트 점유, SELinux, 최근 로그
# - 시스템 변경 없음 (read-only)

set -u
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'
ok(){   echo "${GRN}✔${NC} $*"; }
warn(){ echo "${YLW}⚠${NC} $*"; }
bad(){  echo "${RED}✘${NC} $*"; }

bin_httpd=$(command -v httpd || true)
bin_apachectl=$(command -v apachectl || true)
[[ -z "$bin_httpd" && -z "$bin_apachectl" ]] && { echo "httpd/apachectl not found"; exit 1; }

echo "${BLD}${BLU}== 1) 설정 문법 검사 (apachectl configtest) ==${NC}"
if out=$($bin_apachectl configtest 2>&1); then
  ok "Syntax OK"
else
  bad "구문 오류: 아래 메시지의 파일:라인을 수정하세요"
  echo "$out"
fi
echo

echo "${BLD}${BLU}== 2) 로드된 모듈 확인 ==${NC}"
mods="$($bin_httpd -M 2>/dev/null || $bin_apachectl -M 2>/dev/null || true)"
echo "$mods" | grep -q 'ssl_module' && ok "mod_ssl 로드됨" || bad "mod_ssl 미로딩 → mod_ssl 설치/로드 필요"
echo "$mods" | grep -q 'headers_module' && ok "mod_headers 로드됨" || warn "mod_headers 미로딩 (HSTS/헤더 사용 시 필요)"
echo "$mods" | grep -q 'remoteip_module' && ok "mod_remoteip 로드됨" || warn "mod_remoteip 미로딩 (실제 클라이언트 IP 복원 시 필요)"
echo

echo "${BLD}${BLU}== 3) 443 가상호스트/중복/포트 점유 확인 ==${NC}"
$bin_apachectl -S 2>/dev/null | sed 's/^/  /' || warn "apachectl -S 실행 불가"
echo
ss -lntp 2>/dev/null | grep ':443' && ok "포트 443 리스닝 프로세스 있음(정상 또는 다른 프로세스 점유)" || warn "현재 443 리스닝 없음(서비스 중지 상태일 수 있음)"
echo

echo "${BLD}${BLU}== 4) 인증서/키 경로 및 키-인증서 매칭 검사 ==${NC}"
# 모든 conf에서 SSL 파일 경로 수집
mapfile -t certs < <(grep -RhoE '^\s*SSLCertificate(File|ChainFile)\s+[^ ]+' /etc/httpd 2>/dev/null | awk '{print $2}' | sort -u)
mapfile -t keys  < <(grep -RhoE '^\s*SSLCertificateKeyFile\s+[^ ]+'       /etc/httpd 2>/dev/null | awk '{print $2}' | sort -u)

check_file(){
  local f="$1" lbl="$2"
  if [[ -z "$f" ]]; then return; fi
  if [[ -f "$f" ]]; then
    ok "$lbl 파일 존재: $f"
    if [[ "$lbl" == "인증서" ]]; then
      # 인증서 SAN/Subject도 간단히 보여줌
      subj=$(openssl x509 -in "$f" -noout -subject 2>/dev/null | sed 's/^/    /')
      san=$(openssl x509 -in "$f" -noout -ext subjectAltName 2>/dev/null | sed 's/^/    /' | head -n 5)
      echo "${DIM}$subj${NC}"
      [[ -n "$san" ]] && echo "${DIM}$san${NC}"
    fi
  else
    bad "$lbl 파일 없음: $f"
  fi
}

for c in "${certs[@]}"; do check_file "$c" "인증서"; done
for k in "${keys[@]}";  do check_file "$k" "개인키";  done

# 키-인증서 페어 간단 매칭 (동일 디렉토리 단위로 추정)
pair_check(){
  local cert="$1" key="$2"
  [[ -f "$cert" && -f "$key" ]] || return
  local cm km
  cm=$(openssl x509 -noout -modulus -in "$cert" 2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')
  km=$(openssl pkey -noout -modulus -in "$key"  2>/dev/null | openssl md5 2>/dev/null | awk '{print $2}')
  if [[ -n "$cm" && -n "$km" ]]; then
    if [[ "$cm" == "$km" ]]; then
      ok "키-인증서 매칭 OK: $(basename "$cert") ↔ $(basename "$key")"
    else
      bad "키-인증서 불일치: $(basename "$cert") ↔ $(basename "$key")"
    fi
  fi
}

# 간단 매칭 시도: 같은 디렉토리에 있는 가장 가까운 cert/key를 매칭
for c in "${certs[@]}"; do
  dir=$(dirname "$c")
  for k in "${keys[@]}"; do
    [[ "$(dirname "$k")" == "$dir" ]] && pair_check "$c" "$k"
  done
done
echo

echo "${BLD}${BLU}== 5) mTLS(Authenticated Origin Pulls) 설정 누락 점검 ==${NC}"
# SSLVerifyClient require 가 있는데 SSLCACertificateFile/Path가 없거나 파일이 없으면 실패
mtls_conf=$(grep -RnlE '^\s*SSLVerifyClient\s+require' /etc/httpd 2>/dev/null || true)
if [[ -n "$mtls_conf" ]]; then
  echo "mTLS 강제 감지됨: $mtls_conf"
  ca_file=$(grep -RhoE '^\s*SSLCACertificateFile\s+[^ ]+' /etc/httpd 2>/dev/null | awk '{print $2}' | head -n1)
  if [[ -z "$ca_file" ]]; then
    bad "SSLVerifyClient require 사용하지만 SSLCACertificateFile 설정이 없음 → Origin Pulls CA 파일 경로 추가 필요"
  else
    if [[ -f "$ca_file" ]]; then
      ok "SSLCACertificateFile 존재: $ca_file"
      # 간단 유효성 체크
      openssl x509 -in "$ca_file" -noout -subject >/dev/null 2>&1 && ok "CA 파일 파싱 OK" || bad "CA 파일 파싱 실패: $ca_file"
    else
      bad "SSLCACertificateFile 경로에 파일이 없음: $ca_file"
    fi
  fi
else
  echo "mTLS 강제 설정(SSLVerifyClient require) 없음"
fi
echo

echo "${BLD}${BLU}== 6) SELinux 컨텍스트/퍼미션 힌트 ==${NC}"
getenforce >/dev/null 2>&1 && sel=$(getenforce) || sel="unknown"
echo "SELinux: $sel"
# /etc/ssl, /etc/pki/tls 경로 권장. 컨텍스트가 이상하면 restorecon 안내
for d in /etc/ssl/cf-origin /etc/pki/tls /etc/httpd; do
  [[ -d "$d" ]] && echo "  $(ls -ld "$d")"
done
echo "  권장: 인증서 디렉터리는 root:root, 파일 권한 600/640; 컨텍스트 이상 시 → sudo restorecon -Rv /etc/ssl/cf-origin"
echo

echo "${BLD}${BLU}== 7) 최근 에러 로그 출력 (상위 80줄) ==${NC}"
if command -v journalctl >/dev/null 2>&1; then
  journalctl -xeu httpd.service --no-pager | tail -n 80
else
  # 파일 로그 경로 추정
  for f in /var/log/httpd/error_log /var/log/apache2/error.log; do
    [[ -f "$f" ]] && { echo "log: $f"; tail -n 80 "$f"; }
  done
fi

echo
echo "${BLD}${BLU}== 8) 요약 가이드 ==${NC}"
echo "• 파일 없음/오타 → SSLCertificateFile/KeyFile 경로 수정"
echo "• 키-인증서 불일치 → 올바른 Origin Cert/Private Key로 교체"
echo "• mTLS require + CA 미지정 → SSLCACertificateFile에 Origin Pulls CA 설정 또는 require 해제"
echo "• mod_ssl 미로딩 → mod_ssl 설치/로드 후 재시작"
echo "• HSTS/헤더 사용 시 headers_module 필요"
echo "• 포트 충돌 시 :443 점유 프로세스 종료/조정"
