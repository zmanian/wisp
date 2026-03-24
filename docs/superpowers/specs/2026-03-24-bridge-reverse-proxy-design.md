# Bridge Reverse Proxy and HTTP Service Documentation

**Date:** 2026-03-24
**Branch:** `feature/issue-110-channel-chat`
**Status:** Approved

## Problem

The Sprites platform enforces a one-HTTP-service-per-sprite constraint via the `http_port` field on services. The Wisp channel bridge owns this slot (port 39281), which means user apps running on the sprite have no way to receive HTTP traffic through the sprite's public URL.

Claude Code running on the sprite needs a way to expose HTTP services (web apps, APIs, etc.) to the outside world without conflicting with the bridge.

## Solution

Add a reverse proxy to the bridge so it can forward non-bridge HTTP requests to user-registered backends on localhost. Add documentation to the project CLAUDE.md so Claude Code knows how to use it.

## Route Registration API

Three new endpoints, all requiring `X-Wisp-Bridge-Key`:

### `POST /routes` — register a route

```json
// Request
{"prefix": "/app", "port": 3000}

// Response (201)
{"ok": true, "prefix": "/app", "port": 3000}
```

### `DELETE /routes` — remove a route

```json
// Request
{"prefix": "/app"}

// Response (200)
{"ok": true}
```

### `GET /routes` — list all registered routes

```json
// Response (200)
{"routes": [{"prefix": "/app", "port": 3000}, {"prefix": "/", "port": 8080}]}
```

### Matching rules

- Routes are matched **longest prefix first** (e.g. `/api` beats `/` for `/api/users`).
- A route with prefix `/` acts as a default catch-all.
- Bridge paths (`/message`, `/interrupt`, `/status`, `/events`, `/routes`) are reserved and cannot be registered.

## Reverse Proxy Behavior

When the bridge receives a request that doesn't match any bridge path:

1. Find the longest matching route prefix.
2. **Strip the prefix** from the path (e.g. `/app/foo` with prefix `/app` proxies to `localhost:3000/foo`).
3. Forward the request method, headers, and body to `http://localhost:{port}{stripped_path}`.
4. Return the upstream's response (status, headers, body) to the caller.
5. If no route matches, return **404 Not Found**.
6. If the upstream is unreachable, return **502 Bad Gateway**.

### Security

- Route registration/deletion (`POST /routes`, `DELETE /routes`, `GET /routes`) requires `X-Wisp-Bridge-Key`.
- Proxied requests do **not** require the bridge secret. The sprite URL's own auth mode (`sprite` or `public`) is the access control layer.
- No upstream port validation on registration. If nothing is listening, the proxy returns 502.

### HTTP methods

The proxy handles all standard methods: GET, POST, PUT, DELETE, PATCH, HEAD.

## Route Persistence

Routes are stored in `~/.wisp/channel-bridge/routes.json`:

```json
[{"prefix": "/app", "port": 3000}, {"prefix": "/", "port": 8080}]
```

Loaded on bridge startup, written on every `POST /routes` or `DELETE /routes`. Routes survive bridge restarts and sprite checkpoint/restore.

## CLAUDE.md Documentation

During `ensure_claude_project_config()`, the bridge writes an HTTP services section to `{working_directory}/CLAUDE.md`. The section is managed between marker comments (`<!-- wisp-bridge-start -->` / `<!-- wisp-bridge-end -->`) so it can be updated on bridge upgrades without clobbering user content.

Content:

```markdown
<!-- wisp-bridge-start -->
## HTTP Services (Wisp Bridge)

This sprite's public URL routes through the Wisp channel bridge. To expose an HTTP service:

1. Start your server on any port (e.g. `python3 -m http.server 3000`)
2. Register the route with the bridge:
   ```bash
   SECRET=$(cat ~/.wisp/channel-bridge/bridge_secret)
   curl -X POST http://localhost:39281/routes \
     -H "X-Wisp-Bridge-Key: $SECRET" \
     -H "Content-Type: application/json" \
     -d '{"prefix": "/", "port": 3000}'
   ```
3. Your service is now accessible at the sprite's public URL.

Multiple routes are supported. Longest prefix wins:
```bash
curl -X POST http://localhost:39281/routes \
  -H "X-Wisp-Bridge-Key: $SECRET" \
  -H "Content-Type: application/json" \
  -d '{"prefix": "/api", "port": 4000}'
```

Prefixes are stripped: a request to `/api/users` with prefix `/api` proxies to `localhost:4000/users`.

To list routes: `GET /routes`
To remove a route: `DELETE /routes` with `{"prefix": "/api"}`

Reserved paths (cannot be registered): /message, /interrupt, /status, /events, /routes
<!-- wisp-bridge-end -->
```

## Implementation Scope

### Bridge changes (bridge.py)

- Route store: load/save `routes.json`, in-memory list protected by `STATE_LOCK`
- `POST /routes`, `DELETE /routes`, `GET /routes` endpoints (secret-protected)
- Reverse proxy fallback for all HTTP methods: longest prefix match, strip prefix, forward to `localhost:{port}`, return upstream response or 502
- `ensure_claude_project_config()` writes/updates CLAUDE.md with HTTP services section

### iOS client changes

- Bump `WispChannelBridge.version` from "3" to "4" so the updated bridge.py gets uploaded to sprites

### No changes needed

- channel.py (MCP helper, unrelated)
- ClaudeStreamParser.swift (SSE parsing, unrelated)
- View models and views (no new UI for route management)
