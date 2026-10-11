"""Upload validation.

These need Pillow, which only the service containers have, so the module
skips itself when it is not installed rather than failing a local run:

    docker compose exec shop-service python -m unittest tests.test_images
"""

import io
import unittest

try:
    from PIL import Image

    from app import images

    HAVE_PILLOW = True
except ImportError:  # pragma: no cover - depends on where the suite runs
    HAVE_PILLOW = False


def png_bytes(size=(800, 600), mode="RGBA"):
    buffer = io.BytesIO()
    colour = (30, 60, 120, 255) if mode == "RGBA" else (30, 60, 120)
    Image.new(mode, size, colour).save(buffer, "PNG")
    return buffer.getvalue()


@unittest.skipUnless(HAVE_PILLOW, "Pillow is only installed in the service image")
class ProcessImageContentType(unittest.TestCase):
    """The declared content type is a hint, not the decision.

    Dart's MultipartFile, curl -F and plain FormData all label a file
    "application/octet-stream" unless told otherwise, so rejecting on that
    label rejected every photo the app sent.
    """

    def test_octet_stream_png_is_accepted(self):
        out = images.process_image(png_bytes(), "application/octet-stream")
        self.assertTrue(out.startswith(b"\xff\xd8"), "should come back as JPEG")

    def test_missing_content_type_is_accepted(self):
        self.assertTrue(images.process_image(png_bytes(), None))
        self.assertTrue(images.process_image(png_bytes(), ""))

    def test_content_type_with_parameters_is_accepted(self):
        self.assertTrue(images.process_image(png_bytes(), "image/png; charset=binary"))

    def test_uppercase_content_type_is_accepted(self):
        self.assertTrue(images.process_image(png_bytes(), "IMAGE/PNG"))

    def test_a_type_we_definitely_cannot_use_is_still_refused(self):
        with self.assertRaises(images.ImageRejected):
            images.process_image(png_bytes(), "application/msword")

    def test_bytes_that_are_not_an_image_are_refused_whatever_the_label_says(self):
        with self.assertRaises(images.ImageRejected):
            images.process_image(b"this is not a picture", "image/png")


@unittest.skipUnless(HAVE_PILLOW, "Pillow is only installed in the service image")
class ProcessImageOutput(unittest.TestCase):
    def test_transparency_is_flattened_rather_than_crashing(self):
        # JPEG has no alpha channel; saving RGBA straight to JPEG raises.
        self.assertTrue(images.process_image(png_bytes(mode="RGBA"), "image/png"))

    def test_large_images_are_shrunk_to_the_long_edge(self):
        out = images.process_image(png_bytes((4000, 3000)), "image/png")
        self.assertLessEqual(max(Image.open(io.BytesIO(out)).size), images.MAX_EDGE_PX)

    def test_small_images_are_not_upscaled(self):
        out = images.process_image(png_bytes((320, 240)), "image/png")
        self.assertEqual(Image.open(io.BytesIO(out)).size, (320, 240))

    def test_empty_upload_is_refused(self):
        with self.assertRaises(images.ImageRejected):
            images.process_image(b"", "image/png")

    def test_oversized_upload_is_refused_before_decoding(self):
        with self.assertRaises(images.ImageRejected):
            images.process_image(b"x" * (images.MAX_UPLOAD_BYTES + 1), "image/png")


@unittest.skipUnless(HAVE_PILLOW, "Pillow is only installed in the service image")
class ProcessDocument(unittest.TestCase):
    def test_a_pdf_is_stored_as_is(self):
        pdf = b"%PDF-1.4\n% a scanned police clearance\n"
        data, content_type = images.process_document(pdf, "application/octet-stream")
        self.assertEqual(data, pdf)
        self.assertEqual(content_type, "application/pdf")

    def test_a_pdf_is_detected_by_its_bytes_not_its_label(self):
        pdf = b"%PDF-1.4\n"
        _, content_type = images.process_document(pdf, "image/png")
        self.assertEqual(content_type, "application/pdf")

    def test_a_photographed_document_is_compressed_like_any_image(self):
        data, content_type = images.process_document(png_bytes(), "application/octet-stream")
        self.assertEqual(content_type, "image/jpeg")
        self.assertTrue(data.startswith(b"\xff\xd8"))


if __name__ == "__main__":
    unittest.main()
