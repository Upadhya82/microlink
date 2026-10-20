"""Item 9: how a verification document is named and handed over.

    cd services/user-service
    JWT_SECRET=<32+ chars> python -m pytest tests/test_downloads.py -q
"""

import unittest

from app.downloads import content_disposition, download_name, extension_for


class ExtensionTests(unittest.TestCase):
    def test_known_types(self):
        self.assertEqual(extension_for("application/pdf"), ".pdf")
        self.assertEqual(extension_for("image/jpeg"), ".jpg")
        self.assertEqual(extension_for("image/png"), ".png")

    def test_a_charset_parameter_is_ignored(self):
        self.assertEqual(extension_for("application/pdf; charset=binary"), ".pdf")

    def test_case_does_not_matter(self):
        self.assertEqual(extension_for("APPLICATION/PDF"), ".pdf")

    def test_an_unknown_or_missing_type_has_no_extension(self):
        self.assertEqual(extension_for("application/zip"), "")
        self.assertEqual(extension_for(None), "")
        self.assertEqual(extension_for(""), "")


class DownloadNameTests(unittest.TestCase):
    def test_a_pdf_keeps_its_name_and_gains_pdf(self):
        self.assertEqual(download_name("police-report", "application/pdf"), "police-report.pdf")

    def test_the_stored_type_wins_over_the_uploaded_name(self):
        # Uploaded as .jpeg but stored as a PDF: offering it as .jpeg would
        # make it fail to open for no good reason.
        self.assertEqual(download_name("scan.jpeg", "application/pdf"), "scan.pdf")

    def test_an_image_is_named_jpg(self):
        self.assertEqual(download_name("my id.png", "image/jpeg"), "my id.jpg")

    def test_a_missing_name_falls_back(self):
        self.assertEqual(download_name(None, "application/pdf"), "document.pdf")
        self.assertEqual(download_name("", "application/pdf"), "document.pdf")

    def test_a_directory_part_is_dropped(self):
        self.assertEqual(
            download_name("C:\\\\Users\\\\me\\\\licence.pdf", "application/pdf"), "licence.pdf"
        )
        self.assertEqual(download_name("/tmp/licence.pdf", "application/pdf"), "licence.pdf")

    def test_a_dotfile_keeps_its_whole_name(self):
        self.assertEqual(download_name(".hidden", "application/pdf"), ".hidden.pdf")

    def test_an_unknown_type_keeps_the_name_untouched(self):
        self.assertEqual(download_name("archive.zip", "application/zip"), "archive.zip")

    def test_a_name_that_is_only_a_path_falls_back(self):
        self.assertEqual(download_name("/", "application/pdf"), "document.pdf")


class ContentDispositionTests(unittest.TestCase):
    def test_a_pdf_is_shown_inline_with_its_name(self):
        self.assertEqual(
            content_disposition("licence.pdf", "application/pdf"),
            'inline; filename="licence.pdf"',
        )

    def test_attachment_is_available_too(self):
        self.assertEqual(
            content_disposition("licence.pdf", "application/pdf", inline=False),
            'attachment; filename="licence.pdf"',
        )

    def test_a_sinhala_name_also_gets_the_utf8_form(self):
        header = content_disposition("හැඳුනුම්පත.pdf", "application/pdf")
        self.assertTrue(header.startswith("inline; "))
        # The ASCII part must stay readable rather than become mojibake...
        self.assertIn('filename="document.pdf"', header)
        # ... and the real name travels in filename*.
        self.assertIn("filename*=UTF-8''", header)

    def test_the_utf8_form_round_trips(self):
        from urllib.parse import unquote

        header = content_disposition("හැඳුනුම්පත.pdf", "application/pdf")
        encoded = header.split("filename*=UTF-8''", 1)[1]
        self.assertEqual(unquote(encoded), "හැඳුනුම්පත.pdf")

    def test_a_quote_in_the_name_cannot_break_the_header(self):
        header = content_disposition('my "id" card.pdf', "application/pdf")
        self.assertEqual(header.count('"'), 2)
        self.assertNotIn('\\', header)

    def test_a_newline_in_the_name_cannot_split_the_header(self):
        header = content_disposition("id\r\nX-Evil: yes.pdf", "application/pdf")
        self.assertNotIn("\r", header)
        self.assertNotIn("\n", header)

    def test_an_ascii_only_name_sends_one_form_only(self):
        header = content_disposition("licence.pdf", "application/pdf")
        self.assertNotIn("filename*", header)


if __name__ == "__main__":
    unittest.main()
