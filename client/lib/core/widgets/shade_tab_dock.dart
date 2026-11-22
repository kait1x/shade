import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/shade_motion.dart';

class ShadeTabDock extends StatelessWidget {
  const ShadeTabDock({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  static const _destinations = [
    (Icons.chat_bubble_outline_rounded, 'Чаты'),
    (Icons.settings_outlined, 'Настройки'),
    (Icons.person_outline_rounded, 'Профиль'),
  ];

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(28);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: shape,
                boxShadow: const [
                  BoxShadow(
                      color: Colors.black54,
                      blurRadius: 18,
                      offset: Offset(0, 5)),
                ],
              ),
              child: ClipRRect(
                borderRadius: shape,
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                  child: Material(
                    color: const Color(0xF019191C),
                    shape: RoundedRectangleBorder(
                      borderRadius: shape,
                      side: const BorderSide(color: Color(0xFF333336)),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Row(children: [
                        for (var index = 0;
                            index < _destinations.length;
                            index++)
                          Expanded(child: _tile(context, index)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, int index) {
    final (icon, label) = _destinations[index];
    final selected = selectedIndex == index;
    final color =
        selected ? ShadeColors.textPrimary : ShadeColors.textSecondary;
    final radius = BorderRadius.circular(22);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Semantics(
        button: true,
        selected: selected,
        child: AnimatedContainer(
          duration: ShadeMotion.duration(context, 180),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF303035) : Colors.transparent,
            borderRadius: radius,
          ),
          child: InkWell(
            borderRadius: radius,
            onTap: () {
              if (selected) return;
              ShadeMotion.selection(context);
              onSelected(index);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 7),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 22, color: color),
                const SizedBox(height: 3),
                Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.15,
                        fontWeight: FontWeight.w600,
                        color: color)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
