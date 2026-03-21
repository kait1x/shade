import 'package:flutter/material.dart';
import 'package:shade/main.dart';

/// Styled message bubble with gradient and shadow.
class MessageBubble extends StatelessWidget {
  final String text;
  final DateTime timestamp;
  final bool isMine;
  final bool isEncrypted;

  const MessageBubble({
    super.key,
    required this.text,
    required this.timestamp,
    required this.isMine,
    this.isEncrypted = false,
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
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
            if (isEncrypted)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.lock_rounded,
                      size: 10,
                      color: (isMine ? Colors.white : ShadeColors.textSecondary)
                          .withOpacity(0.5),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'E2EE',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                        color:
                            (isMine ? Colors.white : ShadeColors.textSecondary)
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
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTimestamp(timestamp),
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        (isMine ? Colors.white : ShadeColors.textSecondary)
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
