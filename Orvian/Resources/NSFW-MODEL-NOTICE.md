# NSFW model attribution

Marqo/nsfw-image-detection-384, by Marqo, is licensed under Apache License 2.0.
Model: https://huggingface.co/Marqo/nsfw-image-detection-384
License: https://www.apache.org/licenses/LICENSE-2.0

The embedded FP16 Core ML backbone comes from zorrobyte/NSFWScanner,
commit c8ff10d90d80e3d4f65d75b9a745a529c2defb78, whose conversion is MIT licensed.
The included NSFWScanner-LICENSE.txt reproduces that license.

Orvian adds an explicit FP32 softmax to the model's logits before the classifier
output. Backbone weights, RGB normalization and class ordering are unchanged.
Exact input / output checksums and preprocessing are in scripts/nsfw/model-manifest.json.

Classification is probabilistic and depends on image content and the chosen
threshold. Published accuracy on the author's dataset is not a guarantee
for kDrive thumbnails. GIF thumbnails represent only a still image.
