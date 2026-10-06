"""Verify package hashes everywhere; optionally compare native predictions on macOS."""
import argparse
import hashlib
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def verify_hashes():
    manifest = json.loads((Path(__file__).parent / 'model-manifest.json').read_text())
    package = ROOT / 'Orvian/Resources/NSFWClassifier.mlpackage'
    assert manifest['labels'] == ['NSFW', 'SFW']
    for relative, expected in manifest['files'].items():
        path = package / relative
        with path.open('rb') as stream:
            assert hashlib.file_digest(stream, 'sha256').hexdigest() == expected, relative
    assert (package / 'Data/com.apple.CoreML/weights/weight.bin').stat().st_size == 11205248
    print('Package hashes and genuine weight size verified')
    return package


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--reference', type=Path, help='Upstream logits package; requires native Core ML on macOS')
    args = parser.parse_args()
    package = verify_hashes()
    if args.reference:
        import coremltools as ct
        from PIL import Image
        model = ct.models.MLModel(str(package))
        reference = ct.models.MLModel(str(args.reference))
        images = [Image.new('RGB', (384, 384), color) for color in ['black', 'white', 'gray']]
        gradient = Image.new('RGB', (384, 384))
        gradient.putdata([(x * 255 // 383, y * 255 // 383, 127) for y in range(384) for x in range(384)])
        images.append(gradient)
        for image in images:
            actual = model.predict({'image': image})['classLabel_probs']
            logits = reference.predict({'image': image})['classLabel_probs']
            maximum = max(logits.values())
            exps = {k: math.exp(v - maximum) for k, v in logits.items()}
            expected = {k: v / sum(exps.values()) for k, v in exps.items()}
            assert abs(sum(actual.values()) - 1) < 0.001
            assert all(math.isfinite(v) and 0 <= v <= 1 for v in actual.values())
            assert max(abs(actual[k] - expected[k]) for k in expected) < 0.01
        print('Native predictions match softmax of unchanged reference logits (< 0.01)')


if __name__ == '__main__':
    main()
