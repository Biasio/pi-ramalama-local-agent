#!/usr/bin/env python3
"""Builds this session's shadow models.json and project settings.json.
Runs inside pi-sandbox-image (never on the host), called by lib/session.sh.

argv: <provider_key> <base_url> <id> <name> [<id> <name> ...]
Reads  /base/models.json, /base/settings.json (optional, real user files)
Writes /work/models.json, /work/settings.json (defaultModel = first id)
"""
import json, pathlib, sys


def load(path, default):
    p = pathlib.Path(path)
    if not p.exists():
        return default
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError as exc:
        print(f"[Warning] {path} is not valid JSON, starting from empty: {exc}", file=sys.stderr)
        return default


key, base_url, *pairs = sys.argv[1:]
models = [{"id": i, "name": n} for i, n in zip(pairs[::2], pairs[1::2])]

data = load("/base/models.json", {"providers": {}})
data.setdefault("providers", {})
if base_url not in {p.get("baseUrl") for p in data["providers"].values() if isinstance(p, dict)}:
    data["providers"][key] = {"baseUrl": base_url, "api": "openai-completions",
                              "apiKey": "not-needed", "models": models}
    print(f"[Merge] Router provider added with {len(models)} model(s).", file=sys.stderr)
else:
    print("[Merge] Router baseUrl already present, skipped.", file=sys.stderr)
pathlib.Path("/work/models.json").write_text(json.dumps(data, indent=2))

if models:
    settings = load("/base/settings.json", {})
    settings["defaultModel"] = models[0]["id"]
    pathlib.Path("/work/settings.json").write_text(json.dumps(settings, indent=2))
    print(f"[Merge] Project settings.json defaultModel -> {models[0]['id']}", file=sys.stderr)
