# Channel Chat Plan

This branch tracks the client-side groundwork for issue [#110](https://github.com/mcintyre94/wisp/issues/110): moving chat from exec-based NDJSON over WebSocket to a channel bridge that uses HTTP for input and SSE for streaming output.

## Scope in `feature/issue-110-channel-chat`

- Add a temporary `ClaudeChatTransportMode` enum so the migration can be validated before exec chat is deleted.
- Add channel bridge request and status models on the iOS side.
- Add channel bridge URL and request builders that can target a sprite's public or sprite-auth URL.
- Add a reusable SSE parser so the eventual bridge can stream structured events without depending on WebSocket framing.
- Route `ChatViewModel` through the channel bridge when the experimental transport mode is enabled.
- Persist the last SSE event ID per chat so channel-mode reconnect can resume after app backgrounding.
- Add tests around the new URL, auth, model, and SSE parsing behavior.

## Bridge Design Landed in This Branch

- One managed bridge service runs per sprite on a fixed HTTP port and is installed through the Sprites services API.
- The bridge preserves Wisp's many-chats-per-sprite model by managing one Claude session per Wisp `chat_id` behind the scenes.
- Each chat-specific Claude process now registers its own unique dev-channel MCP server entry in Claude's project state before startup, so multiple chats can coexist without sharing channel config.
- Claude runs behind a PTY and the bridge auto-accepts the one-time startup prompts that still gate research-preview dev channels on Claude Code 2.1.81.
- Each chat-specific Claude process gets its own lightweight MCP channel helper, while the shared bridge service owns the public HTTP API:
  - `POST /message`
  - `POST /interrupt`
  - `GET /events?chat_id=...`
  - `GET /status?chat_id=...`
- The bridge persists chat state on the sprite and reuses Claude session IDs across restarts, including `--resume ... --fork-session` for quick/side-chat style branches.
- Outbound chat events come from Claude's persisted session JSONL rather than exec NDJSON, so Wisp can keep using the existing `ClaudeStreamEvent` rendering pipeline.
- Protected sprite URLs still reuse the Sprites bearer token, and the bridge now adds its own per-sprite shared secret header for defense in depth.
- Live validation against sprite `wisp-110-20260321-123846` succeeded for both an initial turn and a follow-up turn on the same `chat_id`, with `HELLO_BRIDGE` and `SECOND_BRIDGE` both delivered over SSE.

## Intended End State

- Wisp chat is channel-only.
- The transport picker and dual-path client logic are short-lived migration scaffolding, not a permanent product choice.
- Exec remains in the app only for non-chat operations that still need remote shell access.

## Remaining Follow-Ups

1. ~~Decide whether the bridge should stay rooted at the sprite URL or move behind a dedicated subpath once we confirm how sprite HTTP proxying interacts with user-hosted apps.~~ **Done.** Sprites only allow one `http_port` service — no path-based routing exists. Bridge stays at root and includes a reverse proxy for user apps.
2. Decide how much quick/side chat should preserve exec-era tool restrictions now that the bridge owns long-lived Claude sessions.
3. ~~Remove the transport picker and delete exec-based chat now that the bridge path is proven end to end on a real sprite.~~ **Done.** `ClaudeChatTransportMode` enum, transport picker, and all exec-based chat code paths removed. Channel is now the only chat transport.
