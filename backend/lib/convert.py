"""Convert a Qwen3.5 MLX build from Hugging Face into a uzu model folder, with lalamo (github.com/trymirai/lalamo).

Run with lalamo's Python (uzu-convert sets that up):
  python -I convert.py REPO OUT_DIR HANASHI_DIR [--vendor V] [--identity "sentence"]

1. The repo is downloaded into the Hugging Face cache, and src/ next to OUT_DIR gets APFS clones of its files (no
   extra disk). config.json is rewritten so that rope_parameters carries partial_rotary_factor, which lalamo's Qwen3.5
   importer requires and some MLX builds keep only one level up. generation_config.json is Qwen's recommended sampling
   (Qwen/Qwen3.5-27B's, the file lalamo's own Qwen3.5 specs use).
2. Some MLX uploads keep Hugging Face's tensor layout: conv1d as (C, 1, K) and RMSNorm weights without the +1 that MLX
   bakes in. mlx-lm fixes that when it loads them (qwen3_5.py sanitize); lalamo assumes the baked layout, so
   fixups.safetensors gets the corrected tensors and is listed first, where lalamo looks before the originals.
3. lalamo converts it with the model's own chat template. encoding.json (uzu's chat format, make_encoding.py) is added,
   and for the 9B shape Mirai's Qwen3.5-9B speculator (it drafts tokens; the same file ships with Mirai's 9B builds).
"""

import argparse
import datetime
import json
import shutil
import subprocess
import sys
from functools import partial
from pathlib import Path

import ml_dtypes
import numpy as np
from huggingface_hub import hf_hub_download, snapshot_download
from lalamo.commands import convert
from lalamo.main import CliConversionCallbacks
from lalamo.model_import.model_configs import HFQwen35Config
from lalamo.model_import.model_spec import ConfigMap, FileSpec, LanguageModelSpec
from lalamo.model_import.model_specs.output_parser_regexes import OPTIONAL_THINKING_OUTPUT_PARSER_REGEX
from lalamo.model_import.model_specs.qwen import QWEN_END_OF_THINKING_TAG
from lalamo.model_import.model_specs.reasoning_configs import BOOLEAN_REASONING_DEFAULT_ON_CONFIG
from lalamo.model_import.origins import LocalOrigin

HERE = Path(__file__).resolve().parent
SOURCE_FILES = ("tokenizer.json", "tokenizer_config.json", "chat_template.jinja")
GENERATION_CONFIG = ("Qwen/Qwen3.5-27B", "generation_config.json")
SPECULATOR_REPOS = {(32, 4096): "trymirai/Qwen3.5-9B-M"}  # (layers, hidden size) -> a Mirai build with a speculator
MIRAI_CACHE = Path.home() / ".cache/mirai/models/mirai"
MLX_BAKED_NORM_SUFFIXES = (
    ".input_layernorm.weight",
    ".post_attention_layernorm.weight",
    "model.norm.weight",
    ".q_norm.weight",
    ".k_norm.weight",
)
FIXUPS_FILE = "fixups.safetensors"


def clone(source: Path, destination: Path) -> None:
    destination.unlink(missing_ok=True)
    subprocess.run(["cp", "-c", str(source.resolve()), str(destination)], check=True)


def read_safetensors_header(path: Path) -> tuple[int, dict]:
    with path.open("rb") as file:
        header_size = int.from_bytes(file.read(8), "little")
        header = json.loads(file.read(header_size))
    header.pop("__metadata__", None)
    return 8 + header_size, header


def read_bfloat16(path: Path, data_start: int, entry: dict) -> np.ndarray:
    if entry["dtype"] != "BF16":
        raise SystemExit(f"expected a BF16 tensor, got {entry['dtype']}")
    begin, end = entry["data_offsets"]
    with path.open("rb") as file:
        file.seek(data_start + begin)
        raw = file.read(end - begin)
    return np.frombuffer(raw, dtype=ml_dtypes.bfloat16).reshape(entry["shape"])


def write_bfloat16_safetensors(path: Path, tensors: dict[str, np.ndarray]) -> None:
    header, blobs, offset = {}, [], 0
    for name, tensor in tensors.items():
        blob = np.ascontiguousarray(tensor.astype(ml_dtypes.bfloat16)).tobytes()
        header[name] = {"dtype": "BF16", "shape": list(tensor.shape), "data_offsets": [offset, offset + len(blob)]}
        blobs.append(blob)
        offset += len(blob)
    header_bytes = json.dumps(header).encode()
    header_bytes += b" " * (-len(header_bytes) % 8)
    path.write_bytes(len(header_bytes).to_bytes(8, "little") + header_bytes + b"".join(blobs))


def mlx_layout_fixups(source_dir: Path, weight_files: tuple[str, ...]) -> dict[str, np.ndarray]:
    """Tensors mlx-lm's Qwen3.5 sanitize would change: empty when the upload is already in MLX layout."""
    shards = [(source_dir / name, *read_safetensors_header(source_dir / name)) for name in weight_files]
    entries = [(path, start, name, entry) for path, start, header in shards for name, entry in header.items()]
    if not any("conv1d.weight" in name and entry["shape"][-1] != 1 for _, _, name, entry in entries):
        return {}
    fixups = {}
    for path, start, name, entry in entries:
        if "conv1d.weight" in name and entry["shape"][-1] != 1:
            fixups[name] = np.moveaxis(read_bfloat16(path, start, entry), 2, 1)
        elif len(entry["shape"]) == 1 and name.endswith(MLX_BAKED_NORM_SUFFIXES):
            fixups[name] = read_bfloat16(path, start, entry).astype(np.float32) + 1.0
    return fixups


def prepare_source(repo: str, source_dir: Path) -> tuple[tuple[str, ...], dict, int]:
    print(f"==> Downloading {repo} (or using the copy already in the Hugging Face cache)", flush=True)
    snapshot = Path(snapshot_download(repo))
    config = json.loads((snapshot / "config.json").read_text())
    text_config = config.get("text_config", config)
    if config.get("model_type") not in ("qwen3_5", "qwen3_5_moe") and text_config.get("model_type") not in ("qwen3_5", "qwen3_5_text"):
        raise SystemExit(f"{repo} is not a Qwen3.5 model (model_type {config.get('model_type')}); only Qwen3.5 builds convert here.")
    quant = config.get("quantization") or config.get("quantization_config") or {}
    if not quant.get("bits"):
        raise SystemExit(f"{repo} is not an MLX quantized build. Use its MLX 4-bit or 8-bit version (search Hugging Face for '<name> MLX').")

    source_dir.mkdir(parents=True, exist_ok=True)
    index_path = snapshot / "model.safetensors.index.json"
    weight_files = (
        tuple(sorted(set(json.loads(index_path.read_text())["weight_map"].values())))
        if index_path.exists()
        else ("model.safetensors",)
    )
    for filename in (*SOURCE_FILES, *weight_files):
        if (snapshot / filename).exists():
            clone(snapshot / filename, source_dir / filename)
    if not (source_dir / "chat_template.jinja").exists():
        raise SystemExit(f"{repo} has no chat_template.jinja.")
    rope = text_config.setdefault("rope_parameters", {})
    rope.setdefault("partial_rotary_factor", text_config.get("partial_rotary_factor", 0.25))
    rope.setdefault("rope_theta", text_config.get("rope_theta", 10_000_000))
    (source_dir / "config.json").write_text(json.dumps(config, indent=2))
    shutil.copyfile(hf_hub_download(*GENERATION_CONFIG), source_dir / "generation_config.json")

    (source_dir / FIXUPS_FILE).unlink(missing_ok=True)
    fixups = mlx_layout_fixups(source_dir, weight_files)
    if fixups:
        write_bfloat16_safetensors(source_dir / FIXUPS_FILE, fixups)
        print(f"==> Hugging Face tensor layout detected: {len(fixups)} tensors corrected in {FIXUPS_FILE}", flush=True)
        weight_files = (FIXUPS_FILE, *weight_files)
    return weight_files, text_config, len(fixups)


def speculator_dir(text_config: dict) -> Path | None:
    repo = SPECULATOR_REPOS.get((text_config.get("num_hidden_layers"), text_config.get("hidden_size")))
    if repo is None:
        return None
    for cached in sorted(MIRAI_CACHE.glob("alibaba-qwen3.5-9b-mirai-*/*/speculator")):
        if (cached / "model.safetensors").exists():
            return cached
    print(f"==> Downloading Mirai's speculator from {repo} (0.8 GB)", flush=True)
    return Path(snapshot_download(repo, allow_patterns=["speculator/*"])) / "speculator"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("repo")
    parser.add_argument("out_dir", type=Path)
    parser.add_argument("hanashi_dir", type=Path)
    parser.add_argument("--vendor", default="")
    parser.add_argument("--identity", help="sentence the model's chat template appends to every system message")
    args = parser.parse_args()

    out_dir = args.out_dir.resolve()
    name = out_dir.name
    source_dir = out_dir.parent / ".src" / name
    weight_files, text_config, fixup_count = prepare_source(args.repo, source_dir)

    print(f"==> Converting with lalamo into {out_dir}", flush=True)
    spec = LanguageModelSpec(
        vendor=args.vendor or args.repo.split("/")[0],
        family="Qwen3.5",
        name=name,
        size="",
        origin=LocalOrigin(root=str(source_dir), weight_files=weight_files),
        config_type=HFQwen35Config,
        output_parser_regex=OPTIONAL_THINKING_OUTPUT_PARSER_REGEX,
        end_of_thinking_tag=QWEN_END_OF_THINKING_TAG,
        reasoning_config=BOOLEAN_REASONING_DEFAULT_ON_CONFIG,
        configs=ConfigMap(chat_template=FileSpec("chat_template.jinja")),
    )
    convert(spec, out_dir, None, partial(CliConversionCallbacks, overwrite=True))

    encoding = [sys.executable, "-I", str(HERE / "make_encoding.py"), str(args.hanashi_dir), str(out_dir)]
    if args.identity:
        encoding[3:3] = ["--identity", args.identity]
    subprocess.run(encoding, check=True)

    speculator = speculator_dir(text_config)
    shutil.rmtree(out_dir / "speculator", ignore_errors=True)
    if speculator is not None:
        (out_dir / "speculator").mkdir()
        for file in speculator.iterdir():
            clone(file, out_dir / "speculator" / file.name)
        print("==> Added Mirai's Qwen3.5-9B speculator", flush=True)
    else:
        print("==> No speculator for this model size (Mirai ships one for the 9B only); it runs without drafting", flush=True)

    shutil.rmtree(source_dir, ignore_errors=True)  # clones of the cache: nothing is lost
    (out_dir / "uzu-home.json").write_text(json.dumps({
        "source_repo": args.repo, "converted_at": datetime.datetime.now().isoformat(timespec="seconds"),
        "fixups": fixup_count, "speculator": speculator is not None, "identity": args.identity or None,
    }, indent=1))
    print(f"==> Ready: {out_dir}", flush=True)


if __name__ == "__main__":
    main()
