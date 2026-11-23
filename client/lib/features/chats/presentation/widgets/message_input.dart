import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shade/core/services/message_image.dart';
import 'package:shade/core/theme/shade_theme.dart';

class MessageInput extends StatefulWidget {
  final FutureOr<void> Function(String) onSend;
  final int maxLines;
  final FutureOr<void> Function(List<int>)? onImageSelected;
  final VoidCallback? onVoiceRecord;
  final VoidCallback? onShareLocation;
  final VoidCallback? onTyping;
  final VoidCallback? onStopTyping;
  const MessageInput(
      {super.key,
      required this.onSend,
      this.maxLines = 5,
      this.onImageSelected,
      this.onVoiceRecord,
      this.onShareLocation,
      this.onTyping,
      this.onStopTyping});
  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  bool _sending = false;
  bool _picking = false;
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

  Future<void> _handleSend() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending || _picking) return;
    setState(() => _sending = true);
    final original = _controller.text;
    try {
      await widget.onSend(text);
      if (!mounted) return;
      ShadeMotion.selection(context);
      // Do not erase edits made while encryption/storage was in progress.
      if (_controller.text == original) _controller.clear();
      _focusNode.requestFocus();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text(
                'Не удалось отправить. Текст сохранён — попробуйте ещё раз.')));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _pickImage() async {
    if (_picking || _sending) return;
    final source = await showModalBottomSheet<ImageSource>(
        context: context,
        sheetAnimationStyle: ShadeMotion.sheet(context),
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
                      Text('Сделайте снимок или выберите готовый.',
                          style: TextStyle(
                              fontSize: 13,
                              color: context
                                  .shadeColor(ShadeColors.textSecondary))),
                      const SizedBox(height: 18),
                      ListTile(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          leading: Icon(Icons.camera_alt_outlined,
                              color:
                                  context.shadeColor(ShadeColors.violetLight)),
                          title: const Text('Камера'),
                          subtitle: const Text('Снять новое фото'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.pop(ctx, ImageSource.camera)),
                      ListTile(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16)),
                          leading: Icon(Icons.photo_library_outlined,
                              color: context.shadeColor(ShadeColors.cyan)),
                          title: const Text('Галерея'),
                          subtitle: const Text('Выбрать с устройства'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                          onTap: () => Navigator.pop(ctx, ImageSource.gallery)),
                      if (widget.onShareLocation != null)
                        ListTile(
                          leading: const Icon(Icons.location_on_outlined),
                          title: const Text('Геопозиция'),
                          onTap: () {
                            Navigator.pop(ctx);
                            widget.onShareLocation?.call();
                          },
                        ),
                    ]))));
    if (source != null && mounted) await _getImage(source);
  }

  Future<void> _getImage(ImageSource source) async {
    final picker = ImagePicker();
    try {
      setState(() => _picking = true);
      final file = await picker.pickImage(
        source: source,
        maxWidth: 1280,
        maxHeight: 1280,
        imageQuality: 80,
      );
      if (file == null || widget.onImageSelected == null || !mounted) return;

      final rawBytes = await file.readAsBytes();
      if (rawBytes.length > 20 * 1024 * 1024) {
        throw const FormatException('Выберите фото до 20 МБ');
      }
      final cleanJpeg = await compute(prepareMessageImage, rawBytes);
      if (!mounted) return;
      await widget.onImageSelected!(cleanJpeg);
    } catch (e) {
      // Honest diagnostics: the real exception reaches the console; the user
      // text matches the source (camera permission vs a bad gallery file).
      debugPrint('shade: chat photo pick failed: $e');
      if (mounted) {
        final message = e is FormatException
            ? (e.message == 'Invalid image'
                ? 'Формат не поддерживается. Выберите JPEG, PNG или WebP.'
                : e.message)
            : source == ImageSource.camera
                ? 'Не удалось сделать снимок. Проверьте разрешения камеры и попробуйте снова.'
                : 'Не удалось открыть изображение. Попробуйте другой файл.';
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
        decoration: BoxDecoration(
            color: context.shadeColor(ShadeColors.black),
            border: Border(top: BorderSide(color: Color(0xFF29292D)))),
        child: SafeArea(
            top: false,
            child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
                child:
                    Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  if (widget.onImageSelected != null)
                    Padding(
                        padding: const EdgeInsets.only(bottom: 3, right: 4),
                        child: IconButton(
                            tooltip: 'Прикрепить фото',
                            onPressed: _picking || _sending ? null : _pickImage,
                            icon: Icon(Icons.add_rounded,
                                color: context
                                    .shadeColor(ShadeColors.textSecondary),
                                size: 26))),
                  if (widget.onVoiceRecord != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3, right: 4),
                      child: IconButton(
                        tooltip: 'Голосовое сообщение',
                        onPressed:
                            _picking || _sending ? null : widget.onVoiceRecord,
                        icon: const Icon(Icons.mic_none_rounded),
                      ),
                    ),
                  Expanded(
                      child: AnimatedContainer(
                          duration: ShadeMotion.duration(context, 160),
                          decoration: BoxDecoration(
                              color:
                                  context.shadeColor(ShadeColors.surfaceCard),
                              borderRadius: BorderRadius.circular(22),
                              border: Border.all(
                                  color: _focusNode.hasFocus
                                      ? context
                                          .shadeColor(const Color(0xFF626267))
                                      : context
                                          .shadeColor(ShadeColors.greyBorder))),
                          child: TextField(
                              key: const Key('message-field'),
                              controller: _controller,
                              focusNode: _focusNode,
                              maxLines: widget.maxLines,
                              keyboardType: TextInputType.multiline,
                              minLines: 1,
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: TextInputAction.newline,
                              style: TextStyle(
                                  color: context
                                      .shadeColor(ShadeColors.textPrimary),
                                  fontSize: 16,
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
                          duration: ShadeMotion.duration(context, 160),
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                              color: _hasText
                                  ? context.shadeColor(ShadeColors.textPrimary)
                                  : context
                                      .shadeColor(ShadeColors.surfaceElevated),
                              borderRadius: BorderRadius.circular(17)),
                          child: IconButton(
                              key: const Key('send-message'),
                              tooltip: 'Отправить',
                              onPressed: _hasText && !_sending && !_picking
                                  ? _handleSend
                                  : null,
                              icon: _sending || _picking
                                  ? const SizedBox.square(
                                      dimension: 19,
                                      child: ShadeLoadingIndicator(
                                          strokeWidth: 2,
                                          color: Color(0xFF8E8E93)))
                                  : Icon(Icons.arrow_upward_rounded,
                                      size: 24,
                                      color: _hasText
                                          ? context
                                              .shadeColor(ShadeColors.black)
                                          : context.shadeColor(
                                              ShadeColors.textMuted))))),
                ]))));
  }
}
