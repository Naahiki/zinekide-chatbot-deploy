# Zinekide Chatbot · Despliegue

Archivos de configuración para desplegar el [chatbot Zinekide](https://github.com/Naahiki/zinekide-chatbot) en el servidor del cliente.

Este repo contiene **solo configs y scripts**, no incluye código fuente. El motor del chatbot se descarga como imagen Docker pre-construida desde GitHub Container Registry.

- **Imagen Docker**: `ghcr.io/naahiki/zinekide-chatbot` (privada, acceso vía PAT facilitado por [DVM](https://datavaluemanagement.es))
- **Versión actual recomendada**: `2.0.4`

---

## Qué hay en este repo

| Archivo | Propósito |
|---------|-----------|
| `docker-compose.yml` | Define el servicio del chatbot (1 container, pull desde GHCR). |
| `.env.example` | Plantilla de variables de entorno. Copiar a `.env` y rellenar. |
| `nginx/zinekide-chatbot.conf.template` | Site Nginx (reverse proxy + SSL). Adaptar al hostname del cliente. |
| `nginx/zinekide-chatbot-proxy.conf` | Snippet con headers de proxy reutilizables. |
| `setup-nginx.sh` | (Opcional) Script idempotente que configura Nginx + SSL automáticamente desde `.env`. Útil en despliegues simples; sysadmins con Nginx personalizado pueden adaptar el `.conf` a mano. |

---

## Despliegue en 4 pasos

### Pre-requisitos

- Servidor Linux (Ubuntu/Debian) con Docker + Compose v2.
- Nginx + Certbot ya instalados (típicamente ya los tendréis sirviendo otros sites).
- A-record del subdominio del chatbot apuntando al servidor (ej. `chatbot.example.eus`).
- API key de OpenAI o Anthropic (la paga el cliente final).
- PAT de GitHub con scope `read:packages` (lo facilita DVM).

### 1. Descargar archivos

```bash
mkdir -p /opt/zinekide-chatbot && cd /opt/zinekide-chatbot
git clone https://github.com/Naahiki/zinekide-chatbot-deploy.git .
# o descomprimir el .zip equivalente
```

### 2. Configurar `.env`

```bash
cp .env.example .env
nano .env
```

Rellenar los campos marcados como REQUERIDO en la plantilla. El resto tienen defaults sanos.

### 3. Pullear la imagen y arrancar el container

```bash
echo "<TOKEN_GHCR>" | docker login ghcr.io -u <usuario-dvm> --password-stdin
docker compose pull
docker compose up -d
```

El chatbot queda escuchando en `127.0.0.1:3001` (solo loopback).

### 4. Configurar Nginx + SSL

Hay dos vías, según el cliente prefiera control manual o automatización:

#### A) Si vuestro sysadmin gestiona Nginx a mano (recomendado en entornos serios)

1. Copiar `nginx/zinekide-chatbot.conf.template` a vuestro `sites-available/`.
2. Sustituir `{{DOMAIN}}` por vuestro subdominio y `{{HOST_PORT}}` por `3001`.
3. Copiar `nginx/zinekide-chatbot-proxy.conf` a `/etc/nginx/snippets/`.
4. Emitir cert con `certbot --nginx -d <dominio>` o vuestro flujo habitual de Let's Encrypt.
5. `nginx -t && systemctl reload nginx`.

#### B) Si preferís el script automático

```bash
sudo ./setup-nginx.sh
```

El script lee `.env`, copia el template, emite cert con certbot, reload nginx. Idempotente.

### Verificación

```bash
curl https://<vuestro-dominio>/healthz
# → {"status":"ok"}

curl https://<vuestro-dominio>/readyz
# → {"status":"ok","checks":{"llm_key":true,"partner_reachable":true}}

curl -I https://<vuestro-dominio>/widget.latest.js
# → HTTP/2 200, content-type: application/javascript
```

Si todo OK, insertar en el layout principal de vuestra web:

```html
<script src="https://<vuestro-dominio>/widget.latest.js" defer></script>
```

---

## Variables de entorno (resumen)

Detalle completo y comentado en [`.env.example`](.env.example).

| Variable | Requerido | Descripción |
|----------|-----------|-------------|
| `CHATBOT_IMAGE` | ✓ | Imagen Docker, ej. `ghcr.io/naahiki/zinekide-chatbot:2.0.4` |
| `OPENAI_API_KEY` o `ANTHROPIC_API_KEY` | ✓ | Al menos una de las dos |
| `PARTNER_API_URL` | ✓ | URL del Symfony con los endpoints REST |
| `PARTNER_API_KEY` | ✓ | Bearer compartido para `/api/chat/events` |
| `ALLOWED_ORIGINS` | ✓ | Dominios desde los que se carga el widget (CORS) |
| `PUBLIC_DOMAIN` | ✓ | Subdominio del chatbot |
| `ADMIN_EMAIL` | ✓ | Para registro Let's Encrypt |
| `PARTNER_SEARCH_AUTH_*` |   | Solo si el endpoint search lleva auth |

---

## Mantenimiento

### Actualizar a versión nueva de la imagen

```bash
# Editar .env: CHATBOT_IMAGE=ghcr.io/naahiki/zinekide-chatbot:2.0.4
docker compose pull
docker compose up -d
```

Downtime ~5 segundos. Para rollback, volver a la tag anterior y repetir.

### Logs

```bash
docker compose logs chatbot-backend -f --tail=100
```

### Rotación de claves

- **OpenAI/Anthropic**: actualizar valor en `.env` + `docker compose up -d --no-deps chatbot-backend`.
- **`PARTNER_API_KEY`**: actualizar a la vez en `.env` del chatbot Y en la config del Symfony del partner.

---

## Recursos

- **Especificación API completa** (los 6 endpoints que el cliente sirve): documento `Especificacion_API_Chatbot_Zinekide_v2.md` facilitado por DVM.
- **Guía operativa completa**: documento `Despliegue_Chatbot_Zinekide_Guia.md`.
- **Soporte**: DVM (nahiki.dev@gmail.com).

---

## Versionado

Las tags de este repo siguen el versionado de la imagen Docker:

- `v2.0.4` (actual)
- `v2.0.2` — widget embebido + plug & play
- `v2.0.1` — refinamiento prompt
- `v2.0.0` — primera release v2

Al actualizar la imagen (`CHATBOT_IMAGE` en `.env`), conviene también `git pull` en este repo por si hay cambios en `docker-compose.yml`, `nginx/*` o `setup-nginx.sh` que requieran ajustes.
