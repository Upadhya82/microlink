import 'dart:io';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import '../network/api_exception.dart';

/// Phone and desktop: write the document to a temporary file and ask the
/// system to open it with whatever handles that type.
///
/// A temporary directory rather than Downloads: these are identity
/// documents, and the app should not leave copies of someone's ID lying in
/// a folder that other apps and the gallery scan. The file is overwritten
/// each time and the OS clears the directory on its own.
Future<void> openBytes(
  Uint8List bytes, {
  required String fileName,
  String? contentType,
}) async {
  final File file;
  try {
    final directory = await getTemporaryDirectory();
    file = File('${directory.path}${Platform.pathSeparator}$fileName');
    await file.writeAsBytes(bytes, flush: true);
  } catch (_) {
    throw const ApiException('Could not save the document to open it.');
  }

  final result = await OpenFilex.open(file.path, type: contentType);
  if (result.type == ResultType.done) return;

  throw ApiException(
    switch (result.type) {
      ResultType.noAppToOpen =>
        'No app on this device can open this file. Install a PDF reader and try again.',
      ResultType.permissionDenied =>
        'Permission to open files was refused.',
      ResultType.fileNotFound => 'Could not save the document to open it.',
      _ => 'Could not open the document.',
    },
  );
}
