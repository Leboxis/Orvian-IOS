"""Pinned NudeNet 320n and JoyTag exports for local iOS inference.

Run on macOS with Python 3.12. --fetch-only is usable on Windows too.
No sample user images are downloaded or uploaded by this script.
"""
import argparse
from contextlib import contextmanager
import importlib.util
import json
import os
from pathlib import Path
import platform
from unittest.mock import patch

from reference import download_verified, semen_tag_index, sha256

ROOT = Path(__file__).resolve().parents[2]
LOCK = json.loads(Path(__file__).with_name('assets.json').read_text(encoding='utf-8'))
VERSION = LOCK['pipeline_version']
NUDENET_LABELS = [
    'FEMALE_GENITALIA_COVERED', 'FACE_FEMALE', 'BUTTOCKS_EXPOSED',
    'FEMALE_BREAST_EXPOSED', 'FEMALE_GENITALIA_EXPOSED', 'MALE_BREAST_EXPOSED',
    'ANUS_EXPOSED', 'FEET_EXPOSED', 'BELLY_COVERED', 'FEET_COVERED',
    'ARMPITS_COVERED', 'ARMPITS_EXPOSED', 'FACE_MALE', 'BELLY_EXPOSED',
    'MALE_GENITALIA_EXPOSED', 'ANUS_COVERED', 'FEMALE_BREAST_COVERED', 'BUTTOCKS_COVERED',
]


def fetch_assets(cache):
    for name, asset in LOCK['assets'].items():
        print(f'Verifying {name}', flush=True)
        path = cache / name
        try:
            download_verified(asset['url'], path, asset['sha256'])
        except (ValueError, OSError):
            # Never replace a corrupt existing cache. Mirrors must have exactly
            # the same pinned digest; an HTML download page isn't a weight file.
            if path.exists() or 'mirror' not in asset:
                raise
            print(f'Using checksum-locked mirror for {name}', flush=True)
            download_verified(asset['mirror'], path, asset['sha256'])


def load_wrappers(cache):
    import torch
    from torch import nn

    os.environ.setdefault('YOLO_CONFIG_DIR', str(cache / 'ultralytics'))
    os.environ.setdefault('MPLCONFIGDIR', str(cache / 'matplotlib'))
    os.environ.setdefault('HF_HOME', str(cache / 'huggingface'))
    from ultralytics import YOLO

    detector = YOLO(str(cache / 'nudenet/320n.pt')).model.float().eval()
    names = [detector.names[i] for i in range(len(detector.names))]
    if names != NUDENET_LABELS:
        raise ValueError('NudeNet class ordering differs from the pinned runtime contract')
    detector.fuse()
    # Match the published ONNX export and avoid returning training head tensors.
    head = detector.model[-1]
    head.export = True
    head.format = 'onnx'
    head.dynamic = False

    source = cache / 'joytag/Models.py'
    module_spec = importlib.util.spec_from_file_location('orvian_joytag', source)
    module = importlib.util.module_from_spec(module_spec)
    module_spec.loader.exec_module(module)
    joytag = module.VisionModel.load_model(cache / 'joytag').float().eval()
    tags = (cache / 'joytag/top_tags.txt').read_text(encoding='utf-8').splitlines()
    index = semen_tag_index(tags)
    if joytag.n_tags != len(tags) or joytag.image_size != 448:
        raise ValueError('JoyTag shape or tag count differs from the pinned runtime contract')

    class DetectorExport(nn.Module):
        def __init__(self):
            super().__init__()
            self.model = detector

        def forward(self, image):
            return self.model(image)

    class JoyTagExport(nn.Module):
        def __init__(self):
            super().__init__()
            self.model = joytag
            self.register_buffer('mean', torch.tensor([0.48145466, 0.4578275, 0.40821073]).view(1, 3, 1, 1))
            self.register_buffer('std', torch.tensor([0.26862954, 0.26130258, 0.27577711]).view(1, 3, 1, 1))

        def forward(self, image):
            logits = self.model({'image': (image - self.mean) / self.std})['tags']
            return logits[:, index:index + 1].sigmoid()

    return DetectorExport().eval(), JoyTagExport().eval()


@contextmanager
def exportable_attention():
    """Equivalent unfused SDPA for tracing; native fused operators aren't portable."""
    import torch

    def attention(query, key, value, attn_mask=None, dropout_p=0.0, is_causal=False, scale=None):
        if attn_mask is not None or dropout_p or is_causal:
            raise ValueError('Only the pinned JoyTag inference attention is supported')
        factor = scale if scale is not None else query.shape[-1] ** -0.5
        return torch.softmax((query @ key.transpose(-2, -1)) * factor, dim=-1) @ value

    with patch('torch.nn.functional.scaled_dot_product_attention', attention):
        yield


def convert(cache, output):
    import coremltools as ct
    import numpy as np
    import torch

    output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(min(4, os.cpu_count() or 1))
    wrappers = load_wrappers(cache)
    exports = [('NudeNet320n', wrappers[0], 320, 'detections', [1, 22, 2100]),
               ('JoyTag', wrappers[1], 448, 'semenScore', [1, 1])]
    manifest = {'version': VERSION, 'sources': LOCK, 'models': {}}
    for name, wrapper, size, feature, shape in exports:
        example = torch.zeros(1, 3, size, size)
        with torch.inference_mode(), exportable_attention():
            traced = torch.jit.trace(wrapper, example, check_trace=False)
            actual = traced(example)
            if list(actual.shape) != shape:
                raise ValueError(f'Unexpected {name} output: {list(actual.shape)}')
        model = ct.convert(
            traced, convert_to='mlprogram', minimum_deployment_target=ct.target.iOS16,
            compute_precision=ct.precision.FLOAT16,
            inputs=[ct.ImageType(name='image', shape=example.shape,
                                 color_layout=ct.colorlayout.RGB, scale=1 / 255.0)],
            outputs=[ct.TensorType(name=feature, dtype=np.float32)],
        )
        model.version = VERSION
        model.short_description = f'{name}; local fp16 image content analysis for Orvian'
        model.license = 'AGPL-3.0' if name == 'NudeNet320n' else 'Apache-2.0'
        model.user_defined_metadata['orvian.pipelineVersion'] = VERSION
        if name == 'JoyTag':
            model.user_defined_metadata['orvian.tag'] = 'cum'
            model.user_defined_metadata['orvian.tagIndex'] = str(semen_tag_index(
                (cache / 'joytag/top_tags.txt').read_text(encoding='utf-8').splitlines()))
        else:
            model.user_defined_metadata['orvian.labels'] = json.dumps(NUDENET_LABELS)
        destination = output / f'{name}.mlpackage'
        model.save(str(destination))
        manifest['models'][name] = {
            'input_size': size, 'output': feature, 'shape': shape,
            'files': {p.relative_to(destination).as_posix(): sha256(p)
                      for p in sorted(destination.rglob('*')) if p.is_file()},
        }
        print(f'Exported {destination}', flush=True)
    (output / 'content-model-manifest.json').write_text(
        json.dumps(manifest, indent=2) + '\n', encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=ROOT / 'model-cache')
    parser.add_argument('--output', type=Path, default=ROOT / 'Orvian/Resources')
    parser.add_argument('--fetch-only', action='store_true')
    args = parser.parse_args()
    fetch_assets(args.cache)
    if not args.fetch_only:
        if platform.system() != 'Darwin':
            raise SystemExit('Core ML export requires macOS. Use --fetch-only on Windows.')
        convert(args.cache, args.output)


if __name__ == '__main__':
    main()
