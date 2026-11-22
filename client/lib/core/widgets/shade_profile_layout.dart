import 'package:flutter/material.dart';

import 'package:shade/core/theme/shade_theme.dart';
import 'shade_motion.dart';

class ShadeProfileHeader extends StatelessWidget {
  const ShadeProfileHeader({
    super.key,
    required this.visibleName,
    required this.handle,
    required this.smallAvatar,
    required this.largeAvatar,
    this.leading,
  });

  final String visibleName, handle;
  final Widget smallAvatar, largeAvatar;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final textScaler = MediaQuery.textScalerOf(context);
    return SliverAppBar(
      pinned: true,
      leading: leading,
      stretch: true,
      backgroundColor: ShadeColors.black,
      surfaceTintColor: Colors.transparent,
      expandedHeight:
          270 + (textScaler.scale(27) - 27) + (textScaler.scale(14) - 14),
      flexibleSpace: LayoutBuilder(builder: (context, constraints) {
        final collapsed =
            constraints.maxHeight <= topInset + kToolbarHeight + 18;
        return FlexibleSpaceBar(
          collapseMode: CollapseMode.pin,
          titlePadding:
              const EdgeInsetsDirectional.only(start: 56, end: 16, bottom: 11),
          expandedTitleScale: 1,
          title: collapsed
              ? Row(children: [
                  smallAvatar,
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(visibleName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700))),
                ])
              : null,
          background: ExcludeSemantics(
            excluding: collapsed,
            child: Center(
              child: Padding(
                padding: EdgeInsets.fromLTRB(24, topInset + 52, 24, 20),
                child:
                    Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                  largeAvatar,
                  const SizedBox(height: 12),
                  Text(visibleName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 27,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -.6)),
                  const SizedBox(height: 6),
                  Text(handle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: ShadeColors.textSecondary, fontSize: 14)),
                ]),
              ),
            ),
          ),
        );
      }),
    );
  }
}

class ShadeAvatarEdit extends StatelessWidget {
  const ShadeAvatarEdit({super.key, required this.avatar, required this.onTap});

  final Widget avatar;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Изменить аватар',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Stack(clipBehavior: Clip.none, children: [
            avatar,
            Positioned(
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xff111113),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xff29292d), width: 2),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.edit_outlined, size: 15),
                ),
              ),
            ),
          ]),
        ),
      );
}

class ShadeProfileAction extends StatelessWidget {
  const ShadeProfileAction(this.icon, this.label, this.onTap,
      {super.key, this.primary = false});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    final highlighted = active && primary;
    final foreground = !active
        ? ShadeColors.textMuted
        : highlighted
            ? Colors.black
            : ShadeColors.textPrimary;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(
          color: highlighted ? Colors.transparent : ShadeColors.greyBorder),
    );
    return ShadeTapScale(
      child: Material(
        color: highlighted ? ShadeColors.textPrimary : ShadeColors.surfaceCard,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: active
              ? () {
                  ShadeMotion.selection(context);
                  onTap!();
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: foreground, size: 21),
              const SizedBox(height: 9),
              Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: foreground)),
            ]),
          ),
        ),
      ),
    );
  }
}

class ShadeProfileSection extends StatelessWidget {
  const ShadeProfileSection(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(label,
            style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: ShadeColors.textSecondary)),
      );
}

class ShadeProfileCard extends StatelessWidget {
  const ShadeProfileCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
        color: ShadeColors.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: ShadeColors.greyBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0)
              const Divider(
                  height: 1, indent: 56, color: ShadeColors.greyBorder),
            children[i],
          ],
        ]),
      );
}
