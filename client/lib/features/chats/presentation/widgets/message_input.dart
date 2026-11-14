import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import 'package:shade/main.dart';

class MessageInput extends StatefulWidget {
  final ValueChanged<String> onSend;
  final ValueChanged<List<int>>? onImageSelected;
  final VoidCallback? onTyping;
  final VoidCallback? onStopTyping;
  const MessageInput(
      {super.key,
      required this.onSend,
      this.onImageSelected,
      this.onTyping,
      this.onStopTyping});
  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  Timer? _stopTypingTimer;
  DateTime? _lastTyping;
  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
      if (hasText) {
        if (_lastTyping == null ||
            DateTime.now().difference(_lastTyping!) >
                const Duration(seconds: 2)) {
          widget.onTyping?.call();
          _lastTyping = DateTime.now();
        }
        _stopTypingTimer?.cancel();
        _stopTypingTimer = Timer(
            const Duration(seconds: 2), () => widget.onStopTyping?.call());
      } else {
        _stopTypingTimer?.cancel();
        widget.onStopTyping?.call();
      }
    });
    _focusNode.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _focusNode.removeListener(_focusChanged);
    _controller.dispose();
    _focusNode.dispose();
    _stopTypingTimer?.cancel();
    super.dispose();
  }

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
  }

  Future<void> _pickImage() async {
    final source = await showModalBottomSheet<ImageSource>(
        context: context,
        showDragHandle: true,
        builder: (ctx) => SafeArea(
            child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Поделиться моментом',
                          style: TextStyle(
                              fontSize: 21, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 8),
                      const Text('Сделайте снимок или выберите готовый.',
                          style: TextStyle(
                              fontSize: 13, color: ShadeColors.textSecondary)),
                      const SizedBox(height: 18),
                      ListTile(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          leading: const Icon(Icons.camera_alt_outlined,
                              color: ShadeColors.violetLight),
                          title: const Text('Камера'),
                          subtitle: const Text('Снять новое фото'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.pop(ctx, ImageSource.camera)),
                      ListTile(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          leading: const Icon(Icons.photo_library_outlined,
                              color: ShadeColors.cyan),
                          title: const Text('Галерея'),
                          subtitle: const Text('Выбрать с устройства'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
                    ]))));
    if (source != null && mounted) await _getImage(source);
  }

  Future<void> _getImage(ImageSource source) async {
    final picker = ImagePicker();
    try {
      final file = await picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 80,
      );
      if (file == null || widget.onImageSelected == null) return;

      // Read and re-encode to strip ALL metadata (EXIF, GPS, camera, etc.)
      final rawBytes = await file.readAsBytes();
      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) return;

      // Re-encode as clean JPEG — no metadata preserved
      final cleanJpeg = img.encodeJpg(decoded, quality: 80);
      if (!mounted) return;
      widget.onImageSelected!(Uint8List.fromList(cleanJpeg));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Не удалось открыть фото. Проверьте разрешения камеры или выберите другое изображение.')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
        decoration: const BoxDecoration(
            color: ShadeColors.black,
            border: Border(top: BorderSide(color: Color(0xFF292929)))),
        child: SafeArea(
            top: false,
            child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                child:
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (widget.onImageSelected != null)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 3, right: 4),
                        child: IconButton(
                            tooltip: 'Прикрепить фото',
                            onPressed: _pickImage,
                            icon: const Icon(Icons.add_rounded,
                                color: ShadeColors.textSecondary, size: 26))),
                  Expanded(
                      child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          decoration: BoxDecoration(
                              color: ShadeColors.surfaceCard,
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                  color: _focusNode.hasFocus
                                      ? ShadeColors.violet.withValues(alpha: .6)
                                      : ShadeColors.greyBorder)),
                          child: TextField(
                              key: const Key('message-field'),
                              controller: _controller,
                              focusNode: _focusNode,
                              maxLines: 5,
                              minLines: 1,
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: TextInputAction.send,
                              style: const TextStyle(
                                  color: ShadeColors.textPrimary,
                                  fontSize: 15,
                                  height: 1.45),
                              decoration: const InputDecoration(
                                  hintText: 'Сообщение',
                                  filled: false,
                                  border: InputBorder.none,
                                  enabledBorder: InputBorder.none,
                                  focusedBorder: InputBorder.none,
                                  contentPadding: EdgeInsets.symmetric(
                                      horizontal: 17, vertical: 13)),
                              onSubmitted: (_) => _handleSend()))),
                  const SizedBox(width: 9),
                  Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: AnimatedContainer(
                          duration: const Duration(milliseconds: 160),
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                              color: _hasText
                                  ? ShadeColors.violetDark
                                  : ShadeColors.surfaceElevated,
                              borderRadius: BorderRadius.circular(18)),
                          child: IconButton(
                              key: const Key('send-message'),
                              tooltip: 'Отправить',
                              onPressed: _hasText ? _handleSend : null,
                              icon: Icon(Icons.arrow_upward_rounded,
                                  size: 24,
                                  color: _hasText
                                      ? Colors.white
                                      : ShadeColors.textMuted)))),
                ]))));
  }
}
