#!/bin/bash

# ==============================================================================
# 脚本名称: blocklist.sh (V7 - 智能配置与版本检查版)
# 脚本功能: 自动整合静态IP/ASN黑名单与Fail2ban动态封禁列表，并持久化。
# V7 更新:  - 自动为新安装的 Fail2ban 创建基础的 sshd 防护配置 (jail.local)。
#           - 检查已安装的 Fail2ban 版本，若低于推荐版本则提示用户。
#           - 不会卸载用户已有的 Fail2ban，遵循非破坏性原则。
# 使用方法: sudo ./blocklist.sh
# ==============================================================================

# --- 脚本设置 ---
IPSET_V4_NAME="blacklist_ipv4"
IPSET_V6_NAME="blacklist_ipv6"
LOG_FILE="/var/log/autoban.log"
FAIL2BAN_MIN_VERSION="0.10.0" # 设置一个推荐的最低版本

# --- 日志记录函数 ---
# $1: 日志消息
log_action() {
    local message="$1"
    # 同时输出到控制台和日志文件，并附带时间戳
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | sudo tee -a "$LOG_FILE"
}

# --- 版本比较函数 ---
# $1: 版本1, $2: 版本2
# 返回 0 如果 版本1 = 版本2
# 返回 1 如果 版本1 > 版本2
# 返回 2 如果 版本1 < 版本2
version_compare() {
    if [[ "$1" == "$2" ]]; then return 0; fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    for ((i=0; i<${#ver1[@]} || i<${#ver2[@]}; i++)); do
        if ((10#${ver1[i]:-0} > 10#${ver2[i]:-0})); then return 1; fi
        if ((10#${ver1[i]:-0} < 10#${ver2[i]:-0})); then return 2; fi
    done
    return 0
}

# --- 基础检查 ---
if [ "$EUID" -ne 0 ]; then
  echo "错误: 请以root权限运行此脚本 (使用 sudo ./blocklist.sh)"
  exit 1
fi

sudo touch "$LOG_FILE"; sudo chmod 644 "$LOG_FILE"
log_action "--- 脚本开始执行 (V7) ---"

# --- 依赖安装 ---
log_action "--- 步骤 1: 检查并安装所需依赖 ---"

if [ -f /etc/debian_version ]; then
    PKG_MANAGER="apt-get"
    PACKAGES="iptables ipset curl fail2ban iptables-persistent"
    log_action "检测到 Debian/Ubuntu 系统。"
elif [ -f /etc/redhat-release ]; then
    PKG_MANAGER="yum"
    PACKAGES="iptables ipset curl fail2ban iptables-services"
    log_action "检测到 CentOS/RHEL 系统。"
else
    log_action "错误: 无法识别的操作系统。"; exit 1
fi

# 处理已安装的 Fail2ban
if command -v fail2ban-server &> /dev/null; then
    CURRENT_VERSION=$(fail2ban-server --version 2>/dev/null | awk '{print $2}')
    if [ -n "$CURRENT_VERSION" ]; then
        log_action "检测到已安装 Fail2ban 版本: $CURRENT_VERSION"
        version_compare "$CURRENT_VERSION" "$FAIL2BAN_MIN_VERSION"
        if [[ $? -eq 2 ]]; then
            log_action "警告: 您当前的 Fail2ban 版本 ($CURRENT_VERSION) 低于推荐的最低版本 ($FAIL2BAN_MIN_VERSION)。"
            log_action "      脚本将继续运行，但建议您手动升级 Fail2ban 以获得更好的性能和安全性。"
        fi
    fi
    # 从待安装列表中移除 fail2ban
    PACKAGES=$(echo "$PACKAGES" | sed 's/fail2ban//')
fi

NEEDS_INSTALL=""
for PKG in $PACKAGES; do
    if ! command -v $PKG &> /dev/null && ! rpm -q $PKG &> /dev/null; then
        if [ "$PKG" == "iptables-persistent" ] && [ -f /usr/sbin/netfilter-persistent ]; then continue; fi
        NEEDS_INSTALL="$NEEDS_INSTALL $PKG"
    fi
done

IS_FAIL2BAN_NEWLY_INSTALLED=0
if [[ "$NEEDS_INSTALL" == *"fail2ban"* ]]; then
    IS_FAIL2BAN_NEWLY_INSTALLED=1
fi

if [ -n "$NEEDS_INSTALL" ]; then
    log_action "正在准备安装:${NEEDS_INSTALL}"
    if [ "$PKG_MANAGER" == "apt-get" ]; then
        export DEBIAN_FRONTEND=noninteractive
        sudo $PKG_MANAGER update -y
        sudo $PKG_MANAGER install -y $NEEDS_INSTALL
    else
        if systemctl is-active --quiet firewalld; then
            log_action "检测到 firewalld 正在运行，将禁用它以使用 iptables。"
            sudo systemctl stop firewalld
            sudo systemctl disable firewalld
        fi
        sudo $PKG_MANAGER install -y $NEEDS_INSTALL
    fi
    log_action "依赖安装完成。"
else
    log_action "所有依赖已满足。"
fi

if [ $IS_FAIL2BAN_NEWLY_INSTALLED -eq 1 ]; then
    log_action "检测到 Fail2ban 是新安装的，正在创建基础的 SSH 防护配置..."
    JAIL_LOCAL="/etc/fail2ban/jail.local"
    if [ ! -f "$JAIL_LOCAL" ]; then
        log_action "创建配置文件: $JAIL_LOCAL"
        echo -e "[sshd]\nenabled = true\nbackend = systemd" | sudo tee "$JAIL_LOCAL" > /dev/null
        log_action "已为 sshd 启用基于 systemd 日志的防护。"
    else
        log_action "$JAIL_LOCAL 已存在，检查 sshd 配置..."
        if ! grep -q "\[sshd\]" "$JAIL_LOCAL"; then
            log_action "在 $JAIL_LOCAL 中未找到 [sshd] 配置，正在添加..."
            echo -e "\n[sshd]\nenabled = true\nbackend = systemd" | sudo tee -a "$JAIL_LOCAL" > /dev/null
        else
            log_action "[sshd] 配置已存在，不作修改。"
        fi
    fi
fi

if ! systemctl is-active --quiet fail2ban; then
    log_action "Fail2ban 未运行，正在启动并启用..."
    sudo systemctl restart fail2ban
    log_action "等待 3 秒确保 fail2ban 服务完全初始化..."
    sleep 3
    if ! systemctl is-active --quiet fail2ban; then
        log_action "警告: 无法启动 fail2ban 服务。请运行 'sudo journalctl -xeu fail2ban.service' 查看错误日志。"
    else
        log_action "Fail2ban 已成功启动并设置开机自启。"
    fi
else
    log_action "Fail2ban 服务正在运行。"
fi


# --- IPSET 初始化 ---
log_action "\n--- 步骤 2: 初始化 IPSET 集合 ---"
sudo ipset create $IPSET_V4_NAME hash:net -exist
sudo ipset create $IPSET_V6_NAME hash:net family inet6 -exist
log_action "IPSET 集合 '$IPSET_V4_NAME' 和 '$IPSET_V6_NAME' 已准备就绪。"


# --- Fail2ban 集成 ---
log_action "\n--- 步骤 3: 从 Fail2ban 导入封禁IP ---"
if command -v fail2ban-client &> /dev/null && systemctl is-active --quiet fail2ban; then
    
    log_action "正在读取 Fail2ban 当前封禁的 IP..."
    JAILS=$(sudo fail2ban-client status | grep "Jail list:" | sed -e 's/.*Jail list:[ \t]*//' -e 's/,//g')
    BANNED_NOW_COUNT=0
    for jail in $JAILS; do
        BANNED_IPS=$(sudo fail2ban-client status "$jail" | grep "Banned IP list:" | sed 's/.*Banned IP list:[ \t]*//')
        for ip in $BANNED_IPS; do
            if [[ -n "$ip" ]]; then
                log_action "  [实时封禁] 发现IP: $ip (来自Jail: $jail)"
                if [[ "$ip" =~ : ]]; then sudo ipset add $IPSET_V6_NAME "$ip" -exist; else sudo ipset add $IPSET_V4_NAME "$ip" -exist; fi
                ((BANNED_NOW_COUNT++))
            fi
        done
    done
    log_action "从 Fail2ban 当前活动封禁中处理了 $BANNED_NOW_COUNT 个IP。"

    log_action "正在分析 Fail2ban 历史封禁记录..."
    HISTORICAL_IPS=""
    HISTORICAL_COUNT=0
    GREP_PATTERN='fail2ban.actions.*Ban'

    if command -v journalctl &> /dev/null; then
        log_action "  -> 使用 journalctl 查询 fail2ban 服务日志..."
        HISTORICAL_IPS=$(sudo journalctl -u fail2ban.service --no-pager --since "1 year ago" | grep "$GREP_PATTERN" | awk '{print $NF}')
    else
        log_action "  -> journalctl 不可用，回退到文件系统查找日志..."
        declare -a log_paths=("/var/log/fail2ban.log" "/var/log/fail2ban/fail2ban.log")
        LOG_BASE=""
        for path in "${log_paths[@]}"; do
            if [ -f "$path" ]; then
                LOG_BASE=$(dirname "$path")/$(basename "$path" .log)
                break
            fi
        done

        if [ -n "$LOG_BASE" ]; then
            log_action "  -> 发现日志文件, 正在扫描 ${LOG_BASE}*"
            HISTORICAL_IPS=$(sudo zgrep "$GREP_PATTERN" "${LOG_BASE}"* 2>/dev/null | awk '{print $NF}')
        else
            log_action "  -> 警告: 未在标准位置找到 Fail2ban 日志文件，跳过历史记录分析。"
        fi
    fi
    
    if [ -n "$HISTORICAL_IPS" ]; then
        UNIQUE_IPS=$(echo "$HISTORICAL_IPS" | sort -u)
        for ip in $UNIQUE_IPS; do
            log_action "  [历史日志] 发现IP: $ip"
            if [[ "$ip" =~ : ]]; then sudo ipset add $IPSET_V6_NAME "$ip" -exist; else sudo ipset add $IPSET_V4_NAME "$ip" -exist; fi
            ((HISTORICAL_COUNT++))
        done
        log_action "从 Fail2ban 历史日志中添加了 $HISTORICAL_COUNT 个唯一的IP。"
    else
        log_action "未从历史日志中发现可添加的IP。"
    fi
else
    log_action "警告: Fail2ban 未安装或未运行，跳过 Fail2ban 集成步骤。"
fi


# --- 静态文件处理 ---
log_action "\n--- 步骤 4: 读取 .txt 文件并处理静态屏蔽列表 ---"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

for file in "$SCRIPT_DIR"/*.txt; do
    if [ ! -f "$file" ]; then continue; fi
    log_action "正在处理静态文件: $(basename "$file")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | tr -d '[:space:]')
        if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then continue; fi
        log_action "  [静态列表] 处理条目: $line"
        if [[ "$line" =~ ^AS[0-9]+$ ]]; then
            ASN_NUM=$(echo "$line" | sed 's/AS//i')
            log_action "    -> 正在查询 ASN: AS$ASN_NUM ..."
            ASN_RANGES_V4=$(curl -s "https://api.hackertarget.com/aslookup/?q=AS$ASN_NUM" | grep '\.')
            ASN_RANGES_V6=$(curl -s "https://api.hackertarget.com/aslookup/?q=AS$ASN_NUM" | grep ':' | grep -v '","')
            if [ -z "$ASN_RANGES_V4" ] && [ -z "$ASN_RANGES_V6" ]; then log_action "    -> 警告: 无法获取 AS$ASN_NUM 的IP段。"; continue; fi
            for range in $ASN_RANGES_V4; do sudo ipset add $IPSET_V4_NAME "$range" -exist; done
            for range in $ASN_RANGES_V6; do sudo ipset add $IPSET_V6_NAME "$range" -exist; done
            log_action "    -> 已将 AS$ASN_NUM 的所有IP段添加到黑名单。"
        elif [[ "$line" =~ : ]]; then sudo ipset add $IPSET_V6_NAME "$line" -exist
        else sudo ipset add $IPSET_V4_NAME "$line" -exist
        fi
    done < "$file"
done
log_action "所有 .txt 文件处理完毕。"


# --- IPTABLES 规则应用 ---
log_action "\n--- 步骤 5: 应用 IPTABLES 规则 ---"
if ! sudo iptables -C INPUT -m set --match-set $IPSET_V4_NAME src -j DROP > /dev/null 2>&1; then
    sudo iptables -I INPUT 1 -m set --match-set $IPSET_V4_NAME src -j DROP
    log_action "已添加 IPv4 黑名单规则。"
else
    log_action "IPv4 黑名单规则已存在。"
fi
if ! sudo ip6tables -C INPUT -m set --match-set $IPSET_V6_NAME src -j DROP > /dev/null 2>&1; then
    sudo ip6tables -I INPUT 1 -m set --match-set $IPSET_V6_NAME src -j DROP
    log_action "已添加 IPv6 黑名单规则。"
else
    log_action "IPv6 黑名单规则已存在。"
fi


# --- 规则持久化 ---
log_action "\n--- 步骤 6: 持久化防火墙规则 ---"
if [ "$PKG_MANAGER" == "apt-get" ]; then
    log_action "正在为 Debian/Ubuntu 保存规则..."
    sudo netfilter-persistent save
else
    log_action "正在为 CentOS/RHEL 保存规则并启用服务..."
    sudo service iptables save
    sudo service ip6tables save
    sudo systemctl enable iptables > /dev/null 2>&1
    sudo systemctl enable ip6tables > /dev/null 2>&1
fi
log_action "防火墙规则已持久化。"

V4_ENTRIES=$(sudo ipset list $IPSET_V4_NAME 2>/dev/null | grep "Number of entries" | awk '{print $4}')
V6_ENTRIES=$(sudo ipset list $IPSET_V6_NAME 2>/dev/null | grep "Number of entries" | awk '{print $4}')
log_action "当前 IPv4 黑名单包含 ${V4_ENTRIES:-0} 个条目, IPv6 黑名单包含 ${V6_ENTRIES:-0} 个条目。"
log_action "--- ✅ 所有操作已成功完成！ ---\n"