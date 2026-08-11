```bash
install_docker() {
    echo "Install Docker"

    # 检测操作系统
    if [ -f /etc/os-release ]; then
        . /etc/os-release
    else
        echo "Cannot detect operating system: /etc/os-release not found"
        return 1
    fi

    echo "Detected OS: ${PRETTY_NAME:-unknown}"
    echo "ID: ${ID:-unknown}"
    echo "VERSION_ID: ${VERSION_ID:-unknown}"

    # Docker 软件源
    local DOCKER_URL="https://download.docker.com"

    if [ "${REGION:-}" = "cn" ]; then
        DOCKER_URL="https://mirrors.aliyun.com/docker-ce"
        echo "Using domestic Docker mirror: $DOCKER_URL"
    fi

    case "${ID:-}" in
        ubuntu|debian)
            echo "Installing Docker on ${ID}"

            apt-get update
            apt-get install -y ca-certificates curl gnupg

            install -m 0755 -d /etc/apt/keyrings

            curl -fsSL "${DOCKER_URL}/linux/${ID}/gpg" \
                | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg

            chmod a+r /etc/apt/keyrings/docker.gpg

            # VERSION_CODENAME 通常由 /etc/os-release 提供
            if [ -z "${VERSION_CODENAME:-}" ]; then
                echo "Cannot determine VERSION_CODENAME"
                return 1
            fi

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

        centos|rhel|rocky|almalinux)
            echo "Installing Docker on ${ID}"

            # CentOS 7 已经 EOL
            if [ "${VERSION_ID%%.*}" = "7" ]; then
                echo "ERROR: ${ID} ${VERSION_ID} is EOL and is not supported by this installer."
                return 1
            fi

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

        fedora)
            echo "Installing Docker on Fedora"

            dnf install -y dnf-plugins-core

            dnf config-manager \
                --add-repo "${DOCKER_URL}/linux/fedora/docker-ce.repo"

            dnf install -y \
                docker-ce \
                docker-ce-cli \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin
            ;;

        *)
            echo "Unsupported distribution: ID=${ID:-empty}, VERSION_ID=${VERSION_ID:-empty}"
            return 1
            ;;
    esac

    systemctl enable --now docker

    echo
    echo "Docker installed successfully:"
    docker --version
    docker compose version
}