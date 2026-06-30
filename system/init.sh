#!/bin/bash
#########################################
# time: 20260621
# ab: good man
# Example
# A. bash init.sh  --mode base --pubkey <base64>
#
# B. bash init.sh --mode init --monitor-ip 10.10.10.10 --pubkey <base64>
#  [防火墙关闭] 所有端口(含9100)对外开放。安装 node_exporter and docker。
#
# C. bash init.sh --mode init --monitor-ip 10.10.10.10 --ports 8080,8443 --pubkey <base64>
#  [防火墙关闭] 所有端口对外开放。
#
# D. bash init.sh --mode init --monitor-ip 10.10.10.10 --ports 8080,8443 --ssh-ip 1.1.1.1,2.2.2.2 --pubkey <base64>
#  [防火墙开启] 仅开放 ssh-ip 对 22 端口的访问，限制 monitor-ip 对 9100 的访问，全网开放 8080,8443。
#########################################
set -e

PUBKEY_B64=""
MODE=""
MONITOR_IP=""
ALLOW_PORTS=""
SSH_ALLOW_IP=""
PUBLIC_PORTS=""

ENABLE_MONITOR=0
ENABLE_FIREWALL=0
REGION="global"

validate_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

log() {
    echo
    echo "=================================================="
    echo "$1"
    echo "=================================================="
}
     
fail() {
    echo "ERROR: $1"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2
            ;;
        --monitor-ip)
            MONITOR_IP="$2"
            shift 2
            ;;
        --ports)
            ALLOW_PORTS="$2"
            shift 2
            ;;
        --ssh-ip)
            SSH_ALLOW_IP="$2"
            shift 2
            ;;
        --pubkey)
            PUBKEY_B64="$2"
            shift 2
            ;;            
        -h|--help)
            cat <<EOF
Usage:
  $0 --mode base --pubkey <base64>
  $0 --mode init --monitor-ip <ip> --pubkey <base64>
  $0 --mode init --monitor-ip <ip> --ports 8080,8443 --pubkey <base64>
  $0 --mode init --monitor-ip <ip> --ports 8080,8443 --ssh-ip 1.1.1.1,2.2.2.2 --pubkey <base64>
EOF
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

if [ -z "$MODE" ]; then
    fail "Please specify --mode base or --mode init"
fi

if [ -n "$ALLOW_PORTS" ]; then
    PUBLIC_PORTS="$ALLOW_PORTS"
fi

case "$MODE" in
    base)
        [ -z "$MONITOR_IP" ] || fail "--monitor-ip is only valid in init mode"
        [ -z "$ALLOW_PORTS" ] || fail "--ports is only valid in init mode"
        [ -z "$SSH_ALLOW_IP" ] || fail "--ssh-ip is only valid in init mode"
        [ -n "$PUBKEY_B64" ] || fail "--pubkey is required."
        ;;
    init)
        ENABLE_MONITOR=1

        [ -n "$MONITOR_IP" ] || fail "--monitor-ip is required."
        validate_ipv4 "$MONITOR_IP" || fail "Invalid monitor ip."
        [ -n "$PUBKEY_B64" ] || fail "--pubkey is required."

        if [ -n "$SSH_ALLOW_IP" ]; then
            ENABLE_FIREWALL=1
            IFS=',' read -ra SSH_IPS <<< "$SSH_ALLOW_IP"
            for ip in "${SSH_IPS[@]}"; do
                validate_ipv4 "$ip" || fail "Invalid ssh ip: $ip"
            done
        fi
        ;;        
    *)
        fail "Unknown mode: $MODE"
        ;;
esac

detect_os() {
    . /etc/os-release
    case "$ID" in
        ubuntu|debian)
            FAMILY="debian"
            PKG_INSTALL="apt install -y"
            PKG_UPDATE="apt update"
            FIREWALL="ufw"
            SSH_SERVICE="ssh"
            ;;
        rocky|almalinux|rhel|centos)
            FAMILY="rhel"
            PKG_INSTALL="dnf install -y"
            PKG_UPDATE="dnf makecache"
            FIREWALL="firewalld"
            SSH_SERVICE="sshd"
            ;;
        *)
            echo "Unsupported OS: $ID"
            exit 1
            ;;
    esac
    echo "OS Family : $FAMILY"
    echo "OS        : $ID"
    echo "Version   : $VERSION_ID"
}

detect_region() {
    log "Detect Region"
    # 使用 Cloudflare Trace 接口检测公网出口 IP 的国家代码，设置 3 秒超时
    local loc
    loc=$(curl -s -m 3 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep loc= | cut -d= -f2 || true)
    
    if [ "$loc" = "CN" ]; then
        REGION="cn"
        echo "Region detected: China (CN). Will use domestic mirrors."
    else
        REGION="global"
        echo "Region detected: Global (${loc:-UNKNOWN}). Will use default mirrors."
    fi
}

configure_mirrors() {
    if [ "$REGION" != "cn" ]; then
        return
    fi
    
    log "Configure Domestic Mirrors (Aliyun)"
    
    if [ "$FAMILY" = "debian" ]; then
        # Ubuntu 24.04+ 使用了新的 Deb822 格式
        if [ "$ID" = "ubuntu" ] && [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
            cp /etc/apt/sources.list.d/ubuntu.sources /etc/apt/sources.list.d/ubuntu.sources.bak
            sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list.d/ubuntu.sources
            sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list.d/ubuntu.sources
            sed -i 's/ports.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list.d/ubuntu.sources
            echo "APT mirrors replaced with Aliyun (Ubuntu Deb822 format)."
        elif [ -f /etc/apt/sources.list ]; then
            # 老版本 Ubuntu 和 Debian
            cp /etc/apt/sources.list /etc/apt/sources.list.bak
            if [ "$ID" = "ubuntu" ]; then
                sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
                sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
                sed -i 's/ports.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list
            elif [ "$ID" = "debian" ]; then
                sed -i 's/deb.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list
                sed -i 's/security.debian.org/mirrors.aliyun.com/g' /etc/apt/sources.list
            fi
            echo "APT mirrors replaced with Aliyun (Legacy format)."
        fi
    elif [ "$FAMILY" = "rhel" ]; then
        # CentOS 系列换源 (Best Effort)
        if [ "$ID" = "centos" ]; then
            sed -i 's/mirrorlist/#mirrorlist/g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
            sed -i 's|#baseurl=http://mirror.centos.org|baseurl=https://mirrors.aliyun.com|g' /etc/yum.repos.d/CentOS-* 2>/dev/null || true
            echo "YUM mirrors replaced with Aliyun."
        fi
    fi
}

disable_firewall() {
    log "Disable Firewall"
    if [ "$FAMILY" = "debian" ]; then
        if command -v ufw >/dev/null 2>&1; then
            ufw --force disable || true
            systemctl stop ufw
            systemctl disable ufw >/dev/null 2>&1 || true
        fi
    else
        if systemctl list-unit-files | grep -q '^firewalld.service'; then
            systemctl disable --now firewalld >/dev/null 2>&1 || true
        fi
    fi
}

configure_firewall() {
    log "Configure Firewall"
    IFS=',' read -ra PORTS <<< "$PUBLIC_PORTS"
    
    if [ -n "$SSH_ALLOW_IP" ]; then
        IFS=',' read -ra SSH_IPS <<< "$SSH_ALLOW_IP"
    fi

    if [ "$FAMILY" = "debian" ]; then
        ufw --force reset
        ufw default deny incoming
        ufw default allow outgoing

        if [ -n "$SSH_ALLOW_IP" ]; then
            for ip in "${SSH_IPS[@]}"; do
                ufw allow from "$ip" to any port 22 proto tcp
            done
        else
            ufw allow 22/tcp
        fi

        for p in "${PORTS[@]}"; do
            p=$(echo "$p" | xargs)
            [ -n "$p" ] && ufw allow "${p}/tcp"
        done

        if [ -n "$MONITOR_IP" ]; then
            ufw allow from "$MONITOR_IP" to any port 9100 proto tcp
        fi

        systemctl enable ufw
        ufw --force enable

    else
        systemctl enable firewalld
        systemctl start firewalld

        if [ -n "$SSH_ALLOW_IP" ]; then
            for ip in "${SSH_IPS[@]}"; do
                firewall-cmd --permanent \
                    --add-rich-rule="rule family='ipv4' source address='${ip}' port protocol='tcp' port='22' accept"
            done
        else
            firewall-cmd --permanent --add-port=22/tcp
        fi

        for p in "${PORTS[@]}"; do
            p=$(echo "$p" | xargs)
            [ -n "$p" ] && firewall-cmd --permanent --add-port="${p}/tcp"
        done

        if [ -n "$MONITOR_IP" ]; then
            firewall-cmd --permanent \
                --add-rich-rule="rule family='ipv4' source address='${MONITOR_IP}' port protocol='tcp' port='9100' accept"
        fi
        firewall-cmd --reload
    fi
}

update_system() {
    log "Update System"
    if [ "$FAMILY" = "debian" ]; then
        apt update
        DEBIAN_FRONTEND=noninteractive apt upgrade -y
        apt install -y curl wget vim git jq unzip net-tools htop tree
    else
        dnf makecache
        dnf upgrade -y
        dnf install -y curl wget vim git jq unzip net-tools htop tree
    fi
}

configure_ps1() {
    local user_home
    if [ -n "$SUDO_USER" ]; then
        user_home="/home/$SUDO_USER"
    else
        user_home="/root"
    fi
    touch "${user_home}/.bashrc"
    sed -i '/^PS1=/d' "${user_home}/.bashrc"
    cat >> "${user_home}/.bashrc" <<'EOF'
PS1='\[\e[1;34m\]\u\[\e[1;37m\]@\[\e[1;36m\]\h\[\e[1;37m\]:\[\e[1;95m\]\w\[\e[1;37m\]\$\[\e[0m\] '
EOF
    sed -i '/^PS1=/d' /root/.bashrc
    cat >> /root/.bashrc <<'EOF'
PS1='\[\e[1;31m\]\u\[\e[1;37m\]@\[\e[1;36m\]\h\[\e[1;37m\]:\[\e[1;95m\]\w\[\e[1;31m\]#\[\e[0m\] '
EOF
    if [ "$EUID" -eq 0 ]; then
        PS1='\[\e[1;31m\]\u\[\e[1;37m\]@\[\e[1;36m\]\h\[\e[1;37m\]:\[\e[1;95m\]\w\[\e[1;31m\]#\[\e[0m\] '
    else
        PS1='\[\e[1;34m\]\u\[\e[1;37m\]@\[\e[1;36m\]\h\[\e[1;37m\]:\[\e[1;95m\]\w\[\e[1;37m\]\$\[\e[0m\] '
    fi
}

disable_rm_prompt() {
    if alias rm >/dev/null 2>&1; then
        unalias rm
    fi
    [ -f ~/.bashrc ] && sed -i "/alias rm='rm -i'/d" ~/.bashrc
    if [ "$(id -u)" -eq 0 ] && [ -f /root/.bashrc ]; then
        sed -i "/alias rm='rm -i'/d" /root/.bashrc
    fi
    echo "rm prompt disabled."
}

setup_NoahsArk() {
    log "Configure NoahsArk"
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    if [ -n "$PUBKEY_B64" ]; then
        PUBKEY="$(printf '%s' "$PUBKEY_B64" | base64 -d)" || fail "Invalid pubkey."
        grep -qxF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || \
            printf '%s\n' "$PUBKEY" >> /root/.ssh/authorized_keys
    fi

    sed -ri '/^#?PermitRootLogin/d' /etc/ssh/sshd_config
    sed -ri '/^#?PubkeyAuthentication/d' /etc/ssh/sshd_config
    sed -ri '/^#?PasswordAuthentication/d' /etc/ssh/sshd_config
    cat >> /etc/ssh/sshd_config <<EOF
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication yes
EOF
    SSHD_BIN="$(command -v sshd)"
    [ -x "$SSHD_BIN" ] || fail "NoahsArk not found"
    "$SSHD_BIN" -t || fail "NoahsArk config test failed"
    systemctl reload "${SSH_SERVICE}"
    echo "NoahsArk configured"
}

configure_limits() {
    log "Configure Limits" 
cat >/etc/security/limits.d/99-custom.conf <<EOF
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
* soft nproc 65535
* hard nproc 65535
EOF
}

configure_sysctl() {
    log "Configure Sysctl 16g ubuntu"
cat >/etc/sysctl.d/99-custom.conf <<EOF
fs.file-max = 1048576
net.core.somaxconn = 4096
# net.ipv4.tcp_max_syn_backlog = 4096
# net.ipv4.tcp_tw_reuse = 1
# net.ipv4.tcp_fin_timeout = 30
# net.ipv4.tcp_max_tw_buckets = 262144
# net.ipv4.tcp_keepalive_time = 600
# vm.swappiness = 10
EOF
    sysctl --system
}

install_docker() {
    log "Install Docker"
    if command -v docker >/dev/null 2>&1; then
        echo "Docker already installed"
        return
    fi
    
    # 根据地域动态选择 Docker 软件源
    local DOCKER_URL="https://download.docker.com"
    if [ "$REGION" = "cn" ]; then
        DOCKER_URL="https://mirrors.aliyun.com/docker-ce"
        echo "Using domestic Docker mirror: $DOCKER_URL"
    fi

    if [ "$FAMILY" = "debian" ]; then
        apt install -y ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        # 修复了原来硬编码为 ubuntu 的问题，改为根据系统 ID 自动适配
        curl -fsSL ${DOCKER_URL}/linux/${ID}/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_URL}/linux/${ID} $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
            > /etc/apt/sources.list.d/docker.list
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        cp /usr/libexec/docker/cli-plugins/docker-compose /usr/local/sbin
    else
        dnf install -y dnf-plugins-core
        dnf config-manager --add-repo ${DOCKER_URL}/linux/centos/docker-ce.repo
        dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
    systemctl enable docker
    systemctl start docker
}

configure_timezone() {
    log "Configure Timezone"
    timedatectl set-timezone Asia/Shanghai
    if [ "$FAMILY" = "debian" ]; then
        apt install -y chrony locales
        systemctl enable --now chrony
        locale-gen en_US.UTF-8 || true
        locale-gen en_GB.UTF-8 || true
        update-locale LANG=en_US.UTF-8 LC_TIME=C || true
        sed -i '/LC_TIME/d' /etc/default/locale
        echo "LC_TIME=en_DK.UTF-8" >> /etc/default/locale		
    else
        dnf install -y chrony
        systemctl enable --now chronyd
    fi
    timedatectl set-ntp true >/dev/null 2>&1 || true
    echo "Current Time : $(date)"
}

configure_docker() {
    log "Configure Docker"
    mkdir -p /etc/docker
cat >/etc/docker/daemon.json <<EOF
{
"log-driver": "json-file",
"log-opts": {
"max-size": "100m",
"max-file": "5"
},
"live-restore": true
}
EOF
    systemctl restart docker
    docker info >/dev/null 2>&1 || fail "Docker start failed"
}

install_node_exporter() {
    log "Install Node Exporter"
    mkdir -p /opt/node-exporter
    mkdir -p /var/lib/node_exporter/textfile_collector
cat >/opt/node-exporter/docker-compose.yml <<EOF
services:
    node_exporter:
        image: quay.io/prometheus/node-exporter:latest
        container_name: node_exporter
        command:
        - '--path.rootfs=/host'
        - '--collector.textfile.directory=/textfile'    
        network_mode: host
        pid: host
        restart: unless-stopped
        volumes:
        - '/:/host:ro,rslave'
        - '/var/lib/node_exporter/textfile_collector:/textfile:ro'    
EOF
    cd /opt/node-exporter
    docker compose pull
    docker compose up -d
    sleep 3
    docker inspect node_exporter >/dev/null 2>&1 || fail "node_exporter start failed"    
}

install_edge_monitor() {
    log "Install Edge Monitor"
    mkdir -p /var/lib/node_exporter/textfile_collector
cat >/usr/local/bin/check_edge_node.sh <<'EOF'
#!/bin/bash
PROCESS=0
PORT80=0
PORT443=0
pgrep -x edge-node >/dev/null 2>&1 && PROCESS=1
ss -lntH '( sport = :80 )' | grep -q . && PORT80=1
ss -lntH '( sport = :443 )' | grep -q . && PORT443=1
cat > /var/lib/node_exporter/textfile_collector/edge_node.prom <<EOT
edge_node_process_up $PROCESS
edge_node_port_up{port="80"} $PORT80
edge_node_port_up{port="443"} $PORT443
EOT
EOF
chmod +x /usr/local/bin/check_edge_node.sh
cat >/etc/cron.d/edge-node-exporter <<EOF
* * * * * root /usr/local/bin/check_edge_node.sh >/dev/null 2>&1
EOF
    /usr/local/bin/check_edge_node.sh
}

summary() {
    log "Initialization Completed"
    echo "OS Family      : $FAMILY"
    echo "OS             : $ID"
    echo "Version        : $VERSION_ID"
    echo "Region         : $REGION"
    echo
    if [ "$ENABLE_MONITOR" = "1" ]; then
        systemctl is-active docker >/dev/null 2>&1 \
            && echo "Docker         : OK" \
            || echo "Docker         : FAILED"
        docker inspect node_exporter >/dev/null 2>&1 \
            && echo "Node Exporter  : OK" \
            || echo "Node Exporter  : FAILED"
    else
        echo "Monitor        : Disabled"
    fi
    
    if [ "$ENABLE_FIREWALL" = "1" ]; then
        echo "Firewall       : Enabled"
    else
        echo "Firewall       : Disabled (All ports globally open)"
    fi
    
    if [ "$ENABLE_MONITOR" = "1" ]; then
        echo
        echo "Node Exporter Endpoint:"
        echo "http://$(hostname -I | awk '{print $1}'):9100/metrics"
    fi
    echo
    echo "SSH            : OK"
    echo
}

main() {
    detect_os
    detect_region

    if [ "$MODE" = "base" ] || [ "$MODE" = "init" ]; then
        echo "--> setup_NoahsArk"
        setup_NoahsArk
        echo "--> disable_firewall (Initial state)"
        disable_firewall
    fi

    echo "--> configure_mirrors"
    configure_mirrors

    echo "--> update_system"
    update_system
    
    echo "--> configure_limits"
    configure_limits
    
    echo "--> configure_sysctl"
    configure_sysctl
    
    echo "--> configure_ps1"
    configure_ps1
    
    echo "--> disable_rm_prompt"
    disable_rm_prompt
    
    echo "--> configure_timezone"
    configure_timezone

    if [ "$ENABLE_FIREWALL" = "1" ]; then
        echo "--> ENABLE_FIREWALL"
        configure_firewall
    fi

    if [ "$ENABLE_MONITOR" = "1" ]; then
        echo "--> install_docker"
        install_docker
        echo "--> configure_docker"
        configure_docker
        echo "--> install_node_exporter"
        install_node_exporter
        echo "--> install_edge_monitor"
        install_edge_monitor
    fi

    summary
}

main "$@"