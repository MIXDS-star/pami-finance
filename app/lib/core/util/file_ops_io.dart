import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readLocalFile(String path) => File(path).readAsBytes();

Future<void> deleteLocalFile(String path) async {
  try {
    await File(path).delete();
  } catch (_) {}
}
