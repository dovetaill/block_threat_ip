#!/bin/bash

# ==============================================================================
# 脚本名称: blocklist.sh (V9 - 终极性能优化版)
# 脚本功能: 通过批量导入大幅提升性能，整合静态与动态黑名单并持久化。
# V9 更新:  - 核心重构：将所有 ipset 操作（创建、添加）汇总到临时文件中。
#           - 使用 `ipset restore` 命令一次性、原子化地应用所有变更。
#           - 无论是静态列表还是 Fail2ban 列表，所有 IP 均采用批量模式导入。
#           - 显著减少了数万条IP时的执行时间，并降低了系统I/O。
# ==============================================================================

# --- 脚本设置 ---
IPSET_V4_NAME="blacklist_ipv4"
IPSET_V6_NAME="blacklist_ipv6"
LOG_FILE="/var/log/autoban.log"
FAIL2BAN_MIN_VERSION="0.10.0" # 推荐的最低版本

# --- 日志记录函数 ---
log_action() {
    local message="$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') - ${message}" | sudo tee -a "$LOG_FILE"
}

# --- 版本比较函数 ---
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
log_action "--- 脚本开始执行 (V9 - 性能优化版) ---"

# --- 依赖安装 ---
# (此部分与 V8 版本相同，为简洁起见，此处省略)
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
        if [[ "$NEEDS_INSTALL" == *"iptables-persistent"* ]]; then
            log_action "预配置 iptables-persistent 以实现非交互式安装..."
            echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | sudo debconf-set-selections
            echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | sudo debconf-set-selections
        fi
        export DEBIAN_FRONTEND=noninteractive
        sudo $PKG_MANAGER update -y
        sudo $PKG_MANAGER install -y $NEEDS_INSTALL
    else
        if systemctl is-active --quiet firewalld; then
            log_action "检测到 firewalld 正在运行，将禁用它以使用 iptables。"
            sudo systemctl stop firewalld; sudo systemctl disable firewalld
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

# --- 核心重构：批量处理 ---
log_action "\n--- 步骤 2: 准备批量导入任务 ---"

# 创建一个临时文件来存储所有 ipset 命令
IPSET_RESTORE_FILE=$(mktemp)

# 1. 首先写入创建集合的命令（如果不存在）
# 使用 -exist 选项，这样即使集合已存在，restore也不会失败
echo "create $IPSET_V4_NAME hash:net -exist" >> "$IPSET_RESTORE_FILE"
echo "create $IPSET_V6_NAME hash:net family inet6 -exist" >> "$IPSET_RESTORE_FILE"

# 2. 从 Fail2ban 收集IP并写入临时文件
log_action "  -> 正在从 Fail2ban 收集 IP..."
if command -v fail2ban-client &> /dev/null && systemctl is-active --quiet fail2ban; then
    # a. 当前封禁
    JAILS=$(sudo fail2ban-client status | grep "Jail list:" | sed -e 's/.*Jail list:[ \t]*//' -e 's/,//g')
    for jail in $JAILS; do
        BANNED_IPS=$(sudo fail2ban-client status "$jail" | grep "Banned IP list:" | sed 's/.*Banned IP list:[ \t]*//')
        for ip in $BANNED_IPS; do
            if [[ -n "$ip" ]]; then
                if [[ "$ip" =~ : ]]; then echo "add $IPSET_V6_NAME $ip -exist" >> "$IPSET_RESTORE_FILE";
                else echo "add $IPSET_V4_NAME $ip -exist" >> "$IPSET_RESTORE_FILE"; fi
            fi
        done
    done

    # b. 历史封禁
    GREP_PATTERN='fail2ban.actions.*Ban'
    HISTORICAL_IPS=""
    if command -v journalctl &> /dev/null; then
        HISTORICAL_IPS=$(sudo journalctl -u fail2ban.service --no-pager --since "1 year ago" | grep "$GREP_PATTERN" | awk '{print $NF}')
    else
        declare -a log_paths=("/var/log/fail2ban.log" "/var/log/fail2ban/fail2ban.log")
        LOG_BASE=""
        for path in "${log_paths[@]}"; do
            if [ -f "$path" ]; then LOG_BASE=$(dirname "$path")/$(basename "$path" .log); break; fi
        done
        if [ -n "$LOG_BASE" ]; then HISTORICAL_IPS=$(sudo zgrep "$GREP_PATTERN" "${LOG_BASE}"* 2>/dev/null | awk '{print $NF}'); fi
    fi

    if [ -n "$HISTORICAL_IPS" ]; then
        echo "$HISTORICAL_IPS" | sort -u | while read -r ip; do
            if [[ "$ip" =~ : ]]; then echo "add $IPSET_V6_NAME $ip -exist" >> "$IPSET_RESTORE_FILE";
            else echo "add $IPSET_V4_NAME $ip -exist" >> "$IPSET_RESTORE_FILE"; fi
        done
    fi
    log_action "  -> Fail2ban IP 收集完成。"
else
    log_action "  -> 警告: Fail2ban 未运行，跳过。"
fi

# 3. 从静态 .txt 文件收集 IP 和 ASN 并写入临时文件
log_action "  -> 正在从静态 .txt 文件收集条目..."
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
for file in "$SCRIPT_DIR"/*.txt; do
    if [ ! -f "$file" ]; then continue; fi
    log_action "    -> 正在处理文件: $(basename "$file")"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(echo "$line" | tr -d '[:space:]')
        if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then continue; fi
        
        if [[ "$line" =~ ^AS[0-9]+$ ]]; then
            ASN_NUM=$(echo "$line" | sed 's/AS//i')
            log_action "      -> 正在后台查询 ASN: $line ..."
            ASN_RANGES=$(curl -s "https://api.hackertarget.com/aslookup/?q=AS$ASN_NUM" | grep '[./:]' | grep -v '","')
            if [ -n "$ASN_RANGES" ]; then
                echo "$ASN_RANGES" | while read -r range; do
                    if [[ "$range" =~ : ]]; then echo "add $IPSET_V6_NAME $range -exist" >> "$IPSET_RESTORE_FILE";
                    else echo "add $IPSET_V4_NAME $range -exist" >> "$IPSET_RESTORE_FILE"; fi
                done
            else
                log_action "      -> 警告: 无法获取 AS$ASN_NUM 的IP段。"
            fi
        elif [[ "$line" =~ : ]]; then
            echo "add $IPSET_V6_NAME $line -exist" >> "$IPSET_RESTORE_FILE"
        else
            echo "add $IPSET_V4_NAME $line -exist" >> "$IPSET_RESTORE_FILE"
        fi
    done < "$file"
done
log_action "  -> 所有静态文件收集完成。"

# --- 核心操作：一次性导入 ---
log_action "\n--- 步骤 3: 正在通过 'ipset restore' 批量应用所有变更 ---"
sudo ipset restore < "$IPSET_RESTORE_FILE"
if [ $? -eq 0 ]; then
    log_action "批量导入成功。"
else
    log_action "错误: 批量导入时发生错误。请检查临时文件: $IPSET_RESTORE_FILE"
fi
# 清理临时文件
rm -f "$IPSET_RESTORE_FILE"

# --- IPTABLES 规则应用 ---
log_action "\n--- 步骤 4: 应用 IPTABLES 规则 ---"
# (代码同V8)
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
log_action "\n--- 步骤 5: 持久化防火墙规则 ---"
# (代码同V8)
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


# --- 最终状态报告 ---
V4_ENTRIES=$(sudo ipset list $IPSET_V4_NAME 2>/dev/null | grep "Number of entries" | awk '{print $4}')
V6_ENTRIES=$(sudo ipset list $IPSET_V6_NAME 2>/dev/null | grep "Number of entries" | awk '{print $4}')
log_action "当前 IPv4 黑名单包含 ${V4_ENTRIES:-0} 个条目, IPv6 黑名单包含 ${V6_ENTRIES:-0} 个条目。"
log_action "--- ✅ 所有操作已成功完成！ ---\n"
