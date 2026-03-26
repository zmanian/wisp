# Wisp Channel Plugin

Channel plugin for [Claude Code](https://code.claude.com) that enables chat from the [Wisp](https://github.com/mcintyre94/wisp) iOS app on [Sprites.dev](https://sprites.dev) cloud VMs.

## How it works

The plugin runs as an MCP server alongside Claude Code on a Sprite. It provides:

- **HTTP server** (port 39281) for receiving messages from the Wisp iOS app
- **SSE streaming** for delivering Claude's responses back to the app
- **Reverse proxy** for routing user HTTP traffic to app backends on the sprite

## Setup

The Wisp iOS app handles installation automatically. When you open a chat on a sprite, Wisp:

1. Uploads the plugin files to `~/.wisp/plugin/`
2. Registers the MCP server in Claude's settings
3. Starts Claude as a managed Sprites service with `--channels server:wisp`

## Development

```bash
cd wisp-plugin
bun install
```

## License

Apache 2.0
