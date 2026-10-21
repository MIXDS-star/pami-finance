// Local file helpers with a web-safe fallback (no dart:io on the web).
export 'file_ops_stub.dart' if (dart.library.io) 'file_ops_io.dart';
