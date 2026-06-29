#!/usr/bin/env bash
# check-domain.sh
# Usage:
#   ./check-domain.sh domain.com
#   ./check-domain.sh domain1.com domain2.com
#   ./check-domain.sh domains.txt
#   ./check-domain.sh -s 8.8.8.8 domain.com

DNS_SERVER="223.5.5.5"

while getopts "s:h" opt; do
  case "$opt" in
    s) DNS_SERVER="$OPTARG" ;;
    h)
      echo "Usage: $0 [-s dns_server] domain|domain..."
      exit 0
      ;;
  esac
done
shift $((OPTIND-1))

command -v dig >/dev/null || { echo "请安装 dnsutils(bind-utils)"; exit 1; }
command -v whois >/dev/null || { echo "请安装 whois"; exit 1; }

query() {
    local name="$1"
    local type="$2"
    dig @"$DNS_SERVER" +short "$name" "$type" | paste -sd "," -
}

dns_status() {
    dig @"$DNS_SERVER" "$1" +nocmd +noquestion +nostats \
    | awk '/status:/{gsub(",","",$6);print $6}'
}

status_cn() {
case "$1" in
NOERROR) echo "NOERROR（解析正常）";;
NXDOMAIN) echo "NXDOMAIN（域名不存在/未委派）";;
SERVFAIL) echo "SERVFAIL（DNS故障或DNSSEC异常）";;
REFUSED) echo "REFUSED（DNS拒绝响应）";;
*) echo "$1";;
esac
}

wildcard() {
    local d="$1"
    local r
    r=$(query "chatgpt-check-$RANDOM.$d" A)
    [ -n "$r" ] && echo "是 -> $r" || echo "否"
}

whois_status() {
    whois "$1" 2>/dev/null |
    grep -iE 'Domain Status|Status:' |
    sed -E 's/.*Status:[[:space:]]*//I' |
    head -1
}

check() {
local d="$1"

echo "================================================================================"
echo "域名(Domain)     : $d"
echo "DNS服务器        : $DNS_SERVER"

st=$(dns_status "$d")
echo "DNS状态          : $(status_cn "$st")"

ws=$(whois_status "$d")
[ -z "$ws" ] && ws="-"
echo "WHOIS状态        : $ws"

ns=$(query "$d" NS);     [ -z "$ns" ] && ns="-"
soa=$(query "$d" SOA);   [ -z "$soa" ] && soa="-"
a=$(query "$d" A);       [ -z "$a" ] && a="-"
aaaa=$(query "$d" AAAA); [ -z "$aaaa" ] && aaaa="-"
wwwc=$(query "www.$d" CNAME)
wwwa=$(query "www.$d" A)
if [ -n "$wwwc" ]; then
  www="CNAME -> $wwwc"
elif [ -n "$wwwa" ]; then
  www="$wwwa"
else
  www="-"
fi
mx=$(query "$d" MX); [ -z "$mx" ] && mx="-"
txt=$(query "$d" TXT); [ -z "$txt" ] && txt="-"

dnskey=$(dig @"$DNS_SERVER" +short "$d" DNSKEY)
[ -n "$dnskey" ] && dnssec="已启用" || dnssec="未启用"

echo "NS               : $ns"
echo "SOA              : $soa"
echo "@                : $a"
echo "AAAA             : $aaaa"
echo "WWW              : $www"
echo "MX               : $mx"
echo "TXT              : $txt"
echo "泛解析(Wildcard) : $(wildcard "$d")"
echo "DNSSEC           : $dnssec"

result="正常"
echo "$ws" | grep -qi serverHold && result="注册局暂停解析(serverHold)"
echo "$ws" | grep -qi clientHold && result="注册商暂停解析(clientHold)"
[ "$st" = "SERVFAIL" ] && result="DNS解析失败"
[ "$st" = "NXDOMAIN" ] && [ "$result" = "正常" ] && result="域名不存在或未委派"

echo "最终结果(Result) : $result"
echo
}

if [ $# -eq 0 ]; then
    echo "请指定域名或文件"
    exit 1
fi

if [ $# -eq 1 ] && [ -f "$1" ]; then
    while IFS= read -r line; do
        line=$(echo "$line"|xargs)
        [ -z "$line" ] && continue
        [[ "$line" =~ ^# ]] && continue
        check "$line"
    done < "$1"
else
    for d in "$@"; do
        check "$d"
    done
fi