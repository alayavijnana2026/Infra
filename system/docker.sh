install_docker() {
    log "Install Docker"

    if command -v docker >/dev/null 2>&1; then
        echo "Docker already installed"
        return
    fi

    local DOCKER_URL="https://download.docker.com"

    if [ "$REGION" = "cn" ]; then
        DOCKER_URL="https://mirrors.aliyun.com/docker-ce"
        echo "Using domestic Docker mirror: $DOCKER_URL"
    fi

    case "$ID" in
        ubuntu|debian)
            apt-get update
            apt-get install -y ca-certificates curl gnupg

            install -m 0755 -d /etc/apt/keyrings

            curl -fsSL "${DOCKER_URL}/linux/${ID}/gpg" \
                | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

            chmod a+r /etc/apt/keyrings/docker.gpg
            . /etc/os-release
            
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] ${DOCKER_URL}/linux/${ID} ${VERSION_CODENAME} stable" \
                > /etc/apt/sources.list.d/docker.list

            apt-get update

            apt-get install -y \
                docker-ce \
                docker-ce-cli \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin
            ;;

        centos)
            dnf install -y dnf-plugins-core

            dnf config-manager \
                --add-repo "${DOCKER_URL}/linux/centos/docker-ce.repo"

            dnf install -y \
                docker-ce \
                docker-ce-cli \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin
            ;;

        *)
            echo "Unsupported distribution: ID=$ID"
            return 1
            ;;
    esac

    systemctl enable --now docker

    docker --version
    docker compose version
}
install_docker