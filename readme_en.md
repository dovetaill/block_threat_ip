# Advanced Automated Firewall Script (ipset + Fail2ban Integration)

**Version: 7.0**

This is a powerful Shell script designed to build an intelligent, efficient, and self-learning active defense firewall system using `iptables` and `ipset`. It not only loads static blacklists but also deeply integrates with `Fail2ban`'s dynamic banning capabilities to automatically and permanently block dynamically discovered attackers.

---

## 📖 Table of Contents

- [✨ Core Features](#-core-features)
- [🤔 How It Works: Why is This Approach Better?](#-how-it-works-why-is-this-approach-better)
- [⚙️ System Requirements](#-system-requirements)
- [🚀 Quick Start Guide](#-quick-start-guide)
  - [Step 1: Prepare the Script](#step-1-prepare-the-script)
  - [Step 2: (Important) Configure Fail2ban](#step-2-important-configure-fail2ban)
  - [Step 3: (Optional) Create Static Blacklists](#step-3-optional-create-static-blacklists)
  - [Step 4: Run the Script](#step-4-run-the-script)
- [✅ How to Verify the Results](#-how-to-verify-the-results)
  - [1. Check the Execution Log (Recommended)](#1-check-the-execution-log-recommended)
  - [2. List the Contents of the IPSet Blacklists](#2-list-the-contents-of-the-ipset-blacklists)
  - [3. Check the iptables Firewall Rules](#3-check-the-iptables-firewall-rules)
- [🤖 Automate with Cron](#-automate-with-cron)
- [⚠️ Risks and Important Notes](#️-risks-and-important-notes)
- [🔧 Troubleshooting](#-troubleshooting)
- [❌ How to Revert All Changes](#-how-to-revert-all-changes)

---

## ✨ Core Features

- **Automated Dependency Management**: Automatically detects and installs necessary packages like `iptables`, `ipset`, `curl`, **`fail2ban`**, and persistence tools.
- **Deep Fail2ban Integration**:
    - Installs, starts, and enables the `fail2ban` service automatically.
    - Gathers all **currently** banned IPs from `fail2ban` and adds them to the `ipset` blacklist.
    - **Advanced Log Parsing**: Prioritizes `journalctl` for robustly querying Fail2ban's entire log history. If unavailable, it intelligently falls back to finding and parsing all **rotated and compressed log files** (`.log`, `.log.1`, `.log.gz`, etc.), ensuring no historical ban is missed.
- **Batch File Processing**: Automatically reads and processes all `.txt` files in the script's directory as a source for static blacklists.
- **Intelligent Format Recognition**: Can parse mixed content within the same file, including **individual IPs**, **IP ranges (CIDR)**, and **ASN numbers**.
- **High-Performance Blocking**: Utilizes `ipset` to manage blacklists, requiring only two `iptables` rules to block thousands of IPs with minimal performance impact.
- **IPv4 & IPv6 Support**: Automatically creates and manages separate blacklists for IPv4 (`blacklist_ipv4`) and IPv6 (`blacklist_ipv6`).
- **Persistence**: Ensures all firewall rules, including `ipset` sets, are saved and restored after a system reboot.
- **Idempotent by Design**: The script is safe to run repeatedly. It automatically handles duplicates and only performs incremental updates.
- **Detailed Logging**: All significant actions are logged with timestamps to `/var/log/autoban.log` for easy auditing.
- **Non-Destructive**: Respects the user's existing environment. It **will not uninstall** a pre-existing `fail2ban` installation and will **automatically create a basic configuration** if one is missing.

## 🤔 How It Works: Why is This Approach Better?

Traditional `fail2ban` creates a separate `iptables` rule for every single IP it bans. When the ban list grows to thousands of entries, this can slightly degrade network performance as the kernel has to traverse a long chain of rules.

This script enhances this process by using `ipset`:

1.  **Performance Boost**: The script adds all IPs to be blocked into a single `ipset` collection. `iptables` then only needs one rule: "DROP any traffic coming from a source IP that is a member of this set." Querying an `ipset` is significantly faster than traversing thousands of individual `iptables` rules.
2.  **Self-Learning & Persistence**: `fail2ban` is an excellent real-time threat detector, but its bans are often temporary. This script periodically scans `fail2ban`'s logs and promotes these temporarily-banned IPs to a **permanent** blacklist, effectively creating a firewall that "learns" and "remembers" past attackers.

## ⚙️ System Requirements

- **OS**: A Linux distribution based on Debian/Ubuntu or CentOS/RHEL.
- **Permissions**: `root` or `sudo` access is required.
- **Network**: An active internet connection is needed for package installation and ASN lookups.

## 🚀 Quick Start Guide

### Step 1: Prepare the Script

Save the script's content as `blocklist.sh` and make it executable:
```bash
chmod +x blocklist.sh
```

### Step 2: (Important) Configure Fail2ban

This script will install `fail2ban`, but it won't configure its policies. You must define what services `fail2ban` should protect. A basic and highly recommended setup is to protect SSH from brute-force attacks.

1.  Create a local configuration file to avoid being overwritten by updates:
    ```bash
    sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    ```
2.  Edit the new file:
    ```bash
    sudo nano /etc/fail2ban/jail.local
    ```
3.  Find the `[sshd]` section and ensure it is **enabled** and the **backend is set to `systemd`** (the most compatible method):
    ```ini
    [sshd]
    enabled = true
    backend = systemd
    ```
    *If your `jail.local` file is empty, you can simply paste the content above into it.*

4.  Save the file and restart the `fail2ban` service:
    ```bash
    sudo systemctl restart fail2ban
    ```
`fail2ban` will now start monitoring SSH login attempts and ban attackers.

### Step 3: (Optional) Create Static Blacklists

In the **same directory** as `blocklist.sh`, create one or more text files ending with `.txt` (e.g., `scanners.txt`, `my_blocklist.txt`).

Inside these files, add one entry per line. You can mix individual IPs, IP ranges (CIDR), and ASNs.

**Example `scanners.txt` content:**
```txt
# === Shodan Scanners ===
198.20.64.0/22
AS204996

# === A malicious IP I found ===
123.123.123.123

# === An IPv6 range to block ===
2602:80d:1000::/80
```

### Step 4: Run the Script

Execute the script with `root` privileges:
```bash
sudo ./blocklist.sh
```
The script will now perform all necessary actions automatically.

## ✅ How to Verify the Results

### 1. Check the Execution Log (Recommended)

A summary of all actions is logged here, making it the easiest way to check what the script did:
```bash
tail -f /var/log/autoban.log
```
You will see output clearly marking the source of each added entry:
```log
2025-09-13 10:30:01 -   [Live Ban] Found IP: 192.0.2.1 (from Jail: sshd)
2025-09-13 10:30:02 -   [Historic Log] Found IP: 198.51.100.10
2025-09-13 10:30:05 -   [Static List] Processing entry: AS12345
```

### 2. List the Contents of the IPSet Blacklists

- **View IPv4 blacklist**: `sudo ipset list blacklist_ipv4`
- **View IPv6 blacklist**: `sudo ipset list blacklist_ipv6`

### 3. Check the iptables Firewall Rules

- **IPv4**: `sudo iptables -L INPUT -v -n --line-numbers`
- **IPv6**: `sudo ip6tables -L INPUT -v -n --line-numbers`

You should see a `DROP` rule at the top of the `INPUT` chain that refers to the corresponding `ipset` collection.

## 🤖 Automate with Cron

Add this script to a cron job for automatic, incremental updates to your blacklist.

1.  Open the crontab editor: `sudo crontab -e`
2.  Add a line to run the script at a desired interval. For example, to run it every day at 3:00 AM:
    ```
    0 3 * * * /path/to/your/blocklist.sh
    ```
    *Be sure to replace `/path/to/your/blocklist.sh` with the **absolute path** to your script.*

## ⚠️ Risks and Important Notes

- **WARNING: ASN Blocking is a Double-Edged Sword**
  Blocking an entire ASN will block **all** IP addresses owned by that network. While highly effective against scanners, this carries a significant risk of **collateral damage**. For instance, blocking a major cloud provider (AWS, Google Cloud) could prevent you from accessing legitimate websites and services hosted on their platform. **Only block an ASN if you fully understand the consequences.**

- **SSH Lockout Risk**
  Always maintain a backup connection (like a physical console or a separate SSH session) when manipulating firewall rules to avoid accidentally locking yourself out.

- **Firewall Conflicts**
  On CentOS/RHEL systems, this script will attempt to disable `firewalld`. Ensure no other critical services rely on it.

## 🔧 Troubleshooting

- **Fail2ban service fails to start**: Run `sudo journalctl -xeu fail2ban.service` to view detailed error logs. This is almost always due to a syntax error in `/etc/fail2ban/jail.local`.
- **ASN lookup fails**: Check your server's internet connectivity and try running `curl api.hackertarget.com` manually.

## ❌ How to Revert All Changes

To completely remove the blocks added by this script:

1.  **Delete the rules from the `INPUT` chain**:
    ```bash
    # IPv4
    sudo iptables -D INPUT -m set --match-set blacklist_ipv4 src -j DROP
    # IPv6
    sudo ip6tables -D INPUT -m set --match-set blacklist_ipv6 src -j DROP
    ```
2.  **Flush the `ipset` sets (clears all IPs)**:
    ```bash
    sudo ipset flush blacklist_ipv4
    sudo ipset flush blacklist_ipv6
    ```
3.  **Destroy the `ipset` sets (deletes the sets themselves)**:
    ```bash
    sudo ipset destroy blacklist_ipv4
    sudo ipset destroy blacklist_ipv6
    ```
4.  **Save the now-empty rules (Important)**:
    ```bash
    # Debian/Ubuntu
    sudo netfilter-persistent save

    # CentOS/RHEL
    sudo service iptables save
    sudo service ip6tables save
    ```