# Models used for local content analysis

NudeNet 320n v3.4 detects exposed intimate body parts and bare feet.
Upstream: https://github.com/notAI-tech/NudeNet
Weights release: https://github.com/notAI-tech/NudeNet/releases/tag/v3.4-weights
License: GNU Affero General Public License v3.0, reproduced in NUDENET-LICENSE.txt.
The conversion uses Ultralytics (AGPL-3.0): https://github.com/ultralytics/ultralytics.

JoyTag uses a Vision Transformer trained for Danbooru-style image tagging.
Only the sigmoid score of the exact `cum` tag is exposed by this export.
Upstream: https://github.com/fpgaminer/joytag
Weights: https://huggingface.co/fancyfeast/joytag
Weights revision: 6b7f16331a6ccf0fdce37d5a9564715f6e772b22
Source revision: ce0c4a451e31b69a92df24c8bcd1c0418e3e4feb
License: Apache License 2.0, reproduced in JOYTAG-LICENSE.txt.

NudeNet uses fp16 internal weights and JoyTag uses fp32 (fp16 produces NaN);
both return Float32 scores or detections.
Source hashes and input/output contracts: scripts/content_models/assets.json.
Reproducible conversion and reference verification: scripts/content_models/.
The generated content-model-manifest.json contains exported package hashes.
The original Marqo package is retained in the repository for regression tests
and excluded from the app build. Its existing notice remains alongside it.

Numerical parity tests use synthetic images; they do not measure recognition
accuracy. Neither model is a guarantee of content, and JoyTag's training domain
can differ from photographs. Both inferences and cached scores stay on device.
