#!/usr/bin/env bash
# sbox.sh — sing-box 服务端面板 (Debian / Alpine)
# 协议: Shadowsocks · VLESS · VMess · Hysteria2 · AnyTLS · Snell v6
# ShadowTLS 作为 Shadowsocks 插件，不是独立协议
set -u
set -o pipefail
export LANG=C.UTF-8 LC_ALL=C.UTF-8
umask 077

SBOX_BIN="/usr/local/bin/sing-box"
SBOX_SELF="/usr/local/bin/sbox"
CONF_DIR="/etc/sing-box"
CONF="$CONF_DIR/config.json"
META="$CONF_DIR/meta.json"
KEYS="$CONF_DIR/keys.json"
CERT_DIR="$CONF_DIR/cert"
LOG_FILE="/var/log/sing-box.log"
MIN_SNELL="1.14.0"
MIN_ANYTLS="1.12.0"
GH_REPO="SagerNet/sing-box"

if [[ -t 1 && "${NO_COLOR:-}" != "1" ]]; then
  C0='\033[0m'; CB='\033[1m'; CD='\033[2m'
  CR='\033[31m'; CG='\033[32m'; CC='\033[36m'
  CBC='\033[96m'
else
  C0=''; CB=''; CD=''; CR=''; CG=''; CC=''; CBC=''
fi

die()  { printf "${CR}[错误] %s${C0}\n" "$*" >&2; exit 1; }
ok()   { printf "${CG}[正确] %s${C0}\n" "$*"; }
err()  { printf "${CR}[错误] %s${C0}\n" "$*" >&2; }
note() { printf "${CC}[信息] %s${C0}\n" "$*" >&2; }
hold() { sleep 1; }

listen_addr() {
  if [[ -n "${LISTEN_ADDR:-}" ]]; then
    printf '%s' "$LISTEN_ADDR"
    return
  fi
  local v
  v=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || printf '1')
  if [[ "$v" != 0 ]]; then LISTEN_ADDR='0.0.0.0'; else LISTEN_ADDR='::'; fi
  printf '%s' "$LISTEN_ADDR"
}

# IPv6 主机在 URI 里必须带方括号
hp() {
  local h=$1 p=$2
  if [[ "$h" == *:* && "$h" != \[* ]]; then
    printf '[%s]:%s' "$h" "$p"
  else
    printf '%s:%s' "$h" "$p"
  fi
}

yaml_host() {
  local h=$1
  if [[ "$h" == *:* ]]; then
    printf '"%s"' "$h"
  else
    printf '%s' "$h"
  fi
}

jq_write() {
  local file=$1 tmp rc=0
  shift
  tmp=$(mktemp) || return 1
  if jq "$@" "$file" > "$tmp" && [[ -s "$tmp" ]]; then
    mv "$tmp" "$file" || rc=1
  else
    rc=1
  fi
  rm -f "$tmp"
  return $rc
}

need_root() { [[ $(id -u) -eq 0 ]] || die "请用 root 运行：sudo bash $0"; }

disp_w() {
  local s=${1-} i c w=0 n
  n=${#s}
  for ((i=0;i<n;i++)); do
    c="${s:i:1}"
    if [[ "$c" = [[:ascii:]] ]]; then
      ((w++))
    else
      ((w+=2))
    fi
  done
  printf '%s' "$w"
}

pad_r() {
  local s=$1 w=$2 dw pad
  dw=$(disp_w "$s")
  pad=$(( w - dw ))
  (( pad < 0 )) && pad=0
  printf '%s%*s' "$s" "$pad" ''
}

hline() {
  local n=${1:-0}
  (( n < 1 )) && return
  printf '%*s' "$n" '' | tr ' ' '-'
}

term_cols() {
  local w=""
  if [[ -t 1 ]]; then
    w=$(stty size 2>/dev/null | awk '{print $2}')
  fi
  [[ -z "$w" || "$w" -lt 1 ]] && w=${COLUMNS:-0}
  [[ -z "$w" || "$w" -lt 1 ]] && w=$(tput cols 2>/dev/null || true)
  [[ -z "$w" || "$w" -lt 1 ]] && w=80
  printf '%s' "$w"
}

trunc_disp() {
  local s=${1-} max=${2-0} i c cw w=0 out="" n
  n=${#s}
  (( max < 1 )) && { printf ''; return; }
  for ((i=0;i<n;i++)); do
    c="${s:i:1}"
    if [[ "$c" = [[:ascii:]] ]]; then cw=1; else cw=2; fi
    if (( w + cw > max )); then
      (( w < max )) && out+="~"
      printf '%s' "$out"
      return
    fi
    out+=$c
    ((w+=cw))
  done
  printf '%s' "$out"
}

UI_IK=(); UI_IV=(); UI_MK=(); UI_ML=()
UI_PROMPT_R=0
col_w=()

ui_reset() { UI_IK=(); UI_IV=(); UI_MK=(); UI_ML=(); }

ui_info() { UI_IK+=("$1"); UI_IV+=("$2"); }

ui_menu() { UI_MK+=("$1"); UI_ML+=("$2"); }

svc_label() {
  case "$(svc_state)" in
    running) printf '运行中' ;;
    stopped) printf '已停止' ;;
    failed) printf '失败' ;;
    starting) printf '启动中' ;;
    stopping) printf '停止中' ;;
    *) printf '未安装' ;;
  esac
}

ui_fill_info() {
  [[ -n "${CACHE_HOST:-}" ]] || CACHE_HOST=$(hostname)
  cap_lines
  ui_info "主机名" "$CACHE_HOST"
  ui_info "系统" "$OS_PRETTY"
  ui_info "CPU" "$(cpu_line)"
  ui_info "内存" "$CAP_MEM"
  ui_info "磁盘" "$CAP_DISK"
  ui_info "内核" "$(sb_version)"
  ui_info "服务" "$(svc_label)"
  ui_info "节点" "$(node_count)"
  ui_info "IP" "$(ip_line)"
}

ui_sep() {
  printf "${CD}+%s+%s+${C0}\033[K\n" "$(hline "$1")" "$(hline "$2")"
}

ui_menu_widths() {
  local cols=$1 n=${#UI_MK[@]} c i dwm gap=2
  col_w=()
  MENU_DW=4
  for ((c=0;c<cols;c++)); do col_w[c]=0; done
  for ((i=0;i<n;i++)); do
    c=$((i % cols))
    dwm=$(disp_w "${UI_MK[i]} ${UI_ML[i]}")
    (( dwm > col_w[c] )) && col_w[c]=$dwm
  done
  for ((c=0;c<cols;c++)); do
    (( c < cols - 1 )) && (( col_w[c] += gap ))
    (( col_w[c] < 1 )) && col_w[c]=1
    MENU_DW=$((MENU_DW + col_w[c]))
  done
}

ui_render() {
  local cols=${1:-4} i n m w1=8 w2=8
  local BOX r c idx text rows maxw val line=1 cw rowtxt content hw1 hw2
  n=${#UI_IK[@]}
  m=${#UI_MK[@]}
  maxw=$(term_cols)
  (( maxw < 36 )) && maxw=36
  BOX=$maxw
  (( BOX > 48 )) && BOX=48
  if (( m > 0 )); then
    ui_menu_widths "$cols"
    if (( MENU_DW > maxw && cols > 2 )); then
      cols=2
      ui_menu_widths "$cols"
    fi
    (( MENU_DW > BOX )) && BOX=$MENU_DW
    (( BOX > maxw )) && BOX=$maxw
  fi
  if (( BOX < 37 && cols > 2 )); then
    cols=2
    (( m > 0 )) && ui_menu_widths "$cols"
  fi
  w1=8
  w2=$(( BOX - 7 - w1 ))
  (( w2 < 4 )) && w2=4
  hw1=$((w1 + 2))
  hw2=$((w2 + 2))
  line=1

  ui_sep "$hw1" "$hw2"
  ((line++))
  printf "${CD}|${C0} ${CB}%s${C0} ${CD}|${C0} ${CB}%s${C0} ${CD}|${C0}\033[K\n" \
    "$(pad_r "项目" "$w1")" "$(pad_r "配置" "$w2")"
  ((line++))
  ui_sep "$hw1" "$hw2"
  ((line++))
  for ((i=0;i<n;i++)); do
    val=$(trunc_disp "${UI_IV[i]}" "$w2")
    printf "${CD}|${C0} %s ${CD}|${C0} ${CBC}%s${C0} ${CD}|${C0}\033[K\n" \
      "$(pad_r "$(trunc_disp "${UI_IK[i]}" "$w1")" "$w1")" "$(pad_r "$val" "$w2")"
    ((line++))
  done
  ui_sep "$hw1" "$hw2"
  ((line++))
  if (( m > 0 )); then
    rows=$(( (m + cols - 1) / cols ))
    content=$((BOX - 4))
    for ((r=0;r<rows;r++)); do
      rowtxt=""
      for ((c=0;c<cols;c++)); do
        idx=$((r * cols + c))
        cw=${col_w[c]:-8}
        if (( idx < m )); then
          text=$(trunc_disp "${UI_MK[idx]} ${UI_ML[idx]}" "$cw")
          rowtxt+="$(pad_r "$text" "$cw")"
        else
          rowtxt+="$(printf '%*s' "$cw" '')"
        fi
      done
      printf "${CD}|${C0} %s ${CD}|${C0}\033[K\n" "$(pad_r "$rowtxt" "$content")"
      ((line++))
    done
    ui_sep "$hw1" "$hw2"
    ((line++))
  fi
  UI_PROMPT_R=$line
}

wait_back() {
  local x
  while :; do
    x=$(prompt "选择" "" "q返回")
    [[ "$x" == q || "$x" == Q ]] && return
  done
}

ui_paint() {
  local cols=${1:-4}
  printf '\033[?25l\033[2J\033[H'
  ui_render "$cols"
  printf '\033[J\033[?25h'
}

ui_redraw() {
  dashboard
  ui_paint 4
}

prompt() {
  local msg=$1 def=${2-} hint=${3-} ans
  if [[ -n "$def" ]]; then
    printf "${CC}%s${C0} ${CD}[%s]${C0}: " "$msg" "$def" >&2
  elif [[ -n "$hint" ]]; then
    printf "${CC}%s${C0} ${CD}[%s]${C0}: " "$msg" "$hint" >&2
  else
    printf "${CC}%s${C0}: " "$msg" >&2
  fi
  IFS= read -r ans || true
  printf '%s' "${ans:-$def}"
}

ask_yn() {
  local msg=$1 def=${2:-n} ans hint="y/N"
  [[ "$def" == [yY] ]] && hint="Y/n"
  printf "${CC}%s${C0} ${CD}[%s]${C0}: " "$msg" "$hint" >&2
  IFS= read -r ans || true
  ans=${ans:-$def}
  [[ "$ans" == [yY] ]]
}

OS_ID=""; OS_PRETTY=""; OS_KIND=""

detect_os() {
  [[ -f /etc/os-release ]] || die "找不到 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_PRETTY="${PRETTY_NAME:-$OS_ID}"
  case "$OS_ID" in
    debian) OS_KIND=debian ;;
    alpine) OS_KIND=alpine ;;
    *) die "只支持 Debian 和 Alpine，当前是：${OS_PRETTY}（ID=$OS_ID）" ;;
  esac
}

pkg_install() {
  case "$OS_KIND" in
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq >/dev/null || { err "apt-get update 失败"; return 1; }
      apt-get install -y -qq --no-install-recommends "$@" >/dev/null || {
        err "apt-get install 失败: $*"
        return 1
      }
      ;;
    alpine)
      apk add --no-cache --quiet "$@" >/dev/null || { err "apk add 失败: $*"; return 1; }
      ;;
  esac
}

ensure_deps() {
  local need=() p
  for p in curl jq tar openssl bash; do
    command -v "$p" >/dev/null 2>&1 || need+=("$p")
  done
  command -v ss >/dev/null 2>&1 || need+=(iproute2)
  if ((${#need[@]})); then
    pkg_install "${need[@]}" ca-certificates || { err "依赖安装失败"; return 1; }
  fi
}

# 跟 free -h / df -h 同一套数；内存/硬盘的 总/已/剩 按列对齐
_cap_strip3() {
  awk '{
    t=$1; u=$2; a=$3
    gsub(/iB/, "", t); gsub(/i/, "", t)
    gsub(/iB/, "", u); gsub(/i/, "", u)
    gsub(/iB/, "", a); gsub(/i/, "", a)
    print t, u, a
  }'
}

mem_nums() {
  local line
  line=$(free -h 2>/dev/null | awk '/^Mem:/{print $2,$3,(NF>=7?$7:$4)}')
  if [[ -z "$line" ]]; then
    line=$(awk '
      /^MemTotal:/{t=$2}
      /^MemAvailable:/{a=$2}
      /^MemFree:/{f=$2}
      END{
        if (a=="") a=f
        printf "%dM %dM %dM", int(t/1024+0.5), int((t-a)/1024+0.5), int(a/1024+0.5)
      }' /proc/meminfo)
  fi
  printf '%s' "$line" | _cap_strip3
}

disk_nums() {
  local line
  line=$(df -hP / 2>/dev/null | awk 'NR==2{print $2,$3,$4}')
  [[ -z "$line" ]] && line=$(df -h / 2>/dev/null | awk 'NR==2{print $2,$3,$4}')
  printf '%s' "$line" | _cap_strip3
}

cap_lines() {
  local mt mu ma dt du da wt wu wa d
  read -r mt mu ma <<< "$(mem_nums)"
  read -r dt du da <<< "$(disk_nums)"
  wt=$(disp_w "$mt"); d=$(disp_w "$dt"); (( d > wt )) && wt=$d
  wu=$(disp_w "$mu"); d=$(disp_w "$du"); (( d > wu )) && wu=$d
  wa=$(disp_w "$ma"); d=$(disp_w "$da"); (( d > wa )) && wa=$d
  (( wt < 4 )) && wt=4
  (( wu < 4 )) && wu=4
  (( wa < 4 )) && wa=4
  CAP_MEM="总 $(pad_r "$mt" "$wt")  已 $(pad_r "$mu" "$wu")  剩 $(pad_r "$ma" "$wa")"
  CAP_DISK="总 $(pad_r "$dt" "$wt")  已 $(pad_r "$du" "$wu")  剩 $(pad_r "$da" "$wa")"
}

cpu_line() {
  [[ -n "${CACHE_CPU:-}" ]] && { printf '%s' "$CACHE_CPU"; return; }
  CACHE_CPU="$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo) 核"
  printf '%s' "$CACHE_CPU"
}

sb_version() {
  local mt
  if [[ ! -x "$SBOX_BIN" ]]; then
    CACHE_SBVER="未安装"
    CACHE_SBVER_MT=""
    printf '未安装'
    return
  fi
  mt=$(stat -c %Y "$SBOX_BIN" 2>/dev/null || echo 0)
  if [[ -n "${CACHE_SBVER:-}" && "${CACHE_SBVER_MT:-}" == "$mt" ]]; then
    printf '%s' "$CACHE_SBVER"
    return
  fi
  CACHE_SBVER=$("$SBOX_BIN" version 2>/dev/null | awk 'NR==1{print $3; exit}')
  CACHE_SBVER_MT=$mt
  printf '%s' "$CACHE_SBVER"
}

svc_state() {
  local s pid
  if [[ "$OS_KIND" == debian ]]; then
    [[ -f /etc/systemd/system/sing-box.service ]] || { printf 'absent'; return; }
    s=$(systemctl show -p ActiveState --value sing-box 2>/dev/null || printf 'unknown')
    case "$s" in
      active)
        pid=$(systemctl show -p MainPID --value sing-box 2>/dev/null || printf '0')
        if [[ "$pid" != 0 && -d "/proc/$pid" ]]; then
          printf 'running'
        else
          printf 'stopped'
        fi
        ;;
      failed) printf 'failed' ;;
      activating) printf 'starting' ;;
      deactivating) printf 'stopping' ;;
      *) printf 'stopped' ;;
    esac
  else
    [[ -f /etc/init.d/sing-box ]] || { printf 'absent'; return; }
    if rc-service sing-box status >/dev/null 2>&1; then
      printf 'running'
    else
      printf 'stopped'
    fi
  fi
}

node_count() {
  local mt
  [[ -f "$CONF" ]] || { printf '0'; return; }
  mt=$(stat -c %Y "$CONF" 2>/dev/null || echo 0)
  if [[ -n "${CACHE_NC:-}" && "${CACHE_NC_MT:-}" == "$mt" ]]; then
    printf '%s' "$CACHE_NC"
    return
  fi
  if ! command -v jq >/dev/null 2>&1; then
    CACHE_NC=0
  else
    CACHE_NC=$(jq '[.inbounds[]? | select((.tag // "") | startswith("ss-inner-") | not)] | length' "$CONF" 2>/dev/null || printf '0')
  fi
  CACHE_NC_MT=$mt
  printf '%s' "$CACHE_NC"
}

is_ip4() { [[ "${1-}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
is_ip6() { [[ "${1-}" == *:* && "${1-}" != *[[:space:]]* ]]; }

curl_ip() {
  local fam=$1 ip
  if [[ "$fam" == 6 ]]; then
    ip=$(curl -6 -fsS --connect-timeout 1 --max-time 2 https://api64.ipify.org 2>/dev/null \
      || curl -6 -fsS --connect-timeout 1 --max-time 2 https://ifconfig.me 2>/dev/null \
      || curl -6 -fsS --connect-timeout 1 --max-time 2 https://icanhazip.com 2>/dev/null \
      || true)
  else
    ip=$(curl -4 -fsS --connect-timeout 1 --max-time 2 https://api.ip.sb/ip 2>/dev/null \
      || curl -4 -fsS --connect-timeout 1 --max-time 2 https://ifconfig.me 2>/dev/null \
      || curl -4 -fsS --connect-timeout 1 --max-time 2 https://icanhazip.com 2>/dev/null \
      || true)
  fi
  ip=$(printf '%s' "$ip" | tr -d ' \r\n')
  if [[ "$fam" == 6 ]]; then is_ip6 "$ip" && printf '%s' "$ip"
  else is_ip4 "$ip" && printf '%s' "$ip"
  fi
}

iface_ip4() {
  ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1
}

iface_ip6() {
  ip -6 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 \
    | grep -vE '^(fc|fd)' | head -n1
}

share_host() {
  local h=""
  h=$(curl_ip 4)
  [[ -z "$h" ]] && h=$(curl_ip 6)
  [[ -z "$h" ]] && h=$(iface_ip4)
  [[ -z "$h" ]] && h=$(iface_ip6)
  printf '%s' "$h"
}

ip_line() {
  local v4="" v6="" f4 f6
  if [[ -n "${IP_LINE:-}" ]]; then
    printf '%s' "$IP_LINE"
    return
  fi
  command -v curl >/dev/null 2>&1 || { IP_LINE='-'; printf '-'; return; }
  f4=$(mktemp) || { IP_LINE='-'; printf '-'; return; }
  f6=$(mktemp) || { rm -f "$f4"; IP_LINE='-'; printf '-'; return; }
  (curl -4 -fsS --connect-timeout 1 --max-time 2 https://api.ip.sb/ip 2>/dev/null || true) >"$f4" &
  (curl -6 -fsS --connect-timeout 1 --max-time 2 https://api64.ipify.org 2>/dev/null || true) >"$f6" &
  wait
  v4=$(tr -d ' \t\r\n' <"$f4")
  v6=$(tr -d ' \t\r\n' <"$f6")
  rm -f "$f4" "$f6"
  is_ip4 "$v4" || v4=""
  is_ip6 "$v6" || v6=""
  if [[ -n "$v4" && -n "$v6" ]]; then IP_LINE="$v4 $v6"
  elif [[ -n "$v4" ]]; then IP_LINE="$v4"
  elif [[ -n "$v6" ]]; then IP_LINE="$v6"
  else IP_LINE="-"
  fi
  printf '%s' "$IP_LINE"
}

rand_str() { openssl rand -base64 "$1" | tr -d '/+=' | head -c "$2"; }

rand_port() {
  local p i used
  used=$(port_set)
  for i in $(seq 1 40); do
    p=$((10000 + RANDOM % 50000))
    printf '%s\n' "$used" | grep -qx "$p" && continue
    printf '%s' "$p"
    return 0
  done
  err "找不到空闲端口"
  return 1
}

port_set() {
  {
    [[ -f "$CONF" ]] && jq -r '.inbounds[]? | .listen_port // empty' "$CONF" 2>/dev/null
    ss -lntu 2>/dev/null | awk 'NR>1{n=$5; sub(/.*:/,"",n); if(n ~ /^[0-9]+$/) print n}'
  } | awk 'NF && $1+0==$1'
}

port_used() { printf '%s\n' "$(port_set)" | grep -qx "$1"; }

ask_port() {
  local def p
  def=$(rand_port) || return 1
  while :; do
    p=$(prompt "端口" "$def")
    [[ "$p" =~ ^[0-9]+$ && p -ge 1 && p -le 65535 ]] || { err "端口必须是 1-65535"; continue; }
    if port_used "$p"; then
      err "端口 $p 已被占用"
      def=$(rand_port) || return 1
      continue
    fi
    printf '%s' "$p"
    return 0
  done
}

uri_enc() { jq -nr --arg s "$1" '$s|@uri'; }

ver_ge() {
  # $1 >= $2，不依赖 sort -V（BusyBox 没有）
  local a=${1#v} b=${2#v}
  a=${a%%-*}
  b=${b%%-*}
  awk -v a="$a" -v b="$b" 'BEGIN{
    n=split(a,A,"."); m=split(b,B,".");
    l=n; if(m>l) l=m;
    for(i=1;i<=l;i++){
      x=(i in A)?A[i]+0:0;
      y=(i in B)?B[i]+0:0;
      if(x>y) exit 0;
      if(x<y) exit 1;
    }
    exit 0
  }'
}

ensure_conf() {
  mkdir -p "$CONF_DIR" "$CERT_DIR"
  if [[ ! -f "$KEYS" ]]; then
    printf '{}\n' > "$KEYS"
  fi
  if [[ ! -f "$CONF" ]]; then
    cat > "$CONF" <<'JSON'
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ],
  "route": {
    "rules": [
      {
        "action": "sniff"
      }
    ],
    "final": "direct"
  }
}
JSON
  fi
  if [[ ! -f "$META" ]]; then
    cat > "$META" <<'JSON'
{
  "version": 1,
  "nodes": {}
}
JSON
  fi
}

meta_put_node() {
  jq_write "$META" --arg t "$1" --argjson n "$2" '.nodes[$t] = $n'
}

meta_del_node() {
  jq_write "$META" --arg t "$1" 'del(.nodes[$t])'
}

keys_put() {
  [[ -f "$KEYS" ]] || printf '{}\n' > "$KEYS"
  jq_write "$KEYS" --arg t "$1" --argjson n "$2" '.[$t] = $n'
}

keys_del() {
  [[ -f "$KEYS" ]] || return 0
  jq_write "$KEYS" --arg t "$1" 'del(.[$t])'
}

keys_get() {
  [[ -f "$KEYS" ]] || { printf ''; return 0; }
  jq -r --arg t "$1" --arg f "$2" '.[$t][$f] // empty' "$KEYS" 2>/dev/null || true
}

ib_get() {
  jq -r --arg t "$1" ".inbounds[]? | select(.tag==\$t) | ($2) // empty" "$CONF" 2>/dev/null
}

node_name() {
  jq -r --arg t "$1" '.nodes[$t].name // $t' "$META" 2>/dev/null
}

conf_add_inbound() {
  jq_write "$CONF" --argjson o "$1" '.inbounds += [$o]'
}

conf_del_tag() {
  jq_write "$CONF" --arg t "$1" '.inbounds |= map(select(.tag != $t))'
}

drop_node() {
  local tag=$1 inner=""
  inner=$(ib_get "$tag" '.detour')
  conf_del_tag "$tag" || true
  [[ -n "$inner" && "$inner" != null ]] && conf_del_tag "$inner"
  meta_del_node "$tag" || true
  keys_del "$tag" || true
}

apply_conf() {
  local tag=${1-} out
  if ! out=$("$SBOX_BIN" check -c "$CONF" 2>&1); then
    err "配置校验失败"
    printf '%s\n' "$out" >&2
    [[ -n "$tag" ]] && drop_node "$tag"
    return 1
  fi
  if ! QUIET=1 svc_restart; then
    err "服务启动失败"
    if [[ -n "$tag" ]]; then
      drop_node "$tag"
      QUIET=1 svc_restart || true
    fi
    return 1
  fi
}

make_tls_cert() {
  local sni=$1 d="$CERT_DIR/$sni"
  mkdir -p "$d"
  if [[ -f "$d/cert.pem" && -f "$d/key.pem" ]]; then
    printf '%s' "$d"
    return
  fi
  if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -days 3650 -nodes \
    -keyout "$d/key.pem" -out "$d/cert.pem" \
    -subj "/CN=$sni" >/dev/null 2>&1; then
    err "证书生成失败"
    return 1
  fi
  printf '%s' "$d"
}

goarch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf 'amd64' ;;
    aarch64|arm64) printf 'arm64' ;;
    armv7l|armv7)  printf 'armv7' ;;
    *) err "不支持的架构: $(uname -m)"; return 1 ;;
  esac
}

# 只拿正式稳定版：排除 draft / prerelease / alpha / beta / rc
STABLE_FALLBACK="v1.14.1"

stable_tag() {
  local tag="" json
  json=$(curl -fsSL --max-time 12 "https://api.github.com/repos/${GH_REPO}/releases?per_page=30" 2>/dev/null || true)
  if [[ -n "$json" ]]; then
    tag=$(printf '%s' "$json" | jq -r '
      [.[]
        | select(.draft==false and .prerelease==false)
        | select(.tag_name | test("(?i)alpha|beta|rc") | not)
        | .tag_name
      ] | .[0] // empty
    ')
  fi
  if [[ -z "$tag" || "$tag" == null ]]; then
    tag=$(curl -fsSL --max-time 12 "https://api.github.com/repos/${GH_REPO}/releases/latest" 2>/dev/null \
      | jq -r 'if .prerelease==false then .tag_name else empty end')
  fi
  if [[ -z "$tag" || "$tag" == null ]]; then
    tag="$STABLE_FALLBACK"
  fi
  printf '%s' "$tag"
}

download_tarball() {
  local url=$1 dest=$2
  local mirrors=("" "https://ghfast.top/" "https://ghproxy.net/" "https://mirror.ghproxy.com/")
  local m
  for m in "${mirrors[@]}"; do
    note "下载中…"
    if curl -fL --retry 2 --connect-timeout 12 --max-time 180 --progress-bar -o "$dest" "${m}${url}"; then
      return 0
    fi
    note "换源重试…"
  done
  return 1
}

verify_tarball() {
  local file=$1 tag=$2 name=$3
  local digest expect got
  digest=$(curl -fsSL --max-time 12 "https://api.github.com/repos/${GH_REPO}/releases/tags/${tag}" 2>/dev/null \
    | jq -r --arg n "$name" '.assets[]? | select(.name==$n) | .digest // empty' || true)
  if [[ "$digest" != sha256:* ]]; then
    return 0
  fi
  expect="${digest#sha256:}"
  got=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
  [[ -z "$got" ]] && got=$(sha256 -q "$file" 2>/dev/null || true)
  [[ "$got" == "$expect" ]] || { err "checksum 不匹配，拒绝安装"; return 1; }
}

install_singbox() {
  local tag ver arch url tmp bin name had
  note "检查依赖…"
  ensure_deps || return 1
  note "获取稳定版号…"
  tag=$(stable_tag)
  ver="${tag#v}"
  arch=$(goarch) || return 1
  name="sing-box-${ver}-linux-${arch}.tar.gz"
  url="https://github.com/${GH_REPO}/releases/download/${tag}/${name}"
  tmp=$(mktemp -d) || { err "mktemp 失败"; return 1; }
  note "下载 ${tag}…"
  if ! download_tarball "$url" "$tmp/sb.tgz"; then
    rm -rf "$tmp"
    err "下载 sing-box ${tag} 失败（GitHub + 镜像都没打通）"
    return 1
  fi
  note "校验…"
  if ! verify_tarball "$tmp/sb.tgz" "$tag" "$name"; then
    rm -rf "$tmp"
    return 1
  fi
  note "解压安装…"
  if ! tar -xzf "$tmp/sb.tgz" -C "$tmp"; then
    rm -rf "$tmp"
    err "解压失败"
    return 1
  fi
  bin=$(find "$tmp" -type f -name sing-box | head -n1 || true)
  if [[ -z "$bin" ]]; then
    rm -rf "$tmp"
    err "压缩包里没有 sing-box 二进制"
    return 1
  fi
  if [[ "$OS_KIND" == alpine ]] && ! command -v gcompat >/dev/null 2>&1; then
    apk add --no-cache gcompat >/dev/null 2>&1 || true
  fi
  mkdir -p /usr/local/bin
  if ! install -m 0755 "$bin" "$SBOX_BIN"; then
    rm -rf "$tmp"
    err "写入 $SBOX_BIN 失败"
    return 1
  fi
  rm -rf "$tmp"
  if ! "$SBOX_BIN" version >/dev/null 2>&1; then
    if [[ "$OS_KIND" == alpine ]]; then
      apk add --no-cache gcompat >/dev/null 2>&1 || true
    fi
    "$SBOX_BIN" version >/dev/null 2>&1 || { err "sing-box 无法执行"; return 1; }
  fi
  ensure_conf
  had=$(svc_state)
  install_service
  install_self
  if [[ "$had" == running || "$had" == stopped ]]; then
    QUIET=1 svc_restart || { err "内核已更新，但服务没起来"; return 1; }
  fi
  ok "已安装 sing-box $($SBOX_BIN version | awk 'NR==1{print $3}')"
}

install_self() {
  local src
  src=$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")
  [[ -f "$src" ]] && install -m 0755 "$src" "$SBOX_SELF"
}

install_service() {
  if [[ "$OS_KIND" == debian ]]; then
    cat > /etc/systemd/system/sing-box.service <<'UNIT'
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=1
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable sing-box >/dev/null 2>&1
  else
    cat > /etc/init.d/sing-box <<'RC'
#!/sbin/openrc-run
description="sing-box service"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=yes
pidfile="/run/sing-box.pid"
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
RC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1 || true
  fi
}

svc_start() {
  need_bin || return 1
  ensure_conf
  [[ "$(svc_state)" == absent ]] && install_service
  if [[ "$OS_KIND" == debian ]]; then
    systemctl start sing-box
  else
    rc-service sing-box start
  fi
  sleep 0.15
  if [[ "$(svc_state)" != running ]]; then
    err "启动失败"
    return 1
  fi
}

svc_stop() {
  if [[ ! -x "$SBOX_BIN" && "$(svc_state)" == absent ]]; then
    err "未安装"
    return 1
  fi
  [[ "$(svc_state)" == absent ]] && return 0
  if [[ "$OS_KIND" == debian ]]; then
    systemctl stop sing-box 2>/dev/null || true
  else
    rc-service sing-box stop 2>/dev/null || true
  fi
  if [[ "$(svc_state)" == running ]]; then
    err "停止失败"
    return 1
  fi
}

svc_restart() {
  need_bin || return 1
  [[ "$(svc_state)" == absent ]] && install_service
  if [[ "$OS_KIND" == debian ]]; then
    systemctl reset-failed sing-box 2>/dev/null || true
    systemctl restart sing-box
  else
    rc-service sing-box restart 2>/dev/null || rc-service sing-box start
  fi
  sleep 0.15
  if [[ "$(svc_state)" == running ]]; then
    [[ -n "${QUIET:-}" ]] || ok "服务已启动"
  else
    if [[ -z "${QUIET:-}" ]]; then
      err "服务没起来，最近日志："
      if [[ "$OS_KIND" == debian ]]; then
        journalctl -u sing-box -n 30 --no-pager 2>/dev/null || true
      else
        tail -n 30 "$LOG_FILE" 2>/dev/null || true
      fi
    fi
    return 1
  fi
}

dashboard() {
  ui_reset
  ui_fill_info
  ui_menu 1 安装
  ui_menu 2 添加
  ui_menu 3 分享
  ui_menu 4 删除
  ui_menu 5 启动
  ui_menu 6 停止
  ui_menu 7 重启
  ui_menu 8 卸载
}

pick_node_tag() {
  local tags=() tag i=1 c
  while IFS= read -r tag; do
    [[ -n "$tag" ]] && tags+=("$tag")
  done <<EOF
$(jq -r '
    .inbounds[]?
    | select((.tag // "") | startswith("ss-inner-") | not)
    | select(.listen_port != null)
    | .tag
  ' "$CONF" 2>/dev/null)
EOF
  if ((${#tags[@]}==0)); then
    err "没有可操作的节点"
    return 3
  fi
  ((${#UI_IK[@]})) || ui_fill_info
  UI_MK=(); UI_ML=()
  for tag in "${tags[@]}"; do
    ui_menu "$i" "$tag"
    ((i++))
  done
  { ui_paint 3; } >&2
  while :; do
    c=$(prompt "选择" "" "q返回")
    [[ "$c" == q || "$c" == Q ]] && return 2
    [[ "$c" =~ ^[0-9]+$ ]] || continue
    (( c >= 1 && c <= ${#tags[@]} )) || continue
    printf '%s' "${tags[$((c-1))]}"
    return 0
  done
}

need_bin() {
  if [[ ! -x "$SBOX_BIN" ]]; then
    err "先安装"
    return 1
  fi
  ensure_conf
}

require_ver() {
  local need=$1 feat=$2 have
  have=$(sb_version)
  if [[ "$have" == "未安装" ]]; then
    err "未安装 sing-box"
    return 1
  fi
  ver_ge "$have" "$need" || { err "$feat 需要 sing-box >= $need，当前 $have。请先更新。"; return 1; }
}

add_menu() {
  need_bin || return 1
  ((${#UI_IK[@]})) || ui_fill_info
  UI_MK=(); UI_ML=()
  ui_menu 1 Shadowsocks
  ui_menu 2 VLESS
  ui_menu 3 VMess
  ui_menu 4 Hysteria2
  ui_menu 5 AnyTLS
  ui_menu 6 Snell
  ui_paint 3
  local c
  while :; do
    c=$(prompt "选择" "" "q返回")
    case "$c" in
      1) add_ss; return $? ;;
      2) add_vless; return $? ;;
      3) add_vmess; return $? ;;
      4) add_hy2; return $? ;;
      5) add_anytls; return $? ;;
      6) add_snell; return $? ;;
      q|Q) return 2 ;;
    esac
  done
}

add_ss() {
  local port pass tag obj hs pass_st inner st ss
  port=$(ask_port) || return 1
  pass=$(openssl rand -base64 16 | tr -d '\n')
  if ask_yn "ShadowTLS 插件" y; then
    hs=$(prompt "握手站点" "www.microsoft.com")
    pass_st=$(rand_str 18 18)
    tag="ss-$port"
    inner="ss-inner-$port"
    st=$(jq -n \
      --arg tag "$tag" --argjson port "$port" --arg inner "$inner" \
      --arg pass "$pass_st" --arg hs "$hs" --arg listen "$(listen_addr)" \
      '{
        type:"shadowtls", tag:$tag, listen:$listen, listen_port:$port,
        tcp_fast_open:true, detour:$inner, version:3,
        users:[{name:"default", password:$pass}],
        handshake:{server:$hs, server_port:443},
        strict_mode:true
      }')
    ss=$(jq -n --arg tag "$inner" --arg pass "$pass" \
      '{type:"shadowsocks", tag:$tag, method:"2022-blake3-aes-128-gcm", password:$pass}')
    conf_add_inbound "$st" || return 1
    conf_add_inbound "$ss" || { drop_node "$tag"; return 1; }
    meta_put_node "$tag" "$(jq -n \
      --arg name "$tag" --argjson port "$port" --arg inner "$inner" --arg hs "$hs" \
      '{kind:"shadowsocks", plugin:"shadowtls", name:$name, port:$port, inner_tag:$inner, handshake:$hs}')" \
      || { drop_node "$tag"; return 1; }
    apply_conf "$tag" || return 1
    ok "ss+st :$port"
    show_share "$tag"
    return
  fi
  tag="ss-$port"
  obj=$(jq -n --arg tag "$tag" --argjson port "$port" --arg pass "$pass" \
    --arg listen "$(listen_addr)" \
    '{
      type:"shadowsocks", tag:$tag, listen:$listen, listen_port:$port,
      tcp_fast_open:true, method:"2022-blake3-aes-128-gcm", password:$pass,
      multiplex:{enabled:true, padding:true}
    }')
  conf_add_inbound "$obj" || return 1
  meta_put_node "$tag" "$(jq -n --arg name "$tag" --argjson port "$port" \
    '{kind:"shadowsocks", name:$name, port:$port}')" || { drop_node "$tag"; return 1; }
  apply_conf "$tag" || return 1
  ok "ss :$port"
  show_share "$tag"
}

add_vless() {
  local port sni uuid pair priv pub sid tag obj
  port=$(ask_port) || return 1
  sni=$(prompt "SNI" "www.apple.com")
  uuid=$("$SBOX_BIN" generate uuid)
  pair=$("$SBOX_BIN" generate reality-keypair)
  priv=$(printf '%s' "$pair" | awk '/PrivateKey/{print $2}')
  pub=$(printf '%s' "$pair" | awk '/PublicKey/{print $2}')
  [[ -n "$priv" && -n "$pub" ]] || { err "reality-keypair 生成失败"; return 1; }
  sid=$(openssl rand -hex 4)
  tag="vless-$port"
  obj=$(jq -n \
    --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
    --arg sni "$sni" --arg priv "$priv" --arg sid "$sid" --arg listen "$(listen_addr)" \
    '{
      type:"vless", tag:$tag, listen:$listen, listen_port:$port, tcp_fast_open:true,
      users:[{name:"default", uuid:$uuid, flow:"xtls-rprx-vision"}],
      tls:{
        enabled:true,
        server_name:$sni,
        reality:{
          enabled:true,
          handshake:{server:$sni, server_port:443},
          private_key:$priv,
          short_id:[$sid]
        }
      }
    }')
  conf_add_inbound "$obj" || return 1
  meta_put_node "$tag" "$(jq -n \
    --arg name "$tag" --argjson port "$port" --arg sni "$sni" \
    --arg pbk "$pub" --arg sid "$sid" --arg uuid "$uuid" \
    '{kind:"vless", name:$name, port:$port, sni:$sni, public_key:$pbk, short_id:$sid, uuid:$uuid}')" \
    || { drop_node "$tag"; return 1; }
  keys_put "$tag" "$(jq -n \
    --arg pbk "$pub" --arg sid "$sid" --arg sni "$sni" --arg uuid "$uuid" \
    '{public_key:$pbk, short_id:$sid, sni:$sni, uuid:$uuid}')" \
    || { drop_node "$tag"; return 1; }
  apply_conf "$tag" || return 1
  ok "vless :$port"
  show_share "$tag"
}

add_vmess() {
  local port uuid tag obj
  port=$(ask_port) || return 1
  uuid=$("$SBOX_BIN" generate uuid)
  tag="vmess-$port"
  obj=$(jq -n \
    --arg tag "$tag" --argjson port "$port" --arg uuid "$uuid" \
    --arg listen "$(listen_addr)" \
    '{
      type:"vmess", tag:$tag, listen:$listen, listen_port:$port, tcp_fast_open:true,
      users:[{name:"default", uuid:$uuid, alterId:0}]
    }')
  conf_add_inbound "$obj" || return 1
  meta_put_node "$tag" "$(jq -n --arg name "$tag" --argjson port "$port" --arg uuid "$uuid" \
    '{kind:"vmess", name:$name, port:$port, uuid:$uuid}')" \
    || { drop_node "$tag"; return 1; }
  apply_conf "$tag" || return 1
  ok "vmess :$port"
  show_share "$tag"
}

add_hy2() {
  local port sni pass obfs_pw tag certdir obj
  port=$(ask_port) || return 1
  sni=$(prompt "SNI" "www.bing.com")
  pass=$(rand_str 18 18)
  obfs_pw=$(rand_str 16 16)
  tag="hy2-$port"
  certdir=$(make_tls_cert "$sni") || return 1
  obj=$(jq -n \
    --arg tag "$tag" --argjson port "$port" --arg pass "$pass" \
    --arg sni "$sni" --arg cert "$certdir/cert.pem" --arg key "$certdir/key.pem" \
    --arg opw "$obfs_pw" --arg listen "$(listen_addr)" \
    '{
      type:"hysteria2", tag:$tag, listen:$listen, listen_port:$port,
      ignore_client_bandwidth:true,
      obfs:{type:"salamander", password:$opw},
      users:[{name:"default", password:$pass}],
      tls:{enabled:true, server_name:$sni, alpn:["h3"], certificate_path:$cert, key_path:$key},
      masquerade:{type:"string", status_code:200, content:"OK"}
    }')
  conf_add_inbound "$obj" || return 1
  meta_put_node "$tag" "$(jq -n \
    --arg name "$tag" --argjson port "$port" --arg sni "$sni" \
    '{kind:"hysteria2", name:$name, port:$port, sni:$sni, insecure:"1"}')" \
    || { drop_node "$tag"; return 1; }
  apply_conf "$tag" || return 1
  ok "hy2 :$port"
  show_share "$tag"
}

add_anytls() {
  require_ver "$MIN_ANYTLS" "AnyTLS" || return 1
  local port sni pass tag certdir obj
  port=$(ask_port) || return 1
  sni=$(prompt "SNI" "www.microsoft.com")
  pass=$(rand_str 18 18)
  tag="anytls-$port"
  certdir=$(make_tls_cert "$sni") || return 1
  obj=$(jq -n \
    --arg tag "$tag" --argjson port "$port" --arg pass "$pass" \
    --arg sni "$sni" --arg cert "$certdir/cert.pem" --arg key "$certdir/key.pem" \
    --arg listen "$(listen_addr)" \
    '{
      type:"anytls", tag:$tag, listen:$listen, listen_port:$port, tcp_fast_open:true,
      users:[{name:"default", password:$pass}],
      tls:{enabled:true, server_name:$sni, alpn:["h2","http/1.1"], certificate_path:$cert, key_path:$key}
    }')
  conf_add_inbound "$obj" || return 1
  meta_put_node "$tag" "$(jq -n \
    --arg name "$tag" --argjson port "$port" --arg sni "$sni" \
    '{kind:"anytls", name:$name, port:$port, sni:$sni, insecure:"1"}')" \
    || { drop_node "$tag"; return 1; }
  apply_conf "$tag" || return 1
  ok "anytls :$port"
  show_share "$tag"
}

add_snell() {
  require_ver "$MIN_SNELL" "Snell v6" || return 1
  local port psk tag obj
  port=$(ask_port) || return 1
  psk=$(rand_str 24 24)
  tag="snell-$port"
  obj=$(jq -n \
    --arg tag "$tag" --argjson port "$port" --arg psk "$psk" \
    --arg listen "$(listen_addr)" \
    '{
      type:"snell", tag:$tag, listen:$listen, listen_port:$port, tcp_fast_open:true,
      version:6, psk:$psk, mode:"default"
    }')
  conf_add_inbound "$obj" || return 1
  meta_put_node "$tag" "$(jq -n \
    --arg name "$tag" --argjson port "$port" \
    '{kind:"snell", name:$name, port:$port, mode:"default"}')" \
    || { drop_node "$tag"; return 1; }
  apply_conf "$tag" || return 1
  ok "snell :$port"
  show_share "$tag"
}

del_node() {
  need_bin || return 1
  local tag inner e
  tag=$(pick_node_tag); e=$?
  (( e != 0 )) && return "$e"
  ask_yn "确认删除 $tag" n || return 2
  local saved meta_blob keys_blob
  inner=$(ib_get "$tag" '.detour')
  [[ -z "$inner" || "$inner" == null ]] && inner=$(jq -r --arg t "$tag" '.nodes[$t].inner_tag // empty' "$META" 2>/dev/null || true)
  saved=$(jq --arg t "$tag" --arg i "${inner:-}" '[.inbounds[] | select(.tag==$t or ($i != "" and .tag==$i))]' "$CONF")
  meta_blob=$(jq --arg t "$tag" '.nodes[$t] // empty' "$META" 2>/dev/null || true)
  keys_blob=$(jq --arg t "$tag" '.[$t] // empty' "$KEYS" 2>/dev/null || true)
  conf_del_tag "$tag"
  [[ -n "$inner" && "$inner" != null ]] && conf_del_tag "$inner"
  meta_del_node "$tag"
  keys_del "$tag"
  if apply_conf; then
    ok "已删除 $tag"
  else
    jq_write "$CONF" --argjson b "$saved" '.inbounds += $b' || true
    if [[ -n "$meta_blob" && "$meta_blob" != "null" && "$meta_blob" != "" ]]; then
      jq_write "$META" --arg t "$tag" --argjson n "$meta_blob" '.nodes[$t]=$n' || true
    fi
    if [[ -n "$keys_blob" && "$keys_blob" != "null" && "$keys_blob" != "" ]]; then
      jq_write "$KEYS" --arg t "$tag" --argjson n "$keys_blob" '.[$t]=$n' || true
    fi
    QUIET=1 svc_restart || true
    err "删除失败，已恢复"
    return 1
  fi
}

show_block() {
  local title=$1 body=$2
  printf "\n  %s\n" "$title"
  printf '%s\n' "$body" | sed 's/^/  /'
}

share_ss() {
  local tag=$1 host=$2
  local port method pass name uri yaml json
  port=$(ib_get "$tag" '.listen_port')
  method=$(ib_get "$tag" '.method')
  pass=$(ib_get "$tag" '.password')
  name=$(node_name "$tag")
  uri="ss://$(printf '%s' "${method}:${pass}" | openssl base64 -A)@$(hp "$host" "$port")#$(uri_enc "$name")"
  yaml=$(printf '%s\n' \
    "- name: ${name}" \
    "  type: ss" \
    "  server: $(yaml_host "$host")" \
    "  port: ${port}" \
    "  cipher: ${method}" \
    "  password: \"${pass}\"" \
    "  smux:" \
    "    enabled: true")
  json=$(jq -n --arg tag "$name" --arg host "$host" --argjson port "$port" \
    --arg method "$method" --arg pass "$pass" \
    '{type:"shadowsocks", tag:$tag, server:$host, server_port:$port, method:$method, password:$pass, multiplex:{enabled:true, padding:true}}')
  show_block "URI" "$uri"
  show_block "Clash" "$yaml"
  show_block "sing-box" "$json"
}

share_st() {
  local tag=$1 host=$2
  local port hs st_pass ss_pass inner method name yaml json
  port=$(ib_get "$tag" '.listen_port')
  hs=$(ib_get "$tag" '.handshake.server')
  st_pass=$(ib_get "$tag" '.users[0].password')
  inner=$(ib_get "$tag" '.detour')
  [[ -z "$inner" || "$inner" == null ]] && inner=$(jq -r --arg t "$tag" '.nodes[$t].inner_tag // empty' "$META")
  if [[ -z "$inner" || "$inner" == null ]]; then
    err "找不到 ShadowTLS 内层"
    return 1
  fi
  method=$(ib_get "$inner" '.method')
  ss_pass=$(ib_get "$inner" '.password')
  name=$(node_name "$tag")
  yaml=$(printf '%s\n' \
    "- name: ${name}" \
    "  type: ss" \
    "  server: $(yaml_host "$host")" \
    "  port: ${port}" \
    "  cipher: ${method}" \
    "  password: \"${ss_pass}\"" \
    "  plugin: shadow-tls" \
    "  plugin-opts:" \
    "    host: ${hs}" \
    "    password: \"${st_pass}\"" \
    "    version: 3")
  json=$(jq -n \
    --arg name "$name" --arg host "$host" --argjson port "$port" \
    --arg method "$method" --arg ssp "$ss_pass" --arg stp "$st_pass" --arg hs "$hs" \
    '[
      {
        type:"shadowsocks", tag:$name, method:$method, password:$ssp,
        detour:($name+"-st")
      },
      {
        type:"shadowtls", tag:($name+"-st"), server:$host, server_port:$port,
        version:3, password:$stp,
        tls:{enabled:true, server_name:$hs, utls:{enabled:true, fingerprint:"chrome"}}
      }
    ]')
  show_block "Clash" "$yaml"
  show_block "sing-box" "$json"
}

share_vless() {
  local tag=$1 host=$2
  local port uuid sni pbk sid name uri yaml json
  port=$(ib_get "$tag" '.listen_port')
  uuid=$(ib_get "$tag" '.users[0].uuid')
  sni=$(keys_get "$tag" sni)
  [[ -z "$sni" ]] && sni=$(ib_get "$tag" '.tls.server_name')
  pbk=$(keys_get "$tag" public_key)
  [[ -z "$pbk" ]] && pbk=$(jq -r --arg t "$tag" '.nodes[$t].public_key // empty' "$META")
  sid=$(keys_get "$tag" short_id)
  [[ -z "$sid" ]] && sid=$(ib_get "$tag" '.tls.reality.short_id[0]')
  name=$(node_name "$tag")
  if [[ -z "$pbk" ]]; then
    err "缺少 Reality public_key，无法分享（keys.json / meta 都没有）"
    return 1
  fi
  uri="vless://${uuid}@$(hp "$host" "$port")?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$(uri_enc "$sni")&fp=chrome&pbk=$(uri_enc "$pbk")&sid=${sid}&type=tcp#$(uri_enc "$name")"
  yaml=$(printf '%s\n' \
    "- name: ${name}" \
    "  type: vless" \
    "  server: $(yaml_host "$host")" \
    "  port: ${port}" \
    "  uuid: ${uuid}" \
    "  network: tcp" \
    "  tls: true" \
    "  udp: true" \
    "  flow: xtls-rprx-vision" \
    "  servername: ${sni}" \
    "  client-fingerprint: chrome" \
    "  reality-opts:" \
    "    public-key: ${pbk}" \
    "    short-id: ${sid}")
  json=$(jq -n --arg tag "$name" --arg host "$host" --argjson port "$port" \
    --arg uuid "$uuid" --arg sni "$sni" --arg pbk "$pbk" --arg sid "$sid" \
    '{
      type:"vless", tag:$tag, server:$host, server_port:$port, uuid:$uuid,
      flow:"xtls-rprx-vision",
      tls:{
        enabled:true, server_name:$sni,
        utls:{enabled:true, fingerprint:"chrome"},
        reality:{enabled:true, public_key:$pbk, short_id:$sid}
      }
    }')
  show_block "URI" "$uri"
  show_block "Clash" "$yaml"
  show_block "sing-box" "$json"
}

share_vmess() {
  local tag=$1 host=$2
  local port uuid name uri yaml json raw b64
  port=$(ib_get "$tag" '.listen_port')
  uuid=$(ib_get "$tag" '.users[0].uuid')
  name=$(node_name "$tag")
  raw=$(jq -nc --arg ps "$name" --arg add "$host" --arg port "$port" --arg id "$uuid" \
    '{v:"2",ps:$ps,add:$add,port:$port,id:$id,aid:"0",scy:"auto",net:"tcp",type:"none",tls:"none"}')
  b64=$(printf '%s' "$raw" | openssl base64 -A)
  uri="vmess://${b64}"
  yaml=$(printf '%s\n' \
    "- name: ${name}" \
    "  type: vmess" \
    "  server: $(yaml_host "$host")" \
    "  port: ${port}" \
    "  uuid: ${uuid}" \
    "  alterId: 0" \
    "  cipher: auto" \
    "  network: tcp" \
    "  udp: true")
  json=$(jq -n --arg tag "$name" --arg host "$host" --argjson port "$port" --arg uuid "$uuid" \
    '{type:"vmess", tag:$tag, server:$host, server_port:$port, uuid:$uuid, security:"auto", alter_id:0}')
  show_block "URI" "$uri"
  show_block "Clash" "$yaml"
  show_block "sing-box" "$json"
}

share_hy2() {
  local tag=$1 host=$2
  local port pass sni obfs_pw name uri yaml json q
  port=$(ib_get "$tag" '.listen_port')
  pass=$(ib_get "$tag" '.users[0].password')
  sni=$(ib_get "$tag" '.tls.server_name')
  obfs_pw=$(ib_get "$tag" '.obfs.password')
  name=$(node_name "$tag")
  q="sni=$(uri_enc "$sni")&insecure=1"
  [[ -n "$obfs_pw" && "$obfs_pw" != null ]] && q="${q}&obfs=salamander&obfs-password=$(uri_enc "$obfs_pw")"
  uri="hysteria2://$(uri_enc "$pass")@$(hp "$host" "$port")/?${q}#$(uri_enc "$name")"
  yaml=$(printf '%s\n' \
    "- name: ${name}" \
    "  type: hysteria2" \
    "  server: $(yaml_host "$host")" \
    "  port: ${port}" \
    "  password: \"${pass}\"" \
    "  sni: ${sni}" \
    "  skip-cert-verify: true")
  if [[ -n "$obfs_pw" && "$obfs_pw" != null ]]; then
    yaml+=$(printf '\n%s\n%s' "  obfs: salamander" "  obfs-password: \"${obfs_pw}\"")
  fi
  json=$(jq -n --arg tag "$name" --arg host "$host" --argjson port "$port" \
    --arg pass "$pass" --arg sni "$sni" --arg opw "${obfs_pw:-}" \
    '{
      type:"hysteria2", tag:$tag, server:$host, server_port:$port, password:$pass,
      tls:{enabled:true, server_name:$sni, insecure:true}
    } + (if ($opw == "" or $opw == "null") then {} else {obfs:{type:"salamander", password:$opw}} end)')
  show_block "URI" "$uri"
  show_block "Clash" "$yaml"
  show_block "sing-box" "$json"
}

share_anytls() {
  local tag=$1 host=$2
  local port pass sni name uri yaml json
  port=$(ib_get "$tag" '.listen_port')
  pass=$(ib_get "$tag" '.users[0].password')
  sni=$(ib_get "$tag" '.tls.server_name')
  name=$(node_name "$tag")
  uri="anytls://$(uri_enc "$pass")@$(hp "$host" "$port")?sni=$(uri_enc "$sni")&insecure=1#$(uri_enc "$name")"
  yaml=$(printf '%s\n' \
    "- name: ${name}" \
    "  type: anytls" \
    "  server: $(yaml_host "$host")" \
    "  port: ${port}" \
    "  password: \"${pass}\"" \
    "  client-fingerprint: chrome" \
    "  udp: true" \
    "  sni: ${sni}" \
    "  skip-cert-verify: true")
  json=$(jq -n --arg tag "$name" --arg host "$host" --argjson port "$port" \
    --arg pass "$pass" --arg sni "$sni" \
    '{
      type:"anytls", tag:$tag, server:$host, server_port:$port, password:$pass,
      tls:{enabled:true, server_name:$sni, insecure:true, utls:{enabled:true, fingerprint:"chrome"}}
    }')
  show_block "URI" "$uri"
  show_block "Clash" "$yaml"
  show_block "sing-box" "$json"
}

share_snell() {
  local tag=$1 host=$2
  local port psk mode name surge yaml json
  port=$(ib_get "$tag" '.listen_port')
  psk=$(ib_get "$tag" '.psk')
  mode=$(ib_get "$tag" '.mode // "default"')
  name=$(node_name "$tag")
  surge="${name} = snell, ${host}, ${port}, psk=${psk}, version=6"
  yaml=$(printf '%s\n' \
    "- name: ${name}" \
    "  type: snell" \
    "  server: $(yaml_host "$host")" \
    "  port: ${port}" \
    "  psk: \"${psk}\"" \
    "  version: 6" \
    "  udp: true" \
    "  mode: ${mode}")
  json=$(jq -n --arg tag "$name" --arg host "$host" --argjson port "$port" \
    --arg psk "$psk" --arg mode "$mode" \
    '{type:"snell", tag:$tag, server:$host, server_port:$port, version:6, psk:$psk, mode:$mode}')
  show_block "Surge" "$surge"
  show_block "Clash" "$yaml"
  show_block "sing-box" "$json"
}

show_share() {
  local tag=${1-} host typ ip
  if [[ -z "$tag" ]]; then
    need_bin || return 1
    local pe
    tag=$(pick_node_tag); pe=$?
    (( pe != 0 )) && return "$pe"
  fi
  host=$(share_host)
  if [[ -z "$host" ]]; then
    ip=$(prompt "分享地址（域名或 IP）" "")
    [[ -n "$ip" ]] || { err "没有分享地址"; return 1; }
    host=$ip
  fi
  typ=$(ib_get "$tag" '.type')
  case "$typ" in
    shadowsocks) share_ss "$tag" "$host" ;;
    shadowtls)   share_st "$tag" "$host" ;;
    vless)       share_vless "$tag" "$host" ;;
    vmess)       share_vmess "$tag" "$host" ;;
    hysteria2)   share_hy2 "$tag" "$host" ;;
    anytls)      share_anytls "$tag" "$host" ;;
    snell)       share_snell "$tag" "$host" ;;
    *) err "未知协议 $typ"; return 1 ;;
  esac
}

uninstall_all() {
  if [[ ! -x "$SBOX_BIN" && "$(svc_state)" == absent && ! -d "$CONF_DIR" ]]; then
    err "未安装"
    return 1
  fi
  ask_yn "卸载内核、服务和全部配置？" n || return 2
  [[ "$(svc_state)" != absent ]] && svc_stop || true
  if [[ "$OS_KIND" == debian ]]; then
    systemctl disable sing-box >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
  else
    rc-update del sing-box default >/dev/null 2>&1 || true
    rm -f /etc/init.d/sing-box
  fi
  rm -f "$SBOX_BIN" "$SBOX_SELF"
  rm -rf "$CONF_DIR"
  CACHE_SBVER="" CACHE_SBVER_MT="" CACHE_NC="" CACHE_NC_MT="" IP_LINE=""
  ok "已卸载"
}

back_main() {
  [[ "${1-}" == skip ]] || hold
  ui_redraw
}

main_menu() {
  local c e
  printf '\033[2J\033[H'
  ui_redraw
  while :; do
    printf '\033[%d;1H\033[K' "${UI_PROMPT_R:-20}" >&2
    c=$(prompt "选择" "" "q退出")
    case "$c" in
      1) install_singbox; back_main ;;
      2) add_menu; e=$?
         if (( e == 0 )); then wait_back; back_main skip
         elif (( e == 2 )); then back_main skip
         else back_main
         fi ;;
      3) show_share; e=$?
         if (( e == 0 )); then wait_back; back_main skip
         elif (( e == 2 )); then back_main skip
         else back_main
         fi ;;
      4) del_node; e=$?
         (( e == 2 )) && back_main skip || back_main ;;
      5) svc_start; back_main ;;
      6) svc_stop; back_main ;;
      7) svc_restart; back_main ;;
      8) uninstall_all; back_main ;;
      q|Q) printf '\n'; exit 0 ;;
    esac
  done
}

main() {
  need_root
  detect_os
  main_menu
}

main "$@"
