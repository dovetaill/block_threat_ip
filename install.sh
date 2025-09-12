#!/bin/bash

# ==============================================================================
# 安装脚本: install.sh
# 功能: 自动从 GitHub 下载最新的 blocklist.sh 脚本和所有 .txt 黑名单文件，
#       并以 root 权限执行主脚本来部署防火墙规则。
# 使用方法: curl -sSL https://raw.githubusercontent.com/dovetaill/block_threat_ip/master/install.sh | sudo bash
# ==============================================================================

# --- 设置 ---
# GitHub 项目信息
GITHUB_USER="dovetaill"
GITHUB_REPO="block_threat_ip"
BRANCH="master" # ★★★ 这里是唯一的修改点 ★★★

# 本地工作目录
INSTALL_DIR="/opt/block_threat_ip"

# --- 函数 ---
# 打印信息
log() {
    echo "--- $1 ---"
}

# --- 脚本主体 ---

# 1. 检查 root 权限
if [ "$EUID" -ne 0 ]; then
  log "错误: 请以 root 权限运行此安装脚本。"
  echo "请使用: curl -sSL https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/install.sh | sudo bash"
  exit 1
fi

log "开始部署高级防火墙自动化脚本..."

# 2. 创建工作目录
log "创建工作目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# 3. 下载主脚本和所有 .txt 文件
log "正在从 GitHub 下载最新的脚本和黑名单..."

# 下载主脚本
curl -sSL "https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/blocklist.sh" -o "blocklist.sh"
if [ $? -ne 0 ]; then
    log "错误: 下载 blocklist.sh 失败，请检查网络或 GitHub 仓库地址。"
    exit 1
fi
chmod +x blocklist.sh
log "下载 blocklist.sh 成功。"

# 下载所有 .txt 文件 (通过 GitHub API 获取文件列表)
API_URL="https://api.github.com/repos/${GITHUB_USER}/${GITHUB_REPO}/contents/?ref=${BRANCH}"
curl -s "$API_URL" | grep "download_url" | grep "\.txt" | awk '{print $2}' | tr -d ',"' | xargs -n 1 curl -sSL -O
log "下载所有 .txt 黑名单文件成功。"

# 4. 执行主脚本
log "一切准备就绪，开始执行 blocklist.sh..."
echo "============================================================"

# 执行主脚本，它会自动处理依赖安装、配置和规则应用
./blocklist.sh

echo "============================================================"
log "部署完成！"
log "所有文件已下载到 $INSTALL_DIR 目录。"
log "您可以通过 'sudo crontab -e' 添加定时任务来定期运行:"
log "0 3 * * * ${INSTALL_DIR}/blocklist.sh"
log "请查看日志文件 /var/log/autoban.log 获取详细执行信息。"
