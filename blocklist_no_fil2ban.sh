#!/bin/bash

# ==============================================================================
# 脚本名称: blocklist.sh (V3 - 最终修正版)
# 脚本功能: 自动读取目录下的txt文件, 屏蔽IP、IP段和ASN编号。
#           自动安装依赖并持久化iptables规则。
# V3 更新:  修正了 `tr-d` 命令的笔误。
# V2 更新:  增强了ASN查询的健壮性，会过滤掉API返回的非IP地址行。
# 使用方法: sudo ./blocklist.sh
# ==============================================================================

# --- 脚本设置 ---
IPSET_V4_NAME="blacklist_ipv4"
IPSET_V6_NAME="blacklist_ipv6"

# --- 基础检查 ---
if [ "$EUID" -ne 0 ]; then
  echo "错误: 请以root权限运行此脚本 (使用 sudo ./blocklist.sh)"
  exit 1
fi

# --- 依赖安装 ---
echo "--- 步骤 1: 检查并安装所需依赖 ---"

if [ -f /etc/debian_version ]; then
    PKG_MANAGER="apt-get"
    PACKAGES="iptables ipset curl iptables-persistent"
    echo "检测到 Debian/Ubuntu 系统。"
elif [ -f /etc/redhat-release ]; then
    PKG_MANAGER="yum"
    PACKAGES="iptables ipset curl iptables-services"
    echo "检测到 CentOS/RHEL 系统。"
else
    echo "错误: 无法识别的操作系统。"
    exit 1
fi

NEEDS_INSTALL=0
for PKG in $PACKAGES; do
    # 检查命令是否存在或RPM包是否已安装
    if ! command -v $PKG &> /dev/null && ! rpm -q $PKG &> /dev/null; then
        # 特殊处理 iptables-persistent，它可能没有直接的命令
        if [ "$PKG" == "iptables-persistent" ] && [ -f /usr/sbin/netfilter-persistent ]; then
            continue
        fi
        echo "正在准备安装: $PKG"
        NEEDS_INSTALL=1
    fi
done

if [ $NEEDS_INSTALL -eq 1 ]; then
    echo "正在更新软件包列表并安装依赖..."
    if [ "$PKG_MANAGER" == "apt-get" ]; then
        export DEBIAN_FRONTEND=noninteractive
        $PKG_MANAGER update -y
        $PKG_MANAGER install -y $PACKAGES
    else # yum
        if systemctl is-active --quiet firewalld; then
            echo "检测到 firewalld 正在运行，将禁用它以使用 iptables。"
            systemctl stop firewalld
            systemctl disable firewalld
        fi
        $PKG_MANAGER install -y $PACKAGES
    fi
    echo "依赖安装完成。"
else
    echo "所有依赖已安装。"
fi


# --- IPSET 初始化 ---
echo -e "\n--- 步骤 2: 初始化 IPSET 集合 ---"
sudo ipset create $IPSET_V4_NAME hash:net -exist
sudo ipset create $IPSET_V6_NAME hash:net family inet6 -exist
echo "IPSET 集合 '$IPSET_V4_NAME' 和 '$IPSET_V6_NAME' 已准备就绪。"


# --- 文件处理 ---
echo -e "\n--- 步骤 3: 读取 .txt 文件并处理屏蔽列表 ---"
SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

for file in "$SCRIPT_DIR"/*.txt; do
    if [ ! -f "$file" ]; then continue; fi

    echo "正在处理文件: $(basename "$file")"
    
    while IFS= read -r line || [[ -n "$line" ]]; do
        # ★★★ 修复点在这里 ★★★
        # 将 `tr-d` 修改为 `tr -d`
        line=$(echo "$line" | tr -d '[:space:]')
        
        if [[ -z "$line" ]] || [[ "$line" =~ ^# ]]; then
            continue
        fi

        if [[ "$line" =~ ^AS[0-9]+$ ]]; then
            ASN_NUM=$(echo "$line" | sed 's/AS//i')
            echo "  -> 正在查询 ASN: AS$ASN_NUM ..."
            
            ASN_RANGES_V4=$(curl -s "https://api.hackertarget.com/aslookup/?q=AS$ASN_NUM" | grep '\.')
            ASN_RANGES_V6=$(curl -s "https://api.hackertarget.com/aslookup/?q=AS$ASN_NUM" | grep ':' | grep -v '","')
            
            if [ -z "$ASN_RANGES_V4" ] && [ -z "$ASN_RANGES_V6" ]; then
                echo "    警告: 无法获取 AS$ASN_NUM 的IP段，可能API无响应或该ASN无IP。"
                continue
            fi
            
            for range in $ASN_RANGES_V4; do
                sudo ipset add $IPSET_V4_NAME "$range" -exist
            done
            
            for range in $ASN_RANGES_V6; do
                sudo ipset add $IPSET_V6_NAME "$range" -exist
            done
            
            echo "  -> 已将 AS$ASN_NUM 的所有IP段添加到黑名单。"

        elif [[ "$line" =~ : ]]; then
            sudo ipset add $IPSET_V6_NAME "$line" -exist

        else
            sudo ipset add $IPSET_V4_NAME "$line" -exist
        fi

    done < "$file"
done
echo "所有 .txt 文件处理完毕。"

# --- IPTABLES 规则应用 ---
echo -e "\n--- 步骤 4: 应用 IPTABLES 规则 ---"
if ! sudo iptables -C INPUT -m set --match-set $IPSET_V4_NAME src -j DROP > /dev/null 2>&1; then
    sudo iptables -I INPUT 1 -m set --match-set $IPSET_V4_NAME src -j DROP
    echo "已添加 IPv4 黑名单规则。"
else
    echo "IPv4 黑名单规则已存在。"
fi

if ! sudo ip6tables -C INPUT -m set --match-set $IPSET_V6_NAME src -j DROP > /dev/null 2>&1; then
    sudo ip6tables -I INPUT 1 -m set --match-set $IPSET_V6_NAME src -j DROP
    echo "已添加 IPv6 黑名单规则。"
else
    echo "IPv6 黑名单规则已存在。"
fi


# --- 规则持久化 ---
echo -e "\n--- 步骤 5: 持久化防火墙规则 ---"
if [ "$PKG_MANAGER" == "apt-get" ]; then
    echo "正在为 Debian/Ubuntu 保存规则..."
    sudo netfilter-persistent save
else
    echo "正在为 CentOS/RHEL 保存规则并启用服务..."
    sudo service iptables save
    sudo service ip6tables save
    sudo systemctl enable iptables > /dev/null 2>&1
    sudo systemctl enable ip6tables > /dev/null 2>&1
fi
echo "防火墙规则已持久化。"

echo -e "\n--- ✅ 所有操作已成功完成！ ---"