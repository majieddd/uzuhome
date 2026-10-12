"""Write encoding.json, the chat format uzu needs for a local model, using uzu's bundled qwen3.5 encoding.

uzu renders chats with its hanashi encodings, not with the model's chat template. With --identity, this inlines
hanashi's qwen3.5 parts as a "custom" encoding whose system message always ends with that sentence, which is
how Qwythos's own chat template differs from Qwen3.5's. Without it, the plain qwen3.5 encoding is used.

Usage: python3 make_encoding.py [--identity "<sentence>"] <hanashi configs dir> <model dir> [<model dir> ...]
"""

import argparse
import json
import sys
from pathlib import Path

TOOLS_SYSTEM_OLD = """            {{- '\\n\\n' + content }}
        {%- endif %}
    {%- endif %}
    {{- '<|im_end|>\\n' }}
{%- else %}
    {%- if messages[0].role == 'system' %}
        {%- set content = render_content(messages[0].content, false, true)|trim %}
        {{- '<|im_start|>system\\n' + content + '<|im_end|>\\n' }}
    {%- endif %}
{%- endif %}"""

TOOLS_SYSTEM_NEW = """            {{- '\\n\\n' + content }}
        {%- endif %}
    {%- endif %}
    {{- '\\n\\n' + qwythos_identity }}
    {{- '<|im_end|>\\n' }}
{%- else %}
    {{- '<|im_start|>system\\n' }}
    {%- if messages[0].role == 'system' %}
        {%- set content = render_content(messages[0].content, false, true)|trim %}
        {%- if content %}
            {{- content + '\\n\\n' }}
        {%- endif %}
    {%- endif %}
    {{- qwythos_identity }}
    {{- '<|im_end|>\\n' }}
{%- endif %}"""


def identity_encoding(configs_dir: Path, identity: str) -> dict:
    load = lambda part, name: json.loads((configs_dir / part / f"{name}.json").read_text())  # noqa: E731

    rendering = load("rendering", "qwen3.5")
    template = rendering["jinja"]["template"]
    if template.count(TOOLS_SYSTEM_OLD) != 1:
        sys.exit("qwen3.5 template changed upstream; system-message block not found exactly once")
    rendering["jinja"]["template"] = (
        "{%- set qwythos_identity = " + json.dumps(identity) + " %}\n" + template.replace(TOOLS_SYSTEM_OLD, TOOLS_SYSTEM_NEW)
    )
    return {
        "type": "hanashi",
        "name": "custom",
        "parsing": load("parsing", "qwen3.5"),
        "rendering": rendering,
        "tokens": load("tokens", "qwen3.5"),
        "ordering": load("ordering", "default"),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--identity")
    parser.add_argument("configs_dir", type=Path)
    parser.add_argument("model_dirs", type=Path, nargs="+")
    args = parser.parse_args()

    encoding = (
        identity_encoding(args.configs_dir, args.identity)
        if args.identity
        else {"type": "hanashi", "name": "qwen3.5"}
    )
    for model_dir in args.model_dirs:
        (model_dir / "encoding.json").write_text(json.dumps([encoding], indent=1))
        print(f"wrote {model_dir / 'encoding.json'}")


if __name__ == "__main__":
    main()
