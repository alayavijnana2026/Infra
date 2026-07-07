#!/bin/bash

set -e

VERSION="${1:-1.11.1}"
USER="node_exporter"
INSTALL_DIR="/usr/local/node_exporter"
BIN_PATH="/usr/local/bin/node_exporter"

echo "==> 创建用户"
if ! id "$USER" &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin $USER
fi

curl -Lks4 https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-amd64.tar.gz | tar xz -C /usr/local/
cp /usr/local/node_exporter-${VERSION}.linux-amd64/node_exporter $BIN_PATH
chmod +x $BIN_PATH

echo "==> 创建 systemd service"
mkdir -p /var/lib/node_exporter/textfile_collector

cat >/etc/systemd/system/node_exporter.service <<EOF
[Unit]
Description=Prometheus Node Exporter
After=network.target

[Service]
User=${USER}
Group=${USER}
Type=simple
ExecStart=${BIN_PATH} \
  --path.procfs=/proc \
  --path.sysfs=/sys \
  --collector.filesystem.mount-points-exclude="^/(sys|proc|dev|host|etc)($|/)" \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector

Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "==> 启动服务"
systemctl daemon-reload
systemctl enable node_exporter
systemctl restart node_exporter

echo "==> 状态检查"
systemctl status node_exporter --no-pager