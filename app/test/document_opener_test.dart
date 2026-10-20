import 'package:flutter_test/flutter_test.dart';

import 'package:frontend/core/utils/document_opener.dart';

/// Item 9: the name a document is opened under. Android picks the app that
/// can open a file from its extension, so getting this wrong means a PDF
/// that simply will not open.
void main() {
  group('suggestedFileName from Content-Disposition', () {
    test('the header name is preferred over the stored one', () {
      expect(
        suggestedFileName(
          headerValue: 'inline; filename="police-report.pdf"',
          fallbackName: 'something-else.pdf',
          contentType: 'application/pdf',
        ),
        'police-report.pdf',
      );
    });

    test('the utf-8 form wins, so a Sinhala name survives', () {
      expect(
        suggestedFileName(
          headerValue:
              "inline; filename=\"document.pdf\"; filename*=UTF-8''%E0%B6%85%E0%B6%BA%E0%B6%AF%E0%B7%94%E0%B6%B8.pdf",
          contentType: 'application/pdf',
        ),
        'අයදුම.pdf',
      );
    });

    test('malformed percent-encoding falls back to the plain name', () {
      expect(
        suggestedFileName(
          headerValue: "inline; filename=\"licence.pdf\"; filename*=UTF-8''%E0%",
          contentType: 'application/pdf',
        ),
        'licence.pdf',
      );
    });

    test('an attachment header is read the same way', () {
      expect(
        suggestedFileName(
          headerValue: 'attachment; filename=id-card.jpg',
          contentType: 'image/jpeg',
        ),
        'id-card.jpg',
      );
    });

    test('no header falls back to the stored file name', () {
      expect(
        suggestedFileName(fallbackName: 'licence.pdf', contentType: 'application/pdf'),
        'licence.pdf',
      );
    });

    test('nothing at all still produces an openable name', () {
      expect(suggestedFileName(contentType: 'application/pdf'), 'document.pdf');
      expect(suggestedFileName(), 'document');
    });
  });

  group('the extension always matches what the server served', () {
    test('a name with the wrong extension is corrected', () {
      expect(
        suggestedFileName(fallbackName: 'scan.jpeg', contentType: 'application/pdf'),
        'scan.pdf',
      );
    });

    test('a name with no extension gains one', () {
      expect(
        suggestedFileName(fallbackName: 'police report', contentType: 'application/pdf'),
        'police report.pdf',
      );
    });

    test('a matching extension is left alone, whatever its case', () {
      expect(
        suggestedFileName(fallbackName: 'Licence.PDF', contentType: 'application/pdf'),
        'Licence.PDF',
      );
    });

    test('an unknown served type leaves the name as it is', () {
      expect(
        suggestedFileName(fallbackName: 'archive.zip', contentType: 'application/zip'),
        'archive.zip',
      );
    });

    test('a content type with a charset is still understood', () {
      expect(
        suggestedFileName(fallbackName: 'licence', contentType: 'application/pdf; charset=binary'),
        'licence.pdf',
      );
    });
  });

  group('a name from the server cannot escape the temp directory', () {
    test('a path is reduced to its last part', () {
      expect(
        suggestedFileName(
          headerValue: 'inline; filename="../../etc/passwd.pdf"',
          contentType: 'application/pdf',
        ),
        'passwd.pdf',
      );
    });

    test('a windows path is reduced too', () {
      expect(
        suggestedFileName(
          headerValue: r'inline; filename="C:\Windows\system32\evil.pdf"',
          contentType: 'application/pdf',
        ),
        'evil.pdf',
      );
    });

    test('characters a filesystem will not take are dropped', () {
      expect(
        suggestedFileName(
          headerValue: 'inline; filename="my:id*card?.pdf"',
          contentType: 'application/pdf',
        ),
        'myidcard.pdf',
      );
    });

    test('a name that is only dots falls back', () {
      expect(
        suggestedFileName(
          headerValue: 'inline; filename=".."',
          contentType: 'application/pdf',
        ),
        'document.pdf',
      );
    });
  });

  group('isPdfContentType', () {
    test('recognises a pdf', () {
      expect(isPdfContentType('application/pdf'), isTrue);
      expect(isPdfContentType('APPLICATION/PDF'), isTrue);
      expect(isPdfContentType('application/pdf; charset=binary'), isTrue);
    });

    test('anything else is not a pdf', () {
      expect(isPdfContentType('image/jpeg'), isFalse);
      expect(isPdfContentType(''), isFalse);
      expect(isPdfContentType(null), isFalse);
    });
  });
}
