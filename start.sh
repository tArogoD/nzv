#!/bin/bash

WORK_DIR=/app
# 指定版本变量
DASHBOARD_VERSION="v1.6.0"
AGENT_VERSION="v1.60.0"

setup_ssl() {
    openssl genrsa -out $WORK_DIR/nezha.key 2048
    openssl req -new -key $WORK_DIR/nezha.key -out $WORK_DIR/nezha.csr -subj "/CN=$NZ_DOMAIN"
    openssl x509 -req -days 3650 -in $WORK_DIR/nezha.csr -signkey $WORK_DIR/nezha.key -out $WORK_DIR/nezha.pem

    chmod 600 $WORK_DIR/nezha.key 
    chmod 644 $WORK_DIR/nezha.pem
}

create_nginx_config() {
    cat << EOF > /etc/nginx/conf.d/default.conf
server {
    http2 on;

    server_name $NZ_DOMAIN;
    ssl_certificate          $WORK_DIR/nezha.pem;
    ssl_certificate_key      $WORK_DIR/nezha.key;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;

    underscores_in_headers on;
    set_real_ip_from 0.0.0.0/0;
    real_ip_header CF-Connecting-IP;

    location ^~ /proto.NezhaService/ {
        grpc_set_header Host \$host;
        grpc_set_header nz-realip \$http_CF_Connecting_IP;
        grpc_read_timeout 600s;
        grpc_send_timeout 600s;
        grpc_socket_keepalive on;
        client_max_body_size 10m;
        grpc_buffer_size 4m;
        grpc_pass grpc://dashboard;
    }

    location ~* ^/api/v1/ws/(server|terminal|file)(.*)$ {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$http_cf_connecting_ip;
        proxy_set_header Origin https://\$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass http://127.0.0.1:8008;
    }

    location / {
        proxy_set_header Host \$host;
        proxy_set_header nz-realip \$http_cf_connecting_ip;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
        proxy_max_temp_file_size 0;
        proxy_pass http://127.0.0.1:8008;
    }
}

upstream dashboard {
    server 127.0.0.1:8008;
    keepalive 512;
}
EOF
}

check_env_variables() {
    [ -z "$NZ_DOMAIN" ] && { echo "Error: NZ_DOMAIN not set"; exit 1; }
    [ -z "$ARGO_AUTH" ] && { echo "Error: ARGO_AUTH not set"; exit 1; }
    [ -z "$NZ_agentsecretkey" ] && { echo "Error: NZ_agentsecretkey not set"; exit 1; }
}

download_components() {
    # 下载指定版本的 Dashboard
    wget -q "https://github.com/nezhahq/nezha/releases/download/${DASHBOARD_VERSION}/dashboard-linux-amd64.zip" -O "dashboard-linux-amd64.zip"
    if [ $? -eq 0 ]; then
        unzip -qo "dashboard-linux-amd64.zip" -d "$WORK_DIR" && rm "dashboard-linux-amd64.zip"
    fi

    # 下载指定版本的 Agent
    wget -q "https://github.com/nezhahq/agent/releases/download/${AGENT_VERSION}/nezha-agent_linux_amd64.zip" -O "nezha-agent_linux_amd64.zip"
    if [ $? -eq 0 ]; then
        unzip -qo "nezha-agent_linux_amd64.zip" -d "$WORK_DIR" && rm "nezha-agent_linux_amd64.zip"
    fi
}

start_services() {
    nohup nginx >/dev/null 2>&1 &
    nohup ./cloudflared-linux-amd64 tunnel --protocol http2 run --token "$ARGO_AUTH" >/dev/null 2>&1 &
    nohup ./dashboard-linux-amd64 >/dev/null 2>&1 &
    NZ_SERVER=$NZ_DOMAIN:443 NZ_TLS=true NZ_CLIENT_SECRET=$NZ_agentsecretkey disable_auto_update=true nohup ./nezha-agent >/dev/null 2>&1 &
}

stop_services() {
    pkill -f "dashboard-linux-amd64|cloudflared-linux-amd64|nezha-agent|nginx"
}

main() {
    check_env_variables

    [ -f "restore.sh" ] && { chmod +x restore.sh; ./restore.sh; }

    setup_ssl
    create_nginx_config

    download_components

    [ ! -f "cloudflared-linux-amd64" ] && wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64

    chmod +x dashboard-linux-amd64 cloudflared-linux-amd64 nezha-agent

    start_services
}

main

while true; do
    # 获取当前上海时间
    current_time=$(TZ='Asia/Shanghai' date +"%H:%M")

    # 检查是否为凌晨4点
    if [ "$current_time" == "04:00" ]; then
        # 执行备份
        [ -f "backup.sh" ] && { 
            chmod +x backup.sh
            ./backup.sh
        }
        # 等待一小时，避免重复执行
        sleep 3600
    fi

    sleep 1800
done
