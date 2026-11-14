import 'dart:typed_data';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shade/main.dart';

/// Styled message bubble with gradient and shadow.
class MessageBubble extends StatelessWidget {
  final String text;
  final DateTime timestamp;
  final bool isMine;
  final bool isEncrypted;
  final bool isImage;
  final Uint8List? imageData;
  final String status; // 'sent', 'delivered', 'read'
  final VoidCallback? onLongPress;
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
    this.onLongPress,
    this.replyText,
    this.replySender,
  });

  @override
  Widget build(BuildContext context) {
    final alignment = isMine ? Alignment.centerRight : Alignment.centerLeft;

    return GestureDetector(
      onLongPress: onLongPress,
      child: Align(
        alignment: alignment,
        child: Container(
          constraints: BoxConstraints(
            maxWidth:
                (MediaQuery.of(context).size.width * 0.82).clamp(0.0, 560.0),
          ),
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 18),
          padding: isImage
              ? const EdgeInsets.all(4)
              : const EdgeInsets.fromLTRB(15, 12, 13, 9),
          decoration: BoxDecoration(
            gradient: isMine
                ? const LinearGradient(
                    colors: [Color(0xFFF0F0F0), Color(0xFFDDDDDD)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  )
                : null,
            color: isMine ? null : ShadeColors.surfaceElevated,
            borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(20),
                topRight: const Radius.circular(20),
                bottomLeft: Radius.circular(isMine ? 20 : 6),
                bottomRight: Radius.circular(isMine ? 6 : 20)),
            border: isMine
                ? null
                : Border.all(
                    color: ShadeColors.greyBorder.withValues(alpha: .8)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (isImage && imageData != null)
                GestureDetector(
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _FullScreenImage(imageData: imageData!),
                      ),
                    );
                  },
                  child: Hero(
                    tag: imageData.hashCode,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.memory(
                        imageData!,
                        fit: BoxFit.cover,
                        width: MediaQuery.of(context).size.width * 0.6,
                      ),
                    ),
                  ),
                ),
              if (!isImage) ...[
                // Reply preview
                if (replyText != null && replySender != null)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: (isMine ? Colors.black : ShadeColors.violet)
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
                          replySender!,
                          style: TextStyle(
                            color: isMine
                                ? Colors.black.withValues(alpha: 0.7)
                                : ShadeColors.cyan,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          replyText!,
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
                Text(
                  text,
                  style: TextStyle(
                    color: isMine ? ShadeColors.black : ShadeColors.textPrimary,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _formatTimestamp(timestamp),
                    style: TextStyle(
                      fontSize: 11,
                      color:
                          isMine ? Colors.black54 : ShadeColors.textSecondary,
                    ),
                  ),
                  if (isMine) ...[
                    const SizedBox(width: 4),
                    _buildStatusIcon(),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildStatusIcon() {
    switch (status) {
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
                  ),
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
                          icon: const Icon(Icons.close_rounded,
                              color: Colors.white, size: 28),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        IconButton(
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
