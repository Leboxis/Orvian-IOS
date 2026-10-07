"""Reference preprocessing and pinned-asset handling; no inference dependencies."""
from pathlib import Path
import hashlib
import importlib.util
import tempfile
import unittest

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('content_reference', ROOT / 'scripts/content_models/reference.py')
reference = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reference)


class ContentModelPreparationTests(unittest.TestCase):
    def test_joytag_centers_landscape_image_on_white_square(self):
        image = Image.new('RGB', (20, 10), (255, 0, 0))
        result = reference.prepare_image(image, 'joytag')
        self.assertEqual(result.size, (448, 448))
        self.assertEqual(result.getpixel((224, 0)), (255, 255, 255))
        self.assertEqual(result.getpixel((224, 224)), (255, 0, 0))
        self.assertEqual(result.getpixel((224, 447)), (255, 255, 255))

    def test_nudenet_pads_bottom_and_right_without_center_crop(self):
        for size, background, content in [((20, 10), (160, 300), (160, 80)),
                                          ((10, 20), (300, 160), (80, 160))]:
            result = reference.prepare_image(Image.new('RGB', size, (255, 0, 0)), 'nudenet')
            self.assertEqual(result.size, (320, 320))
            self.assertEqual(result.getpixel(background), (0, 0, 0))
            self.assertEqual(result.getpixel(content), (255, 0, 0))

    def test_orientation_is_applied_before_padding(self):
        image = Image.new('RGB', (20, 10), (255, 0, 0))
        image.getexif()[274] = 6
        result = reference.prepare_image(image, 'nudenet')
        self.assertEqual(result.getpixel((300, 160)), (0, 0, 0))
        self.assertEqual(result.getpixel((80, 160)), (255, 0, 0))

    def test_joytag_odd_padding_is_rounded_in_source_space(self):
        result = reference.prepare_image(Image.new('RGB', (20, 19), (255, 0, 0)), 'joytag')
        self.assertEqual(result.getpixel((224, 0)), (255, 0, 0))
        self.assertEqual(result.getpixel((224, 447)), (255, 255, 255))

    def test_reference_tensor_is_rgb_and_scaled_once(self):
        tensor = reference.image_tensor(Image.new('RGB', (320, 320), (255, 128, 0)))
        self.assertEqual(tensor.shape, (1, 3, 320, 320))
        np.testing.assert_allclose(tensor[0, :, 0, 0], [1, 128 / 255, 0])

    def test_semen_tag_uses_exact_cum_index_and_missing_tag_fails(self):
        self.assertEqual(reference.semen_tag_index(['feet', 'nude', 'cum', 'cum_on_body']), 2)
        with self.assertRaises(ValueError):
            reference.semen_tag_index(['feet', 'nude', 'cum_on_body'])
        with self.assertRaises(ValueError):
            reference.semen_tag_index(['cum', 'cum'])

    def test_cached_download_is_rejected_when_checksum_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'weight.pt'
            path.write_bytes(b'original weights')
            digest = hashlib.sha256(b'original weights').hexdigest()
            self.assertEqual(reference.download_verified('https://unused.invalid', path, digest), path)
            path.write_bytes(b'corrupt weights')
            with self.assertRaises(ValueError):
                reference.download_verified('https://unused.invalid', path, digest)


if __name__ == '__main__':
    unittest.main()
