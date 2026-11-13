import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/errors/failure.dart';
import '../../core/providers.dart';
import '../../core/router/router.dart';
import '../../core/theme/theme.dart';
import '../../ui/sheets.dart';
import '../../ui/states.dart';

final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

String? validateEmail(String? v) => v == null || !_emailRe.hasMatch(v.trim()) ? 'Escribe un correo válido' : null;
String? validatePassword(String? v) => v == null || v.length < 8 ? 'Mínimo 8 caracteres' : null;

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({required this.title, this.subtitle, required this.children, this.showBack = true});
  final String title;
  final String? subtitle;
  final List<Widget> children;
  final bool showBack;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: showBack ? AppBar() : null,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: ListView(padding: const EdgeInsets.fromLTRB(24, 8, 24, 24), children: [
                Semantics(header: true, child: Text(title, style: context.text.headlineMedium)),
                if (subtitle != null) ...[
                  const SizedBox(height: 8),
                  Text(subtitle!, style: context.text.bodyLarge?.copyWith(color: context.pami.muted)),
                ],
                const SizedBox(height: 24),
                ...children,
              ]),
            ),
          ),
        ),
      );
}

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invite = ref.watch(pendingInviteProvider);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                const Spacer(),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 64, height: 64,
                    decoration: BoxDecoration(color: context.colors.primary, borderRadius: BorderRadius.circular(18)),
                    child: const Icon(Icons.hub_outlined, color: Colors.white, size: 34),
                  ),
                ),
                const SizedBox(height: 24),
                Text('Pami Finance', style: context.text.headlineMedium),
                const SizedBox(height: 8),
                Text('Tus finanzas personales y los gastos que compartes, claros y en un solo lugar.',
                    style: context.text.titleMedium?.copyWith(color: context.pami.muted, fontWeight: FontWeight.w400)),
                const SizedBox(height: 28),
                const _Feature(icon: Icons.bolt_outlined, text: 'Registra un gasto en segundos: texto, voz o foto de la factura.'),
                const _Feature(icon: Icons.call_split, text: 'Reparte una misma factura por producto, sin duplicarla.'),
                const _Feature(icon: Icons.lock_outline, text: 'Lo personal sigue siendo privado aunque compartas un espacio.'),
                if (invite != null) ...[
                  const SizedBox(height: 16),
                  const Notice(message: 'Tienes una invitación a un espacio compartido. Inicia sesión o crea tu cuenta para aceptarla.'),
                ],
                const Spacer(),
                FilledButton(onPressed: () => context.push('/sign-up'), child: const Text('Crear cuenta gratis')),
                const SizedBox(height: 12),
                OutlinedButton(onPressed: () => context.push('/sign-in'), child: const Text('Ya tengo cuenta')),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Icon(icon, color: context.colors.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: context.text.bodyLarge)),
        ]),
      );
}

class SignInScreen extends ConsumerStatefulWidget {
  const SignInScreen({super.key});
  @override
  ConsumerState<SignInScreen> createState() => _SignInScreenState();
}

class _SignInScreenState extends ConsumerState<SignInScreen> with BusyState {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _obscure = true;
  AppFailure? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _error = null);
    await runBusy(() => ref.read(authRepositoryProvider).signIn(_email.text, _password.text),
        onError: (e) => setState(() => _error = AppFailure.from(e)));
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Inicia sesión',
        children: [
          Form(
            key: _form,
            child: AutofillGroup(
              child: Column(children: [
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Correo electrónico'),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  textInputAction: TextInputAction.next,
                  validator: validateEmail,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autofillHints: const [AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Contraseña',
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Mostrar contraseña' : 'Ocultar contraseña',
                      icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (v) => (v ?? '').isEmpty ? 'Escribe tu contraseña' : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ]),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Notice(
              kind: NoticeKind.error,
              message: _error!.message,
              action: _error!.code == 'email_not_confirmed'
                  ? TextButton(onPressed: () => context.push('/verify-email?email=${Uri.encodeComponent(_email.text.trim())}'),
                      child: const Text('Reenviar confirmación'))
                  : null,
            ),
          ],
          const SizedBox(height: 24),
          FilledButton(onPressed: busy ? null : _submit, child: busy ? const _Spinner() : const Text('Entrar')),
          const SizedBox(height: 8),
          TextButton(onPressed: () => context.push('/forgot-password'), child: const Text('Olvidé mi contraseña')),
          TextButton(onPressed: () => context.pushReplacement('/sign-up'), child: const Text('Crear una cuenta')),
        ],
      );
}

class SignUpScreen extends ConsumerStatefulWidget {
  const SignUpScreen({super.key});
  @override
  ConsumerState<SignUpScreen> createState() => _SignUpScreenState();
}

class _SignUpScreenState extends ConsumerState<SignUpScreen> with BusyState {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _accepted = false;
  AppFailure? _error;

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    if (!_accepted) {
      setState(() => _error = const AppFailure(FailureKind.validation, 'Debes aceptar la política de tratamiento de datos para continuar.'));
      return;
    }
    setState(() => _error = null);
    final hasSession = await runBusy(
        () => ref.read(authRepositoryProvider).signUp(email: _email.text, password: _password.text, displayName: _name.text),
        onError: (e) => setState(() => _error = AppFailure.from(e)));
    if (!mounted || hasSession == null) return;
    if (!hasSession) context.go('/verify-email?email=${Uri.encodeComponent(_email.text.trim())}');
  }

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Crea tu cuenta',
        subtitle: 'Solo te pedimos lo necesario. El resto lo puedes completar después.',
        children: [
          Form(
            key: _form,
            child: AutofillGroup(
              child: Column(children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(labelText: 'Nombre visible', helperText: 'Así te verán en los espacios compartidos'),
                  textCapitalization: TextCapitalization.words,
                  autofillHints: const [AutofillHints.givenName],
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe tu nombre' : ((v!.trim().length > 60) ? 'Máximo 60 caracteres' : null),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _email,
                  decoration: const InputDecoration(labelText: 'Correo electrónico'),
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  validator: validateEmail,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.newPassword],
                  decoration: const InputDecoration(labelText: 'Contraseña', helperText: 'Mínimo 8 caracteres'),
                  validator: validatePassword,
                ),
              ]),
            ),
          ),
          const SizedBox(height: 12),
          CheckboxListTile(
            value: _accepted,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            onChanged: (v) => setState(() => _accepted = v ?? false),
            title: const Text('Autorizo el tratamiento de mis datos personales conforme a la Ley 1581 de 2012 y la política de privacidad.'),
          ),
          TextButton(
            onPressed: () => showNxSheet(context, builder: (_) => const PrivacyPolicySummary()),
            child: const Text('Leer resumen de la política de datos'),
          ),
          if (_error != null) ...[const SizedBox(height: 8), Notice(kind: NoticeKind.error, message: _error!.message)],
          const SizedBox(height: 20),
          FilledButton(onPressed: busy ? null : _submit, child: busy ? const _Spinner() : const Text('Crear cuenta')),
        ],
      );
}

class PrivacyPolicySummary extends StatelessWidget {
  const PrivacyPolicySummary({super.key});

  @override
  Widget build(BuildContext context) => const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SheetHeader('Tratamiento de datos (resumen)'),
        Text('• Usamos tus datos para prestarte el servicio: registrar, calcular y mostrar tus finanzas.\n'
            '• Tus movimientos personales solo los ves tú. En un espacio compartido, los miembros ven lo registrado en ese espacio.\n'
            '• Las funciones de IA reciben el mínimo necesario (texto, factura o audio que tú envías) y no se usan para otros fines.\n'
            '• Puedes conocer, actualizar, exportar y suprimir tus datos desde Perfil › Datos y privacidad.\n'
            '• Este resumen no reemplaza la política completa, que debe publicarse antes del lanzamiento (ver docs/PRIVACY_CO.md).'),
      ]);
}

class VerifyEmailScreen extends ConsumerStatefulWidget {
  const VerifyEmailScreen({super.key, required this.email});
  final String email;
  @override
  ConsumerState<VerifyEmailScreen> createState() => _VerifyEmailScreenState();
}

class _VerifyEmailScreenState extends ConsumerState<VerifyEmailScreen> with BusyState {
  bool _sent = false;

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Confirma tu correo',
        subtitle: widget.email.isEmpty
            ? 'Te enviamos un enlace de confirmación. Ábrelo desde este dispositivo para continuar.'
            : 'Te enviamos un enlace a ${widget.email}. Ábrelo desde este dispositivo para continuar.',
        children: [
          if (_sent) const Notice(kind: NoticeKind.success, message: 'Enviamos un nuevo enlace. Revisa también la carpeta de spam.'),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: busy || widget.email.isEmpty
                ? null
                : () => runBusy(() async {
                      await ref.read(authRepositoryProvider).resendConfirmation(widget.email);
                      setState(() => _sent = true);
                    }, onError: (e) => showFailure(context, e)),
            child: const Text('Reenviar enlace'),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: () => context.go('/sign-in'), child: const Text('Ya confirmé, iniciar sesión')),
        ],
      );
}

class ForgotPasswordScreen extends ConsumerStatefulWidget {
  const ForgotPasswordScreen({super.key});
  @override
  ConsumerState<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends ConsumerState<ForgotPasswordScreen> with BusyState {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  bool _sent = false;

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Recupera tu contraseña',
        subtitle: 'Te enviaremos un enlace para crear una nueva.',
        children: [
          Form(
            key: _form,
            child: TextFormField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Correo electrónico'),
              keyboardType: TextInputType.emailAddress,
              validator: validateEmail,
            ),
          ),
          const SizedBox(height: 16),
          // Same message whether or not the account exists (no account enumeration).
          if (_sent) const Notice(kind: NoticeKind.success, message: 'Si existe una cuenta con ese correo, recibirás un enlace en unos minutos.'),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: busy
                ? null
                : () {
                    if (!_form.currentState!.validate()) return;
                    runBusy(() async {
                      await ref.read(authRepositoryProvider).sendPasswordReset(_email.text);
                      setState(() => _sent = true);
                    }, onError: (e) => showFailure(context, e));
                  },
            child: busy ? const _Spinner() : const Text('Enviar enlace'),
          ),
        ],
      );
}

class ResetPasswordScreen extends ConsumerStatefulWidget {
  const ResetPasswordScreen({super.key});
  @override
  ConsumerState<ResetPasswordScreen> createState() => _ResetPasswordScreenState();
}

class _ResetPasswordScreenState extends ConsumerState<ResetPasswordScreen> with BusyState {
  final _form = GlobalKey<FormState>();
  final _p1 = TextEditingController();
  final _p2 = TextEditingController();

  @override
  Widget build(BuildContext context) => _AuthScaffold(
        title: 'Nueva contraseña',
        showBack: false,
        children: [
          Form(
            key: _form,
            child: Column(children: [
              TextFormField(controller: _p1, obscureText: true, decoration: const InputDecoration(labelText: 'Nueva contraseña'), validator: validatePassword),
              const SizedBox(height: 12),
              TextFormField(
                controller: _p2,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Repite la contraseña'),
                validator: (v) => v != _p1.text ? 'Las contraseñas no coinciden' : null,
              ),
            ]),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy
                ? null
                : () {
                    if (!_form.currentState!.validate()) return;
                    runBusy(() async {
                      await ref.read(authRepositoryProvider).updatePassword(_p1.text);
                      ref.read(recoveryPendingProvider.notifier).set(false);
                      if (context.mounted) {
                        showSuccess(context, 'Contraseña actualizada');
                        context.go('/home');
                      }
                    }, onError: (e) => showFailure(context, e));
                  },
            child: busy ? const _Spinner() : const Text('Guardar contraseña'),
          ),
        ],
      );
}

class _Spinner extends StatelessWidget {
  const _Spinner();
  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white));
}
