import '../../core/errors/failure.dart';

/// Runs a backend call and normalises any error into an [AppFailure].
Future<T> guard<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (e) {
    throw AppFailure.from(e);
  }
}
