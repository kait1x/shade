import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shade/core/theme/shade_theme.dart';

/// Grouped, flat bubbles with independent delivery semantics.
class MessageBubble extends StatefulWidget {
  final String text;
  final DateTime timestamp;
  final bool isMine;
  final bool isEncrypted;
  final bool isImage;
  final Uint8List? imageData;
  final String? deliveryLabel;
  final String status; // 'sent', 'delivered', 'read'
  final VoidCallback? onLongPress;
  final bool groupedWithPrevious;
  final bool groupedWithNext;
  final String? replyText;
  final String? replySender;

  const MessageBubble({
    super.key,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.isEncrypted = false,
    this.isImage = false,
    this.imageData,
    this.status = 'sent',
    this.deliveryLabel,
    this.onLongPress,
    this.groupedWithPrevious = false,
    this.groupedWithNext = false,
    this.replyText,
    this.replySender,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _pressed = false;

  void _press(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final MessageBubble(
      :text,
      :timestamp,
      :isMine,
      :isEncrypted,
      :isImage,
      :imageData,
      :status,
      :onLongPress,
      :groupedWithPrevious,
      :groupedWithNext,
      :replyText,
      :replySender
    ) = widget;
    final alignment = isMine ? Alignment.centerRight : Alignment.centerLeft;
    final tail = groupedWithNext ? 16.0 : 5.0;

    return GestureDetector(
      onTapDown: onLongPress == null ? null : (_) => _press(true),
      onTapUp: onLongPress == null ? null : (_) => _press(false),
      onTapCancel: onLongPress == null ? null : () => _press(false),
      onLongPress: onLongPress,
      child: LayoutBuilder(
          builder: (context, bounds) => Align(
                alignment: alignment,
                child: AnimatedScale(
                    scale: _pressed && !MediaQuery.disableAnimationsOf(context)
                        ? .985
                        : 1,
                    alignment:
                        isMine ? Alignment.centerRight : Alignment.centerLeft,
                    duration: ShadeMotion.duration(context, 160),
                    curve: Curves.easeOutCubic,
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: (bounds.maxWidth * 0.84).clamp(0.0, 560.0),
                      ),
                      margin: EdgeInsets.fromLTRB(
                          16, groupedWithPrevious ? 2 : 9, 16, 2),
                      padding: isImage
                          ? const EdgeInsets.all(4)
                          : const EdgeInsets.fromLTRB(14, 10, 11, 7),
                      decoration: BoxDecoration(
                        color: isMine
                            ? const Color(0xFFE9E9ED)
                            : const Color(0xFF171719),
                        borderRadius: BorderRadius.only(
                            topLeft: Radius.circular(
                                !isMine && groupedWithPrevious ? 8 : 19),
                            topRight: Radius.circular(
                                isMine && groupedWithPrevious ? 8 : 19),
                            bottomLeft: Radius.circular(isMine ? 19 : tail),
                            bottomRight: Radius.circular(isMine ? tail : 19)),
                        border: isMine
                            ? null
                            : Border.all(color: const Color(0xFF29292D)),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          // Reply preview
                          if (replyText != null && replySender != null)
                            Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                color:
                                    (isMine ? Colors.black : ShadeColors.violet)
                                        .withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(8),
                                border: Border(
                                  left: BorderSide(
                                    color: isMine
                                        ? Colors.black.withValues(alpha: 0.5)
                                        : ShadeColors.cyan,
                                    width: 2,
                                  ),
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    replySender,
                                    style: TextStyle(
                                      color: isMine
                                          ? Colors.black.withValues(alpha: 0.7)
                                          : ShadeColors.cyan,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    replyText,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: (isMine
                                              ? Colors.black
                                              : ShadeColors.textSecondary)
                                          .withValues(alpha: 0.7),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          if (isImage && imageData != null)
                            GestureDetector(
                              onTap: () {
                                Navigator.of(context).push(
                                  PageRouteBuilder<void>(
                                    transitionDuration:
                                        ShadeMotion.duration(context, 220),
                                    reverseTransitionDuration:
                                        ShadeMotion.duration(context, 180),
                                    pageBuilder: (_, __, ___) =>
                                        _FullScreenImage(imageData: imageData),
                                    transitionsBuilder: (_, animation, __,
                                            child) =>
                                        FadeTransition(
                                            opacity: animation, child: child),
                                  ),
                                );
                              },
                              child: HeroMode(
                                enabled:
                                    !MediaQuery.disableAnimationsOf(context),
                                child: Hero(
                                    tag: imageData.hashCode,
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(16),
                                      child: Image.memory(
                                        imageData,
                                        fit: BoxFit.cover,
                                        cacheWidth: 900,
                                        errorBuilder: (_, __, ___) =>
                                            const Padding(
                                                padding: EdgeInsets.all(24),
                                                child: Icon(Icons
                                                    .broken_image_outlined)),
                                        width: (bounds.maxWidth * .64)
                                            .clamp(0, 440),
                                        height: (bounds.maxWidth * .70)
                                            .clamp(0, 460),
                                      ),
                                    )),
                              ),
                            ),
                          if (isImage && imageData == null)
                            const Padding(
                                padding: EdgeInsets.all(20),
                                child: Text('Фото недоступно')),
                          if (!isImage) ...[
                            Text(
                              isEncrypted
                                  ? text
                                  : 'Не удалось расшифровать сообщение',
                              style: TextStyle(
                                color: isMine
                                    ? ShadeColors.black
                                    : ShadeColors.textPrimary,
                                fontSize: 16,
                                height: 1.38,
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Semantics(
                              label: isMine ? _statusLabel : null,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _formatTimestamp(timestamp),
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: isMine
                                          ? Colors.black54
                                          : ShadeColors.textSecondary,
                                    ),
                                  ),
                                  if (isMine) ...[
                                    const SizedBox(width: 4),
                                    ExcludeSemantics(
                                        child: AnimatedSwitcher(
                                            duration: ShadeMotion.duration(
                                                context, 160),
                                            child: KeyedSubtree(
                                                key: ValueKey(status),
                                                child: _buildStatusIcon()))),
                                  ],
                                ],
                              )),
                        ],
                      ),
                    )),
              )),
    );
  }

  String _formatTimestamp(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  String get _statusLabel =>
      widget.deliveryLabel ??
      switch (widget.status) {
        'queued' => 'Ожидает соединения',
        'read' => 'Прочитано',
        'delivered' => 'Доставлено',
        _ => 'Отправлено',
      };

  Widget _buildStatusIcon() {
    switch (widget.status) {
      case 'blocked':
        return Tooltip(
            message: widget.deliveryLabel ?? 'Отправка заблокирована',
            child: const Icon(Icons.error_outline_rounded,
                size: 14, color: Colors.black54));
      case 'queued':
        return const Tooltip(
            message: 'Ожидает соединения',
            child:
                Icon(Icons.schedule_rounded, size: 14, color: Colors.black54));
      case 'read':
        return const Tooltip(
            message: 'Прочитано',
            child: Icon(Icons.done_all_rounded,
                size: 15, color: Color(0xFF181818)));
      case 'delivered':
        return const Tooltip(
            message: 'Доставлено',
            child:
                Icon(Icons.done_all_rounded, size: 15, color: Colors.black54));
      default: // sent
        return const Tooltip(
            message: 'Отправлено',
            child: Icon(Icons.done_rounded, size: 15, color: Colors.black54));
    }
  }
}

class _FullScreenImage extends StatelessWidget {
  final Uint8List imageData;

  const _FullScreenImage({required this.imageData});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        onTap: () => Navigator.of(context).pop(),
        child: Container(
          color: Colors.black,
          child: Stack(
            children: [
              // Photo
              Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: HeroMode(
                      enabled: !MediaQuery.disableAnimationsOf(context),
                      child: Hero(
                        tag: imageData.hashCode,
                        child: SizedBox(
                          width: MediaQuery.of(context).size.width,
                          height: MediaQuery.of(context).size.height,
                          child: Image.memory(
                            imageData,
                            fit: BoxFit.contain,
                          ),
                        ),
                      )),
                ),
              ),
              // Top bar with close + download
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton(
                          tooltip: 'Закрыть фото',
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.white, size: 28),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        IconButton(
                          tooltip: 'Сохранить фото',
                          icon: const Icon(Icons.download_rounded,
                              color: Colors.white),
                          onPressed: () => _saveImage(context),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _saveImage(BuildContext context) async {
    try {
      // Save to temp file first, then to gallery
      final dir = await getTemporaryDirectory();
      final file = File(
          '${dir.path}/shade_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(imageData);

      await Gal.putImage(file.path);

      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Фото сохранено'),
            backgroundColor: ShadeColors.greenAccent,
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Ошибка сохранения'),
            backgroundColor: Color(0xFFEF4444),
          ),
        );
      }
    }
  }
}
