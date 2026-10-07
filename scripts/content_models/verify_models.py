"""Verify references everywhere; verify mixed-precision Core ML numerics on macOS.

Synthetic fixtures test conversion fidelity, not real-world classification accuracy.
"""
import argparse
import json
from pathlib import Path
import platform

import numpy as np
from PIL import Image

from convert_models import ROOT, VERSION, fetch_assets, load_wrappers, exportable_attention
from reference import image_tensor, prepare_image, sha256


def fixtures():
    yield Image.new('RGB', (240, 480), (255, 0, 0))
    yield Image.new('RGB', (480, 240), (128, 128, 128))
    x, y = np.meshgrid(np.arange(448), np.arange(448))
    yield Image.fromarray(np.stack((x % 256, y % 256, (x + y) % 256), axis=-1).astype('uint8'))
    yield Image.fromarray(np.random.default_rng(123).integers(0, 256, (320, 640, 3), dtype='uint8'))


def check_array(actual, shape, probabilities=False):
    if list(actual.shape) != shape or not np.isfinite(actual).all():
        finite = bool(np.isfinite(actual).all())
        detail = {'shape': list(actual.shape), 'expected': shape, 'dtype': str(actual.dtype),
                  'finite': finite}
        try:
            detail['min'] = float(np.nanmin(actual))
            detail['max'] = float(np.nanmax(actual))
        except Exception:
            pass
        raise ValueError(f'Invalid inference output {actual.shape}; expected {shape}; detail={detail}')
    values = actual if probabilities else actual[:, 4:, :]
    if ((values < 0) | (values > 1)).any():
        raise ValueError('Scores must be probabilities in [0,1]')


def check_package(output, name, size, feature, shape, manifest):
    import coremltools as ct
    from coremltools.proto import FeatureTypes_pb2, MIL_pb2
    package = output / f'{name}.mlpackage'
    model = ct.models.MLModel(str(package), skip_model_load=platform.system() != 'Darwin')
    spec = model.get_spec()
    if spec.description.metadata.userDefined.get('orvian.pipelineVersion') != VERSION:
        raise ValueError('Core ML pipeline version mismatch')
    if name == 'JoyTag' and spec.description.metadata.userDefined.get('orvian.tag') != 'cum':
        raise ValueError('JoyTag output must be the exact cum tag')
    input_feature, = spec.description.input
    output_feature, = spec.description.output
    if (input_feature.name, input_feature.type.imageType.width, input_feature.type.imageType.height) != ('image', size, size):
        raise ValueError('Unexpected Core ML image input')
    if output_feature.name != feature or list(output_feature.type.multiArrayType.shape) != shape:
        raise ValueError('Unexpected Core ML output shape or name')
    if output_feature.type.multiArrayType.dataType != FeatureTypes_pb2.ArrayFeatureType.FLOAT32:
        raise ValueError('Runtime expects Float32 outputs')
    constants = [op for function in spec.mlProgram.functions.values()
                 for block in function.block_specializations.values()
                 for op in block.operations if op.type == 'const']
    has_fp16 = any(op.outputs[0].type.tensorType.dataType == MIL_pb2.FLOAT16
               and op.attributes['val'].HasField('blobFileValue') for op in constants)
    if name == 'NudeNet320n' and not has_fp16:
        raise ValueError('No fp16 weight blobs found in package')
    if name == 'JoyTag' and has_fp16:
        raise ValueError('JoyTag must stay float32; fp16 produces NaN')
    expected_files = manifest['models'][name]['files']
    actual_files = {p.relative_to(package).as_posix(): sha256(p)
                    for p in package.rglob('*') if p.is_file()}
    if actual_files != expected_files:
        raise ValueError(f'{name} exported package checksum mismatch')
    return model


def verify(cache, output, reference_only=False, check_conversion=False):
    import os
    import torch
    import onnxruntime as ort
    torch.set_num_threads(min(4, os.cpu_count() or 1))
    fetch_assets(cache)
    wrappers = load_wrappers(cache)
    options = ort.SessionOptions()
    options.intra_op_num_threads = 4
    session = ort.InferenceSession(str(cache / 'nudenet/320n.onnx'), sess_options=options,
                                  providers=['CPUExecutionProvider'])
    models = [('NudeNet320n', 'nudenet', 320, 'detections', [1, 22, 2100]),
              ('JoyTag', 'joytag', 448, 'semenScore', [1, 1])]
    if not reference_only and platform.system() != 'Darwin':
        raise SystemExit('Native Core ML verification requires macOS; use --reference-only here.')
    manifest = None if reference_only else json.loads((output / 'content-model-manifest.json').read_text())
    if manifest is not None and manifest['version'] != VERSION:
        raise ValueError('Model manifest version mismatch')
    for wrapper, (name, kind, size, feature, shape) in zip(wrappers, models):
        print(f'Checking {name} reference and trace', flush=True)
        with torch.inference_mode(), exportable_attention():
            trace = torch.jit.trace(wrapper, torch.zeros(1, 3, size, size), check_trace=False)
        compiled = None if reference_only else check_package(output, name, size, feature, shape, manifest)
        for fixture_index, image in enumerate(fixtures()):
            padded = prepare_image(image, kind)
            tensor = torch.from_numpy(image_tensor(padded))
            with torch.inference_mode():
                native = wrapper(tensor).numpy()
                exported = trace(tensor).numpy()
            check_array(native, shape, probabilities=kind == 'joytag')
            np.testing.assert_allclose(exported, native, rtol=1e-4, atol=1e-4,
                                       err_msg=f'{name} tracing changed reference inference')
            if kind == 'nudenet':
                original = session.run(None, {session.get_inputs()[0].name: tensor.numpy()})[0]
                check_array(original, shape)
                np.testing.assert_allclose(native[:, :4], original[:, :4], rtol=1e-4, atol=0.02)
                np.testing.assert_allclose(native[:, 4:], original[:, 4:], rtol=1e-3, atol=1e-5)
            if compiled is not None:
                raw = compiled.predict({'image': padded})[feature]
                actual = np.asarray(raw)
                if kind == 'joytag':
                    print(json.dumps({'model': name, 'fixture': fixture_index,
                        'actual_shape': list(actual.shape), 'actual_dtype': str(actual.dtype),
                        'finite': bool(np.isfinite(actual).all()),
                        'native': float(native.reshape(-1)[0])}), flush=True)
                check_array(actual, shape, probabilities=kind == 'joytag')
                if kind == 'nudenet':
                    max_coord_error = float(np.abs(actual[:, :4] - native[:, :4]).max())
                    max_score_error = float(np.abs(actual[:, 4:] - native[:, 4:]).max())
                    active_count = int((native[:, 4:].max(axis=1) > 0.25).sum())
                    print(json.dumps({'model': name, 'fixture': fixture_index,
                        'max_coordinate_error': max_coord_error,
                        'max_score_error': max_score_error,
                        'active_candidates': active_count}), flush=True)
                    if not np.allclose(actual[:, :4], native[:, :4], rtol=0.01, atol=1.0):
                        import coremltools as ct
                        cpu_model = ct.models.MLModel(str(output / f'{name}.mlpackage'),
                            compute_units=ct.ComputeUnit.CPU_ONLY)
                        cpu_result = np.asarray(cpu_model.predict({'image': padded})[feature])
                        print(json.dumps({'diagnostic': 'same package on CPU',
                            'max_coordinate_error': float(np.abs(cpu_result[:, :4] - native[:, :4]).max()),
                            'max_score_error': float(np.abs(cpu_result[:, 4:] - native[:, 4:]).max()),
                            'coordinate_parity': bool(np.allclose(cpu_result[:, :4], native[:, :4], rtol=0.01, atol=1.0))}), flush=True)
                    # App discards boxes with score <= 0.25 before using coordinates
                    # (NudeNetPostprocessor.scores + 0.25/0.45 NMS). fp16 box-regression
                    # noise on background boxes is expected; enforce strict parity
                    # only where coordinates affect classification.
                    active = native[:, 4:, :].max(axis=1) > 0.25
                    active_idx = np.where(active[0])[0]
                    if active_idx.size > 0:
                        np.testing.assert_allclose(actual[0, :4, active_idx], native[0, :4, active_idx],
                            rtol=0.01, atol=1.0,
                            err_msg=f'{name} active-box coordinates changed beyond fp16 tolerance')
                    np.testing.assert_allclose(actual[:, :4], native[:, :4], rtol=0.01, atol=10.0,
                        err_msg=f'{name} background-box coordinates diverged unexpectedly')
                    np.testing.assert_allclose(actual[:, 4:], native[:, 4:], rtol=0.01, atol=0.01)
                else:
                    np.testing.assert_allclose(actual, native, rtol=0.01, atol=0.01)
        if check_conversion:
            import coremltools as ct
            if platform.system() == 'Windows':
                # NumPy 1.x exposes C-int as a distinct scalar class on Windows.
                # coremltools 8.3 maps np.int32 but omits this equal-width alias.
                from coremltools.converters.mil.mil.types import type_mapping
                assert np.dtype(np.intc).itemsize == 4
                type_mapping._NPTYPES_TO_STRINGS.setdefault(np.dtype(np.intc), 'int32')
            # Exercise the entire lowering on Windows too, without requiring
            # the macOS Core ML execution or weight-blob libraries.
            expected_precision = ct.precision.FLOAT16 if name == 'NudeNet320n' else ct.precision.FLOAT32
            ct.convert(trace, convert_to='milinternal', minimum_deployment_target=ct.target.iOS16,
                       compute_precision=expected_precision,
                       inputs=[ct.ImageType(name='image', shape=(1, 3, size, size),
                           color_layout=ct.colorlayout.RGB, scale=1 / 255.0)],
                       outputs=[ct.TensorType(name=feature, dtype=np.float32)])
        print(f'{name}: reference checks passed' + ('' if reference_only else '; Core ML parity passed'), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, default=ROOT / 'model-cache')
    parser.add_argument('--output', type=Path, default=ROOT / 'Orvian/Resources')
    parser.add_argument('--reference-only', action='store_true')
    parser.add_argument('--check-conversion', action='store_true')
    args = parser.parse_args()
    verify(args.cache, args.output, args.reference_only, args.check_conversion)
