import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;

import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/features/home/presentation/widgets/home_style.dart';
import 'shade_glass.dart';
import 'shade_logo.dart';
import 'shade_motion.dart';

/// The native and web chat lists use the same visual components.
class ShadeChatsAppBar extends StatelessWidget {
  const ShadeChatsAppBar({
    super.key,
    required this.searchVisible,
    required this.onToggleSearch,
    this.actions = const [],
  });

  final bool searchVisible;
  final VoidCallback onToggleSearch;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => SliverAppBar(
        pinned: true,
        primary: false,
        backgroundColor: HomeStyle.background,
        surfaceTintColor: Colors.transparent,
        toolbarHeight: 52,
        titleSpacing: 18,
        title: const Row(mainAxisSize: MainAxisSize.min, children: [
          ShadeLogo(size: 24),
          SizedBox(width: 9),
          Flexible(
              child: Text(
            'SHADE',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: 2.8),
          )),
        ]),
        actions: [
          IconButton(
            tooltip: searchVisible ? 'Скрыть поиск' : 'Поиск',
            onPressed: onToggleSearch,
            icon: Icon(searchVisible
                ? Icons.search_off_rounded
                : Icons.search_rounded),
          ),
          ...actions,
          const SizedBox(width: 8),
        ],
      );
}

class ShadeChatsHeader extends StatelessWidget {
  const ShadeChatsHeader({
    super.key,
    required this.searchVisible,
    required this.controller,
    required this.focusNode,
    required this.onQueryChanged,
    required this.savedOnly,
    required this.onFilterChanged,
  });

  final bool searchVisible, savedOnly;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<bool> onFilterChanged;

  @override
  Widget build(BuildContext context) {
    final duration = ShadeMotion.duration(context, 200);
    final search = !searchVisible
        ? const SizedBox(width: double.infinity)
        : Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _searchField(duration),
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Сообщения',
            style: TextStyle(
                fontSize: 32,
                height: 1.12,
                fontWeight: FontWeight.w700,
                letterSpacing: -1.1)),
        if (duration == Duration.zero)
          search
        else
          AnimatedSize(
            duration: duration,
            alignment: Alignment.topCenter,
            curve: Curves.easeOutCubic,
            child: search,
          ),
        const SizedBox(height: 6),
        Wrap(spacing: 7, children: [
          _filter(context, 'Все чаты', false),
          _filter(context, 'Избранное', true),
        ]),
      ]),
    );
  }

  Widget _searchField(Duration duration) {
    final radius = BorderRadius.circular(17);
    return ListenableBuilder(
      listenable: focusNode,
      builder: (context, child) => AnimatedContainer(
        duration: duration,
        curve: Curves.easeOutCubic,
        decoration: ShadeGlass.graphite(
          radius,
          border: focusNode.hasFocus ? ShadeGlass.focusedRim : ShadeGlass.rim,
        ),
        child: child,
      ),
      child: TextField(
        key: const Key('v2-chat-search'),
        controller: controller,
        focusNode: focusNode,
        onChanged: onQueryChanged,
        textInputAction: TextInputAction.search,
        style: const TextStyle(fontSize: 14, color: ShadeColors.textPrimary),
        decoration: InputDecoration(
          hintText: 'Поиск в переписках',
          hintStyle: const TextStyle(color: Color(0xFF99999F)),
          filled: false,
          isDense: true,
          prefixIcon: const Icon(Icons.search_rounded,
              size: 20, color: Color(0xFF99999F)),
          contentPadding:
              const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          suffixIconConstraints: const BoxConstraints(),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => value.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Очистить поиск',
                    icon: const Icon(Icons.close_rounded, size: 18),
                    onPressed: () {
                      controller.clear();
                      onQueryChanged('');
                    },
                  ),
          ),
        ),
      ),
    );
  }

  Widget _filter(BuildContext context, String label, bool saved) {
    final selected = savedOnly == saved;
    final radius = BorderRadius.circular(14);
    return Semantics(
      selected: selected,
      button: true,
      child: Tooltip(
        message:
            saved ? 'Показать только личные заметки' : 'Показать все переписки',
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: ValueKey(saved ? 'v2-saved-filter' : 'v2-all-filter'),
            borderRadius: radius,
            onTap: () {
              if (selected) return;
              ShadeMotion.selection(context);
              onFilterChanged(saved);
            },
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Center(
                widthFactor: 1,
                child: AnimatedContainer(
                  duration: ShadeMotion.duration(context, 180),
                  curve: Curves.easeOutCubic,
                  decoration: selected
                      ? BoxDecoration(
                          color: HomeStyle.ink,
                          borderRadius: radius,
                          border: Border.all(color: HomeStyle.ink))
                      : ShadeGlass.graphite(radius),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  child: AnimatedDefaultTextStyle(
                    duration: ShadeMotion.duration(context, 180),
                    curve: Curves.easeOutCubic,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color:
                            selected ? Colors.black : ShadeColors.textPrimary),
                    child: Text(label),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

bool? shadeComposeCompact(ScrollNotification event) {
  if (event.depth != 0 || event is! UserScrollNotification) return null;
  if (event.direction == ScrollDirection.reverse &&
      event.metrics.maxScrollExtent > 0) {
    return true;
  }
  if (event.direction == ScrollDirection.forward ||
      event.metrics.extentBefore <= 0) {
    return false;
  }
  return null;
}

class ShadeComposeButton extends StatelessWidget {
  const ShadeComposeButton(
      {super.key, required this.compact, required this.onPressed});

  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final duration = ShadeMotion.duration(context, 210);
    return LayoutBuilder(builder: (context, constraints) {
      final labelWidth = (MediaQuery.textScalerOf(context).scale(14) * 4.8 + 62)
          .clamp(126.0, constraints.maxWidth.clamp(126.0, 230.0));
      return AnimatedContainer(
        key: const ValueKey('v2-compose'),
        width: compact ? 48 : labelWidth,
        height: 48,
        duration: duration,
        curve: Curves.easeOutCubic,
        child: ShadeTapScale(
          child: FloatingActionButton(
            heroTag: null,
            tooltip: 'Новый чат',
            elevation: 1,
            focusElevation: 1,
            hoverElevation: 1,
            highlightElevation: 1,
            backgroundColor: HomeStyle.ink,
            foregroundColor: Colors.black,
            shape: const StadiumBorder(),
            onPressed: onPressed,
            child: ClipRect(
              child: Stack(fit: StackFit.expand, children: [
                const Positioned(
                    left: 14,
                    top: 14,
                    child: Icon(Icons.edit_outlined, size: 20)),
                Positioned(
                  left: 41,
                  right: 10,
                  top: 0,
                  bottom: 0,
                  child: AnimatedOpacity(
                    opacity: compact ? 0 : 1,
                    duration: duration,
                    child: const Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Написать',
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                            style: TextStyle(
                                fontSize: 14, fontWeight: FontWeight.w700))),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

class ShadeChatRow extends StatelessWidget {
  const ShadeChatRow({
    super.key,
    required this.title,
    required this.preview,
    required this.avatar,
    required this.onOpen,
    required this.unreadCount,
    required this.confirmed,
    this.selected = false,
    this.time,
    this.status,
  });

  final String title, preview;
  final Widget avatar;
  final VoidCallback onOpen;
  final int unreadCount;
  final bool confirmed, selected;
  final int? time;
  final String? status;

  @override
  Widget build(BuildContext context) {
    final unread = unreadCount > 0;
    final statusIcon = _statusIcon(status);
    return Material(
      color: selected ? ShadeColors.surfaceCard : Colors.transparent,
      child: InkWell(
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 62),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
            child: Row(children: [
              avatar,
              const SizedBox(width: 12),
              Expanded(
                  child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Expanded(
                        child: Text(title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 16,
                                color: ShadeColors.textPrimary,
                                fontWeight: unread
                                    ? FontWeight.w700
                                    : FontWeight.w600))),
                    if (time != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(context, time!),
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 12,
                          color: unread
                              ? ShadeColors.textPrimary
                              : ShadeColors.textMuted,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ]),
                  const SizedBox(height: 3),
                  Row(children: [
                    if (statusIcon != null) ...[
                      statusIcon,
                      const SizedBox(width: 5)
                    ],
                    if (!confirmed) ...[
                      const Tooltip(
                        message: 'Код безопасности пока не сверен',
                        child: Icon(Icons.gpp_maybe_outlined,
                            size: 14, color: ShadeColors.textMuted),
                      ),
                      const SizedBox(width: 5),
                    ],
                    Expanded(
                        child: Text(preview,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 13,
                                color: unread
                                    ? ShadeColors.textPrimary
                                    : ShadeColors.textSecondary))),
                    if (unread)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Badge(
                          backgroundColor: ShadeColors.textPrimary,
                          textColor: Colors.black,
                          label: Text(unreadCount > 99 ? '99+' : '$unreadCount',
                              semanticsLabel: '$unreadCount непрочитанных'),
                        ),
                      ),
                  ]),
                ],
              )),
            ]),
          ),
        ),
      ),
    );
  }

  static Widget? _statusIcon(String? status) {
    final (icon, label) = switch (status) {
      'queued' => (Icons.schedule_rounded, 'В очереди'),
      'blocked' => (Icons.error_outline_rounded, 'Отправка заблокирована'),
      'sent' => (Icons.done_rounded, 'Отправлено'),
      'delivered' => (Icons.done_all_rounded, 'Доставлено'),
      'read' => (Icons.done_all_rounded, 'Прочитано'),
      'retracted' => (Icons.block_rounded, 'Сообщение отозвано'),
      _ => (null, ''),
    };
    if (icon == null) return null;
    return Tooltip(
        message: label,
        child: Icon(icon,
            size: 14,
            color: status == 'read'
                ? ShadeColors.textPrimary
                : ShadeColors.textMuted));
  }

  static String _formatTime(BuildContext context, int ms) {
    final time = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (DateUtils.isSameDay(time, now)) {
      return MaterialLocalizations.of(context).formatTimeOfDay(
        TimeOfDay.fromDateTime(time),
        alwaysUse24HourFormat: true,
      );
    }
    final day = time.day.toString().padLeft(2, '0');
    final month = time.month.toString().padLeft(2, '0');
    if (time.year == now.year) return '$day.$month';
    return '$day.$month.${(time.year % 100).toString().padLeft(2, '0')}';
  }
}
