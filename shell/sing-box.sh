#!/usr/bin/env bash
# ============================================================
#  Sing-Box Manager  ·  极简面板式管理脚本（菜单交互，无命令行参数）
#  内核: SagerNet/sing-box   支持系统: Debian（systemd）/ Alpine（OpenRC）
#  面板协议: Shadowsocks / Hysteria2 / AnyTLS / Snell / Trojan / VMess /
#            TUIC / VLESS
#  依赖: bash（Alpine 首次运行前: apk add bash curl jq openssl；gcompat 脚本自动装）
# ============================================================

SB_REPO="SagerNet/sing-box"

# ---------- 路径（可用环境变量覆盖）----------
SB_DIR="${SB_DIR:-/etc/sing-box}"              # 配置目录
SB_BIN="${SB_BIN:-/usr/local/bin/sing-box}"    # 内核路径
SB_CONF="$SB_DIR/config.json"                  # 运行配置

# ---------- systemd 服务 ----------
SB_SERVICE="/etc/systemd/system/sing-box.service"

# ---------- 颜色（极简：仅弱化的灰与强调白） ----------
C_DIM="\033[2m"; C_B="\033[1m"; C_R="\033[0m"
B() { printf "%b" "$C_B$1$C_R"; }
DIM() { printf "%b" "$C_DIM$1$C_R"; }

# ---------- 工具 ----------
have()   { command -v "$1" >/dev/null 2>&1; }
root()   { [ "$(id -u)" = "0" ]; }
say()    { printf "  %s\n" "$1"; }
ok()     { say "$(B "✓") $1"; }
warn()   { say "$(B "!") $1"; }
die()    { say "$(B "✗") $1"; }

pause() {
  printf "%b" "  \033[2m按任意键返回…\033[0m"
  read_key >/dev/null
}

# 生成随机串
rand_str() { local n="$1"; tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n"; }
# 生成 UUID（Linux 下 /proc 恒可用）
gen_uuid() {
  if have uuidgen; then uuidgen
  else cat /proc/sys/kernel/random/uuid
  fi
}

# 确保依赖齐全（Alpine 额外装 gcompat：官方内核是 glibc 动态链接）
ensure_deps() {
  if have apk; then
    apk add curl jq openssl gcompat >/dev/null 2>&1
  elif have apt-get; then
    have curl && have jq && have openssl || {
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq curl jq openssl >/dev/null 2>&1
    }
  fi
  local c
  for c in curl jq openssl; do have "$c" || { echo "缺少依赖: $c，请手动安装"; exit 1; }; done
}

line() { printf "%b" "  \033[2m----------------------------------------\033[0m\n"; }

# ---------- UI 框架：显示宽度 / 网格 / 数据驱动菜单页 ----------
# 字符串显示宽度（CJK 记 2 列；不依赖 locale，busybox 兼容；忽略 ANSI 转义）
disp_w() {
  local s
  s=$(LC_ALL=C printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g')
  local b na
  b=$(LC_ALL=C printf '%s' "$s" | wc -c)
  na=$(LC_ALL=C printf '%s' "$s" | LC_ALL=C tr -d ' -~' | wc -c)
  echo $(( b - na + na / 3 * 2 ))
}

# 网格渲染：$1=列数，其余为条目（已含编号前缀）；自动按显示宽度对齐
grid() {
  local cols="$1"; shift
  local items=("$@") rows=() i=0
  local r c n=${#items[@]} pad w line_s
  local s
  while [ $i -lt $n ]; do
    r=""
    for c in $(seq 0 $((cols-1))); do
      [ $((i+c)) -ge $n ] && break
      s=${items[i+c]}
      w=$(disp_w "$s")
      # 固定 2 空格列间隙；末列不留尾随空格
      if [ $c -eq $((cols-1)) ]; then pad=0; else pad=$(( COLW - w + 2 )); fi
      r="$r$s$(printf "%${pad}s" "")"
    done
    rows+=("$r")
    i=$((i+cols))
  done
  for line_s in "${rows[@]}"; do echo "   $line_s"; done
}

# 数据驱动菜单页：渲染标题+网格，单键选择后回调（q=退出，r=返回）
# $1=标题  $2=回调函数名  $3=列数  其余="键|标签"条目（自动加粗编号）
menu_page() {
  local title="$1" cb="$2" cols="$3"; shift 3
  local entry=() keys=() w
  local e k t
  for e in "$@"; do
    k="${e%%|*}"; t="${e#*|}"
    entry+=("$(B "$k)") $t")
    keys+=("$k")
  done
  COLW=0
  for e in "${entry[@]}"; do
    w=$(disp_w "$e"); [ $w -gt $COLW ] && COLW=$w
  done
  show_header
  echo "  $(B "$title")"
  line
  grid "$cols" "${entry[@]}"
  line
  local valid_keys
  if [ "$title" = "主菜单" ]; then
    printf "  选择 (q 退出): "
    valid_keys=("${keys[@]}" q r)
  else
    printf "  选择 (r 返回): "
    valid_keys=("${keys[@]}" r)
  fi
  while :; do
    c=$(read_key "${valid_keys[@]}")
    [ -z "$c" ] && exit_clean
    [ "$c" = " " ] && continue
    [ "$c" = "q" ] && exit_clean
    if [ "$c" = "r" ]; then
      [ "$title" = "主菜单" ] && continue
      return 1
    fi
    "$cb" "$c"
    return 0
  done
}

# 单键确认：$1=提示，仅接受 y/n；y=0，n 或 EOF=1（其他键忽略）
# 按键本身不产生任何输出；后续可见输出由调用方自带换行
confirm_or() {
  printf "  %s" "$1"
  local k
  while :; do
    k=$(read_key y n)
    [ -z "$k" ] && return 1
    [ "$k" = " " ] && continue
    [ "$k" = "n" ] && return 1
    return 0
  done
}

# 单键读取：按下即生效（免回车）。$@ = 合法字符
# EOF → 空串（调用方退出面板）；回车/空格/非法键 → " "（默认/忽略）
read_key() {
  local valid=" $* " k
  if [ -t 0 ]; then
    stty -echo 2>/dev/null
    if ! IFS= read -r -n 1 k; then stty echo 2>/dev/null; printf ""; return; fi
    stty echo 2>/dev/null
  else
    if ! IFS= read -r -n 1 k; then printf ""; return; fi
  fi
  [ -z "$k" ] && { printf " "; return; }
  [[ "$valid" == *"$k"* ]] && { printf "%s" "$k"; return; }
  printf "%s" " "
}

# 带默认值的二选一：$1=默认，其余=合法项；q/ESC → q（调用方处理）
pick_or() {
  local d="$1"; shift
  local k
  printf "  选择 [%s]: " "$d" >&2
  k=$(read_key "$@" q)
  [ "$k" = "q" ] && { printf "q"; return; }
  [ "$k" = " " ] && { printf "%s" "$d"; return; }
  printf "%s" "$k"
}

# 退出面板：清屏 + 干净退出（q 或 EOF 都走这里）
exit_clean() { [ -n "$TERM" ] && clear 2>/dev/null; exit 0; }

# ---------- 运行环境探测 ----------
detect_env() {
  ARCH_RAW="$(uname -m)"
  case "$ARCH_RAW" in
    x86_64)          ARCH_GO="amd64" ;;
    aarch64|armv8*)  ARCH_GO="arm64" ;;
    armv7l|armv6l)   ARCH_GO="arm-7" ;;
    i686)            ARCH_GO="386" ;;
    *)               ARCH_GO="$ARCH_RAW" ;;
  esac

  if [ -d /run/systemd/system ]; then
    INIT_SYS="systemd"
  elif [ -f /sbin/openrc ]; then
    INIT_SYS="openrc"
  else
    echo "仅支持 Debian（systemd）/ Alpine（OpenRC）系统"; exit 1
  fi
}

# ---------- 服务单元 ----------
write_systemd_service() {
  cat > "$SB_SERVICE" <<UNIT
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target network-online.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW CAP_SYS_PTRACE CAP_DAC_READ_SEARCH
ExecStart=$SB_BIN run -D $SB_DIR -c $SB_CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
UNIT
}

write_openrc_service() {
  cat > /etc/init.d/sing-box <<UNIT
#!/sbin/openrc-run
description="sing-box service"
command="$SB_BIN"
command_args="run -D $SB_DIR -c $SB_CONF"
command_background="yes"
pidfile="/run/sing-box.pid"
output_logger="logger -t sing-box"
error_logger="logger -t sing-box"
depend() {
  need net
  after net.firewall
}
UNIT
  chmod +x /etc/init.d/sing-box
}

# ---------- 服务控制 ----------
service_start() {
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl daemon-reload; systemctl enable -q sing-box; systemctl start sing-box
  else
    rc-update add sing-box default 2>/dev/null; rc-service sing-box start
  fi
}
service_stop() {
  if [ "$INIT_SYS" = "systemd" ]; then systemctl stop sing-box
  else rc-service sing-box stop; fi
}
service_restart() {
  if [ "$INIT_SYS" = "systemd" ]; then systemctl restart sing-box
  else rc-service sing-box restart; fi
}
service_running() {
  if [ "$INIT_SYS" = "systemd" ]; then systemctl is-active --quiet sing-box
  else rc-service sing-box status >/dev/null 2>&1; fi
}

# ---------- 内核安装 / 升级 ----------
get_latest_version() {
  local v
  v=$(jq -r '.tag_name' <<< "$(curl -sL --max-time 10 "https://api.github.com/repos/$SB_REPO/releases/latest" 2>/dev/null)" 2>/dev/null)
  if [ -z "$v" ] || [ "$v" = "null" ]; then
    v=$(curl -sI --max-time 10 "https://github.com/$SB_REPO/releases/latest" \
        | tr -d '\r' | awk 'tolower($1)=="location:"{print $2}' \
        | awk -F'/tag/' '{print $2}')
  fi
  printf '%s' "$v" | tr -d 'v'
}

install_core() {
  local ver="$1"
  local base="https://github.com/$SB_REPO/releases/download/v$ver"
  local fname="sing-box-$ver-linux-$ARCH_GO.tar.gz"
  local url="$base/$fname"

  local tmp; tmp=$(mktemp -d)
  if ! curl -sL --fail --max-time 300 -o "$tmp/sb.tgz" "$url"; then
    rm -rf "$tmp"; die "下载失败，请检查网络"; return 1
  fi
  tar -xzf "$tmp/sb.tgz" -C "$tmp" 2>/dev/null
  # 先验证新内核可用，再覆盖旧文件；失败时旧内核原样保留
  local bin="$tmp/sing-box-$ver-linux-$ARCH_GO/sing-box"
  if [ ! -x "$bin" ] || ! "$bin" version >/dev/null 2>&1; then
    rm -rf "$tmp"; die "下载的内核不可用，已保留原版本"; return 1
  fi
  install -m 0755 "$bin" "$SB_BIN"
  rm -rf "$tmp"

  "$SB_BIN" version >/dev/null 2>&1 || { die "安装后无法运行"; return 1; }
}

# ---------- 卸载 ----------
do_uninstall() {
  show_header
  echo "  $(B "卸载")"
  line
  say "将停止服务并删除：内核、$SB_DIR、NAT 规则、脚本自身"
  local node_n=0
  for p in anytls hysteria2 shadowsocks snell trojan tuic vless vmess; do
    conf_has "$p" && node_n=$((node_n+1))
  done
  [ $node_n -gt 0 ] && warn "现有 $node_n 个节点将一并删除"
  echo
  if ! confirm_or "确认卸载? (y/n)"; then
    return
  fi

  printf "\n"
  say "正在卸载…"
  service_stop >/dev/null 2>&1
  service_stop_pidhop
  if [ "$INIT_SYS" = "systemd" ]; then
    systemctl disable sing-box >/dev/null 2>&1
    systemctl reset-failed sing-box >/dev/null 2>&1
    rm -f "$SB_SERVICE"; systemctl daemon-reload >/dev/null 2>&1
  elif [ "$INIT_SYS" = "openrc" ]; then
    rc-update del sing-box default >/dev/null 2>&1; rm -f /etc/init.d/sing-box
  fi
  # 端口跳跃 NAT 规则清理（live + 持久化）在 service_stop_pidhop
  rm -f /run/sing-box.pid
  rm -f "$SB_BIN"; rm -rf "$SB_DIR"
  printf "\n"
  ok "卸载完成。"
  pause
  # 移除面板脚本自身（仅限真实脚本文件，eval/桩测上下文 $0 不匹配）
  case "$0" in *sing-box.sh) printf "  已移除面板脚本: %s\n" "$0"; rm -f -- "$0" ;; esac
  exit 0
}

# ---------- 端口跳跃（Hysteria2 / TUIC，UDP REDIRECT）----------
setup_port_hop() {
  show_header
  say "端口跳跃：UDP 端口段重定向（Hysteria2 / TUIC 适用）"
  line
  read_num "节点端口 (已存在协议的监听端口): " ""
  local HT="$IN_VAL"
  [[ "$HT" =~ ^[0-9]+$ ]] || { warn "端口无效"; pause; return; }
  read_num "跳变范围起始 [20000]: " 20000
  local PS="$IN_VAL"
  read_num "跳变范围结束 [50000]: " 50000
  local PE="$IN_VAL"
  [ "$PE" -gt "$PS" ] || { warn "范围无效"; pause; return; }

  have iptables || { warn "未安装 iptables"; pause; return; }

  iptables -t nat -A PREROUTING -p udp --dport $PS:$PE -j REDIRECT --to-ports "$HT" \
    && ok "已添加: $PS:$PE/udp → $HT"

  # 持久化：有 netfilter-persistent 直接存盘，否则落一份可自行加入开机脚本的规则
  if have netfilter-persistent; then
    netfilter-persistent save >/dev/null 2>&1
  else
    mkdir -p /etc/sing-box
    {
      echo "#!/bin/sh"
      echo "iptables -t nat -A PREROUTING -p udp --dport $PS:$PE -j REDIRECT --to-ports $HT"
    } > /etc/sing-box/port-hop.sh
    chmod +x /etc/sing-box/port-hop.sh
    ok "规则已存 /etc/sing-box/port-hop.sh"
  fi
  pause
}

# ---------- 端口跳跃（Hysteria2 / TUIC，UDP REDIRECT）----------
# 停止前清理端口跳跃规则（live 删除 + 有删动才同步持久化），卸载流程调用
service_stop_pidhop() {
  have iptables || return 0
  local n=0 r
  while read -r r; do
    iptables -t nat ${r/-A/-D} >/dev/null 2>&1 && n=$((n+1))
  done <<EOF
$(iptables -t nat -S PREROUTING 2>/dev/null | grep 'REDIRECT --to-ports')
EOF
  [ $n -gt 0 ] && have netfilter-persistent && netfilter-persistent save >/dev/null 2>&1
  return 0
}

# ============================================================
#  配置存储层（config.json + 每协议一文件的 JSON 元数据）
# ============================================================

init_conf() {
  mkdir -p "$SB_DIR" 2>/dev/null || { echo "无法创建 $SB_DIR（需要 root）"; exit 1; }

  # 记录服务器公网 IP（获取失败不落盘，下次启动重试）
  if [ ! -f "$SB_DIR/.ip" ]; then
    IP_ADDR=$(curl -s4 --max-time 5 ip.sb || curl -s4 --max-time 5 ifconfig.me || echo "")
    [ -n "$IP_ADDR" ] && echo "$IP_ADDR" > "$SB_DIR/.ip"
  fi
  IP_ADDR=$(cat "$SB_DIR/.ip" 2>/dev/null || echo "")
}

# 读协议配置文件
conf_get() { cat "$SB_DIR/$1.json" 2>/dev/null; }
conf_has() { [ -s "$SB_DIR/$1.json" ]; }
conf_set() { printf '%s' "$2" > "$SB_DIR/$1.json"; chmod 600 "$SB_DIR/$1.json"; }
conf_del() { rm -f "$SB_DIR/$1.json" "$SB_DIR/$1.meta"; }

# 全量 JSON 重建：inbounds + users + tls + route + experimental
build_config() {
  local f="$SB_DIR/config.json"

  # 通用 outbound
  local out='[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}]'

  # DNS + 基础路由
  local dns route
  dns='{"servers":[{"type":"https","tag":"remote","server":"8.8.8.8"},{"type":"udp","tag":"local","server":"223.5.5.5"}]}'
  route='{"rules":[{"action":"sniff"}],"final":"direct","default_domain_resolver":"local"}'

  # 逐协议片段拼接（与 conf_set 的命名一致）
  local inb="" f2 seg
  for f2 in anytls hysteria2 shadowsocks snell trojan tuic vless vmess; do
    conf_has "$f2" || continue
    seg=$(conf_get "$f2")
    [ -n "$seg" ] && inb="$inb$seg,"
  done
  inb="${inb%,}"

  cat > "$f.new" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "dns": $dns,
  "inbounds": [$inb],
  "outbounds": $out,
  "route": $route,
  "experimental": { "cache_file": { "enabled": true } }
}
EOF
}

# 校验 + 应用配置（先写 .new，校验通过才替换，避免半成品配置）
apply_config() {
  build_config
  if ! "$SB_BIN" check -c "$SB_CONF.new" >/dev/null 2>&1; then
    warn "配置校验失败："
    "$SB_BIN" check -c "$SB_CONF.new" 2>&1 | sed 's/^/    /'
    return 1
  fi
  mv "$SB_CONF.new" "$SB_CONF"
  service_restart
  ok "配置已生效。"
}

get_ver() { "$SB_BIN" version 2>/dev/null | awk '/version/{print $3; exit}'; }

# ---------- 域名 / 证书 ----------
ask_domain() {
  # 返回值全局变量 DOMAIN
  while :; do
    printf "  域名 (回车 = 自签模式): "; read -r DOMAIN
    [ -z "$DOMAIN" ] && { DOMAIN=""; return; }
    [[ "$DOMAIN" =~ ^[A-Za-z0-9._-]+$ ]] || { warn "域名格式不对"; continue; }
    break
  done
}

resolve_domain() {
  getent hosts "$1" 2>/dev/null | awk '{print $1; exit}' || \
    nslookup "$1" 2>/dev/null | awk '/^Address/{print $2}' | tail -1
}

is_wildcard() { [[ "$1" == *"*."* ]]; }

# ---------- 输入校验：无效输入当场重问，回车=默认 ----------
# 普通串：拒绝会破坏 JSON 的引号/反斜杠 → IN_VAL
read_safe() {
  local s
  while :; do
    printf "  %s" "$1"; read -r s
    [ -z "$s" ] && { IN_VAL="$2"; return 0; }
    case "$s" in *'"'*|*'\'*) warn "不能包含引号或反斜杠"; continue ;; esac
    IN_VAL="$s"; return 0
  done
}
# 数字 → IN_VAL
read_num() {
  local s
  while :; do
    printf "  %s" "$1"; read -r s
    [ -z "$s" ] && { IN_VAL="$2"; return 0; }
    [[ "$s" =~ ^[0-9]+$ ]] || { warn "须为数字"; continue; }
    IN_VAL="$s"; return 0
  done
}
# UUID（回车=随机）→ IN_VAL
read_uuid() {
  local s
  while :; do
    printf "  %s" "$1"; read -r s
    [ -z "$s" ] && { IN_VAL=$(gen_uuid); return 0; }
    [[ "$s" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] && { IN_VAL="$s"; return 0; }
    warn "UUID 格式不对"
  done
}

# ---------- ACME（Let's Encrypt / ZeroSSL）----------
issue_acme() {
  # $1=域名  全局: TLS_DIR  返回0=成功
  local d="$1"
  TLS_DIR="$SB_DIR/certs/$d"
  mkdir -p "$TLS_DIR"
  if [ -s "$TLS_DIR/server.crt" ] && [ -s "$TLS_DIR/server.key" ]; then
    return 0
  fi

  cat > "$SB_DIR/acme.json" <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [],
  "outbounds": [{ "type": "direct", "tag": "direct" }],
  "route": { "final": "direct" },
  "experimental": {
    "acme": {
      "domain": ["$d"],
      "data_dir": "$TLS_DIR",
      "default_server_name": "$d",
      "email": "admin@$d"
    }
  }
}
EOF

  # 停主服务以腾出 80 端口（HTTP-01 challenge）
  local was_running=0
  service_running && { was_running=1; service_stop; }

  "$SB_BIN" run -c "$SB_DIR/acme.json" >"$SB_DIR/acme.log" 2>&1 &
  local pid=$!
  for _ in $(seq 1 30); do
    [ -s "$TLS_DIR/server.crt" ] && break
    kill -0 $pid 2>/dev/null || break
    sleep 2
  done
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
  rm -f "$SB_DIR/acme.json"

  [ $was_running = 1 ] && service_start

  if [ -s "$TLS_DIR/server.crt" ]; then
    return 0
  fi
  warn "签发失败，日志："; tail -5 "$SB_DIR/acme.log" 2>/dev/null | sed 's/^/    /'
  return 1
}

# ---------- 端口 ----------
read_port() {  # $1=default, 输出全局 PORT
  local d="${1:-443}"
  printf "  端口 (回车=%s): " "$d"; read -r PORT
  PORT="${PORT:-$d}"
  [[ "$PORT" =~ ^[0-9]+$ ]] && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || { warn "端口无效"; return 1; }
  if have ss && { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT$" || \
                  ss -lun 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$PORT$"; }; then
    warn "端口 $PORT 已被占用"; return 1
  fi
  return 0
}

issue_selfsigned() {
  local dir="$1"
  mkdir -p "$dir"
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$dir/ca.key" -out "$dir/ca.crt" -days 3650 \
    -subj "/CN=SBox-CA" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes \
    -keyout "$dir/server.key" -out "$dir/server.csr" \
    -subj "/CN=server" >/dev/null 2>&1
  cat > "$dir/san.cnf" <<EOF
subjectAltName=IP:127.0.0.1,IP:$IP_ADDR,DNS:server,DNS:*.wildcard
EOF
  openssl x509 -req -in "$dir/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" \
    -CAcreateserial -days 3650 -extfile "$dir/san.cnf" \
    -out "$dir/server.crt" >/dev/null 2>&1
  rm -f "$dir/server.csr" "$dir/san.cnf"
  [ -s "$dir/server.crt" ]
}

# ============================================================
#  协议层
# ============================================================

# ---------- Shadowsocks ----------
add_ss() {
  show_header
  echo "  $(B "Shadowsocks")"
  line
  read_port 8388 || { pause; return; }
  read_safe "密码 (回车=随机): " ""
  local pw="$IN_VAL" need=0
  echo "  加密方式:"
  grid 2 \
    "$(B "1)") 2022-blake3-aes-128-gcm" "$(B "2)") 2022-blake3-aes-256-gcm" \
    "$(B "3)") aes-128-gcm" "$(B "4)") aes-256-gcm" \
    "$(B "5)") chacha20-ietf-poly1305"
  c=$(pick_or 2 1 2 3 4 5)
  [ "$c" = "q" ] && { pause; return; }
  local method need=0
  case "$c" in
    1) method="2022-blake3-aes-128-gcm"; need=16 ;;
    2) method="2022-blake3-aes-256-gcm"; need=32 ;;
    3) method="aes-128-gcm" ;;
    4) method="aes-256-gcm" ;;
    5) method="chacha20-ietf-poly1305" ;;
  esac
  if [ "$need" != 0 ]; then
    # SS2022: 密码须为 base64 编码的 16/32 字节密钥
    [ -z "$pw" ] && pw=$(openssl rand -base64 "$need" | tr -d '\n')
    local got; got=$(printf '%s' "$pw" | openssl base64 -d -A 2>/dev/null | wc -c | tr -d ' ')
    [ "$got" = "$need" ] || { warn "密码须为 base64 的 $need 字节密钥"; pause; return; }
  fi
  [ -z "$pw" ] && pw=$(rand_str 16)

  write_protocol "shadowsocks" \
    "port=$PORT|method=$method|password=$pw|name=ss-$(rand_str 4)"
  apply_config && show_node_info shadowsocks
  pause
}

# ---------- Hysteria2 ----------
add_hy2() {
  show_header
  echo "  $(B "Hysteria2")"
  line
  read_port 8443 || { pause; return; }
  read_safe "密码 (回车=随机): " "$(rand_str 12)"
  local PW="$IN_VAL"
  echo "  证书: $(B "1)") ACME(需域名+80空闲)  $(B "2)") 自签(客户端 insecure)"
  c=$(pick_or 2 1 2)
  [ "$c" = "q" ] && { pause; return; }
  ask_domain
  if [ "$c" = "1" ] && [ -n "$DOMAIN" ]; then
    setup_tls_from_flags "$DOMAIN"
  else
    TLS_DIR="$SB_DIR/certs/self"
    mkdir -p "$TLS_DIR"
    [ -s "$TLS_DIR/server.crt" ] || issue_selfsigned "$TLS_DIR"
    TLS_MODE="self"
  fi
  read_safe "obfs 混淆 (回车=无): " ""
  local OB="$IN_VAL"

  write_protocol "hysteria2" \
    "port=$PORT|password=$PW|obfs=$OB|tls_dir=$TLS_DIR|tls_mode=$TLS_MODE|domain=$DOMAIN|name=hy2-$(rand_str 4)"
  apply_config && show_node_info hysteria2
  pause
}

# ============================================================
#  write_protocol：把 key=value|... 参数转成 sing-box inbound JSON
#  并写入 $SB_DIR/<protocol>.json（一协议一片段）
# ============================================================
write_protocol() {
  local proto="$1"; shift
  local kv="$1"
  # 解析成关联数组
  local -A P=()
  local pair
  local IFS='|'
  for pair in $kv; do
    local k="${pair%%=*}" v="${pair#*=}"
    P["$k"]="$v"
  done
  unset IFS

  local j=""
  local port="${P[port]:-443}"
  local name="${P[name]:-$proto}"

  case "$proto" in

  shadowsocks)
    j=$(cat <<EOF
{
  "type": "shadowsocks",
  "tag": "$name",
  "listen": "::",
  "listen_port": $port,
  "method": "${P[method]}",
  "password": "${P[password]}"
}
EOF
)
    ;;

  hysteria2)
    local obfs_sect=""
    [ -n "${P[obfs]}" ] && obfs_sect=$(printf ',\n  "obfs": { "type": "salamander", "password": "%s" }' "${P[obfs]}")
    j=$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "$name",
  "listen": "::",
  "listen_port": $port,
  "users": [ { "password": "${P[password]}" } ],
  "tls": {
    "enabled": true,
    "certificate_path": "${P[tls_dir]}/server.crt",
    "key_path": "${P[tls_dir]}/server.key"
  }$obfs_sect
}
EOF
)
    ;;

  anytls)
    j=$(cat <<EOF
{
  "type": "anytls",
  "tag": "$name",
  "listen": "::",
  "listen_port": $port,
  "users": [ { "name": "u", "password": "${P[password]}" } ],
  "tls": {
    "enabled": true,
    "certificate_path": "${P[tls_dir]}/server.crt",
    "key_path": "${P[tls_dir]}/server.key"
  }
}
EOF
)
    ;;

  snell)
    j=$(cat <<EOF
{
  "type": "snell",
  "tag": "$name",
  "listen": "::",
  "listen_port": $port,
  "psk": "${P[psk]}",
  "version": ${P[version]}
}
EOF
)
    ;;

  trojan)
    j=$(cat <<EOF
{
  "type": "trojan",
  "tag": "$name",
  "listen": "::",
  "listen_port": $port,
  "users": [ { "name": "u", "password": "${P[password]}" } ],
  "tls": {
    "enabled": true,
    "certificate_path": "${P[tls_dir]}/server.crt",
    "key_path": "${P[tls_dir]}/server.key"
  }
}
EOF
)
    ;;

  vmess)
    j=$(cat <<EOF
{
  "type": "vmess",
  "tag": "$name",
  "listen": "::",
  "listen_port": $port,
  "users": [ { "name": "u", "uuid": "${P[uuid]}", "alterId": ${P[alterId]:-0} } ]
}
EOF
)
    ;;

  tuic)
    j=$(cat <<EOF
{
  "type": "tuic",
  "tag": "$name",
  "listen": "::",
  "listen_port": $port,
  "users": [ { "name": "u", "uuid": "${P[uuid]}", "password": "${P[password]}" } ],
  "congestion_control": "bbr",
  "tls": {
    "enabled": true,
    "alpn": ["h3"],
    "certificate_path": "${P[tls_dir]}/server.crt",
    "key_path": "${P[tls_dir]}/server.key"
  }
}
EOF
)
    ;;

  vless)
    local flow_sect=""
    [ -n "${P[flow]}" ] && flow_sect=$(printf ',\n  "flow": "%s"' "${P[flow]}")
    j=$(cat <<EOF
{
  "type": "vless",
  "tag": "$name",
  "listen": "::",
  "listen_port": $port,
  "users": [ { "name": "u", "uuid": "${P[uuid]}"$flow_sect } ],
  "tls": {
    "enabled": true,
    "certificate_path": "${P[tls_dir]}/server.crt",
    "key_path": "${P[tls_dir]}/server.key"
  }
}
EOF
)
    ;;

  *)
    warn "未知协议: $proto"; return 1 ;;
  esac

  conf_set "$proto" "$j"
  # 元数据（不进 sing-box -C 目录扫描：用 .meta 扩展名）
  {
    echo "domain=${P[domain]}"
    echo "tls_mode=${P[tls_mode]}"
    echo "tls_dir=${P[tls_dir]}"
  } > "$SB_DIR/$proto.meta"
}

# ============================================================
#  节点信息与订阅
# ============================================================
SUBS_CONTENT=""
show_node_info() {
  local proto="$1"
  local d; d=$(conf_get "$proto")
  [ -z "$d" ] && { warn "未找到配置"; return; }

  # 从 meta 恢复 TLS 上下文（key=value，直接 source 到临时变量）
  if [ -f "$SB_DIR/$proto.meta" ]; then
    local mtls="" mdom=""
    while IFS='=' read -r k v; do
      case "$k" in
        tls_mode) mtls="$v" ;;
        domain)   mdom="$v" ;;
      esac
    done < "$SB_DIR/$proto.meta"
    [ -n "$mtls" ] && TLS_MODE="$mtls"
    DOMAIN="$mdom"
  fi

  local tag port
  tag=$(jq -r '.tag' <<<"$d")
  port=$(jq -r '.listen_port' <<<"$d")
  local ip="$IP_ADDR"

  line
  say "名称:  $tag"
  say "地址:  $ip"
  say "端口:  $port"
  say "协议:  $proto"

  local link=""
  case "$proto" in
    shadowsocks)
      local method pw
      method=$(jq -r '.method' <<<"$d"); pw=$(jq -r '.password' <<<"$d")
      say "加密:  $method"
      say "密码:  $pw"
      link="ss://$(base64_urlencode "${method}:${pw}@${ip}:${port}")#${tag}"
      ;;
    hysteria2)
      local pw; pw=$(jq -r '.users[0].password' <<<"$d")
      say "密码:  $pw"
      say "TLS:   $(tls_note)"
      link="hy2://${pw}@${ip}:${port}/?insecure=$(insecure_flag)#${tag}"
      ;;
    anytls)
      local pw; pw=$(jq -r '.users[0].password' <<<"$d")
      say "密码:  $pw"
      link="anytls://$(url_enc "$pw")@${ip}:${port}/?insecure=$(insecure_flag)#${tag}"
      ;;
    snell)
      say "PSK:   $(jq -r '.psk' <<<"$d")"
      say "版本:  v$(jq -r '.version' <<<"$d")"
      ;;
    trojan)
      local pw; pw=$(jq -r '.users[0].password' <<<"$d")
      say "密码:  $pw"
      link="trojan://$(url_enc "$pw")@${ip}:${port}/?insecure=$(insecure_flag)#${tag}"
      ;;
    vmess)
      local uuid aid
      uuid=$(jq -r '.users[0].uuid' <<<"$d"); aid=$(jq -r '.users[0].alterId' <<<"$d")
      say "UUID:  $uuid"
      say "alterId: $aid"
      local vjson; vjson=$(jq -cn --arg a "$ip" --arg p "$port" --arg id "$uuid" --arg t "$tag" \
        '{v:"2",ps:$t,add:$a,port:($p|tonumber),id:$id,aid:"0",scy:"auto",net:"tcp",type:"none",host:"",path:"",tls:"",sni:"",alpn:"",fp:""}')
      link="vmess://$(base64_urlencode "$vjson")"
      ;;
    tuic)
      local uuid pw
      uuid=$(jq -r '.users[0].uuid' <<<"$d"); pw=$(jq -r '.users[0].password' <<<"$d")
      say "UUID:  $uuid"
      say "密码:  $pw"
      link="tuic://${uuid}:${pw}@${ip}:${port}?congestion_control=bbr&alpn=h3&insecure=$(insecure_flag)&sni=$(domain_or_ip)#${tag}"
      ;;
    vless)
      local uuid flow
      uuid=$(jq -r '.users[0].uuid' <<<"$d"); flow=$(jq -r '.users[0].flow // ""' <<<"$d")
      say "UUID:  $uuid"
      [ -n "$flow" ] && say "流控:  $flow"
      link="vless://${uuid}@${ip}:${port}?security=tls&flow=${flow}&insecure=$(insecure_flag)#${tag}"
      ;;
  esac

  [ -n "$link" ] && { say "链接:  $link"; SUBS_CONTENT="$SUBS_CONTENT$link"$'\n'; }
  line
}

tls_note() {
  [ "$TLS_MODE" = "self" ] && echo "自签（客户端须开 insecure）" || echo "ACME 有效证书"
}
insecure_flag() { [ "$TLS_MODE" = "self" ] && echo 1 || echo 0; }
domain_or_ip()  { [ -n "$DOMAIN" ] && echo "$DOMAIN" || echo "$IP_ADDR"; }
url_enc() { jq -rn --arg s "$1" '$s|@uri'; }
base64_urlencode() { printf '%s' "$1" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '='; }

# ---------- AnyTLS ----------
add_anytls() {
  show_header
  echo "  $(B "AnyTLS")"
  line
  read_port 8443 || { pause; return; }
  read_safe "密码 (回车=随机): " "$(rand_str 16)"
  local PW="$IN_VAL"
  ask_domain
  setup_tls_from_flags "$DOMAIN"
  write_protocol "anytls" \
    "port=$PORT|password=$PW|tls_dir=$TLS_DIR|tls_mode=$TLS_MODE|domain=$DOMAIN|name=anytls-$(rand_str 4)"
  apply_config && show_node_info anytls
  pause
}

# ---------- Snell ----------
add_snell() {
  show_header
  echo "  $(B "Snell")"
  line
  local cur; cur=$(get_ver)
  if [ -n "$cur" ] && [ "$(printf '%s\n' "$cur" "1.14.0" | sort -V | head -1)" != "1.14.0" ]; then
    warn "Snell 需内核 >= 1.14.0（当前 v$cur），先在主菜单更新"
    pause
    return
  fi
  read_port 6160 || { pause; return; }
  read_safe "psk (回车=随机): " "$(rand_str 24)"
  local PW="$IN_VAL"
  echo "  版本: $(B "1)") v5  $(B "2)") v6"
  c=$(pick_or 1 1 2)
  [ "$c" = "q" ] && { pause; return; }
  local ver="5"; [ "$c" = "2" ] && ver="6"
  if [ "$ver" = "6" ]; then
    local plen; plen=$(printf '%s' "$PW" | wc -c | tr -d ' ')
    [ "$plen" -ge 12 ] && [ "$plen" -le 255 ] || { warn "v6 的 psk 须为 12-255 字节"; pause; return; }
  fi
  write_protocol "snell" "port=$PORT|psk=$PW|version=$ver|name=snell-$(rand_str 4)"
  apply_config && show_node_info snell
  pause
}

# ---------- Trojan ----------
add_trojan() {
  show_header
  echo "  $(B "Trojan")"
  line
  read_port 443 || { pause; return; }
  read_safe "密码 (回车=随机): " "$(rand_str 16)"
  local PW="$IN_VAL"
  ask_domain
  setup_tls_from_flags "$DOMAIN"
  write_protocol "trojan" \
    "port=$PORT|password=$PW|tls_dir=$TLS_DIR|tls_mode=$TLS_MODE|domain=$DOMAIN|name=trojan-$(rand_str 4)"
  apply_config && show_node_info trojan
  pause
}

# ---------- VMess ----------
add_vmess() {
  show_header
  echo "  $(B "VMess")"
  line
  read_port 10086 || { pause; return; }
  read_uuid "UUID (回车=随机): "
  local U="$IN_VAL"
  read_num "alterId [0]: " 0
  local AID="$IN_VAL"
  write_protocol "vmess" "port=$PORT|uuid=$U|alterId=$AID|name=vmess-$(rand_str 4)"
  apply_config && show_node_info vmess
  pause
}

# ---------- TUIC ----------
add_tuic() {
  show_header
  echo "  $(B "TUIC")"
  line
  read_port 8443 || { pause; return; }
  read_uuid "UUID (回车=随机): "
  local U="$IN_VAL"
  read_safe "密码 (回车=随机): " "$(rand_str 16)"
  local PW="$IN_VAL"
  ask_domain
  setup_tls_from_flags "$DOMAIN"
  write_protocol "tuic" \
    "port=$PORT|uuid=$U|password=$PW|tls_dir=$TLS_DIR|tls_mode=$TLS_MODE|domain=$DOMAIN|name=tuic-$(rand_str 4)"
  apply_config && show_node_info tuic
  pause
}

# ---------- VLESS ----------
add_vless() {
  show_header
  echo "  $(B "VLESS")"
  line
  read_port 443 || { pause; return; }
  read_uuid "UUID (回车=随机): "
  local U="$IN_VAL"
  echo "  流控: $(B "1)") 无  $(B "2)") xtls-rprx-vision"
  c=$(pick_or 2 1 2)
  [ "$c" = "q" ] && { pause; return; }
  local flow=""
  [ "$c" = "2" ] && flow="xtls-rprx-vision"
  ask_domain
  setup_tls_from_flags "$DOMAIN"
  write_protocol "vless" \
    "port=$PORT|uuid=$U|flow=$flow|tls_dir=$TLS_DIR|tls_mode=$TLS_MODE|domain=$DOMAIN|name=vless-$(rand_str 4)"
  apply_config && show_node_info vless
  pause
}

# ---------- 证书辅助：已知域名时选择 ACME 或自签 ----------
setup_tls_from_flags() {
  local d="$1"
  if [ -n "$d" ] && ! is_wildcard "$d" && [ -n "$(resolve_domain "$d")" ]; then
    if issue_acme "$d"; then
      TLS_DIR="$SB_DIR/certs/$d"; TLS_MODE="full"; DOMAIN="$d"; return
    fi
    warn "ACME 失败，回退自签"
  fi
  TLS_DIR="$SB_DIR/certs/self"
  mkdir -p "$TLS_DIR"
  [ -s "$TLS_DIR/server.crt" ] || issue_selfsigned "$TLS_DIR"
  TLS_MODE="self"
}

# ============================================================
#  菜单
# ============================================================
show_header() {
  [ -n "$TERM" ] && clear 2>/dev/null
  printf "\n"
  DIM "  ┌──────────────────────────────────────┐"
  printf "\n"
  printf "              %bSING-BOX %bPANEL%b\n" "$C_B" "$C_R$C_DIM" "$C_R"
  DIM "  └──────────────────────────────────────┘"
  printf "\n"
}

menu_add() {
  # 协议按字母顺序排列，2 列网格；r=返回上级
  while menu_page "添加节点" act_add 2 \
    "1|AnyTLS"      "2|Hysteria2" \
    "3|Shadowsocks" "4|Snell" \
    "5|Trojan"      "6|TUIC" \
    "7|VLESS"       "8|VMess"; do :; done
}
act_add() {
  case "$1" in
    1) add_anytls ;;
    2) add_hy2 ;;
    3) add_ss ;;
    4) add_snell ;;
    5) add_trojan ;;
    6) add_tuic ;;
    7) add_vless ;;
    8) add_vmess ;;
  esac
}

menu_nodes() {
  # 协议固定顺序编号 1-8，与添加菜单一致
  local protos="anytls hysteria2 shadowsocks snell trojan tuic vless vmess"
  while :; do
    show_header
    echo "  $(B "节点列表")"
    line
    local n=0 i=0
    local keys=() map=()
    for p in $protos; do
      i=$((i+1))
      if conf_has "$p"; then
        local tag port
        tag=$(jq -r '.tag' "$SB_DIR/$p.json" 2>/dev/null)
        port=$(jq -r '.listen_port' "$SB_DIR/$p.json" 2>/dev/null)
        n=$((n+1))
        say "  $(B "$i")) $(printf "%-12s" "$p") $tag :$port"
        keys+=("$i"); map+=("$p")
      fi
    done
    [ $n -eq 0 ] && say "（暂无节点）"
    line
    printf "  选择 (r 返回): "
    local c
    if [ $n -eq 0 ]; then
      c=$(read_key r)
    else
      c=$(read_key "${keys[@]}" r)
    fi
    [ -z "$c" ] && exit_clean
    [ "$c" = " " ] && continue
    [ "$c" = "q" ] && exit_clean
    [ "$c" = "r" ] && return
    # 编号转协议名
    local pick=""
    for ((i=0; i<n; i++)); do
      [ "${keys[i]}" = "$c" ] && pick="${map[i]}"
    done
    # 确认删除：y 单键确认，其他键取消
    if confirm_or "删除 $pick? (y/n)"; then
      printf "\n"
      conf_del "$pick"; apply_config
    else
      printf "\n"
      say "已取消。"
    fi
    echo
  done
}

menu_links() {
  show_header
  echo "  $(B "分享订阅")"
  SUBS_CONTENT=""
  local n=0
  for p in anytls hysteria2 shadowsocks snell trojan tuic vless vmess; do
    conf_has "$p" && { show_node_info "$p"; n=$((n+1)); }
  done
  [ $n -eq 0 ] && say "（暂无节点）" && { pause; return; }

  if [ -n "$SUBS_CONTENT" ]; then
    line
    say "订阅内容 (Base64):"
    line
    printf '%s' "$SUBS_CONTENT" | base64 -w0 | fold -w72 | sed 's/^/    /'
    echo
    say "（Clash/Surge 不支持 Snell，其余均可导入）"
  fi
  pause
}

get_status() {
  if service_running; then echo "运行中"; else echo "已停止"; fi
}

menu_service() {
  while menu_page "服务管理 · $(get_status)" act_service 2 \
    "1|启动" "2|停止" \
    "3|重启" "4|端口跳跃"; do sleep 1; done
}
act_service() {
  case "$1" in
    1) service_start; ok "已启动" ;;
    2) service_stop;  ok "已停止" ;;
    3) service_restart; ok "已重启" ;;
    4) setup_port_hop ;;
  esac
}

do_update() {
  show_header
  echo "  $(B "更新内核")"
  line
  local cur; cur=$(get_ver)
  say "当前版本: v${cur:-未知}"
  say "检查更新…"
  local latest; latest=$(get_latest_version)
  if [ -z "$latest" ] || [ "$latest" = "null" ]; then
    printf "\n"
    warn "获取最新版本失败，稍后再试"
    pause; return
  fi
  if [ "$latest" = "$cur" ]; then
    printf "\n"
    ok "已是最新版本 v$cur"
    pause; return
  fi
  printf "\n"
  say "发现新版本: v$latest"
  say "正在更新…"
  local was_running=0; service_running && was_running=1
  service_stop
  if install_core "$latest"; then
    [ $was_running = 1 ] && service_start
    printf "\n"
    ok "已更新到 v$latest"
  else
    [ $was_running = 1 ] && service_start
    printf "\n"
    if [ $was_running = 1 ]; then warn "更新失败，已恢复原版本运行"; else warn "更新失败，原内核保持不变"; fi
  fi
  pause
}

# ============================================================
#  主菜单 & 入口
# ============================================================
menu_main() {
  # q = 退出面板（menu_page 返回 1 → exit_clean）
  while menu_page "主菜单" act_main 3 \
    "1|添加节点" "2|节点列表" "3|分享订阅" \
    "4|服务管理" "5|更新内核" "6|卸载"; do :; done
  exit_clean
}
act_main() {
  case "$1" in
    1) menu_add ;;
    2) menu_nodes ;;
    3) menu_links ;;
    4) menu_service ;;
    5) do_update ;;
    6) do_uninstall ;;
  esac
}

main() {
  if ! root; then
    echo "请用 root 运行：sudo bash $0"
    exit 1
  fi
  ensure_deps
  detect_env
  init_conf

  # 首次运行自动装内核 + 服务单元 + 开机自启
  local need_install=0
  [ -x "$SB_BIN" ] || need_install=1
  if [ "$INIT_SYS" = "systemd" ] && [ ! -f "$SB_SERVICE" ]; then need_install=1; fi
  if [ "$INIT_SYS" = "openrc" ] && [ ! -f /etc/init.d/sing-box ]; then need_install=1; fi

  if [ $need_install = 1 ]; then
    show_header
    echo "  $(B "初始化")"
    line
    say "未检测到内核，自动安装…"
    local latest; latest=$(get_latest_version)
    case "$latest" in ""|"null") latest="1.14.0"; DIM "  （未获取到版本号，回退 v1.14.0）" ;; *) say "目标版本: v$latest" ;; esac
    say "正在下载安装…"
    install_core "$latest" || { printf "\n"; die "内核安装失败，请检查网络后重试"; exit 1; }
    say "内核 v$latest 安装完成"
    case "$INIT_SYS" in
      systemd)
        write_systemd_service
        systemctl daemon-reload
        systemctl enable -q sing-box 2>/dev/null
        ;;
      openrc)
        write_openrc_service
        rc-update add sing-box default 2>/dev/null
        ;;
    esac
  fi

  menu_main
}

main "$@"
