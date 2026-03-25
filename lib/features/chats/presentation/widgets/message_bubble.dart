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

  const MessageBubble({
    super.key,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.isEncrypted = false,
    this.isImage = false,
    this.imageData,
  });

  @override
  Widget build(BuildContext context) {
    final alignment = isMine ? Alignment.centerRight : Alignment.centerLeft;

    return Align(
      alignment: alignment,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        padding: isImage
            ? const EdgeInsets.all(4)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          gradient: isMine
              ? const LinearGradient(
                  colors: [ShadeColors.violetDark, ShadeColors.violet],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: isMine ? null : ShadeColors.surfaceElevated,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: isMine
                  ? ShadeColors.violet.withOpacity(0.25)
                  : Colors.black.withOpacity(0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (isImage && imageData != null)
              GestureDetector(
                onTap: () {
                  Navigator.of(context).push(
                    PageRouteBuilder(
                      transitionDuration: const Duration(milliseconds: 300),
                      reverseTransitionDuration:
                          const Duration(milliseconds: 300),
                      pageBuilder: (context, animation, secondaryAnimation) =>
                          _FullScreenImage(imageData: imageData!),
                      transitionsBuilder:
                          (context, animation, secondaryAnimation, child) {
                        return FadeTransition(
                          opacity: animation,
                          child: child,
                        );
                      },
                    ),
                  );
                },
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.memory(
                    imageData!,
                    fit: BoxFit.cover,
                    width: MediaQuery.of(context).size.width * 0.6,
                  ),
                ),
              ),
            if (!isImage) ...[
              if (isEncrypted)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.lock_rounded,
                        size: 10,
                        color:
                            (isMine ? Colors.white : ShadeColors.textSecondary)
                                .withOpacity(0.5),
                      ),
                      const SizedBox(width: 3),
                      Text(
                        'E2EE',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8,
                          color: (isMine
                                  ? Colors.white
                                  : ShadeColors.textSecondary)
                              .withOpacity(0.5),
                        ),
                      ),
                    ],
                  ),
                ),
              Text(
                text,
                style: TextStyle(
                  color: isMine ? Colors.white : ShadeColors.textPrimary,
                  fontSize: 15,
                  height: 1.35,
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
                    color: (isMine ? Colors.white : ShadeColors.textSecondary)
                        .withOpacity(0.5),
                  ),
                ),
                if (isMine) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.done_all_rounded,
                    size: 14,
                    color: Colors.white.withOpacity(0.5),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTimestamp(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
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
