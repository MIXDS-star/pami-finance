import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/errors/failure.dart';
import '../core/providers.dart';
import '../core/theme/theme.dart';

/// Renders loading / error / data for any AsyncValue consistently.
class AsyncView<T> extends StatelessWidget {
  const AsyncView({super.key, required this.value, required this.data, this.onRetry, this.loading, this.compact = false});

  final AsyncValue<T> value;
  final Widget Function(T data) data;
  final VoidCallback? onRetry;
  final Widget? loading;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return value.when(
      skipLoadingOnRefresh: true,
      skipLoadingOnReload: true,
      data: data,
      loading: () => loading ?? LoadingState(compact: compact),
      error: (e, _) => ErrorState(error: e, onRetry: onRetry, compact: compact),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key, this.compact = false, this.label = 'Cargando…'});
  final bool compact;
  final String label;

  @override
  Widget build(BuildContext context) {
    final indicator = Semantics(
      label: label,
      child: const SizedBox(width: 28, height: 28, child: CircularProgressIndicator(strokeWidth: 2.6)),
    );
    return compact
        ? Padding(padding: const EdgeInsets.all(24), child: Center(child: indicator))
        : Center(child: indicator);
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action, this.compact = false});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: 32, vertical: compact ? 24 : 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: context.pami.brandSoft, shape: BoxShape.circle),
            child: Icon(icon, size: 30, color: context.colors.primary),
          ),
          const SizedBox(height: 16),
          Text(title, style: context.text.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[
            const SizedBox(height: 6),
            Text(message!, style: context.text.bodyMedium?.copyWith(color: context.pami.muted), textAlign: TextAlign.center),
          ],
          if (action != null) ...[const SizedBox(height: 20), action!],
        ],
      ),
    );
    return compact ? content : Center(child: SingleChildScrollView(child: content));
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.error, this.onRetry, this.compact = false});
  final Object error;
  final VoidCallback? onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final f = AppFailure.from(error);
    final icon = switch (f.kind) {
      FailureKind.network => Icons.cloud_off_outlined,
      FailureKind.permission => Icons.lock_outline,
      FailureKind.auth => Icons.login,
      FailureKind.notConfigured => Icons.settings_suggest_outlined,
      _ => Icons.error_outline,
    };
    final title = switch (f.kind) {
      FailureKind.network => 'Sin conexión',
      FailureKind.permission => 'Sin permiso',
      FailureKind.auth => 'Sesión expirada',
      FailureKind.notConfigured => 'Configuración pendiente',
      FailureKind.notFound => 'No encontrado',
      _ => 'Algo salió mal',
    };
    return EmptyState(
      icon: icon,
      title: title,
      message: f.message,
      compact: compact,
      action: onRetry == null ? null : OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: const Text('Reintentar')),
    );
  }
}

/// Shown at the top of the shell while the device has no network.
class OfflineBanner extends ConsumerWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final online = ref.watch(connectivityProvider).value ?? true;
    return AnimatedSize(
      duration: PamiTokens.motion,
      child: online
          ? const SizedBox(width: double.infinity)
          : Semantics(
              liveRegion: true,
              child: Container(
                width: double.infinity,
                color: context.pami.warning.withValues(alpha: 0.16),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(children: [
                  Icon(Icons.cloud_off_outlined, size: 18, color: context.pami.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('Sin conexión. Puedes guardar borradores; nada se marca como sincronizado sin confirmación del servidor.',
                        style: context.text.bodySmall),
                  ),
                ]),
              ),
            ),
    );
  }
}

/// Inline notice with an icon (never color alone).
class Notice extends StatelessWidget {
  const Notice({super.key, required this.message, this.kind = NoticeKind.info, this.title, this.action});
  final String message;
  final String? title;
  final NoticeKind kind;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (kind) {
      NoticeKind.info => (context.pami.info, Icons.info_outline),
      NoticeKind.warning => (context.pami.warning, Icons.warning_amber_rounded),
      NoticeKind.error => (context.colors.error, Icons.error_outline),
      NoticeKind.success => (context.pami.positive, Icons.check_circle_outline),
    };
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(PamiTokens.radiusS),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (title != null) Text(title!, style: context.text.titleSmall),
              Text(message, style: context.text.bodyMedium),
              if (action != null) Padding(padding: const EdgeInsets.only(top: 4), child: action!),
            ]),
          ),
        ]),
      ),
    );
  }
}

enum NoticeKind { info, warning, error, success }

void showSuccess(BuildContext context, String message) => _snack(context, message, Icons.check_circle_outline);
void showFailure(BuildContext context, Object error) =>
    _snack(context, AppFailure.from(error).message, Icons.error_outline, error: true);

void _snack(BuildContext context, String message, IconData icon, {bool error = false}) {
  final m = ScaffoldMessenger.maybeOf(context);
  if (m == null) return;
  m
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Row(children: [Icon(icon, color: Colors.white, size: 20), const SizedBox(width: 10), Expanded(child: Text(message))]),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      duration: Duration(seconds: error ? 5 : 3),
    ));
}
