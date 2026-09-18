#!/usr/bin/env bash
# bbr.sh — Debian 专用网络/内核调优（drop-in 写入，可一键回滚）
# 运行方式：bash bbr.sh（需 root）
if [ -z "${BASH_VERSION:-}" ]; then echo "[ERROR] 请用 bash 运行: bash $0" >&2; exit 1; fi
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "[ERROR] 请以 root 运行" >&2; exit 1; }
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = "debian" ] || { echo "[ERROR] 仅支持 Debian 系统，当前为: ${ID:-unknown}" >&2; exit 1; }

sysctl_get() { sysctl -n "$1" 2>/dev/null || echo 0; }
# tune <当前值> <计算值> <下限> <上限>：与当前值取大后夹区间；原值超上限时保留原值（只增不减）
tune() {
    local v=$1
    [ "$2" -gt "$v" ] && v=$2
    [ "$v" -lt "$3" ] && v=$3
    [ "$v" -gt "$4" ] && v=$4
    [ "$1" -gt "$v" ] && v=$1
    echo "$v"
}

memory_mb=$(($(awk '/MemTotal/{print $2}' /proc/meminfo) / 1024))
if [ "$memory_mb" -ge 1024 ]; then mem_show="$((memory_mb / 1024))G"; else mem_show="${memory_mb}M"; fi

fs_file_max=$(tune "$(sysctl_get fs.file-max)" $((memory_mb * 256)) 65536 2097152)
conntrack_max=$(tune "$(sysctl_get net.netfilter.nf_conntrack_max)" $((memory_mb / 16)) 65536 2097152)
rmem_max=$(tune "$(sysctl_get net.core.rmem_max)" $((memory_mb * 4096)) 4194304 67108864)
wmem_max=$(tune "$(sysctl_get net.core.wmem_max)" $((memory_mb * 4096)) 4194304 67108864)
backlog=$(tune "$(sysctl_get net.core.netdev_max_backlog)" $((memory_mb * 128)) 1000 250000)
somaxconn=$(tune "$(sysctl_get net.core.somaxconn)" $((memory_mb * 16)) 128 65535)
tw_buckets=$(tune "$(sysctl_get net.ipv4.tcp_max_tw_buckets)" $((memory_mb * 4)) 4096 1048576)

# BBR + fq 探测：内核支持才启用，否则留在 cubic
cc=cubic
qdisc=""
if sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    cc=bbr
    if sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1; then
        qdisc="net.core.default_qdisc = fq"
    fi
fi

# 按需加载 conntrack
sysctl -n net.netfilter.nf_conntrack_max >/dev/null 2>&1 || modprobe nf_conntrack 2>/dev/null || true

apt-get update -y >/dev/null 2>&1 || true

# ---- sysctl drop-in ----
SYSCTL_FILE=/etc/sysctl.d/99-tuning.conf
cat > "$SYSCTL_FILE" <<EOF
# 由 bbr.sh 生成于 $(date '+%F %T')
vm.swappiness = 1
fs.file-max = $fs_file_max

net.core.rmem_max = $rmem_max
net.core.wmem_max = $wmem_max
net.core.netdev_max_backlog = $backlog
net.core.somaxconn = $somaxconn
$qdisc

net.ipv4.ip_forward = 1
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_syn_backlog = $somaxconn
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = $tw_buckets
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_rmem = 4096 87380 $rmem_max
net.ipv4.tcp_wmem = 4096 65536 $wmem_max
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_congestion_control = $cc

net.netfilter.nf_conntrack_max = $conntrack_max
net.netfilter.nf_conntrack_buckets = $((conntrack_max / 4))
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 10
net.netfilter.nf_conntrack_udp_timeout_stream = 60

net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
# forwarding=1 会停收 RA，SLAAC 机器需 accept_ra=2 才不丢 IPv6
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2
EOF

# 逐条应用，不支持的单条跳过
while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    sysctl -w "$line" >/dev/null 2>&1 || echo "[WARN] 跳过: $line" >&2
done < "$SYSCTL_FILE"

# ---- limits 与 journald drop-in ----
mkdir -p /etc/security/limits.d /etc/systemd/journald.conf.d
printf '%s\n' '* soft nofile 512000' '* hard nofile 512000' \
    'root soft nofile 512000' 'root hard nofile 512000' > /etc/security/limits.d/99-tuning.conf
printf '%s\n' '[Journal]' 'SystemMaxUse=384M' 'SystemMaxFileSize=128M' 'ForwardToSyslog=no' \
    > /etc/systemd/journald.conf.d/99-tuning.conf
systemctl restart systemd-journald 2>/dev/null || true

echo "[INFO] 完成 ✔ 内存: $mem_show | BBR: $cc | conntrack: $conntrack_max"
echo "[INFO] 回滚: rm $SYSCTL_FILE /etc/security/limits.d/99-tuning.conf /etc/systemd/journald.conf.d/99-tuning.conf && sysctl --system"
