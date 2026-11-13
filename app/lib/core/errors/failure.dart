/// Translates backend/network errors into messages that say what happened
/// and what the person can do. Raw errors are never shown or logged with
/// financial content.
library;

import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

enum FailureKind { network, auth, permission, validation, conflict, notFound, notConfigured, rateLimited, unknown }

class AppFailure implements Exception {
  const AppFailure(this.kind, this.message, {this.code, this.currentVersion});

  final FailureKind kind;
  final String message;
  final String? code;

  /// For version conflicts: the version currently stored on the server.
  final int? currentVersion;

  bool get retryable => kind == FailureKind.network || kind == FailureKind.rateLimited;

  @override
  String toString() => message;

  static AppFailure from(Object error) {
    if (error is AppFailure) return error;
    if (error is PostgrestException) return _fromPostgrest(error);
    if (error is FunctionException) return _fromFunction(error);
    if (error is AuthException) return _fromAuth(error);
    if (error is StorageException) return _fromStorage(error);
    if (error is TimeoutException || _looksOffline(error)) {
      return const AppFailure(FailureKind.network,
          'No hay conexión con el servidor. Revisa tu internet e inténtalo de nuevo; no se perdió nada.');
    }
    return const AppFailure(FailureKind.unknown, 'Ocurrió un error inesperado. Inténtalo de nuevo.');
  }

  static bool _looksOffline(Object e) {
    final s = '${e.runtimeType} $e';
    return s.contains('SocketException') || s.contains('ClientException') || s.contains('Failed host lookup') || s.contains('XMLHttpRequest error') ||
        s.contains('Connection refused') || s.contains('Failed to fetch');
  }

  static AppFailure _fromPostgrest(PostgrestException e) {
    final code = e.hint;
    if (e.code == 'PT409' || code == 'version_conflict') {
      return AppFailure(FailureKind.conflict,
          'Otra persona modificó este registro mientras lo editabas. Recarga para ver los cambios antes de guardar.',
          code: code, currentVersion: int.tryParse('${e.details ?? ''}'));
    }
    if (e.code == 'PT401' || e.code == 'PGRST301' || e.code == 'PGRST303') {
      return const AppFailure(FailureKind.auth, 'Tu sesión expiró. Inicia sesión de nuevo.');
    }
    if (e.code == 'PT403' || e.code == '42501') {
      return AppFailure(FailureKind.permission, messageFor(code) ?? 'No tienes permiso para hacer esto en este espacio.', code: code);
    }
    if (e.code == 'PT404') return const AppFailure(FailureKind.notFound, 'El registro ya no existe o no tienes acceso.');
    if (e.code == 'PT410') return AppFailure(FailureKind.validation, messageFor(code) ?? 'La invitación ya no es válida.', code: code);
    if (e.code == 'PT429') return AppFailure(FailureKind.rateLimited, messageFor(code) ?? 'Demasiadas solicitudes. Espera un momento.', code: code);
    if (e.code == 'PT422' || e.code == '23514' || e.code == '22P02') {
      return AppFailure(FailureKind.validation, messageFor(code) ?? 'Revisa los datos: hay un valor que no es válido.', code: code);
    }
    return const AppFailure(FailureKind.unknown, 'El servidor no pudo completar la operación. Inténtalo de nuevo.');
  }

  static AppFailure _fromFunction(FunctionException e) {
    final details = e.details;
    final code = details is Map ? (details['error'] is Map ? details['error']['code'] as String? : null) : null;
    switch (e.status) {
      case 401:
        return const AppFailure(FailureKind.auth, 'Tu sesión expiró. Inicia sesión de nuevo.');
      case 429:
        if (code == 'ai_rate_limited') {
          return const AppFailure(FailureKind.rateLimited,
              'Se alcanzó el límite de uso del servicio de IA. Espera un momento o registra el movimiento manualmente.',
              code: 'ai_rate_limited');
        }
        return const AppFailure(FailureKind.rateLimited, 'Has hecho muchas solicitudes seguidas. Espera un minuto.');
      case 503:
        if (code == 'ai_not_configured') {
          return const AppFailure(FailureKind.notConfigured,
              'Esta función de IA aún no está configurada en el servidor. Puedes registrar el movimiento manualmente.',
              code: 'ai_not_configured');
        }
    }
    return AppFailure(e.status >= 500 ? FailureKind.unknown : FailureKind.validation,
        messageFor(code) ?? 'El servicio no pudo procesar la solicitud.', code: code);
  }

  static AppFailure _fromAuth(AuthException e) {
    final m = e.message.toLowerCase();
    if (m.contains('invalid login') || m.contains('invalid_credentials')) {
      return const AppFailure(FailureKind.auth, 'Correo o contraseña incorrectos.');
    }
    if (m.contains('not confirmed')) {
      return const AppFailure(FailureKind.auth, 'Confirma tu correo antes de iniciar sesión. Revisa tu bandeja de entrada.',
          code: 'email_not_confirmed');
    }
    if (m.contains('already registered') || m.contains('already been registered')) {
      return const AppFailure(FailureKind.validation, 'Ya existe una cuenta con ese correo. Inicia sesión o recupera tu contraseña.');
    }
    if (m.contains('password')) {
      return const AppFailure(FailureKind.validation, 'La contraseña debe tener al menos 8 caracteres.');
    }
    if (m.contains('rate limit') || e.statusCode == '429') {
      return const AppFailure(FailureKind.rateLimited, 'Demasiados intentos. Espera unos minutos.');
    }
    if (m.contains('expired') || m.contains('refresh')) {
      return const AppFailure(FailureKind.auth, 'Tu sesión expiró. Inicia sesión de nuevo.');
    }
    return const AppFailure(FailureKind.auth, 'No fue posible autenticarte. Inténtalo de nuevo.');
  }

  static AppFailure _fromStorage(StorageException e) {
    switch (e.statusCode) {
      case '413':
        return const AppFailure(FailureKind.validation, 'El archivo supera el tamaño máximo de 10 MB.');
      case '415':
        return const AppFailure(FailureKind.validation, 'Formato no admitido. Usa JPG, PNG, WEBP o PDF.');
      case '403':
      case '401':
        return const AppFailure(FailureKind.permission, 'No tienes permiso para adjuntar archivos en este espacio.');
    }
    return const AppFailure(FailureKind.unknown, 'No se pudo subir o descargar el archivo.');
  }

  /// Stable server codes -> Spanish copy.
  static String? messageFor(String? code) => _messages[code];

  static const _messages = <String, String>{
    'amount_positive': 'El importe debe ser mayor que cero.',
    'amount_too_large': 'El importe es demasiado alto.',
    'description_required': 'Escribe un concepto.',
    'date_required': 'Indica la fecha.',
    'date_out_of_range': 'La fecha está fuera del rango permitido.',
    'payload_invalid': 'Algunos datos no tienen el formato correcto.',
    'currency_unknown': 'Moneda no admitida.',
    'category_invalid': 'La categoría no es válida para este espacio.',
    'category_kind_mismatch': 'Esa categoría no corresponde a este tipo de movimiento.',
    'payer_required': 'Indica quién pagó.',
    'payer_duplicated': 'Hay pagadores repetidos.',
    'participants_required': 'Indica entre quiénes se reparte.',
    'participant_duplicated': 'Hay personas repetidas en el reparto.',
    'participant_not_member': 'Una de las personas no pertenece a este espacio.',
    'participant_inactive': 'Una de las personas ya no es miembro activo del espacio.',
    'split_method_invalid': 'El método de reparto no es válido.',
    'ledger_payments_mismatch': 'Los pagos no suman el total del gasto.',
    'ledger_splits_mismatch': 'El reparto no suma el total del gasto.',
    'ledger_foreign_participant': 'Hay personas que no pertenecen al espacio.',
    'ledger_personal_foreign': 'Los gastos personales solo pueden ser tuyos.',
    'ledger_private_kind': 'Los ingresos y transferencias se registran en tu espacio personal.',
    'ledger_receipt_unreconciled': 'Las líneas de la factura no coinciden con el total pagado.',
    'ledger_item_allocation_mismatch': 'La asignación de una línea no suma su valor.',
    'ledger_item_allocation_orphan': 'Una línea está asignada a alguien que no participa en el gasto.',
    'receipt_line_invalid': 'Una línea de la factura no es válida.',
    'receipt_path_invalid': 'El archivo adjunto no pertenece a este espacio.',
    'account_invalid': 'La cuenta seleccionada no es válida.',
    'account_not_yours': 'Solo quien pagó puede elegir su cuenta.',
    'transfer_accounts_invalid': 'Elige dos cuentas tuyas distintas.',
    'transfer_currency_mismatch': 'Las cuentas deben tener la misma moneda que la transferencia.',
    'transaction_deleted': 'Este movimiento fue eliminado.',
    'forbidden_workspace': 'No tienes permiso para registrar movimientos en este espacio.',
    'forbidden_transaction': 'No tienes permiso sobre este movimiento.',
    'creator_or_admin_required': 'Solo quien lo creó o un administrador puede hacerlo.',
    'admin_required': 'Necesitas ser administrador del espacio.',
    'owner_required': 'Solo el propietario puede hacerlo.',
    'not_member': 'Esa persona no es miembro activo del espacio.',
    'cannot_change_own_role': 'No puedes cambiar tu propio rol.',
    'use_transfer_ownership': 'Para cambiar el propietario usa «Transferir propiedad».',
    'cannot_remove_owner': 'No se puede retirar al propietario.',
    'use_leave': 'Para salir tú, usa «Abandonar espacio».',
    'owner_must_transfer': 'Transfiere la propiedad a otro miembro antes de salir.',
    'workspace_personal_reserved': 'Tu espacio personal no se puede compartir ni abandonar.',
    'workspace_archived': 'El espacio está archivado.',
    'workspace_limit': 'Alcanzaste el máximo de espacios.',
    'invite_owner_role': 'La propiedad se transfiere, no se invita.',
    'invite_limit': 'Hay demasiadas invitaciones pendientes. Revoca alguna.',
    'invite_accepted': 'Esta invitación ya fue usada.',
    'invite_declined': 'Esta invitación fue rechazada.',
    'invite_revoked': 'Esta invitación fue revocada.',
    'invite_expired': 'Esta invitación expiró. Pide una nueva.',
    'invite_not_found': 'La invitación no existe.',
    'invite_email_mismatch': 'Esta invitación es para otro correo electrónico.',
    'settlement_parties_invalid': 'Elige dos personas distintas.',
    'settlement_party_required': 'Solo las partes o un administrador pueden registrar este reembolso.',
    'settlement_foreign_party': 'Ambas personas deben pertenecer al espacio.',
    'budget_income_personal_only': 'Los presupuestos basados en ingresos solo están disponibles en tu espacio personal.',
    'month_not_finished': 'El mes aún no ha terminado.',
    'report_exists': 'Este mes ya tiene un cierre. Puedes generar una versión actualizada.',
    'currency_locked': 'La moneda no se puede cambiar cuando ya hay movimientos.',
    'occurrence_needs_transaction': 'Para confirmar un pago previsto, vincúlalo a un movimiento real.',
    'auth_required': 'Inicia sesión para continuar.',
    'account_deleted': 'Esta cuenta fue eliminada.',
    'text_required': 'Escribe qué compraste.',
    'text_too_long': 'El texto es demasiado largo (máximo 1.000 caracteres).',
    'question_required': 'Escribe tu pregunta.',
    'ai_refused': 'El asistente no pudo procesar esta solicitud.',
    'ai_invalid_output': 'La IA devolvió una respuesta no válida. Revisa o registra manualmente.',
    'ai_truncated': 'La respuesta fue demasiado larga. Intenta con una pregunta más concreta.',
    'ai_provider_error': 'El proveedor de IA no está disponible ahora. Inténtalo más tarde.',
    'receipt_file_not_found': 'No se encontró el archivo de la factura.',
    'receipt_file_too_large': 'La factura supera 10 MB.',
    'receipt_file_type_invalid': 'El archivo no es una imagen o PDF válido.',
    'receipt_pdf_unsupported': 'El servicio de IA configurado no lee PDF. Toma una foto de la factura o escribe las líneas.',
    'receipt_heic_unsupported': 'El formato HEIC no es compatible: toma la foto en JPG.',
    'audio_type_invalid': 'Formato de audio no admitido.',
    'audio_too_large': 'La grabación es demasiado larga.',
    'audio_empty': 'La grabación está vacía.',
    'audio_no_speech': 'No se detectó voz en la grabación.',
    'confirmation_required': 'Escribe ELIMINAR para confirmar.',
  };
}
