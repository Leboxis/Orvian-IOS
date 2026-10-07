# NudeNet 320n + JoyTag Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Classify folder images locally into explicit content, feet or neither.
**Architecture:** Replace the bundled Marqo inference with sequential NudeNet and JoyTag Core ML inference. Extend cached records with independent content scores and preserve the scan lifecycle.
**Tech Stack:** Swift, SwiftUI, Vision, Core ML, PyTorch, Python 3.12, macOS CI.
**Spec:** `docs/superpowers/specs/2026-10-07-nudenet-joytag-design.md`

## Global Constraints

- Local inference only; iOS 26.0+, Swift 5.
- NudeNet 320n v3.4; JoyTag weights revision `6b7f16331a6ccf0fdce37d5a9564715f6e772b22`.
- Three finite scores in [0,1]; explicit content takes priority; failures remain unscanned.
- Default threshold 0.50, range 0.30...0.99; model-version invalidation.
- Push to main and monitor GitHub Actions authorized by the user's follow-up.

## Review Focus

- Legacy one-score caches must not silently become three-category results.
- Padding must preserve edge content, orientation and background color.
- JoyTag scores must use sigmoid and the verified `cum` tag index.
- NudeNet outputs must retain official class ordering, argmax and NMS.
- Missing models or either inference failing must never yield « Aucun ».

### Task 1: Reproducible model preparation

Files: `scripts/content_models/`, `Tests/test_content_models.py`.
Interfaces: checksum-verified downloads; deterministic reference preprocessing;
`convert_models.py` produces `NudeNet320n.mlpackage`, `JoyTag.mlpackage` and a manifest.

- [x] Add failing behavioral tests for padding, tag selection and checksum rejection; run them.
- [x] Implement pinned downloads, reference preprocessing and fp16 exports.
- [ ] Verify exports natively against reference inference on synthetic fixtures.

### Task 2: Inference, policy and persistence

Files: `Orvian/Core/Classification/`, `Tests/ImageClassificationChecks.swift`, `Tests/iOS/`.
Interfaces: `ImageContentScores(nudity:semen:feet:)`; `classify(imageData:) async throws -> ImageContentScores`;
store reads/records full scores; snapshot classifies through threshold.

- [x] Add policy, NMS, cache migration, scanner and preprocessing tests.
- [x] Implement preprocessing and both inferences, preserving cancellation.
- [ ] Run portable checks and hosted iOS tests where available.

### Task 3: Filters, CI and notices

Files: `FileFilters.swift`, `FolderScanSheet.swift`, `.github/workflows/build.yml`, README and model notices.
Interfaces: three categories plus unscanned; CI exports once and shares packages with IPA build.

- [x] Update category labels/counts and the threshold UI.
- [x] Wire model export/parity tests to CI and require packages for hosted tests and IPA.
- [x] Run the existing Python regression suite and review the whole change.
- [x] Report native checks and device measurements still outstanding, without claiming they passed.

## Validation record and review decisions

- Windows: 39 Python tests passed; the initial six preparation tests failed
  before the reference module was implemented, then passed.
- SHA-256 verification passed for all seven pinned source assets.
- Both native PyTorch wrappers match their traces on four synthetic images;
  NudeNet also matches the pinned official ONNX numerics.
- Both fp16 MIL conversion pipelines passed. Windows verification normalizes
  NumPy's C-int dtype alias for coremltools 8.3; macOS export is unchanged.
- Standalone NudeNet fp16 checkpoint and JoyTag fp16 safetensors were prepared
  under `model-cache/fp16/`; saved JoyTag tensors were reloaded and compared.
- Independent review found two P2 issues, both fixed: threshold below NudeNet's
  candidate floor (range raised to 0.30...0.99) and JoyTag padding offsets for
  odd dimensions (integer source-space offsets). New tests cover odd geometry.
- Core ML package export, native numerical parity, Swift compilation and iOS
  hosted tests remain unexecuted locally: Windows has no Xcode/Core ML runtime.
  The macOS CI gates packaging on these checks; no CI run was triggered here.
- Accuracy, memory use and latency on an iPhone remain unmeasured.
- The user subsequently authorized pushing to main and monitoring GitHub Actions;
  the existing workflow publishes the IPA only after all validation jobs pass.
