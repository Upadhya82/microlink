"""Validate, resize and compress uploaded images.

Shared by every upload path (shop photos, product photos, verification
documents, road-report photos). Images arrive from phone cameras at 4-12MB;
stored raw they would blow up the database and make the app slow to load on
the rural connections this project is aimed at. Everything here is pure
bytes-in/bytes-out so it can be unit tested without FastAPI or a database.
"""

import io

from PIL import Image, UnidentifiedImageError

# Longest edge after resizing. 1600px still looks sharp full-screen on a
# phone and takes a ~5MB camera shot down to roughly 200-400KB.
MAX_EDGE_PX = 1600

# JPEG quality. 82 is the usual sweet spot: no visible artefacts on photos,
# about a third the size of quality 95.
JPEG_QUALITY = 82

# Refused before decoding. A decompression bomb is small on disk and huge in
# memory, so the pixel guard below matters as much as this one.
MAX_UPLOAD_BYTES = 8 * 1024 * 1024

# Pillow decodes to roughly 4 bytes per pixel; 50MP would be ~200MB of RAM.
MAX_PIXELS = 50_000_000

ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/jpg", "image/png", "image/webp"}

# Content types that say "some bytes" and nothing more. Browsers, curl and
# Dart's MultipartFile all send one of these when no type is given, so
# treating them as a rejection throws out perfectly good images -- which is
# exactly what used to happen to every photo the app uploaded.
GENERIC_CONTENT_TYPES = {"application/octet-stream", "binary/octet-stream"}


class ImageRejected(Exception):
    """The upload is not an image we can safely store. The message is shown
    to the user, so it says what to do rather than what went wrong."""


def _check_size(data: bytes) -> None:
    if not data:
        raise ImageRejected("That file is empty.")
    if len(data) > MAX_UPLOAD_BYTES:
        mb = MAX_UPLOAD_BYTES // (1024 * 1024)
        raise ImageRejected(f"That image is too large. Please use one under {mb}MB.")


def process_image(data: bytes, content_type: str | None = None) -> bytes:
    """Return a resized, compressed JPEG.

    Raises [ImageRejected] with a user-facing message for anything that is
    not a usable image. The content type is only a hint -- the real check is
    whether Pillow can decode it, because a client can claim anything.
    """
    _check_size(data)
    # Advisory only, as documented above: a concrete type we know we cannot
    # use earns a clearer message than Pillow would give, but anything vague
    # goes to Pillow, which is the one that actually knows.
    declared = (content_type or "").split(";")[0].strip().lower()
    if (
        declared
        and declared not in GENERIC_CONTENT_TYPES
        and declared not in ALLOWED_CONTENT_TYPES
    ):
        raise ImageRejected("Please upload a JPG, PNG or WebP image.")

    try:
        image = Image.open(io.BytesIO(data))
        # Cheap guard before the expensive decode: the header gives us the
        # dimensions without rendering the pixels.
        width, height = image.size
        if width * height > MAX_PIXELS:
            raise ImageRejected("That image has too many pixels. Please use a smaller one.")
        image.load()
    except ImageRejected:
        raise
    except UnidentifiedImageError:
        raise ImageRejected("That file does not look like an image.")
    except Exception:
        raise ImageRejected("We could not read that image. Please try another one.")

    # Honour the camera's rotation flag, then drop it -- otherwise portrait
    # photos appear sideways in the app.
    try:
        from PIL import ImageOps

        image = ImageOps.exif_transpose(image)
    except Exception:
        pass

    # JPEG has no alpha channel; flatten onto white so transparent PNG logos
    # do not come out with a black background.
    if image.mode in ("RGBA", "LA", "P"):
        image = image.convert("RGBA")
        background = Image.new("RGB", image.size, (255, 255, 255))
        background.paste(image, mask=image.split()[-1])
        image = background
    elif image.mode != "RGB":
        image = image.convert("RGB")

    # Only ever shrink. Upscaling a small photo adds bytes and no detail.
    if max(image.size) > MAX_EDGE_PX:
        image.thumbnail((MAX_EDGE_PX, MAX_EDGE_PX), Image.LANCZOS)

    out = io.BytesIO()
    image.save(out, format="JPEG", quality=JPEG_QUALITY, optimize=True, progressive=True)
    return out.getvalue()


def is_pdf(data: bytes) -> bool:
    """Magic-byte check. Verification documents are often scanned PDFs, and
    the filename extension is not evidence of anything."""
    return data[:5] == b"%PDF-"


def process_document(data: bytes, content_type: str | None = None) -> tuple[bytes, str]:
    """Process a verification document: an image is compressed like any
    other, a PDF is stored as-is.

    Returns ``(bytes, stored_content_type)``.
    """
    _check_size(data)
    if is_pdf(data):
        return data, "application/pdf"
    return process_image(data, content_type), "image/jpeg"
