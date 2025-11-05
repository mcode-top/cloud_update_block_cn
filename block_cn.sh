#!/bin/bash
# ============================================================
# 一键禁止 XrayR 或任何服务出口访问中国大陆 IP 段
# 支持系统: Debian / Ubuntu / CentOS / Rocky / AlmaLinux 等
# 作者: ChatGPT
# ============================================================

CN_IP_URL="https://ispip.clang.cn/all_cn.txt"
CN_IP_FILE="/etc/china_ip_list.txt"
IPSET_NAME="china"

# -------------------------------
# 检查 root
# -------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "[ERROR] 请以 root 权限运行。"
  exit 1
fi

# -------------------------------
# 检测系统
# -------------------------------
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_ID=$ID
else
  echo "[ERROR] 无法检测系统类型。"
  exit 1
fi

echo "[INFO] 当前系统: $PRETTY_NAME"

# -------------------------------
# 检查依赖
# -------------------------------
PKGS=(ipset iptables wget curl bind9-utils)
MISSING=()
for pkg in "${PKGS[@]}"; do
  if ! command -v $pkg >/dev/null 2>&1; then
    MISSING+=($pkg)
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "[WARN] 缺少依赖: ${MISSING[*]}"
  echo "[INFO] 正在自动安装..."
  if [[ $OS_ID =~ (ubuntu|debian) ]]; then
    apt update -y && apt install -y ${MISSING[*]}
  elif [[ $OS_ID =~ (centos|rocky|almalinux|rhel|fedora) ]]; then
    yum install -y ${MISSING[*]}
  else
    echo "[ERROR] 未知系统，请手动安装：${MISSING[*]}"
    exit 1
  fi
fi

# -------------------------------
# 自动检测出口网卡
# -------------------------------
OUT_IFACE=$(ip route | awk '/default/ {print $5; exit}')
if [[ -z "$OUT_IFACE" ]]; then
  echo "[ERROR] 无法检测出口网卡，请手动设置。"
  exit 1
fi
echo "[INFO] 检测到出口网卡: $OUT_IFACE"

# -------------------------------
# 下载 CN IP 段
# -------------------------------
echo "[INFO] 正在下载中国大陆 IP 段..."
mkdir -p /etc
wget -qO "$CN_IP_FILE" "$CN_IP_URL"

if [ $? -ne 0 ] || [ ! -s "$CN_IP_FILE" ]; then
  echo "[ERROR] 下载失败，请检查网络或源。"
  exit 1
fi
echo "[OK] 已下载 $(wc -l < $CN_IP_FILE) 条 CN IP 段。"

# -------------------------------
# 创建/刷新 ipset
# -------------------------------
ipset list $IPSET_NAME >/dev/null 2>&1
if [ $? -ne 0 ]; then
  ipset create $IPSET_NAME hash:net
else
  ipset flush $IPSET_NAME
fi

while read ip; do
  [[ -z "$ip" ]] && continue
  ipset add $IPSET_NAME $ip
done < "$CN_IP_FILE"

echo "[OK] ipset 更新完成。"

# -------------------------------
# 设置防火墙规则
# -------------------------------
iptables -C OUTPUT -m set --match-set $IPSET_NAME dst -o $OUT_IFACE -j DROP 2>/dev/null
if [ $? -ne 0 ]; then
  iptables -I OUTPUT -m set --match-set $IPSET_NAME dst -o $OUT_IFACE -j DROP
  echo "[OK] 已添加防火墙规则。"
else
  echo "[INFO] 已存在规则，跳过添加。"
fi

ipset save > /etc/ipset.rules
iptables-save > /etc/iptables.rules

# -------------------------------
# 定时任务
# -------------------------------
CRON_LINE="0 2 * * * root /usr/local/bin/block_cn.sh >/dev/null 2>&1"
if ! grep -q "block_cn.sh" /etc/crontab; then
  echo "$CRON_LINE" >> /etc/crontab
  echo "[OK] 已添加每日自动更新任务。"
fi

# -------------------------------
# 验证是否生效
# -------------------------------
echo "[INFO] 验证中..."
CN_IP=$(dig +short www.baidu.com | head -n 1)
US_IP=$(dig +short www.google.com | head -n 1)

if [ -n "$CN_IP" ]; then
  curl -s -I --max-time 5 $CN_IP >/dev/null
  if [ $? -ne 0 ]; then
    echo "✅ 百度无法访问（已屏蔽中国大陆 IP）"
  else
    echo "⚠️ 百度仍可访问（可能规则未生效）"
  fi
fi

if [ -n "$US_IP" ]; then
  curl -s -I --max-time 5 $US_IP >/dev/null
  if [ $? -eq 0 ]; then
    echo "✅ Google 可访问（出口正常）"
  else
    echo "⚠️ Google 无法访问（请检查出口网络）"
  fi
fi

echo "[DONE] CN IP 屏蔽配置完成。"
