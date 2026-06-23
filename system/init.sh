#!/bin/bash
#########################################
# time: 20260621
# ab: good man
# Example
# A. bash init.sh  --mode base 
#  --mode base 
#  Do not install monitoring, do not configure firewall, turn off firewall, and disable firewall at startup.
#
# B. bash init.sh --mode init --monitor-ip 10.10.10.10
# --mode init 
# --monitor-ip 
# 配置监控对指定Ip:9100开放 [防火墙仍然关闭],安装node_exporter and docker
# 防火墙只有在--ports 8080,8443 和 --ssh-ip 1.1.1.1 时候开启
# c. bash init.sh --mode init --monitor-ip 10.10.10.10  --ports 8080,8443
#  --ports 
# No restrictions set, SSH port is open to the entire network, firewall configured, firewall enabled, firewall enabled on boot.
# bash init.sh \
#   --mode init \
#   --monitor-ip 10.10.10.10 \
#   --ports 8080,8443 \
#   --ssh-ip 1.1.1.1
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

  $0

  $0 --mode base \
    --pubkey <base64>
  $0 \
    --mode init \
    --monitor-ip <ip> \
    --pubkey <base64>

  $0 \
    --mode init \
    --monitor-ip <ip> \
    --ports 8080,8443 \
    --pubkey <base64>

  $0 \
    --mode init \
    --monitor-ip <ip> \
    --ports 8080,8443 \
    --ssh-ip <ip> \
    --pubkey <base64>

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
    ENABLE_FIREWALL=1
    PUBLIC_PORTS="$ALLOW_PORTS"
fi

# 从这里开始
case "$MODE" in
    base)
        [ -z "$MONITOR_IP" ] || fail "--monitor-ip is only valid in init mode"
        [ -z "$ALLOW_PORTS" ] || fail "--ports is only valid in init mode"
        [ -z "$SSH_ALLOW_IP" ] || fail "--ssh-ip is only valid in init mode"
        ;;
esac
case "$MODE" in
    "")
        ;;
    base)
        [ -n "$PUBKEY_B64" ] || \
            fail "--pubkey is required."
        ;;
    init)
        ENABLE_MONITOR=1

        [ -n "$MONITOR_IP" ] || \
            fail "--monitor-ip is required."

        validate_ipv4 "$MONITOR_IP" || \
            fail "Invalid monitor ip."

        if [ -n "$SSH_ALLOW_IP" ]; then
            ENABLE_FIREWALL=1
            validate_ipv4 "$SSH_ALLOW_IP" || \
                fail "Invalid ssh ip."
        fi
        [ -n "$PUBKEY_B64" ] || \
            fail "--pubkey is required."
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
disable_firewall() {

    log "Disable Firewall"

    if [ "$FAMILY" = "debian" ]; then

        if command -v ufw >/dev/null 2>&1; then
            ufw --force disable || true
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

    if [ "$FAMILY" = "debian" ]; then

        ufw --force reset

        ufw default deny incoming
        ufw default allow outgoing


        if [ -n "$SSH_ALLOW_IP" ]; then
            ufw allow from "$SSH_ALLOW_IP" to any port 22 proto tcp
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
            firewall-cmd --permanent \
                --add-rich-rule="rule family='ipv4' source address='${SSH_ALLOW_IP}' port protocol='tcp' port='22' accept"
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

        apt install -y \
            curl \
            wget \
            vim \
            git \
            jq \
            unzip \
            net-tools \
            htop \
            tree

    else

        dnf makecache

        dnf upgrade -y

        dnf install -y \
            curl \
            wget \
            vim \
            git \
            jq \
            unzip \
            net-tools \
            htop \
            tree

    fi
}

# 输出 ANSI 颜色表
configure_ps1() {
    local user_home

    if [ -n "$SUDO_USER" ]; then
        user_home="/home/$SUDO_USER"
    else
        user_home="/root"
    fi
    # 普通用户
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
    # 当前 shell 生效
    if alias rm >/dev/null 2>&1; then
        unalias rm
    fi

    # 删除 ~/.bashrc 中的 rm -i
    [ -f ~/.bashrc ] && sed -i "/alias rm='rm -i'/d" ~/.bashrc
    # 删除 /root/.bashrc 中的 rm -i（root 用户）
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
        PUBKEY="$(printf '%s' "$PUBKEY_B64" | base64 -d)" || \
            fail "Invalid pubkey."

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
    echo "NoahsArk  configured"
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
    log "Configure Sysctl"
cat >/etc/sysctl.d/99-custom.conf <<EOF
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
vm.swappiness = 10
vm.max_map_count = 262144
EOF
    sysctl --system
}
install_docker() {
    log "Install Docker"
    if command -v docker >/dev/null 2>&1; then
        echo "Docker already installed"
        return
    fi
    if [ "$FAMILY" = "debian" ]; then
        apt install -y \
            ca-certificates \
            curl \
            gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
            > /etc/apt/sources.list.d/docker.list

        apt update

        apt install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    else
        dnf install -y dnf-plugins-core
        dnf config-manager --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo
        dnf install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin
    fi
    systemctl enable docker
    systemctl start docker
}
configure_timezone() {
    log "Configure Timezone"
    timedatectl set-timezone Asia/Shanghai
    if [ "$FAMILY" = "debian" ]; then
        apt install -y chrony
        systemctl enable --now chrony
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
    docker info >/dev/null 2>&1 || \
    fail "Docker start failed"
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
    docker inspect node_exporter >/dev/null 2>&1 || \
        fail "node_exporter start failed"    
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
    #chmod +x /usr/local/bin/check_edge_node.sh
    #crontab -l 2>/dev/null | grep -q check_edge_node.sh || \
    #(
    #    crontab -l 2>/dev/null
    #    echo "* * * * * /usr/local/bin/check_edge_node.sh >/dev/null 2>&1"
    #) | crontab -
    #/usr/local/bin/check_edge_node.sh
}

summary() {
    log "Initialization Completed"
    echo "OS Family      : $FAMILY"
    echo "OS             : $ID"
    echo "Version        : $VERSION_ID"
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
        echo "Firewall       : Disabled"
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
    if [ "$MODE" = "base" ] || [ "$MODE" = "init" ]; then
    echo "setup_NoahsArk"
        setup_NoahsArk
    fi
    # setup_NoahsArk
    update_system
        echo "update_system"
    configure_limits
        echo "configure_limits"
    configure_sysctl
        echo "configure_sysctl"
    configure_ps1
        echo "configure_ps1"
    disable_rm_prompt
        echo "disable_rm_prompt"
    configure_timezone
    echo "configure_timezone"
    if [ "$ENABLE_FIREWALL" = "1" ]; then

        configure_firewall
                echo "ENABLE_FIREWALL"
    else
        disable_firewall
            echo "disable_firewall"
    fi

    if [ "$ENABLE_MONITOR" = "1" ]; then
        install_docker
            echo "install_docker"
        configure_docker
            echo "configure_docker"
        install_node_exporter
            echo "install_node_exporter"
        install_edge_monitor
            echo "install_edge_monitor"
    fi

    summary
}

main "$@"