#!/usr/bin/env bash
set -euo pipefail

# Ubuntu 部署脚本：
# 1) 安装并配置 dnsdist 作为 DNS 代理，仅监听/放行来自 192.168.99.0/24 的请求
# 2) 开启 IPv4/IPv6 转发
# 3) 使用 nftables 配置 SNAT：将来自 192.168.99.0/24 的流量经 pnet0 出口做源地址转换
#
# 用法：
#   sudo bash deploy_dnsdist_snat.sh
#
# 可通过环境变量覆盖默认值：
#   UPSTREAM_DNS="8.8.8.8:53,1.1.1.1:53" DNSDIST_LISTEN="0.0.0.0:53" LAN_CIDR="192.168.99.0/24" WAN_IF="pnet0" sudo bash deploy_dnsdist_snat.sh

LAN_CIDR="${LAN_CIDR:-192.168.99.0/24}"
WAN_IF="${WAN_IF:-pnet0}"
DNSDIST_LISTEN="${DNSDIST_LISTEN:-192.168.99.10:53}"
UPSTREAM_DNS_RAW="${UPSTREAM_DNS:-223.5.5.5:53,114.114.114.114:53}"
DNSDIST_CONF="/etc/dnsdist/dnsdist.conf"
SYSCTL_CONF="/etc/sysctl.d/99-dnsdist-router.conf"
NFT_CONF="/etc/nftables.conf"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 root 或 sudo 运行此脚本" >&2
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "当前系统不支持 apt-get，本脚本仅适用于 Ubuntu/Debian 系" >&2
  exit 1
fi

if ! ip link show "${WAN_IF}" >/dev/null 2>&1; then
  echo "未找到出接口: ${WAN_IF}" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y dnsdist nftables

mkdir -p /etc/dnsdist

IFS=',' read -r -a UPSTREAM_DNS_ARRAY <<< "${UPSTREAM_DNS_RAW}"
DNSDIST_POOLS=""
for server in "${UPSTREAM_DNS_ARRAY[@]}"; do
  server_trimmed="$(echo "${server}" | xargs)"
  [[ -z "${server_trimmed}" ]] && continue
  DNSDIST_POOLS+="newServer({address='${server_trimmed}'})\n"
done

if [[ -z "${DNSDIST_POOLS}" ]]; then
  echo "未提供有效的上游 DNS" >&2
  exit 1
fi

cat > "${DNSDIST_CONF}" <<EOF
setLocal('${DNSDIST_LISTEN}')
setACL({'${LAN_CIDR}'})
$(printf "%b" "${DNSDIST_POOLS}")
EOF

chmod 0644 "${DNSDIST_CONF}"

cat > "${SYSCTL_CONF}" <<EOF
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF

sysctl --system

cat > "${NFT_CONF}" <<EOF
#!/usr/sbin/nft -f

flush ruleset

table ip nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr ${LAN_CIDR} oifname "${WAN_IF}" masquerade
  }
}
EOF

systemctl enable nftables
nft -f "${NFT_CONF}"
systemctl restart nftables

systemctl enable dnsdist
systemctl restart dnsdist

cat <<EOF
部署完成。

已执行：
1. 安装 dnsdist 和 nftables
2. dnsdist 监听 ${DNSDIST_LISTEN}，并仅允许 ${LAN_CIDR} 访问
3. 开启 IPv4/IPv6 转发
4. 配置 nftables：来自 ${LAN_CIDR} 且从 ${WAN_IF} 出口的流量执行源地址转换（当前为 masquerade）

关键文件：
- ${DNSDIST_CONF}
- ${SYSCTL_CONF}
- ${NFT_CONF}

检查命令：
- systemctl status dnsdist --no-pager
- systemctl status nftables --no-pager
- sysctl net.ipv4.ip_forward
- sysctl net.ipv6.conf.all.forwarding
- nft list ruleset
- ss -lnup | grep ':53 '

如需把 masquerade 改为固定 SNAT 地址，可将 ${NFT_CONF} 中的：
  masquerade
改为：
  snat to <你的pnet0出口IP>
EOF
