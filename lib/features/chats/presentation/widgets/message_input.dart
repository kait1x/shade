import 'package:flutter/material.dart';
import 'package:shade/main.dart';

/// Floating message input with neon glow border.
class MessageInput extends StatefulWidget {
  final ValueChanged<String> onSend;

  const MessageInput({super.key, required this.onSend});

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput>
    with SingleTickerProviderStateMixin {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  late AnimationController _glowController;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) {
        setState(() => _hasText = hasText);
      }
    });

    _focusNode.addListener(() => setState(() {}));

    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _glowAnimation = Tween<double>(begin: 0.3, end: 0.8).animate(
      CurvedAnimation(parent: _glowController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    _glowController.dispose();
    super.dispose();
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;

    widget.onSend(text);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final isFocused = _focusNode.hasFocus;

    return SafeArea(
      child: AnimatedBuilder(
        animation: _glowAnimation,
        builder: (context, _) {
          final glowOpacity = isFocused ? _glowAnimation.value : 0.15;

          return Container(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              color: ShadeColors.surfaceCard,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(
                color: ShadeColors.violet.withOpacity(glowOpacity),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: ShadeColors.violet.withOpacity(glowOpacity * 0.4),
                  blurRadius: isFocused ? 16 : 8,
                  spreadRadius: isFocused ? 1 : 0,
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    maxLines: 4,
                    minLines: 1,
                    textCapitalization: TextCapitalization.sentences,
                    style: const TextStyle(
                      color: ShadeColors.textPrimary,
                      fontSize: 15,
                    ),
                    cursorColor: ShadeColors.violet,
                    decoration: const InputDecoration(
                      hintText: 'Сообщение...',
                      hintStyle: TextStyle(color: ShadeColors.textMuted),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    onSubmitted: (_) => _handleSend(),
                  ),
                ),
                const SizedBox(width: 4),
                _SendButton(
                  isActive: _hasText,
                  onPressed: _handleSend,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SendButton extends StatelessWidget {
  final bool isActive;
  final VoidCallback onPressed;

  const _SendButton({required this.isActive, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        gradient: isActive
            ? const LinearGradient(
                colors: [ShadeColors.violet, ShadeColors.cyan],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        color: isActive ? null : ShadeColors.surfaceElevated,
        borderRadius: BorderRadius.circular(22),
        boxShadow: isActive
            ? [
                BoxShadow(
                  color: ShadeColors.violet.withOpacity(0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: IconButton(
        onPressed: isActive ? onPressed : null,
        padding: EdgeInsets.zero,
        icon: Icon(
          Icons.send_rounded,
          size: 20,
          color: isActive ? Colors.white : ShadeColors.textMuted,
        ),
      ),
    );
  }
}
