#!/usr/bin/env bash
# setup-nginx.sh — configura Nginx + SSL Let's Encrypt para el chatbot Zinekide.
#
# Idempotente: se puede ejecutar varias veces sin romper nada. Asume:
#   - Ubuntu/Debian con nginx + certbot ya instalados.
#   - El A-record del dominio ya apunta al servidor.
#   - El docker compose del chatbot está corriendo (puerto local accesible).
#
# Variables leídas del .env (en el mismo directorio que este script):
#   PUBLIC_DOMAIN   - dominio público (REQUERIDO)
#   ADMIN_EMAIL     - email para Let's Encrypt (REQUERIDO)
#   HOST_PORT       - puerto local del container (default 3001)
#
# Uso:
#   sudo ./setup-nginx.sh

set -euo pipefail

# ─── Resolución de variables ──────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [ ! -f "$ENV_FILE" ]; then
  echo "✗ No se encontró .env en $SCRIPT_DIR. Copia .env.example a .env y rellénalo." >&2
  exit 1
fi

# Carga del .env sin contaminar el shell con variables que no sean nuestras.
PUBLIC_DOMAIN="$(grep -E '^PUBLIC_DOMAIN=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")"
ADMIN_EMAIL="$(grep -E '^ADMIN_EMAIL=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")"
HOST_PORT="$(grep -E '^HOST_PORT=' "$ENV_FILE" | tail -1 | cut -d'=' -f2- | tr -d '"' | tr -d "'")"
HOST_PORT="${HOST_PORT:-3001}"

if [ -z "${PUBLIC_DOMAIN:-}" ]; then
  echo "✗ PUBLIC_DOMAIN no definido en $ENV_FILE" >&2
  exit 1
fi
if [ -z "${ADMIN_EMAIL:-}" ]; then
  echo "✗ ADMIN_EMAIL no definido en $ENV_FILE" >&2
  exit 1
fi

if [ "$EUID" -ne 0 ]; then
  echo "✗ Este script necesita root. Reintenta con: sudo $0" >&2
  exit 1
fi

# ─── Pre-checks ───────────────────────────────────────────────────────────
command -v nginx   >/dev/null 2>&1 || { echo "✗ nginx no está instalado" >&2; exit 1; }
command -v certbot >/dev/null 2>&1 || { echo "✗ certbot no está instalado (apt install certbot python3-certbot-nginx)" >&2; exit 1; }

echo "▸ Dominio:    $PUBLIC_DOMAIN"
echo "▸ Email Let's Encrypt: $ADMIN_EMAIL"
echo "▸ Puerto local:        $HOST_PORT"

# Verifica que el chatbot está respondiendo en el puerto local
if ! curl -sf "http://127.0.0.1:${HOST_PORT}/healthz" >/dev/null 2>&1; then
  echo "⚠ El chatbot no responde en http://127.0.0.1:${HOST_PORT}/healthz" >&2
  echo "  Asegúrate de haber ejecutado 'docker compose up -d' antes." >&2
  echo "  Continúo igualmente, pero verifica esto después." >&2
fi

# ─── Snippet de proxy compartido ──────────────────────────────────────────
mkdir -p /etc/nginx/snippets
install -m 0644 "${SCRIPT_DIR}/nginx/zinekide-chatbot-proxy.conf" \
  /etc/nginx/snippets/zinekide-chatbot-proxy.conf

# ─── Site config ──────────────────────────────────────────────────────────
SITE_CONF="/etc/nginx/sites-available/zinekide-chatbot.conf"
HTTP_ONLY_CONF="$(mktemp)"
trap 'rm -f "$HTTP_ONLY_CONF"' EXIT

# 1) Config temporal SOLO HTTP para que certbot pueda hacer HTTP-01 challenge
cat > "$HTTP_ONLY_CONF" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${PUBLIC_DOMAIN};
  location /.well-known/acme-challenge/ {
    root /var/www/html;
  }
  location / {
    return 200 "challenge endpoint, cert emission in progress\\n";
  }
}
EOF

# Si NO existe cert todavía, primero pasamos por el HTTP-only para emitirlo.
NEED_CERT="false"
if [ ! -f "/etc/letsencrypt/live/${PUBLIC_DOMAIN}/fullchain.pem" ]; then
  NEED_CERT="true"
fi

if [ "$NEED_CERT" = "true" ]; then
  echo "▸ Sin cert previo. Instalando config HTTP-only para emitir Let's Encrypt..."
  install -m 0644 "$HTTP_ONLY_CONF" "$SITE_CONF"
  ln -sf "$SITE_CONF" "/etc/nginx/sites-enabled/zinekide-chatbot.conf"
  mkdir -p /var/www/html
  nginx -t
  systemctl reload nginx

  echo "▸ Emitiendo cert Let's Encrypt..."
  certbot certonly --webroot -w /var/www/html \
    -d "$PUBLIC_DOMAIN" \
    --non-interactive --agree-tos -m "$ADMIN_EMAIL"
else
  echo "▸ Cert ya existe para $PUBLIC_DOMAIN (saltando emisión)."
fi

# 2) Config final con SSL
echo "▸ Instalando config final con SSL..."
sed -e "s|{{DOMAIN}}|${PUBLIC_DOMAIN}|g" \
    -e "s|{{HOST_PORT}}|${HOST_PORT}|g" \
    "${SCRIPT_DIR}/nginx/zinekide-chatbot.conf.template" > "$SITE_CONF"

ln -sf "$SITE_CONF" "/etc/nginx/sites-enabled/zinekide-chatbot.conf"
nginx -t
systemctl reload nginx

# ─── Verificación final ───────────────────────────────────────────────────
echo ""
echo "▸ Verificación end-to-end:"
sleep 1
HTTP_CODE_HZ="$(curl -s -o /dev/null -w '%{http_code}' "https://${PUBLIC_DOMAIN}/healthz" || echo "000")"
HTTP_CODE_WG="$(curl -s -o /dev/null -w '%{http_code}' "https://${PUBLIC_DOMAIN}/widget.latest.js" || echo "000")"

echo "  /healthz           -> HTTP $HTTP_CODE_HZ"
echo "  /widget.latest.js  -> HTTP $HTTP_CODE_WG"

if [ "$HTTP_CODE_HZ" = "200" ] && [ "$HTTP_CODE_WG" = "200" ]; then
  echo ""
  echo "✓ Despliegue listo en https://${PUBLIC_DOMAIN}"
  echo ""
  echo "Snippet para insertar el widget en zinekide.eus (antes de </body>):"
  echo "  <script src=\"https://${PUBLIC_DOMAIN}/widget.latest.js\" defer></script>"
else
  echo ""
  echo "⚠ Algo no responde correctamente. Revisa:"
  echo "   - docker compose ps     (chatbot-backend healthy?)"
  echo "   - docker compose logs   (errores de arranque)"
  echo "   - journalctl -u nginx   (errores de proxy)"
  exit 1
fi
