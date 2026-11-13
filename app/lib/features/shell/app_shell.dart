import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/theme.dart';
import '../../ui/states.dart';
import '../capture/capture_sheet.dart';

/// Bottom navigation: Inicio · Movimientos · [+] · Espacios · Plan.
class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.shell});
  final StatefulNavigationShell shell;

  static const _items = [
    (Icons.home_outlined, Icons.home, 'Inicio'),
    (Icons.receipt_long_outlined, Icons.receipt_long, 'Movimientos'),
    (Icons.add, Icons.add, 'Añadir'),
    (Icons.groups_outlined, Icons.groups, 'Espacios'),
    (Icons.flag_outlined, Icons.flag, 'Plan'),
  ];

  int get _selected => shell.currentIndex >= 2 ? shell.currentIndex + 1 : shell.currentIndex;

  void _tap(BuildContext context, int i) {
    if (i == 2) {
      HapticFeedback.mediumImpact();
      showCaptureSheet(context);
      return;
    }
    final branch = i > 2 ? i - 1 : i;
    shell.goBranch(branch, initialLocation: branch == shell.currentIndex);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        const SafeArea(bottom: false, child: OfflineBanner()),
        Expanded(child: MediaQuery.removePadding(context: context, removeTop: false, child: shell)),
      ]),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(color: context.colors.surface, border: Border(top: BorderSide(color: context.pami.border))),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 64,
            child: Row(children: [
              for (var i = 0; i < _items.length; i++)
                Expanded(child: i == 2 ? _AddButton(onTap: () => _tap(context, 2)) : _NavItem(
                  icon: _items[i].$1, selectedIcon: _items[i].$2, label: _items[i].$3,
                  selected: _selected == i, onTap: () => _tap(context, i),
                )),
            ]),
          ),
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.icon, required this.selectedIcon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = selected ? context.colors.primary : context.pami.muted;
    return Semantics(
      button: true,
      onTap: onTap,
      selected: selected,
      label: label,
      excludeSemantics: true,
      child: InkResponse(
        onTap: onTap,
        radius: 36,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          AnimatedContainer(
            duration: PamiTokens.motionFast,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
            decoration: BoxDecoration(color: selected ? context.pami.brandSoft : Colors.transparent, borderRadius: BorderRadius.circular(14)),
            child: Icon(selected ? selectedIcon : icon, color: color, size: 24),
          ),
          const SizedBox(height: 2),
          FittedBox(child: Text(label, style: context.text.labelSmall?.copyWith(color: color, fontWeight: selected ? FontWeight.w700 : FontWeight.w500))),
        ]),
      ),
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Center(
        child: Semantics(
          button: true,
          onTap: onTap,
          label: 'Añadir registro',
          excludeSemantics: true,
          child: Material(
            color: context.colors.primary,
            shape: const CircleBorder(),
            elevation: 3,
            shadowColor: context.colors.primary.withValues(alpha: 0.4),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: onTap,
              child: SizedBox(width: 54, height: 54, child: Icon(Icons.add, color: context.colors.onPrimary, size: 30)),
            ),
          ),
        ),
      );
}
