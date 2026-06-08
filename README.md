# Zinekide Chatbot — Despliegue

Configuración y scripts para desplegar el chatbot de [Zinekide](https://zinekide.eus) en el servidor del cliente.

El motor del chatbot (backend + widget) viene como **imagen Docker pre-construida** desde GitHub Container Registry. Este repo solo contiene los archivos de configuración (`docker-compose.yml`, `.env.example`, `nginx/`, `setup-nginx.sh`). No hay código fuente del chatbot aquí.

- **Imagen Docker:** `ghcr.io/naahiki/zinekide-chatbot:2.0.23` (privada, acceso vía PAT facilitado por DVM).
- **Versionado:** las tags de este repo (`v2.0.23`, ...) van en espejo con las versiones de imagen. Hacéis `git checkout v2.0.23` y el `.env.example` ya apunta a la imagen correcta.
- **Soporte:** Data Value Management (DVM) — nahiki.dev@gmail.com.

---

## Arquitectura

```
┌──────────────────────────────────────────────────────────────────┐
│                       NAVEGADOR del usuario                      │
│                                                                  │
│   visita ─►  https://zinekide.eus                                │
│                  │                                               │
│                  │ <script src="https://chatbot.xxx/widget.js">  │
│                  ▼                                               │
│         ┌─────────────────────────────────────┐                  │
│         │  Widget JS  (Shadow DOM, ~70 KB)    │                  │
│         └────────────────┬────────────────────┘                  │
│                          │ POST /chat                            │
└──────────────────────────┼───────────────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│              SERVER DEL CLIENTE                                  │
│                                                                  │
│   Nginx + SSL (Let's Encrypt)                                    │
│    ├─ /widget.v*.js     ────►┐                                   │
│    ├─ /chat                  │  127.0.0.1:3001                   │
│    ├─ /widget/config         ►│  ┌──────────────────────────┐    │
│    ├─ /healthz, /readyz  ───►┘  │ chatbot-backend (Docker) │    │
│                                 │ - Motor LLM              │    │
│                                 │ - Widget embebido        │    │
│                                 └────────────┬─────────────┘    │
│                                              │                  │
│   Symfony de Veiss — zinekide.eus            │                  │
│    └─ /api/projects/*, /api/chat/events  ◄───┘                  │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

El widget habla siempre con el chatbot, nunca directamente con Symfony.

---

## Requisitos del servidor

| Requisito | Comprobación |
|---|---|
| Linux (Ubuntu 22.04+ / Debian 12+) | `lsb_release -a` |
| Docker + Docker Compose v2 | `docker --version`, `docker compose version` |
| Nginx + Certbot | `nginx -v`, `certbot --version` |
| Puertos 80 y 443 abiertos | A internet, para Let's Encrypt |
| Subdominio del chatbot apuntando al servidor | `dig +short chatbot.zinekide.eus @1.1.1.1` |
| PAT de GHCR | Facilitado por DVM (scope `read:packages`) |
| API key de OpenAI o Anthropic | La paga el cliente |

---

## Despliegue paso a paso

### 1. Clonar este repo en el servidor

```bash
ssh root@<ip-servidor>
mkdir -p /opt/zinekide-chatbot && cd /opt/zinekide-chatbot
git clone https://github.com/Naahiki/zinekide-chatbot-deploy.git .
git checkout v2.0.23
```

Sin `git`, alternativa equivalente:

```bash
curl -L https://github.com/Naahiki/zinekide-chatbot-deploy/archive/refs/tags/v2.0.23.tar.gz \
  | tar xz --strip-components=1
```

### 2. Configurar `.env`

```bash
cp .env.example .env
nano .env
```

Rellenad los valores marcados como **REQUERIDO**. El resto tiene defaults sanos.

Lo mínimo:

```dotenv
CHATBOT_IMAGE=ghcr.io/naahiki/zinekide-chatbot:2.0.23
OPENAI_API_KEY=sk-proj-...
PARTNER_API_URL=https://zinekide.eus
ALLOWED_ORIGINS=https://zinekide.eus,https://www.zinekide.eus
PUBLIC_DOMAIN=chatbot.zinekide.eus
ADMIN_EMAIL=ops@zinekide.eus
```

### 3. Autenticarse en GHCR y arrancar el container

```bash
echo "<PAT_GHCR>" | docker login ghcr.io -u naahiki --password-stdin
docker compose pull
docker compose up -d
```

El chatbot escucha en `127.0.0.1:3001` (loopback, no expuesto a internet aún).

### 4. Configurar Nginx + SSL

Script idempotente — se puede ejecutar varias veces sin problema:

```bash
sudo ./setup-nginx.sh
```

El script lee `.env`, monta una config Nginx temporal HTTP-only, emite el cert Let's Encrypt y deja la config definitiva con SSL + reverse proxy a `127.0.0.1:3001`.

### 5. Verificar

```bash
curl https://chatbot.zinekide.eus/healthz
# {"status":"ok"}

curl https://chatbot.zinekide.eus/readyz
# {"status":"ok","checks":{"llm_key":true,"partner_reachable":true}}

curl -I https://chatbot.zinekide.eus/widget.latest.js
# HTTP/2 200, content-type: application/javascript
```

### 6. Insertar el widget en zinekide.eus

Una línea **antes de `</body>`** en el layout principal de Symfony (típicamente `templates/base.html.twig`):

```html
<script
  id="zinekide-widget-script"
  src="https://chatbot.zinekide.eus/widget.latest.js"
  defer
></script>
```

> **Importante:** no añadáis ningún `<script>` inline adicional que intente crear manualmente el elemento `<zinekide-widget>`. El bundle ya gestiona ciclo de vida completo (initial render + `astro:after-swap` + `astro:page-load` + rehidratación). Cualquier script paralelo crearía una **segunda instancia** del widget.

---

## Mantenimiento

### Ver logs

```bash
docker compose logs chatbot-backend -f --tail=100
```

### Actualizar a una versión nueva

Cuando DVM publica `v2.0.24`, `v2.1.0`, etc.:

```bash
cd /opt/zinekide-chatbot
git fetch --tags
git checkout v2.0.24
docker compose pull
docker compose up -d
```

Downtime durante el `up -d`: ~5 segundos.

### Rollback

```bash
git checkout v2.0.23
docker compose pull
docker compose up -d
```

### Rotar la API key del LLM

```bash
nano .env   # cambiar OPENAI_API_KEY
docker compose up -d --no-deps chatbot-backend
```

---

## Variables de entorno

| Variable | Requerido | Default | Descripción |
|----------|-----------|---------|-------------|
| `CHATBOT_IMAGE` | ✓ | — | Imagen Docker (`ghcr.io/naahiki/zinekide-chatbot:<version>`) |
| `OPENAI_API_KEY` o `ANTHROPIC_API_KEY` | ✓ | — | Al menos una |
| `PARTNER_API_URL` | ✓ | — | URL del Symfony de Veiss |
| `ALLOWED_ORIGINS` | ✓ | — | Dominios donde se carga el widget (coma-separados) |
| `PUBLIC_DOMAIN` | ✓ | — | Subdominio del chatbot |
| `ADMIN_EMAIL` | ✓ | — | Email para Let's Encrypt |
| `PARTNER_API_KEY` |   | — | Bearer para `/api/chat/events`. Opcional en la spec actual |
| `LLM_PROVIDER` |   | `openai` | `openai` \| `anthropic` |
| `LLM_MODEL` |   | `gpt-4o-mini` | Modelo inicial |
| `LLM_CONFIG_FROM_PARTNER` |   | `false` | `true` solo cuando Veiss exponga `/api/assistant/config` |
| `WIDGET_CONFIG_FROM_PARTNER` |   | `false` | `true` solo cuando Veiss exponga `/api/widget/config` |
| `PARTNER_SEARCH_AUTH_SCHEME` |   | `none` | `none` \| `bearer` \| `apikey` |
| `PARTNER_TIMEOUT_MS` |   | `5000` | Timeout llamadas a Veiss |
| `RATE_LIMIT_SESSION_CAPACITY` |   | `20` | Mensajes/sesión |
| `RATE_LIMIT_IP_CAPACITY` |   | `60` | Mensajes/IP |
| `MAX_MESSAGE_LEN` |   | `2000` | Caracteres por mensaje |
| `HOST_PORT` |   | `3001` | Puerto local del container |

Plantilla completa con comentarios: [`.env.example`](.env.example).

---

## Problemas comunes

| Síntoma | Causa probable |
|---|---|
| `setup-nginx.sh` falla emitiendo el cert | DNS no propagado todavía |
| `/readyz` devuelve `partner_reachable:false` | DNS, firewall o Symfony caído |
| `/readyz` devuelve `llm_key:false` | `OPENAI_API_KEY` vacía o mal formada |
| Widget responde "ha habido un error" | `ALLOWED_ORIGINS` no incluye el dominio donde se carga |
| Aparecen **dos widgets** en la web | Hay un `<script>` inline que crea otra instancia en paralelo al bundle — eliminarlo |
| `tool_search_failed` con `err_kind:auth` | Auth de `/api/projects/search` mal configurado |

---

## Soporte

- **Motor IA, widget, imagen Docker:** DVM — nahiki.dev@gmail.com.
- **Symfony + panel admin + endpoints REST:** Veiss.
- **API keys LLM + servidor de producción:** cliente final.

Para incidencias urgentes, mandadme correo con:

- `docker compose ps` y `docker compose logs chatbot-backend --tail=200`.
- `curl -v https://chatbot.zinekide.eus/readyz`.
- Versión actual: `grep CHATBOT_IMAGE .env`.
