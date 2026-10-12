#!/usr/bin/env python3
"""The chat models in Mirai's catalog, read from the registry the uzu engine caches (~/.cache/mirai/registry.json).

    catalog.py            one line per model: id|bytes|label
    catalog.py --label ID the label uzu Home lists that model under
"""
import json
import os
import sys

REGISTRY = os.path.expanduser("~/.cache/mirai/registry.json")
SIZE_NAMES = {"mirai-s": "Small", "mirai-m": "Medium", "mirai-l": "Large"}


def chat_models():
    try:
        with open(REGISTRY) as fh:
            entries = json.load(fh)
    except (OSError, ValueError):
        return []
    out = []
    for m in entries:
        if not any((s or {}).get("type") == "chat" for s in m.get("specializations") or []):
            continue
        if (m.get("accessibility") or {}).get("type") != "local":
            continue
        files = ((m["accessibility"].get("reference") or {}).get("files")) or []
        size = sum(int(f.get("size") or 0) for f in files)
        out.append({"id": m["id"], "bytes": size, "label": label(m, size)})
    return out


def label(m, size):
    family = (((m.get("family") or {}).get("metadata")) or {}).get("name") or m["id"].split(":")[1]
    props = m.get("properties") or {}
    params = ((props.get("metadata")) or {}).get("name") or props.get("id") or ""
    q = m.get("quantization") or {}
    tier = SIZE_NAMES.get(q.get("method"), (q.get("metadata") or {}).get("name") or q.get("method") or "")
    bits = q.get("bits_per_weight")
    detail = ", ".join(x for x in (f"{bits}-bit" if bits else "", f"{size / 1e9:.1f} GB" if size else "") if x)
    name = " ".join(x for x in (family, params) if x)
    return f"{name} · Mirai {tier}" + (f" ({detail})" if detail else "")


def main():
    models = chat_models()
    if len(sys.argv) == 3 and sys.argv[1] == "--label":
        for m in models:
            if m["id"] == sys.argv[2]:
                print(m["label"])
                return 0
        return 1
    if not models:
        print("Mirai's catalog is not cached yet: it is fetched the first time the engine starts.", file=sys.stderr)
        return 1
    for m in models:
        print(f"{m['id']}|{m['bytes']}|{m['label']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
