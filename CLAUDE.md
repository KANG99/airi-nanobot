# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Is

Integration glue that connects [Airi](https://github.com/moeru-ai/airi) (AI VTuber browser frontend, Vue/TypeScript) to [nanobot](https://github.com/HKUDS/nanobot) (AI agent framework, Python/Docker). The two subprojects live under `airi/` and `nanobot/` — each has its own `AGENTS.md` with detailed architecture and dev commands.

## Architecture

```
Airi (browser :5173)  →  CORS Proxy (:18900)  →  nanobot API (:8900)  →  nanobot Gateway (:8765 WS, :18790 health)
```

The CORS proxy is needed because Airi runs in the browser and nanobot's API doesn't return CORS headers. The proxy also **merges multi-message requests** (system + user) into a single user message — nanobot's `/v1/chat/completions` only accepts one user-role message.

## Root-Level Files (the integration layer)

| File | Role |
|---|---|
| `setup.sh` | One-command deploy: clones repos, configures nanobot for Docker, builds & starts containers, starts CORS proxy, installs Airi deps, starts dev server, opens browser config page. Idempotent-ish — skips clone/install on re-run. |
| `cors-proxy.py` | HTTP proxy (`127.0.0.1:18900` → `127.0.0.1:8900`). Adds CORS headers + merges multi-message chat requests. Stdlib-only, no deps. |
| `nanobot_config.py` | Writes `~/.nanobot/config.json` with Docker-required host overrides (`0.0.0.0`) and API key. Also fixes `localhost` → `host.docker.internal` in provider `apiBase` fields so containers can reach host-running Ollama/vLLM. |
| `nanobot-setup.html` | Template deployed into Airi's `public/` dir. Injected by `setup.sh` with the actual `BASE_URL` and `API_KEY`. On page load, writes credentials to Airi's `localStorage` under `openai-compatible` provider, then redirects to Airi. |

## Quick Start

```bash
./setup.sh
```

Requires: `git`, `docker`, `node`, `pnpm`, `python3`, `curl`.

## Subprojects

- **`airi/`** — See `airi/AGENTS.md`. pnpm monorepo. Dev: `cd airi && pnpm i && pnpm dev`. Stage-web runs on `:5173`.
- **`nanobot/`** — See `nanobot/AGENTS.md`. Python 3.11+ agent framework. Runs in Docker via `docker compose`. API on `:8900`, gateway WS on `:8765`.

## Key Configuration

- nanobot config lives at `~/.nanobot/config.json`. Docker needs `gateway.host`, `api.host`, `channels.websocket.host` set to `0.0.0.0`.
- Airi talks to nanobot through the `openai-compatible` provider type, pointing at the CORS proxy (`http://127.0.0.1:18900/v1/`).
- The proxy is a transparent pass-through except for `POST /v1/chat/completions` where it merges `messages[]` into a single user message.
