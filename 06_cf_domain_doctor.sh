#!/usr/bin/env bash
# cf_domain_doctor.sh — Cloudflare 연결·SSL 진단 (여러 도메인 지원)
# 사용법:
#   ./cf_domain_doctor.sh [--fix-ca] domain1 [domain2 ...]
#   ORIGIN_IP=<오리진IP> ./cf_domain_doctor.sh domain
# 특징:
#   - whois 없으면 자동 설치(패키지 관리자 자동 탐지)
#   - IPv4/IPv6 경로, 엣지/오리진 인증서, SAN, 리다이렉트, NS/DS/CAA 점검
#   - curl 'SSL certificate problem' 감지 → 가이드, --fix-ca 지정 시 자동 갱신 후 재시도

set -euo pipefail
RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; BLD=$'\e[1m'; DIM=$'\e[2m'; NC=$'\e[0m'
ok(){   echo "${GRN}✔${NC} $*"; }
warn(){ echo "${YLW}⚠${NC} $*"; }
bad(){  echo "${RED}✘${NC} $*"; }

need(){ command -v "$1" >/dev/null 2>&1 || { bad "필요 명령어 없음: $1"; exit 1; }; }
for b in dig curl openssl awk grep sed; do need "$b"; done

# ---- 옵션 파싱 ----
DO_FIX_CA=0
if [[ "${1:-}" == "--fix-ca" || "${1:-}" == "--ensure-ca" ]]; then
  DO_FIX_CA=1
  shift
fi

# ---- whois 자동 설치 ----
install_whois() {
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf -y install whois
  elif command -v yum >/dev/null 2>&1; then
    sudo yum -y install whois
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y whois
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add --no-cache whois
  elif command -v zypper >/dev/null 2>&1; then
    sudo zypper -n in whois
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm whois
  elif command -v brew >/dev/null 2>&1; then
    brew install whois
  else
    return 1
  fi
}
ensure_whois() {
  if ! command -v whois >/dev/null 2>&1; then
    echo "whois 가 없어 설치를 시도합니다..."
    if install_whois; then
      ok "whois 설치 완료"
    else
      warn "whois 자동 설치 실패 — whois 없이도 제한적으로 계속 진행합니다."
    fi
  fi
}
ensure_whois
HAVE_WHOIS=0; command -v whois >/dev/null 2>&1 && HAVE_WHOIS=1
HAVE_GETENT=0; command -v getent >/dev/null 2>&1 && HAVE_GETENT=1

# ---- 편의 변수 ----
ORIGIN_IP="${ORIGIN_IP:-}"
[[ -z "$ORIGIN_IP" ]] && ORIGIN_IP="$(curl -s --max-time 3 http://checkip.amazonaws.com || true)"

# ---- CA store update helpers ----
print_ca_update_hints() {
  echo "권장 조치: 시스템 CA 신뢰 저장소가 오래되었을 수 있습니다."
  echo "  - Amazon/RHEL 계열:  sudo dnf -y upgrade ca-certificates openssl nss curl; sudo update-ca-trust extract || true"
  echo "  - CentOS7/RHEL7:     sudo yum -y update ca-certificates openssl nss; sudo update-ca-trust enable; sudo update-ca-trust extract"
  echo "  - Debian/Ubuntu:     sudo apt-get update -y && sudo apt-get install --reinstall -y ca-certificates && sudo update-ca-certificates -f"
  echo "  - Alpine:            sudo apk add --no-cache ca-certificates && sudo update-ca-certificates"
}
auto_fix_ca_store() {
  [[ $DO_FIX_CA -ne 1 ]] && return 0
  echo "CA 신뢰 저장소/ TLS 스택 자동 갱신을 시도합니다 (--fix-ca 지정됨)…"
  if command -v dnf >/dev/null 2>&1; then
    sudo dnf -y upgrade ca-certificates openssl nss curl || true
    sudo update-ca-trust extract || true
  elif command -v yum >/dev/null 2>&1; then
    sudo yum -y update ca-certificates openssl nss curl || true
    sudo update-ca-trust enable || true
    sudo update-ca-trust extract || true
  elif command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y
    sudo apt-get install --reinstall -y ca-certificates || true
    sudo apt-get -y install openssl curl || true
    sudo update-ca-certificates -f || true
  elif command -v apk >/dev/null 2>&1; then
    sudo apk add --no-cache ca-certificates openssl curl || true
    sudo update-ca-certificates || true
  else
    warn "자동 갱신 미지원 패키지 관리자. 수동으로 갱신하세요."
    print_ca_update_hints
  fi
}

# ---- Cloudflare 대역 판별(IPv4/IPv6) ----
is_cf_ipv4(){
  local ip="$1"
  [[ "$ip" =~ ^173\.245\.(4[8-9]|5[0-9]|6[0-3])\. ]] && return 0
  [[ "$ip" =~ ^103\.21\.24[4-7]\. ]] && return 0
  [[ "$ip" =~ ^103\.22\.20[0-3]\. ]] && return 0
  [[ "$ip" =~ ^103\.31\.[4-7]\. ]] && return 0
  [[ "$ip" =~ ^141\.101\.(6[4-9]|[78][0-9]|9[0-9]|1[01][0-9]|12[0-7])\. ]] && return 0
  [[ "$ip" =~ ^108\.162\.(19[2-9]|2[0-4][0-9]|25[0-5])\. ]] && return 0
  [[ "$ip" =~ ^190\.93\.(24[0-9]|25[0-5])\. ]] && return 0
  [[ "$ip" =~ ^188\.114\.(9[6-9]|10[0-9]|11[0-1])\. ]] && return 0
  [[ "$ip" =~ ^197\.234\.24[0-3]\. ]] && return 0
  [[ "$ip" =~ ^198\.41\.(12[8-9]|1[3-9][0-9]|2[0-4][0-9]|25[0-5])\. ]] && return 0
  [[ "$ip" =~ ^162\.(158|159)\. ]] && return 0
  [[ "$ip" =~ ^172\.(6[4-9]|7[0-1])\. ]] && return 0
  [[ "$ip" =~ ^131\.0\.(7[2-5])\. ]] && return 0
  [[ "$ip" =~ ^104\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
  return 1
}
is_cf_ipv6(){
  local ip="$1"
  [[ "$ip" =~ ^2400:cb00: ]] && return 0
  [[ "$ip" =~ ^2606:4700: ]] && return 0
  [[ "$ip" =~ ^2803:f800: ]] && return 0
  [[ "$ip" =~ ^2405:b500: ]] && return 0
  [[ "$ip" =~ ^2405:8100: ]] && return 0
  [[ "$ip" =~ ^2a06:98c[0-9a-f]: ]] && return 0
  [[ "$ip" =~ ^2c0f:f248: ]] && return 0
  return 1
}

cf_ip_owner(){
  local ip="$1"
  if [[ "$ip" =~ : ]]; then
    if [[ $HAVE_WHOIS -eq 1 ]]; then
      local who; who="$(whois "$ip" 2>/dev/null | tr -d '\r' || true)"
      echo "$who" | grep -qi 'Cloudflare' && { echo "CF"; return; }
      is_cf_ipv6 "$ip" && echo "CF" || echo "OTHER"
    else
      is_cf_ipv6 "$ip" && echo "CF" || echo "OTHER"
    fi
  else
    if [[ $HAVE_WHOIS -eq 1 ]]; then
      local who; who="$(whois "$ip" 2>/dev/null | tr -d '\r' || true)"
      echo "$who" | grep -qi 'Cloudflare' && echo "CF" || echo "OTHER"
    else
      is_cf_ipv4 "$ip" && echo "CF" || echo "OTHER"
    fi
  fi
}

edge_request(){ curl -sI --max-time 15 "https://$1" 2>&1; }
http_request(){ curl -sI --max-time 15 "http://$1" 2>&1; }
origin_head(){ curl -kIs --max-time 15 --resolve "$1:443:$2" "https://$1" 2>&1; }
origin_cert_dump(){
  openssl s_client -connect "$2:443" -servername "$1" -showcerts </dev/null 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>/dev/null
}
pick_cf_ip_v4(){
  local d="$1" ip
  while read -r ip; do
    [[ -z "$ip" ]] && continue
    [[ "$(cf_ip_owner "$ip")" == "CF" ]] && { echo "$ip"; return 0; }
  done < <(dig A "$d" +short)
  dig A "$d" +short | head -n1
}

hosts_override_check(){
  local d="$1"
  if grep -n "[[:space:]]$d" /etc/hosts >/dev/null 2>&1; then
    warn "/etc/hosts에 $d 매핑이 존재:"
    grep -n "[[:space:]]$d" /etc/hosts | sed 's/^/   /'
  fi
  if [[ $HAVE_GETENT -eq 1 ]]; then
    local hs; hs="$(getent hosts "$d" || true)"
    [[ -n "$hs" ]] && echo "해석 결과(getent):" && echo "$hs" | sed 's/^/  /'
  fi
}

ipv4_ipv6_tests(){
  local d="$1"
  local A AAAA; A="$(dig A "$d" +short | paste -sd' ')" ; AAAA="$(dig AAAA "$d" +short | paste -sd' ')"
  echo "A 레코드  : ${DIM}${A:-none}${NC}"
  echo "AAAA 레코드: ${DIM}${AAAA:-none}${NC}"

  if [[ -n "$A" ]]; then
    for ip in $A; do
      [[ "$(cf_ip_owner "$ip")" == "CF" ]] \
        && ok "A $ip (Cloudflare anycast)" \
        || warn "A $ip (Cloudflare 아님 — DNS only 추정)"
    done
  fi
  if [[ -n "$AAAA" ]]; then
    for ip in $AAAA; do
      [[ "$(cf_ip_owner "$ip")" == "CF" ]] \
        && ok "AAAA $ip (Cloudflare anycast)" \
        || warn "AAAA $ip (Cloudflare 아님 — 회색/직결 가능성)"
    done
  fi

  local v4 v6 code4 server4 ray4 code6 server6 ray6
  v4="$(curl -4sI --max-time 15 "https://$d" 2>&1 || true)"
  v6="$(curl -6sI --max-time 15 "https://$d" 2>&1 || true)"

  code4="$(echo "$v4" | awk '/^HTTP\//{print $2; exit}')"
  server4="$(echo "$v4" | awk 'tolower($0) ~ /^server:/ {print $2}' | tr -d "\r")"
  ray4="$(echo "$v4" | awk 'tolower($0) ~ /^cf-ray:/ {print $2}' | tr -d "\r")"
  if [[ -n "$code4" ]]; then
    echo "IPv4 HTTPS 코드: ${BLD}${code4}${NC}  (${DIM}Server:${server4:-?} CF-RAY:${ray4:- -}${NC})"
    [[ "$server4" =~ [Cc]loudflare ]] && ok "IPv4 경로: Cloudflare 경유" || warn "IPv4 경로: Cloudflare 헤더 미발견"
  else
    warn "IPv4 경로: 응답 없음/실패 (${DIM}${v4##*$'\n'}${NC})"
  fi

  code6="$(echo "$v6" | awk '/^HTTP\//{print $2; exit}')"
  server6="$(echo "$v6" | awk 'tolower($0) ~ /^server:/ {print $2}' | tr -d "\r")"
  ray6="$(echo "$v6" | awk 'tolower($0) ~ /^cf-ray:/ {print $2}' | tr -d "\r")"
  if [[ -n "$code6" ]]; then
    echo "IPv6 HTTPS 코드: ${BLD}${code6}${NC}  (${DIM}Server:${server6:-?} CF-RAY:${ray6:- -}${NC})"
    [[ "$server6" =~ [Cc]loudflare ]] && ok "IPv6 경로: Cloudflare 경유" || warn "IPv6 경로: Cloudflare 헤더 미발견"
  else
    warn "IPv6 경로: 실패/비활성 (서버의 IPv6 아웃바운드 미구성일 수 있음)"
  fi
}

edge_cert_chain_via_cfip(){
  local d="$1" cfip out
  cfip="$(pick_cf_ip_v4 "$d")"
  [[ -z "$cfip" ]] && { warn "CF IP 선택 실패 — 엣지 체인 확인 건너뜀"; return; }
  out="$(openssl s_client -connect "${cfip}:443" -servername "$d" -showcerts </dev/null 2>/dev/null \
        | awk '/subject=|issuer=|Verify return code/ {print}')"
  echo "엣지 인증서(Cloudflare IP ${cfip} 경유):"
  echo "  ${DIM}${out//$'\n'/$'\n  '}${NC}"
  echo "$out" | grep -q 'Verify return code: 0 (ok)' \
    && ok "엣지 인증서 체인: 공인 CA로 정상" \
    || bad "엣지 인증서 체인 검증 실패 → Edge Certificates(Universal SSL) 확인 필요"
}

diagnose(){
  local D="$1"
  echo; echo "${BLD}${BLU}==== $D ==== ${NC}"

  hosts_override_check "$D"

  local NS DS CAA
  NS="$(dig NS "$D" +short | sort -u)"
  DS="$(dig DS "$D" +short || true)"
  CAA="$(dig CAA "$D" +short || true)"

  if echo "$NS" | grep -qi 'ns.cloudflare.com'; then ok "NS 위임: Cloudflare (${DIM}${NS}${NC})"
  else bad "NS 위임: Cloudflare 아님 → 레지스트라에서 CF 네임서버로 교체 필요 (${DIM}${NS:-none}${NC})"; fi
  [[ -n "$DS"  ]] && warn "DNSSEC(DS) 존재: Universal SSL 발급/적용 영향 가능\n${DIM}$DS${NC}" || ok "DNSSEC(DS) 없음"
  [[ -n "$CAA" ]] && warn "CAA 존재: Universal SSL 발급 차단 가능 → 제거/허용 필요(letsEncrypt/digicert/pki.goog)\n${DIM}$CAA${NC}" || ok "CAA 없음"

  ipv4_ipv6_tests "$D"

  # 엣지 요청 + 에러60 감지/자동수정(옵션)
  local EH CODE SERVER CFRAY CFCACHE
  EH="$(edge_request "$D")"
  if echo "$EH" | grep -qi 'SSL certificate problem: unable to get local issuer certificate'; then
    bad "curl: SSL certificate problem (local issuer) → 로컬 CA 신뢰 저장소가 오래됨/손상 의심"
    print_ca_update_hints
    auto_fix_ca_store
    EH="$(edge_request "$D")"   # 재시도
  fi

  CODE="$(echo "$EH" | awk '/^HTTP\// {code=$2} END{print code}')"
  SERVER="$(echo "$EH" | awk 'tolower($0) ~ /^server:/ {print $2}' | tr -d '\r')"
  CFRAY="$(echo "$EH" | awk 'tolower($0) ~ /^cf-ray:/ {print $2}' | tr -d '\r')"
  CFCACHE="$(echo "$EH" | awk 'tolower($0) ~ /^cf-cache-status:/ {print $2}' | tr -d '\r')"

  if [[ -n "$CODE" ]]; then
    echo "도메인 HTTPS 코드: ${BLD}$CODE${NC}   (${DIM}Server:${SERVER:-?} CF-RAY:${CFRAY:--} Cache:${CFCACHE:--}${NC})"
    [[ "$SERVER" =~ [Cc]loudflare ]] && ok "엣지 경유 OK(헤더에 cloudflare/CF-RAY)" || warn "엣지 헤더 없음(DNS only 추정)"
    case "$CODE" in
      526) bad "CF 526: 오리진 인증서 Strict 검증 실패 → Origin Cert/도메인 일치 확인" ;;
      525) bad "CF 525: CF↔오리진 TLS 핸드셰이크 실패 → 오리진 443/TLS 확인" ;;
      520|521|522|523|524) bad "CF $CODE: 오리진 연결 문제(웹서버/방화벽/네트워크)" ;;
      403|401|1020|1015)  warn "보안/레이트리밋/룰 차단" ;;
    esac
  else
    echo "$EH" | grep -qi 'handshake failure' \
      && bad "엣지 TLS 핸드셰이크 실패(Universal SSL 미발급/비활성 또는 CAA/DNSSEC)" \
      || bad "엣지 요청 실패: $(echo "$EH" | tail -n1)"
  fi

  edge_cert_chain_via_cfip "$D"

  # http → https 301
  local RH; RH="$(http_request "$D")"
  echo "$RH" | awk '/^HTTP\// {print $2}' | grep -q '^301$' && echo "$RH" | grep -qi '^Location: https://' \
    && ok "HTTP → HTTPS 301 리다이렉트 정상" \
    || warn "HTTP 리다이렉트 비정상/미설정"

  # 오리진 직접 TLS(선택)
  if [[ -n "$ORIGIN_IP" ]]; then
    echo "오리진(직접) 점검: ${DIM}$ORIGIN_IP${NC}"
    local OH OC
    OH="$(origin_head "$D" "$ORIGIN_IP" || true)"
    echo "$OH" | awk '/^HTTP\// {print $2}' | grep -q '^[0-9][0-9][0-9]$' \
      && ok "오리진 443 응답 수신(Origin Cert일 경우 검증 생략)" \
      || warn "오리진 443 응답 불능/핸드셰이크 실패(방화벽/Apache/vhost 확인)"

    OC="$(origin_cert_dump "$D" "$ORIGIN_IP" || true)"
    if [[ -n "$OC" ]]; then
      echo "${DIM}$OC${NC}" | sed 's/^/  /'
      # 올바른 Origin Cert 여부
      if echo "$OC" | grep -qi "CloudFlare Origin Certificate"; then
        ok "오리진 인증서: Cloudflare Origin Cert"
      fi
      # Managed CA 오인 설치 감지
      if echo "$OC" | grep -qi "Managed CA"; then
        bad "오리진에 'Authenticated Origin Pulls'용 Managed CA를 서버 인증서로 사용 중 → Origin Server에서 발급한 cert/key로 교체 필요"
      fi
      # SAN 검사
      if echo "$OC" | grep -qi "DNS:$D"; then
        ok "오리진 인증서 SAN에 $D 포함"
      else
        bad "오리진 인증서 SAN에 $D 미포함 → vhost/인증서 재발급 필요"
      fi
    else
      warn "오리진 인증서 정보를 가져오지 못함(포트닫힘/핸드셰이크 실패)"
    fi
  fi

  # 권장 액션 요약
  echo "${DIM}추천 액션:${NC}"
  if ! echo "$NS" | grep -qi 'ns.cloudflare.com'; then
    echo "  - 레지스트라 NS를 Cloudflare 쌍으로 교체(추가 NS/오타/잠금/DNSSEC 점검)"
  fi
  if [[ -z "$CODE" ]]; then
    echo "  - SSL/TLS → Edge Certificates: Universal SSL Enable(토글) / CAA·DNSSEC 제거 후 재시도"
  elif [[ "$CODE" == "526" ]]; then
    echo "  - 오리진(Apache)에 Cloudflare Origin Cert 적용, vhost(ServerName/ServerAlias) 도메인 일치 확인"
  elif [[ "$CODE" == "525" ]]; then
    echo "  - 오리진 443 방화벽/보안그룹 허용, TLS 설정(TLS1.2+, mod_ssl) 확인"
  fi
}

# ---- main ----
if [[ "$#" -lt 1 ]]; then
  echo "사용법: $0 [--fix-ca] domain1 [domain2 ...]"
  exit 1
fi

for dom in "$@"; do diagnose "$dom"; done
