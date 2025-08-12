#!/usr/bin/env bash

# ---------- install_hy2.sh – Установка Hysteria 2  ----------

set -euo pipefail

# --- Проверка, что скрипт запущен от root ---
if [[ $EUID -ne 0 ]]; then
    echo "Запустите скрипт от root!"
    exit 1
fi

echo "--- Шаг 1: Обновление системы и установка зависимостей ---"
apt-get update && apt-get install -y curl openssl pwgen iproute2 qrencode

echo "--- Шаг 2: Скачивание и установка Hysteria 2 ---"
bash <(curl -fsSL https://get.hy2.sh/)

echo "--- Шаг 3: Генерация TLS-сертификата ---"
mkdir -p /etc/hysteria
openssl req -x509 -nodes -days 3650 \
    -newkey rsa:2048 \
    -keyout /etc/hysteria/server.key \
    -out /etc/hysteria/server.crt \
    -subj "/CN=localhost"

echo "--- Шаг 4: Поиск свободного порта ---"
find_free_port() {
    while :; do
        local p
        p=$(shuf -i 1024-65535 -n 1)
        if ! ss -tuln | grep -q ":$p "; then
            echo "$p"
            return
        fi
    done
}
RANDOM_PORT=$(find_free_port)
echo "Выбран порт: $RANDOM_PORT"

echo "--- Шаг 5: Запрос количества пользователей ---"
read -rp "Сколько пользовательских конфигураций создать? (1-10): " USER_COUNT
if ! [[ $USER_COUNT =~ ^([1-9]|10)$ ]]; then
    echo "Ошибка: введите число от 1 до 10."
    exit 1
fi

echo "--- Шаг 6: Генерация логинов/паролей ---"
USERPASS_BLOCK="" # то, что попадёт в YAML
USER_INFO=""      # то, что покажем админу

for ((i = 1; i <= USER_COUNT; i++)); do
    USERNAME=$(pwgen -s 12 1)
    PASSWORD=$(pwgen -s 30 1)
    
    # Добавляем строку + перевод строки для YAML (отступ в 4 пробела)
    USERPASS_BLOCK+="    ${USERNAME}: ${PASSWORD}"$'\n'
    # Добавляем информацию для вывода пользователю
    USER_INFO+="  $i) ${USERNAME} / ${PASSWORD}"$'\n'
done

echo "--- Шаг 7: Создание /etc/hysteria/config.yaml ---"
# Важно: отступы внутри блока <<EOF являются частью файла
cat > /etc/hysteria/config.yaml <<EOF
# Сгенерировано install_hy2.sh

listen: :${RANDOM_PORT}

tls:
  cert: /etc/hysteria/server.crt
  key:  /etc/hysteria/server.key

auth:
  type: userpass
  userpass:
${USERPASS_BLOCK}
masquerade:
  type: proxy
  proxy:
    url: https://google.com
    rewriteHost: true

bandwidth:
  up:   1 gbps
  down: 1 gbps

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow:  8388608
  initConnReceiveWindow:  20971520
  maxConnReceiveWindow:   20971520
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s

disableUDP: false
udpIdleTimeout: 60s

EOF

echo "--- Шаг 8: Права на каталог /etc/hysteria ---"
useradd -r -M -s /usr/sbin/nologin hysteria 2>/dev/null || true
chown -R hysteria:hysteria /etc/hysteria

echo "--- Шаг 9: Создание и запуск systemd-сервиса ---"
cat > /etc/systemd/system/hysteria-server.service <<'EOF'
[Unit]
Description=Hysteria Server Service (config.yaml)
After=network-online.target
Wants=network-online.target

[Service]
User=hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now hysteria-server.service

SERVER_IP=$(hostname -I | awk '{print $1}')
SITE="google.com"  # Можно поменять при необходимости

echo -e "\n-------------------- ГОТОВО --------------------"
echo "Hysteria 2 запущена и слушает порт ${RANDOM_PORT}"
echo -e "Аккаунты:\n${USER_INFO%\\n}"
echo "Публичный сертификат: /etc/hysteria/server.crt"
echo "Конфиг сервера:       /etc/hysteria/config.yaml"

echo -e "\nСсылки и QR-коды для подключения:"
i=1
while read -r line; do
    U=$(echo "$line" | awk '{print $2}')
    P=$(echo "$line" | awk '{print $4}')
    LINK="hy2://${U}:${P}@${SERVER_IP}:${RANDOM_PORT}?sni=${SITE}&insecure=1"
    echo "  $i) $LINK"
    qrencode -t ANSIUTF8 "$LINK"
    ((i++))
done <<< "$(echo -e "${USER_INFO%\\n}")"
