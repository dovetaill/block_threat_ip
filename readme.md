# 高级防火墙自动化脚本 (ipset + Fail2ban 整合版)

**版本: 7.0**

这是一个功能强大的 Shell 脚本，旨在通过 `iptables` 和 `ipset` 构建一个智能、高效、且具备“自我学习”能力的主动防御防火墙体系。它不仅能加载静态的黑名单，更能深度整合 `Fail2ban` 的动态封禁能力，将临时发现的攻击者自动转化为永久屏蔽。

---

## 📖 目录

- [✨ 核心功能](#-核心功能)
- [🤔 工作原理：为什么这样更优秀？](#-工作原理为什么这样更优秀)
- [⚙️ 系统要求](#-系统要求)
- [🚀 快速上手指南](#-快速上手指南)
  - [步骤 1: 准备脚本](#步骤-1-准备脚本)
  - [步骤 2: (重要) 配置 Fail2ban](#步骤-2-重要-配置-fail2ban)
  - [步骤 3: (可选) 创建静态黑名单](#步骤-3-可选-创建静态黑名单)
  - [步骤 4: 运行脚本](#步骤-4-运行脚本)
- [✅ 如何验证结果](#-如何验证结果)
  - [1. 查看执行日志 (最推荐)](#1-查看执行日志-最推荐)
  - [2. 查看 IPSet 黑名单内容](#2-查看-ipset-黑名单内容)
  - [3. 查看 iptables 防火墙规则](#3-查看-iptables-防火墙规则)
- [🤖 自动化运行 (Cron)](#-自动化运行-cron)
- [⚠️ 风险与重要注意事项](#️-风险与重要注意事项)
- [🔧 故障排查 (Troubleshooting)](#-故障排查-troubleshooting)
- [❌ 如何撤销所有屏蔽](#-如何撤销所有屏蔽)

---

## ✨ 核心功能

- **自动化依赖管理**: 自动检测并安装 `iptables`, `ipset`, `curl`, **`fail2ban`** 及规则持久化工具。
- **Fail2ban 深度整合**:
    - 自动安装、启动并启用 `fail2ban` 服务。
    - 自动读取 `fail2ban` **当前**封禁的所有 IP，并将其加入 `ipset` 黑名单。
    - **高级日志分析**: 优先使用 `journalctl` (适用于现代 systemd 系统) 查询 Fail2ban 全部历史日志。若不可用，则自动回退到文件系统，**智能查找并解析所有轮转和压缩的日志文件** (`.log`, `.log.1`, `.log.gz` 等)，确保不遗漏任何历史封禁记录。
- **批量文件读取**: 自动处理脚本目录下的所有 `.txt` 文件作为静态黑名单补充。
- **智能格式识别**: 在 `.txt` 文件中可混合处理**独立 IP**、**IP 段 (CIDR)** 和 **ASN 编号**。
- **高效屏蔽**: 利用 `ipset` 创建地址集合，仅用两条 `iptables` 规则即可屏蔽成千上万的 IP，性能极高。
- **支持 IPv4 和 IPv6**: 自动创建并管理 `blacklist_ipv4` 和 `blacklist_ipv6` 两个独立的黑名单集合。
- **规则持久化**: 确保服务器重启后所有屏蔽规则（包括 `ipset` 集合）依然有效。
- **幂等性设计**: 脚本可安全地**重复运行**。自动去重，只进行增量更新。
- **详细日志记录**: 所有关键操作都会记录到 `/var/log/autoban.log` 文件中，便于审计和跟踪。
- **非破坏性**: 尊重用户现有环境，**不会卸载**已安装的 `fail2ban`，并能为其**自动创建基础配置**。

## 🤔 工作原理：为什么这样更优秀？

传统的 `fail2ban` 为每一个被封禁的 IP 都创建一条独立的 `iptables` 规则。当封禁列表增长到数千个时，这会轻微影响网络性能。

本脚本采用 `ipset` 解决了这个问题：

1.  **性能提升**：脚本将所有要屏蔽的 IP 添加到一个 `ipset` 集合中。`iptables` 只需一条规则：“凡是源地址在这个集合里的，全部丢弃”。查询 `ipset` 的效率远高于遍历成百上千条 `iptables` 规则。
2.  **自动学习与持久化**：`fail2ban` 是出色的实时攻击检测器，但其封禁通常是暂时的。本脚本会定期扫描 `fail2ban` 的日志，将其发现的攻击者IP**永久**加入到 `ipset` 黑名单中，实现了防火墙的“自我学习”和“记忆强化”。

## ⚙️ 系统要求

- **操作系统**: 基于 Debian/Ubuntu 或 CentOS/RHEL 的 Linux 发行版。
- **权限**: 需要 `root` 或 `sudo` 权限。
- **网络**: 需要互联网连接，用于下载软件包和查询 ASN 信息。

## 🚀 快速上手指南

### 步骤 1: 准备脚本

将脚本内容保存为 `blocklist.sh`，并赋予执行权限。
```bash
chmod +x blocklist.sh
```

### 步骤 2: (重要) 配置 Fail2ban

本脚本会**安装** `fail2ban`，但**不会配置**它。一个最基础的配置是**防护 SSH 暴力破解**。

1.  创建本地配置文件（避免升级时被覆盖）：
    ```bash
    sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    ```
2.  编辑新创建的文件：
    ```bash
    sudo nano /etc/fail2ban/jail.local
    ```
3.  在文件中找到 `[sshd]` 部分，**确保其被启用且后端设置为 `systemd`**（这是最兼容的方式）：
    ```ini
    [sshd]
    enabled = true
    backend = systemd
    ```
    *如果 `jail.local` 是空的，直接将以上内容粘贴进去即可。*

4.  保存文件并重启 `fail2ban` 服务：
    ```bash
    sudo systemctl restart fail2ban
    ```
现在，`fail2ban` 就会开始监控 SSH 登录失败，并自动封禁攻击者。

### 步骤 3: (可选) 创建静态黑名单

在与 `blocklist.sh` **相同的目录**下，创建任意数量的以 `.txt` 结尾的文本文件（例如 `scanners.txt`, `my_blocklist.txt`）。

在文件中，每行输入一个您想屏蔽的条目。您可以将 IP、IP 段和 ASN 编号混合在一起。

**示例 `scanners.txt` 文件内容:**
```txt
# === Shodan Scanners ===
198.20.64.0/22
AS204996

# === A malicious IP I found ===
123.123.123.123

# === An IPv6 range to block ===
2602:80d:1000::/80
```

### 步骤 4: 运行脚本

以 `root` 权限执行脚本：
```bash
sudo ./blocklist.sh
```
脚本将自动完成所有操作。

## ✅ 如何验证结果

### 1. 查看执行日志 (最推荐)

所有操作的摘要都会记录在这里：
```bash
tail -f /var/log/autoban.log
```
您会看到类似这样的输出，清晰地标明了每个被添加 IP 的来源：
```log
2025-09-13 10:30:01 -   [实时封禁] 发现IP: 192.0.2.1 (来自Jail: sshd)
2025-09-13 10:30:02 -   [历史日志] 发现IP: 198.51.100.10
2025-09-13 10:30:05 -   [静态列表] 处理条目: AS12345
```

### 2. 查看 IPSet 黑名单内容

- **查看 IPv4 黑名单**: `sudo ipset list blacklist_ipv4`
- **查看 IPv6 黑名单**: `sudo ipset list blacklist_ipv6`

### 3. 查看 iptables 防火墙规则

- **IPv4**: `sudo iptables -L INPUT -v -n --line-numbers`
- **IPv6**: `sudo ip6tables -L INPUT -v -n --line-numbers`

您应该能在输出的第一行看到指向相应 `ipset` 集合的 `DROP` 规则。

## 🤖 自动化运行 (Cron)

将此脚本加入 `cron` 定时任务，即可实现黑名单的自动、增量更新。

1.  打开 `crontab` 编辑器： `sudo crontab -e`
2.  在文件末尾添加一行，例如设置每天凌晨3点运行：
    ```
    0 3 * * * /path/to/your/blocklist.sh
    ```
    *请务必将 `/path/to/your/blocklist.sh` 替换为您脚本的**绝对路径**。*

## ⚠️ 风险与重要注意事项

- **严重警告：ASN 封禁是一把双刃剑**
  屏蔽一个 ASN 意味着您会拒绝该 ASN 旗下的**所有** IP 地址。这对于屏蔽扫描器非常高效，但也存在**误伤**的风险。例如，屏蔽了某个大型云服务商（如 AWS, Google Cloud）的 ASN，可能会导致您自己无法访问托管在该平台上的正常网站。**请仅在明确了解后果的情况下屏蔽 ASN。**

- **SSH 远程连接风险**
  操作防火墙时请务必保持一个备用的 SSH 连接，或通过物理控制台访问，以防意外将自己锁定。

- **防火墙冲突**
  在 CentOS/RHEL 系统上，本脚本会自动尝试禁用 `firewalld`。请确保您的服务器没有依赖 `firewalld` 的特殊配置。

## 🔧 故障排查 (Troubleshooting)

- **Fail2ban 无法启动**: 运行 `sudo journalctl -xeu fail2ban.service` 查看详细错误日志，通常是 `jail.local` 配置文件有语法错误。
- **ASN 查询失败**: 检查服务器的网络连接，并尝试手动 `curl api.hackertarget.com` 看是否能通。

## ❌ 如何撤销所有屏蔽

如果您想完全移除此脚本添加的屏蔽，请按以下步骤操作：

1.  **从 `INPUT` 链中删除规则**:
    ```bash
    # IPv4
    sudo iptables -D INPUT -m set --match-set blacklist_ipv4 src -j DROP
    # IPv6
    sudo ip6tables -D INPUT -m set --match-set blacklist_ipv6 src -j DROP
    ```
2.  **清空 `ipset` 集合 (清除所有IP)**:
    ```bash
    sudo ipset flush blacklist_ipv4
    sudo ipset flush blacklist_ipv6
    ```
3.  **销毁 `ipset` 集合 (删除集合本身)**:
    ```bash
    sudo ipset destroy blacklist_ipv4
    sudo ipset destroy blacklist_ipv6
    ```
4.  **持久化空规则 (重要)**:
    ```bash
    # Debian/Ubuntu
    sudo netfilter-persistent save

    # CentOS/RHEL
    sudo service iptables save
    sudo service ip6tables save
    ```