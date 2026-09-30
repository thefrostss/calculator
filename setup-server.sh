#!/bin/bash
# 小本本专属中转站一键安装（Ubuntu / 阿里云轻量服务器）
# 用法：先 export DOMAIN ALI_KEY ALI_SECRET MQTT_USER MQTT_PASS，再 bash 本脚本
set -e
: "${DOMAIN:?缺少 DOMAIN}"
: "${ALI_KEY:?缺少 ALI_KEY}"
: "${ALI_SECRET:?缺少 ALI_SECRET}"
: "${MQTT_USER:?缺少 MQTT_USER}"
: "${MQTT_PASS:?缺少 MQTT_PASS}"

echo "===== [1/6] 安装基础组件 ====="
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y docker.io curl git cron
systemctl enable --now docker cron

echo "===== [2/6] 配置 docker 镜像加速（国内拉取用） ====="
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'EOJ'
{ "registry-mirrors": ["https://docker.m.daocloud.io", "https://docker.1panel.live", "https://hub.rat.dev"] }
EOJ
systemctl restart docker

echo "===== [3/6] 签发 HTTPS 证书（DNS 验证，不占 80 端口） ====="
if [ ! -f /root/.acme.sh/acme.sh ]; then
  rm -rf /tmp/acme.sh
  git clone --depth 1 https://gitee.com/neilpang/acme.sh.git /tmp/acme.sh || \
  git clone --depth 1 https://github.com/acmesh-official/acme.sh.git /tmp/acme.sh
  (cd /tmp/acme.sh && ./acme.sh --install -m "admin@$DOMAIN")
fi
export Ali_Key="$ALI_KEY"
export Ali_Secret="$ALI_SECRET"
/root/.acme.sh/acme.sh --set-default-ca --server letsencrypt
/root/.acme.sh/acme.sh --issue --dns dns_ali -d "$DOMAIN"
mkdir -p /root/emqx/certs
/root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" \
  --key-file /root/emqx/certs/key.pem \
  --fullchain-file /root/emqx/certs/cert.pem \
  --reloadcmd "chmod 644 /root/emqx/certs/*.pem && docker restart emqx"
chmod 644 /root/emqx/certs/*.pem

echo "===== [4/6] 写入 EMQX 配置 ====="
mkdir -p /root/emqx/etc
cat > /root/emqx/etc/emqx.conf << 'EOC'
mqtt { allow_anonymous = false }
authentication = [ { mechanism = password_based, backend = built_in_database, user_id_type = username } ]
listeners.wss.default {
  bind = "0.0.0.0:8084"
  websocket.mqtt_path = "/mqtt"
  ssl_options {
    certfile = "/etc/emqx/certs/cert.pem"
    keyfile = "/etc/emqx/certs/key.pem"
  }
}
EOC

echo "===== [5/6] 启动 EMQX ====="
docker rm -f emqx 2>/dev/null || true
docker pull emqx/emqx:5.8.6 || {
  docker pull docker.m.daocloud.io/emqx/emqx:5.8.6 && \
  docker tag docker.m.daocloud.io/emqx/emqx:5.8.6 emqx/emqx:5.8.6
}
docker run -d --name emqx --restart unless-stopped \
  -p 8084:8084 \
  -v /root/emqx/etc/emqx.conf:/opt/emqx/etc/emqx.conf \
  -v /root/emqx/certs:/etc/emqx/certs:ro \
  emqx/emqx:5.8.6
sleep 15

echo "===== [6/6] 创建聊天账号 ====="
T=""
for i in $(seq 1 12); do
  T=$(docker exec emqx curl -s -X POST http://127.0.0.1:18083/api/v5/login \
      -H 'Content-Type: application/json' \
      -d '{"username":"admin","password":"public"}' | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  [ -n "$T" ] && break
  sleep 4
done
docker exec emqx curl -s -X POST "http://127.0.0.1:18083/api/v5/authentication/password_based:built_in_database/users" \
  -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d "{\"user_id\":\"$MQTT_USER\",\"password\":\"$MQTT_PASS\"}" && echo

echo "===== 自检 ====="
code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 "https://$DOMAIN:8084/mqtt" || echo "FAIL")
echo "TLS 自检返回: $code （400 或 426 都代表加密通道已通）"
docker ps --format '{{.Names}} {{.Status}}' | grep emqx
echo "===== 全部完成 ====="
