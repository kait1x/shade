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
                    MaterialPageRoute(
                      builder: (_) => _FullScreenImage(imageData: imageData!),
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
            else ...[
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
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.download_rounded, color: Colors.white),
            onPressed: () => _saveImage(context),
          ),
        ],
      ),
      body: Center(
        child: InteractiveViewer(
          child: Image.memory(imageData),
        ),
      ),
    );
  }

  Future<void> _saveImage(BuildContext context) async {
    try {
      // Save to temp file first, then to gallery
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/shade_${DateTime.now().millisecondsSinceEpoch}.jpg');
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
