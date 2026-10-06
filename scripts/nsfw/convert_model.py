"""Prepare the pinned Marqo Core ML export with a probability output.

The upstream FP16 backbone is unchanged. Insert an explicit FP32 softmax
before its MIL classify operation. Only protobuf tooling is needed to
prepare the package; native Core ML execution is verified on macOS.
"""
import argparse
import hashlib
import importlib
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import types
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
REVISION = 'c8ff10d90d80e3d4f65d75b9a745a529c2defb78'
WEIGHTS_SHA256 = '25f0a6ee9ddd1c5756a87f3fc61e5c0ae40e3803a36b890369a47b372079ce2d'
MODEL_VERSION = 'marqo-384-fp16-softmax-v1'
PACKAGE_PATH = 'NSFWScanner/Resources/NSFWClassifier.mlpackage'
MODEL_PATH = Path('Data/com.apple.CoreML/model.mlmodel')
WEIGHTS_PATH = Path('Data/com.apple.CoreML/weights/weight.bin')


def model_types():
    # Load Apple's official descriptors without importing native libraries.
    # This permits package preparation / structural tests on Windows too.
    spec = importlib.util.find_spec('coremltools')
    if spec is None:
        raise RuntimeError('Install scripts/nsfw/requirements.txt first')
    if 'orvian_coreml_proto' not in sys.modules:
        package = types.ModuleType('orvian_coreml_proto')
        package.__path__ = [str(Path(next(iter(spec.submodule_search_locations))) / 'proto')]
        sys.modules[package.__name__] = package
    return (importlib.import_module('orvian_coreml_proto.Model_pb2'),
            importlib.import_module('orvian_coreml_proto.MIL_pb2'))


def add_softmax(model):
    _, MIL = model_types()
    blocks = [b for f in model.mlProgram.functions.values() for b in f.block_specializations.values()]
    if len(blocks) != 1:
        raise ValueError('Expected one fixed-shape MIL block')
    block = blocks[0]
    classifiers = [(i, op) for i, op in enumerate(block.operations) if op.type == 'classify']
    if len(classifiers) != 1:
        raise ValueError('Expected the pinned logits classifier, without softmax')
    index, classifier = classifiers[0]
    logits_name = classifier.inputs['probabilities'].arguments[0].name
    if any(op.type == 'softmax' and any(o.name == logits_name for o in op.outputs)
           for op in block.operations[:index]):
        raise ValueError('Classifier is already normalized')
    logits_type = next((output.type for op in block.operations[:index]
                        for output in op.outputs if output.name == logits_name), None)
    if logits_type is None or logits_type.tensorType.dataType != MIL.FLOAT32:
        raise ValueError('Classifier logits must have a known FP32 tensor type')
    operation = MIL.Operation(type='softmax')
    operation.inputs['x'].arguments.add(name=logits_name)
    axis = operation.inputs['axis'].arguments.add().value
    axis.type.tensorType.dataType = MIL.INT32
    axis.immediateValue.tensor.ints.values.append(-1)
    output = operation.outputs.add(name='orvian_class_probabilities')
    output.type.CopyFrom(logits_type)
    operation.attributes['name'].type.tensorType.dataType = MIL.STRING
    operation.attributes['name'].immediateValue.tensor.strings.values.append('orvian_softmax')
    classifier.inputs['probabilities'].arguments[0].name = output.name
    block.operations.insert(index, operation)
    model.description.metadata.versionString = MODEL_VERSION
    model.description.metadata.shortDescription = 'Marqo SFW / NSFW classifier; FP16 backbone with normalized probabilities.'
    model.description.metadata.license = 'Apache-2.0 (Marqo weights); MIT (NSFWScanner conversion)'
    return model


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def fetch_upstream(directory):
    raw = f'https://raw.githubusercontent.com/zorrobyte/NSFWScanner/{REVISION}/{PACKAGE_PATH}'
    media = f'https://media.githubusercontent.com/media/zorrobyte/NSFWScanner/{REVISION}/{PACKAGE_PATH}'
    for relative in [Path('Manifest.json'), MODEL_PATH, WEIGHTS_PATH]:
        destination = directory / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if not destination.exists():
            base = media if relative == WEIGHTS_PATH else raw
            urllib.request.urlretrieve(f'{base}/{relative.as_posix()}', destination)
    if sha256(directory / WEIGHTS_PATH) != WEIGHTS_SHA256:
        raise ValueError('Upstream weights checksum mismatch (or a Git LFS pointer was downloaded)')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, default=ROOT / '.superpowers/sdd/2026-10-06-folder-image-classification/upstream/NSFWClassifier.mlpackage')
    parser.add_argument('--output', type=Path, default=ROOT / 'Orvian/Resources/NSFWClassifier.mlpackage')
    parser.add_argument('--fetch-only', action='store_true', help='Download checksum-verified reference without changing the bundled model')
    args = parser.parse_args()
    fetch_upstream(args.upstream)
    if args.fetch_only:
        print(f'Verified reference downloaded to {args.upstream}')
        return
    Model, _ = model_types()
    model = Model.Model()
    model.ParseFromString((args.upstream / MODEL_PATH).read_bytes())
    raw_model_sha = sha256(args.upstream / MODEL_PATH)
    add_softmax(model)
    shutil.copytree(args.upstream, args.output, dirs_exist_ok=True)
    (args.output / MODEL_PATH).write_bytes(model.SerializeToString(deterministic=True))
    manifest = {
        'version': MODEL_VERSION,
        'upstream_repository': 'https://github.com/zorrobyte/NSFWScanner',
        'upstream_revision': REVISION,
        'upstream_model_sha256': raw_model_sha,
        'model': 'https://huggingface.co/Marqo/nsfw-image-detection-384',
        'labels': ['NSFW', 'SFW'], 'input': [384, 384, 'RGB'],
        'preprocessing': {'scale': 1 / 127.5, 'bias': [-1, -1, -1], 'vision_crop': 'centerCrop'},
        'modification': 'FP32 softmax on logits before classify; backbone and weights unchanged',
        'files': {p.relative_to(args.output).as_posix(): sha256(p)
                  for p in sorted(args.output.rglob('*')) if p.is_file()},
    }
    (Path(__file__).parent / 'model-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print(f'Prepared {args.output}: genuine weights verified, softmax inserted')


if __name__ == '__main__':
    main()
