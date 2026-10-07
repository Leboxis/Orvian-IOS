"""Small, dependency-light contracts shared by export and native verification."""
import hashlib
from pathlib import Path
import urllib.request

import numpy as np
from PIL import Image, ImageOps


def sha256(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def download_verified(url, path, digest):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        temporary = path.with_suffix(path.suffix + '.download')
        try:
            with urllib.request.urlopen(url, timeout=120) as source, temporary.open('wb') as target:
                while block := source.read(1024 * 1024):
                    target.write(block)
            if sha256(temporary) != digest:
                raise ValueError(f'Checksum mismatch: {path.name}')
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    if sha256(path) != digest:
        raise ValueError(f'Checksum mismatch: {path.name}; remove the corrupt cached file and retry')
    return path


def prepare_image(image, model):
    image = ImageOps.exif_transpose(image).convert('RGB')
    width, height = image.size
    size = max(width, height)
    if model == 'joytag':
        canvas = Image.new('RGB', (size, size), (255, 255, 255))
        canvas.paste(image, ((size - width) // 2, (size - height) // 2))
        return canvas.resize((448, 448), Image.Resampling.BICUBIC)
    if model == 'nudenet':
        canvas = Image.new('RGB', (size, size), (0, 0, 0))
        canvas.paste(image, (0, 0))
        return canvas.resize((320, 320), Image.Resampling.BILINEAR)
    raise ValueError(f'Unknown model: {model}')


def image_tensor(image):
    return np.asarray(image, dtype=np.float32).transpose(2, 0, 1)[None] / 255.0


def semen_tag_index(tags):
    if tags.count('cum') != 1:
        raise ValueError('JoyTag must contain exactly one cum tag')
    return tags.index('cum')
