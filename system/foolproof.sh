#!/usr/bin/env bash

set -e

###############################################################################
# args
#
# $1 = USERONE
# $2 = PASSWORD
# $3 = SSSS
# $4 = PUBLIC_PORTS_ONEBYONE
# $5 = PUBLIC_PORTS
###############################################################################

USERONE="${1:-}"
PASSWORD="${2:-}"
SSSS="${3:-}"
PUBLIC_PORTS_ONEBYONE="${4:-}"
PUBLIC_PORTS="${5:-}"

if [ -z "$USERONE" ]; then
    echo "ERROR: USERONE is required"
    echo "Usage:"
    echo "bash $0 USERONE PASSWORD SSSS PUBLIC_PORTS_ONEBYONE PUBLIC_PORTS"
    exit 1
fi

if [ -z "$PASSWORD" ]; then
    echo "ERROR: PASSWORD is required"
    exit 1
fi

if [ -z "$SSSS" ]; then
    echo "ERROR: SSSS is required"
    exit 1
fi

if [ -z "$PUBLIC_PORTS_ONEBYONE" ]; then
    echo "ERROR: PUBLIC_PORTS_ONEBYONE is required"
    exit 1
fi

if [ -z "$PUBLIC_PORTS" ]; then
    echo "ERROR: PUBLIC_PORTS is required"
    exit 1
fi

# limits

cat >/etc/security/limits.d/99-custom.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576

* soft nproc 65535
* hard nproc 65535
root soft nproc 65535
root hard nproc 65535
EOF

# systemd limits

mkdir -p /etc/systemd/system.conf.d

cat >/etc/systemd/system.conf.d/99-custom.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF

mkdir -p /etc/systemd/user.conf.d

cat >/etc/systemd/user.conf.d/99-custom.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
EOF

systemctl daemon-reexec

# node-export

type node_exporter || curl -Lks4 \
    https://raw.githubusercontent.com/alayavijnana2026/Infra/refs/heads/main/system/node-export.sh \
    | bash


# public key

mkdir -p /root/.ssh
chmod 700 /root/.ssh

touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

PUBKEY="$(printf '%s' "$SSSS" | base64 -d 2>/dev/null)" || {
    echo "ERROR: Invalid base64 public key."
    exit 1
}

if [ -z "$PUBKEY" ]; then
    echo "ERROR: Decoded public key is empty."
    exit 1
fi

grep -qxF "$PUBKEY" /root/.ssh/authorized_keys 2>/dev/null || \
    printf '%s\n' "$PUBKEY" >> /root/.ssh/authorized_keys



if id "$USERONE" >/dev/null 2>&1; then
    echo "User already exists: $USERONE"
else
    useradd \
        -m \
        -d "/home/$USERONE" \
        -s /bin/bash \
        -G sudo \
        "$USERONE"

    echo "$USERONE:$PASSWORD" | chpasswd

    echo "User created: $USERONE"
fi

# UFW

if ! command -v ufw >/dev/null 2>&1; then
    echo "ERROR: ufw is not installed."
    exit 1
fi

# IP_RULES

IFS=',' read -ra IP_RULES <<< "$PUBLIC_PORTS_ONEBYONE"

for item in "${IP_RULES[@]}"; do

    [ -z "$item" ] && continue

    IFS='|' read -r ip describe <<< "$item"

    [ -z "$ip" ] && continue

    describe="${describe:-allowed-$ip}"

    echo "Allow $ip -> 9100/tcp [$describe]"

    ufw allow \
        from "$ip" \
        to any port 9100 \
        proto tcp \
        comment "$describe"

    echo "Allow $ip -> 22/tcp [$describe]"

    ufw allow \
        from "$ip" \
        to any port 22 \
        proto tcp \
        comment "$describe"

done


# TCP port

IFS=',' read -ra PUBLIC_PORT_LIST <<< "$PUBLIC_PORTS"

for port in "${PUBLIC_PORT_LIST[@]}"; do

    port="$(echo "$port" | tr -d '[:space:]')"

    [ -z "$port" ] && continue

    echo "Allow public TCP port: $port"

    ufw allow "$port/tcp" comment "PUBLIC-$port"

done


# enable UFW

if ! ufw status | grep -q "^Status: active$"; then
    ufw --force enable
fi

systemctl enable ufw >/dev/null 2>&1 || true

echo
echo "========== UFW STATUS =========="
ufw status
echo "================================="


# hostname

HNS="$(
    curl -s4 --max-time 10 ipinfo.io |
    awk -F'"' '
        /"ip"/      { ip=$4 }
        /"city"/    { city=$4 }
        /"country"/ { country=$4 }
        END {
            gsub(/\./, "-", ip)
            gsub(/ /, "-", city)
            print country "-" city "-" ip
        }
    '
)"

if [ -n "$HNS" ]; then
    hostnamectl set-hostname "$HNS"
    echo "Hostname set to: $HNS"
fi

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

configure_ps1
history -c
history -w

echo
echo "=============================================="
echo " Node initialization completed"
echo "=============================================="
echo "CREATE USERONE USER----: $USERONE"
echo "CREATE USERONE PASSWORD: $PASSWORD"
echo "HOSTNAME: $(hostname)"
echo "OPEN PUBLIC_PORTS_ONEBYONE--: $PUBLIC_PORTS_ONEBYONE"
echo "OPEN PUBLIC_PORTS-----------: $PUBLIC_PORTS"
echo "=============================================="