import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Random v4 id (client request ids, storage folders).
String newId() => _uuid.v4();

/// Deterministic v5 id: the same input always yields the same id. Used for
/// imports so re-importing the same file never duplicates movements.
String stableId(String input) => _uuid.v5(Namespace.url.value, 'pami-import:$input');
