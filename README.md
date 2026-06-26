# Zinekide Chatbot

Motor IA + widget conversacional para [Zinekide](https://zinekide.eus), la plataforma que conecta inversores con producciones audiovisuales en Álava.

Construido por **[Data Value Management](https://datavaluemanagement.es)** (DVM) y desplegado en colaboración con **Veiss Comunicación**, que opera la web sobre Symfony.

- **Especificación API completa**: [`Especificacion_API_Chatbot_Zinekide_v2.md`](../Especificacion_API_Chatbot_Zinekide_v2.md).
- **Imagen Docker**: `ghcr.io/naahiki/zinekide-chatbot:2.0.28` (privada, acceso vía PAT facilitado por DVM).
- **Estado**: producción ready. Pipeline GHCR validado.

---

## Arquitectura

```
┌──────────────────────────────────────────────────────────────────┐
│                       NAVEGADOR del usuario                      │
│                                                                  │
│   visita ─►  https://zinekide.eus                                │
│                  │                                               │
│                  │ el layout Twig carga el script:               │
│                  │ <script src="https://chatbot.xxx/widget.js">  │
│                  ▼                                               │
│         ┌─────────────────────────────────────┐                  │
│         │  Widget JS  (Shadow DOM, ~70 KB)    │                  │
│         └────────────────┬────────────────────┘                  │
│                          │ POST /chat                            │
└──────────────────────────┼───────────────────────────────────────┘
                           ▼
┌──────────────────────────────────────────────────────────────────┐
│              SERVER DEL CLIENTE (Diputación / VPS)               │
│                                                                  │
│   Nginx + SSL                                                    │
│    ├─ /widget.v*.js  ────►┐                                      │
│    ├─ /chat               ►│  127.0.0.1:3001                     │
│    ├─ /widget/config      ►│  ┌──────────────────────────────┐   │
│    ├─ /healthz, /readyz  ─►┘  │ chatbot-backend (Docker GHCR)│   │
│                               │ - Motor LLM                  │   │
│                               │ - Widget embebido en imagen  │   │
│                               │ - Cache config (60s + SWR)   │   │
│                               └────────────┬─────────────────┘   │
│                                            │                     │
│   Symfony (Veiss) — zinekide.eus           │                     │
│    ├─ /api/projects/search                ◄┤                     │
│    ├─ /api/projects/summary               ◄┤                     │
│    ├─ /api/chat/events  (Bearer)          ◄┤                     │
│    ├─ /api/chatbot/knowledge              ◄┤                     │
│    ├─ /api/assistant/config               ◄┤                     │
│    └─ /api/widget/config                  ◄┘                     │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

El widget habla **siempre con el chatbot**, nunca directamente con Symfony. Eso desacopla el front del modelo de datos del cliente.

---

## Despliegue en el servidor del cliente

Requisitos:

- Ubuntu/Debian con Docker + Docker Compose v2.
- Nginx + Certbot ya instalados (estándar en servidores con sites pre-existentes).
- A-record del subdominio del chatbot apuntando al servidor.
- Acceso a GitHub Container Registry (PAT con scope `read:packages` facilitado por DVM).

### 3 pasos

```bash
# 1. Configurar variables de entorno
cp .env.example .env
nano .env   # rellena CHATBOT_IMAGE, OPENAI_API_KEY, PARTNER_API_URL,
            # ALLOWED_ORIGINS, PUBLIC_DOMAIN, ADMIN_EMAIL

# 2. Autenticar contra GHCR y arrancar el container
echo "<TOKEN_GHCR>" | docker login ghcr.io -u <usuario-dvm> --password-stdin
docker compose pull
docker compose up -d

# 3. Configurar Nginx + SSL (idempotente, se puede re-ejecutar)
sudo ./setup-nginx.sh
```

Al terminar:
- `https://<PUBLIC_DOMAIN>/healthz` → `{"status":"ok"}`
- `https://<PUBLIC_DOMAIN>/widget.latest.js` → bundle JS del widget
- `https://<PUBLIC_DOMAIN>/chat` → endpoint POST del chatbot

### Integrar el widget en zinekide.eus

Una línea en `templates/base.html.twig` antes de `</body>`:

```html
<script src="https://<PUBLIC_DOMAIN>/widget.latest.js" defer></script>
```

El widget se auto-monta como burbuja flotante en Shadow DOM. No interfiere con el CSS/JS del resto de la web.

### Actualizar versión

```bash
# Editar .env: CHATBOT_IMAGE=ghcr.io/naahiki/zinekide-chatbot:2.0.28
docker compose pull
docker compose up -d
```

Rollback inverso: cambiar la tag y repetir.

---

## Variables de entorno

| Variable | Requerido | Default | Descripción |
|----------|-----------|---------|-------------|
| `CHATBOT_IMAGE` | ✓ | — | Imagen Docker (`ghcr.io/naahiki/zinekide-chatbot:<version>`) |
| `OPENAI_API_KEY` o `ANTHROPIC_API_KEY` | ✓ | — | Al menos una de las dos |
| `PARTNER_API_URL` | ✓ | — | URL del Symfony de Veiss |
| `PARTNER_API_KEY` |   | — | Bearer compartido para `/api/chat/events`. Opcional: la spec actual de Veiss no aplica auth ahí — déjalo vacío hasta que confirme |
| `ALLOWED_ORIGINS` | ✓ | — | Coma-separado, dominios donde se carga el widget |
| `PUBLIC_DOMAIN` | ✓ | — | Subdominio del chatbot (para SSL) |
| `ADMIN_EMAIL` | ✓ | — | Email para Let's Encrypt |
| `PARTNER_SEARCH_AUTH_SCHEME` |   | `none` | `none` \| `bearer` \| `apikey` |
| `PARTNER_SEARCH_AUTH_TOKEN` |   | — | Si scheme ≠ none |
| `PARTNER_SEARCH_AUTH_HEADER` |   | auto | Nombre del header custom (apikey) |
| `LLM_PROVIDER` |   | `openai` | `openai` \| `anthropic` |
| `LLM_MODEL` |   | `gpt-4o-mini` | Modelo inicial (editable en caliente) |
| `PARTNER_TIMEOUT_MS` |   | `5000` | Timeout llamadas a Veiss |
| `RATE_LIMIT_SESSION_CAPACITY` |   | `20` | Mensajes/sesión |
| `RATE_LIMIT_IP_CAPACITY` |   | `60` | Mensajes/IP |
| `MAX_MESSAGE_LEN` |   | `2000` | Caracteres por mensaje |
| `LOG_LEVEL` |   | `info` | `debug` \| `info` \| `warn` \| `error` \| `off` |
| `HOST_PORT` |   | `3001` | Puerto local del container |

Plantilla completa con comentarios: [`.env.example`](.env.example).

---

## Endpoints expuestos por el chatbot

| Endpoint | Método | Para qué |
|----------|--------|----------|
| `/chat` | POST | Mensaje del usuario → respuesta del LLM + proyectos. Lo llama el widget. |
| `/widget/config` | GET | Config visual del widget (proxy cacheado a `/api/widget/config` de Veiss). |
| `/widget/widget.v<X>.js` | GET | Bundle JS versionado del widget (inmutable, cache 1 año). |
| `/widget/widget.latest.js` | GET | Alias al bundle más reciente (cache 5 min). |
| `/healthz` | GET | Liveness probe. |
| `/readyz` | GET | Readiness probe (verifica LLM key + partner alcanzable). |
| `/internal/keys` | GET (X-Internal-Token) | Lista API keys configuradas. Lo consume el panel admin de Veiss para pintar el selector LLM. |

---

## Endpoints que Veiss debe servir desde Symfony

Detallados en `Especificacion_API_Chatbot_Zinekide_v2.md`. Resumen:

1. `GET /api/projects/search` — búsqueda con filtros.
2. `GET /api/projects/summary` — conteos agregados del catálogo.
3. `POST /api/chat/events` — telemetría (Bearer compartido).
4. `GET /api/chatbot/knowledge` + `PUT /admin/chatbot/knowledge` — KB markdown editable.
5. `GET /api/assistant/config` + `GET/PUT /admin/llm-config` — config LLM.
6. `GET /api/widget/config` + `PUT /admin/widget-config` — config visual del widget (opcional).

---

## Desarrollo local

Requiere Node 20+.

```bash
git clone git@github.com:Naahiki/zinekide-chatbot.git
cd zinekide-chatbot
npm install

cp .env.dev.example .env
nano .env   # OPENAI_API_KEY al menos

npm run dev
# Arranca:
#   - partner-mock en      http://localhost:3002 (Symfony simulado)
#   - chatbot-backend en   http://localhost:3001
#   - widget dev server en http://localhost:5173/demo.html
```

Para demo end-to-end contra el Symfony real de Veiss (consume su catálogo real para el search; el resto de endpoints los simula el mock):

```bash
# En .env: REAL_VEISS_API_URL=https://gestion.zinekide.do24.veiss.com
docker compose -f docker-compose.dev.yml up -d --build
```

---

## Estructura del monorepo

```
zinekide-chatbot/
├── packages/
│   ├── chatbot-backend/    Motor IA (Hono + OpenAI/Anthropic SDK)
│   ├── widget/             Frontend embebible (Svelte + Shadow DOM)
│   └── partner-mock/       Symfony simulado para desarrollo
├── nginx/
│   ├── zinekide-chatbot.conf.template
│   └── zinekide-chatbot-proxy.conf
├── docker-compose.yml       producción (cliente final, pull desde GHCR)
├── docker-compose.dev.yml   dev local con partner-mock y build local
├── setup-nginx.sh           configura Nginx + SSL en el host (idempotente)
├── .env.example             plantilla para producción
└── .env.dev.example         plantilla para desarrollo
```

---

## Versionado y releases

Sigue [SemVer](https://semver.org/):

- `vX.Y.Z` patch — cambios internos sin impacto en el contrato (bugs, refinamientos de prompt).
- `vX.Y.0` minor — nuevos endpoints o features no breaking.
- `vX.0.0` major — cambios incompatibles con clientes existentes.

Publicar nueva versión:

```bash
git tag v2.0.24 -m "v2.0.24 — descripción"
git push origin v2.0.24
# GitHub Actions builda y publica ghcr.io/naahiki/zinekide-chatbot:2.0.28
```

Historial en [GitHub Releases](https://github.com/Naahiki/zinekide-chatbot/releases).

---

## Soporte

- **DVM (motor IA + widget)**: nahiki.dev@gmail.com
- **Veiss (Symfony + panel admin)**: integración a través del proyecto Zinekide.
- **Cliente final**: paga API keys de LLM y opera el panel admin desde Symfony.
