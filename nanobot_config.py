#!/usr/bin/env python3
"""Manage nanobot's config.json for Docker deployment.

Handles Docker networking overrides (host fields, apiKey) plus local-provider
api_base fixup (localhost → host.docker.internal so Ollama/vLLM/LM Studio
running on the host are reachable from inside the container).

Usage:
    python3 nanobot_config.py get-api-key    # print existing key or generate
    python3 nanobot_config.py write <api_key> # write/update config.json
    python3 nanobot_config.py setup           # generate key + write config
    python3 nanobot_config.py fix-localhost   # rewrite localhost→host.docker.internal
"""

import json
import os
import secrets
import sys

CONFIG_JSON = os.path.expanduser("~/.nanobot/config.json")

# Only the fields that MUST be changed for Docker.
# Everything else comes from nanobot's built-in defaults or onboard wizard.
DOCKER_HOST_OVERRIDES = {
    "gateway.host": "0.0.0.0",
    "api.host": "0.0.0.0",
    "channels.websocket.host": "0.0.0.0",
}


def _load() -> dict:
    if os.path.exists(CONFIG_JSON):
        with open(CONFIG_JSON) as f:
            return json.load(f)
    return {}


def _save(config: dict) -> None:
    os.makedirs(os.path.dirname(CONFIG_JSON), exist_ok=True)
    with open(CONFIG_JSON, "w") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)


def _deep_set(d: dict, key_path: str, value: object) -> None:
    keys = key_path.split(".")
    for k in keys[:-1]:
        d = d.setdefault(k, {})
    d[keys[-1]] = value


LOCALHOST_PATTERNS = ("localhost:", "127.0.0.1:")

# Known local providers and their default host ports.
# Mirrors ProviderSpec.default_api_base from nanobot/providers/registry.py.
# Keys are camelCase because Pydantic model_dump(by_alias=True) converts field
# names that way (lm_studio → lmStudio, atomic_chat → atomicChat).
_LOCAL_PROVIDER_DEFAULTS: dict[str, str] = {
    "ollama": "http://host.docker.internal:11434/v1",
    "vllm": "http://host.docker.internal:8000/v1",
    "lmStudio": "http://host.docker.internal:1234/v1",
    "atomicChat": "http://host.docker.internal:1337/v1",
    "ovms": "http://host.docker.internal:8000/v3",
}


def fix_localhost(config_path: str | None = None) -> list[str]:
    """Rewrite localhost api_base → host.docker.internal for Docker networking.

    Inside a Docker container, ``localhost`` resolves to the container itself,
    not the host. Providers like Ollama, vLLM, and LM Studio run on the host,
    so their api_base must use ``host.docker.internal`` (macOS / Windows) or
    the docker0 gateway IP (Linux).

    Returns a list of human-readable change descriptions.
    """
    path = config_path or CONFIG_JSON
    if not os.path.exists(path):
        return []

    with open(path) as f:
        config = json.load(f)

    providers = config.get("providers", {})
    if not isinstance(providers, dict):
        return []

    # Pydantic model_dump(by_alias=True) writes camelCase keys (apiBase).
    # We must read/write the same keys so nanobot picks up the value.
    KEY = "apiBase"
    SNAKE_KEY = "api_base"  # clean up from buggy earlier version

    changes: list[str] = []
    for name, cfg in list(providers.items()):
        if not isinstance(cfg, dict):
            continue
        # Clean up stale snake_case key written by buggy earlier version
        if SNAKE_KEY in cfg:
            del cfg[SNAKE_KEY]
        base = cfg.get(KEY, "")
        if isinstance(base, str) and base:
            for pattern in LOCALHOST_PATTERNS:
                if pattern in base:
                    new_base = base.replace("localhost", "host.docker.internal")
                    new_base = new_base.replace("127.0.0.1", "host.docker.internal")
                    cfg[KEY] = new_base
                    changes.append(
                        f"providers.{name}.apiBase: {base} → {new_base}"
                    )
                    break
        elif name in _LOCAL_PROVIDER_DEFAULTS:
            cfg[KEY] = _LOCAL_PROVIDER_DEFAULTS[name]
            changes.append(
                f"providers.{name}.apiBase: (unset) → {_LOCAL_PROVIDER_DEFAULTS[name]}"
            )

    if changes:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            json.dump(config, f, indent=2, ensure_ascii=False)

    return changes


def get_api_key() -> str:
    """Return existing apiKey or generate a new one."""
    config = _load()
    key = config.get("api", {}).get("apiKey", "")
    if key:
        return key
    return secrets.token_hex(16)


def write_config(api_key: str) -> str:
    """Update config with Docker host overrides and API key. Returns path."""
    config = _load()

    # Ensure parent sections exist
    config.setdefault("api", {})

    for key_path, value in DOCKER_HOST_OVERRIDES.items():
        _deep_set(config, key_path, value)

    config["api"]["apiKey"] = api_key

    _save(config)
    return CONFIG_JSON


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    if len(sys.argv) < 2:
        print("Usage: nanobot_config.py <get-api-key|write <key>|setup>")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "get-api-key":
        print(get_api_key())

    elif cmd == "write":
        if len(sys.argv) < 3:
            print("Usage: nanobot_config.py write <api_key>", file=sys.stderr)
            sys.exit(1)
        api_key = sys.argv[2]
        path = write_config(api_key)
        print(path)

    elif cmd == "setup":
        key = get_api_key()
        path = write_config(key)
        print(f"{key}\n{path}")

    elif cmd == "fix-localhost":
        changes = fix_localhost()
        if changes:
            for line in changes:
                print(line)
        else:
            print("(no localhost api_base entries found)")

    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
