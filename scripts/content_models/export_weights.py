"""Prepare standalone fp16 weights on Windows/macOS, separate from iOS packages."""
import argparse
import json
import os
from pathlib import Path
import shutil

from convert_models import ROOT, LOCK, fetch_assets
from reference import sha256


def export(cache, output):
    fetch_assets(cache)
    os.environ.setdefault('YOLO_CONFIG_DIR', str(cache / 'ultralytics'))
    os.environ.setdefault('MPLCONFIGDIR', str(cache / 'matplotlib'))
    import torch
    import ultralytics  # Registers the verified NudeNet checkpoint's classes.
    from safetensors.torch import load_file, save_file

    output.mkdir(parents=True, exist_ok=True)
    checkpoint = torch.load(cache / 'nudenet/320n.pt', map_location='cpu', weights_only=False)
    parameters = list(checkpoint['model'].parameters())
    if not parameters or any(p.dtype != torch.float16 or not torch.isfinite(p).all() for p in parameters):
        raise ValueError('The published NudeNet 320n checkpoint must already contain finite fp16 weights')
    nude = output / 'nudenet-320n-fp16.pt'
    shutil.copyfile(cache / 'nudenet/320n.pt', nude)

    joy = output / 'joytag'
    joy.mkdir(exist_ok=True)
    tensors = load_file(cache / 'joytag/model.safetensors')
    converted = {name: tensor.half() if tensor.is_floating_point() else tensor for name, tensor in tensors.items()}
    if any(not torch.isfinite(t).all() for t in converted.values()):
        raise ValueError('JoyTag fp16 conversion overflowed')
    save_file(converted, joy / 'model.safetensors', metadata={'source_revision':
        '6b7f16331a6ccf0fdce37d5a9564715f6e772b22', 'precision': 'float16'})
    restored = load_file(joy / 'model.safetensors')
    if set(restored) != set(tensors) or any(not torch.equal(restored[k], converted[k]) for k in converted):
        raise ValueError('Saved JoyTag fp16 weights differ from converted tensors')
    for name in ['config.json', 'top_tags.txt', 'LICENSE']:
        shutil.copyfile(cache / 'joytag' / name, joy / name)
    manifest = {'sources': LOCK, 'precision': 'float16', 'files': {
        p.relative_to(output).as_posix(): {'sha256': sha256(p), 'bytes': p.stat().st_size}
        for p in output.rglob('*') if p.is_file() and p.name != 'fp16-weights.json'}}
    (output / 'fp16-weights.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Verified standalone fp16 weights: {output}', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=ROOT / 'model-cache')
    parser.add_argument('--output', type=Path, default=ROOT / 'model-cache/fp16')
    args = parser.parse_args()
    export(args.cache, args.output)
