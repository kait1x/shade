import 'package:flutter/material.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/shade_motion.dart';

import 'shade_glass.dart';

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
    final shape = BorderRadius.circular(26);
    final duration = ShadeMotion.duration(context, 220);
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 416),
          child: ClipRRect(
            borderRadius: shape,
            // The controls sit above black safe space. The tint and rim
            // supply depth without an offscreen blur pass while scrolling.
            child: DecoratedBox(
              decoration: ShadeGlass.graphite(shape),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Stack(children: [
                  Positioned.fill(
                    child: AnimatedAlign(
                      key: const ValueKey('shade-dock-selection'),
                      duration: duration,
                      curve: Curves.easeOutCubic,
                      alignment: AlignmentDirectional(
                        2 * selectedIndex / (_destinations.length - 1) - 1,
                        0,
                      ),
                      child: FractionallySizedBox(
                        widthFactor: 1 / _destinations.length,
                        heightFactor: 1,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: const Color(0x23FFFFFF),
                              borderRadius: BorderRadius.circular(22),
                              border:
                                  Border.all(color: const Color(0x18FFFFFF)),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Material(
                    type: MaterialType.transparency,
                    child: Row(children: [
                      for (var index = 0; index < _destinations.length; index++)
                        Expanded(child: _tile(context, index)),
                    ]),
                  ),
                ]),
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
    final radius = BorderRadius.circular(20);
    final duration = ShadeMotion.duration(context, 180);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Semantics(
        button: true,
        selected: selected,
        child: InkWell(
          borderRadius: radius,
          onTap: () {
            if (selected) return;
            ShadeMotion.selection(context);
            onSelected(index);
          },
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
              child: TweenAnimationBuilder<Color?>(
                duration: duration,
                tween: ColorTween(end: color),
                builder: (context, tint, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedScale(
                      scale: selected ? 1.05 : .96,
                      duration: duration,
                      curve: Curves.easeOutCubic,
                      child: Icon(icon, size: 20, color: tint),
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(label,
                          maxLines: 1,
                          style: TextStyle(
                              fontSize: 11,
                              height: 1.12,
                              fontWeight: FontWeight.w600,
                              color: tint)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
