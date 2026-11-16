import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shade/core/widgets/avatar_frame.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/core/widgets/shade_motion.dart';

import 'package:shade/features/profile/presentation/avatar_crop.dart';

// Local tokens keep the existing screens' palette intact.
const _surface = Color(0xFF111113),
    _border = Color(0xFF29292D),
    _text = Color(0xFFF5F5F7),
    _secondary = Color(0xFF8E8E93);

/// Mirrors the Android avatar editor with the same crop, frames and texts,
/// but saves through the alpha profile adapter (encrypted local state) while
/// the device-v2 profile contract is missing. The crop pipeline is the
/// shared Android one: decode limits, 512x512 export, EXIF-free re-encode.
class AlphaAvatarEditor extends StatefulWidget {
  final Uint8List? initialImage;
  final String initialName;
  final AvatarFrame initialFrame;
  final Future<void> Function({
    required AvatarFrame frame,
    required bool replaceImage,
    Uint8List? image,
  }) save;
  // Optional injection uses the same gallery flow in deterministic tests.
  final Future<XFile?> Function()? pickImage;
  const AlphaAvatarEditor(
      {super.key,
      required this.initialImage,
      required this.initialName,
      required this.initialFrame,
      required this.save,
      this.pickImage});
  @override
  State<AlphaAvatarEditor> createState() => _AlphaAvatarEditorState();
}

class _AlphaAvatarEditorState extends State<AlphaAvatarEditor> {
  late AvatarFrame _frame = widget.initialFrame;
  ui.Image? _source;
  AvatarCrop? _crop;
  bool _removed = false,
      _busy = false,
      _picking = false,
      _preview = false,
      _saved = false;
  double _startZoom = 1;
  String? _error;
  bool get _locked => _busy || _picking;
  bool get _changed =>
      _source != null || _removed || _frame != widget.initialFrame;
  @override
  void dispose() {
    _source?.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    if (_locked) return;
    setState(() {
      _picking = true;
      _error = null;
    });
    try {
      final file = await (widget.pickImage?.call() ??
          ImagePicker().pickImage(
              source: ImageSource.gallery, requestFullMetadata: false));
      if (file == null || !mounted) return;
      if (await file.length() > 10 * 1024 * 1024) {
        throw const FormatException('Выберите фотографию до 10 МБ');
      }
      final source = await decodeAvatarSource(await file.readAsBytes());
      if (!mounted) {
        source.dispose();
        return;
      }
      final previous = _source;
      setState(() {
        _source = source;
        _crop =
            AvatarCrop(Size(source.width.toDouble(), source.height.toDouble()));
        _removed = false;
        _preview = false;
      });
      // Let the previous painter leave the render tree before releasing its image.
      WidgetsBinding.instance.addPostFrameCallback((_) => previous?.dispose());
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error =
            'Не удалось открыть фото. Проверьте доступ к галерее и попробуйте ещё раз.');
      }
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    if (_locked || !_changed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      Uint8List? bytes;
      if (_source != null && !_removed) {
        bytes = await exportAvatarCrop(_source!, _crop!.rect);
        if (bytes.length > 512 * 1024) {
          throw const FormatException(
              'Изображение получилось слишком большим. Попробуйте другой кадр.');
        }
      }
      await widget.save(
          frame: _frame,
          replaceImage: _removed || _source != null,
          image: bytes);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _saved = true;
      });
      Navigator.pop(context, true);
    } on FormatException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(
            () => _error = 'Не удалось сохранить. Проверьте сеть и повторите.');
      }
    } finally {
      if (mounted && !_saved) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_locked) return;
    if (_changed) {
      final discard = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
                  title: const Text('Отменить изменения?'),
                  content: const Text('Текущий аватар останется прежним.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Продолжить')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Не сохранять'))
                  ]));
      if (discard != true || !mounted) return;
    }
    if (mounted) {
      setState(() => _saved = true);
      Navigator.pop(context);
    }
  }

  void _remove() {
    if (_locked) return;
    setState(() {
      _removed = true;
      _preview = false;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = !_removed &&
        (_source != null || widget.initialImage != null);
    return PopScope(
        canPop: _saved || (!_changed && !_locked),
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop && !_locked) _close();
        },
        child: Scaffold(
            backgroundColor: Colors.black,
            appBar: AppBar(
                backgroundColor: Colors.black,
                surfaceTintColor: Colors.transparent,
                leading: IconButton(
                    tooltip: 'Закрыть',
                    onPressed: _locked ? null : _close,
                    icon: const Icon(Icons.close_rounded)),
                title: const Text('Аватар',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: _text))),
            body: SafeArea(
                top: false,
                child: LayoutBuilder(
                    builder: (context, bounds) => Center(
                        child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: Column(children: [
                              Expanded(
                                  child: SingleChildScrollView(
                                      padding: const EdgeInsets.fromLTRB(
                                          24, 12, 24, 24),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.stretch,
                                          children: [
                                            const Text('Ваш образ в Shade',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                    color: _text,
                                                    fontSize: 24,
                                                    fontWeight: FontWeight.w600,
                                                    letterSpacing: -.5)),
                                            const SizedBox(height: 8),
                                            const Text(
                                                'Фото и рамка для профиля и переписок',
                                                textAlign: TextAlign.center,
                                                style: TextStyle(
                                                    color: _secondary,
                                                    fontSize: 13,
                                                    height: 1.5)),
                                            const SizedBox(height: 28),
                                            LayoutBuilder(
                                                builder: (context, area) {
                                              final side = math.min(
                                                  280.0, area.maxWidth);
                                              return Center(
                                                  child: _avatarPreview(side));
                                            }),
                                            const SizedBox(height: 16),
                                            Text(
                                                _source != null && !_removed
                                                    ? (_preview
                                                        ? 'Предпросмотр результата'
                                                        : 'Перемещайте фото и меняйте масштаб')
                                                    : 'Виден пользователям Shade',
                                                textAlign: TextAlign.center,
                                                style: const TextStyle(
                                                    color: _secondary,
                                                    fontSize: 12,
                                                    height: 1.5)),
                                            if (_source != null &&
                                                !_removed) ...[
                                              const SizedBox(height: 12),
                                              Row(children: [
                                                const Icon(Icons.remove_rounded,
                                                    color: _secondary,
                                                    size: 18),
                                                Expanded(
                                                    child: Slider(
                                                        value: _crop!.zoom,
                                                        min: 1,
                                                        max: 4,
                                                        label:
                                                            '${_crop!.zoom.toStringAsFixed(1)}×',
                                                        onChanged: _locked ||
                                                                _preview
                                                            ? null
                                                            : (v) => setState(
                                                                () => _crop!
                                                                    .setZoom(
                                                                        v)),
                                                        activeColor: _text,
                                                        inactiveColor:
                                                            _border)),
                                                const Icon(Icons.add_rounded,
                                                    color: _secondary,
                                                    size: 18)
                                              ]),
                                              Wrap(
                                                  alignment:
                                                      WrapAlignment.center,
                                                  spacing: 12,
                                                  children: [
                                                    TextButton(
                                                        onPressed: _locked
                                                            ? null
                                                            : () => setState(
                                                                () => _preview =
                                                                    !_preview),
                                                        child: Text(_preview
                                                            ? 'Кадрировать'
                                                            : 'Предпросмотр')),
                                                    TextButton(
                                                        onPressed: _locked
                                                            ? null
                                                            : () =>
                                                                setState(() {
                                                                  _crop = AvatarCrop(
                                                                      _crop!
                                                                          .source);
                                                                  _preview =
                                                                      false;
                                                                }),
                                                        child: const Text(
                                                            'Сбросить'))
                                                  ]),
                                            ],
                                            const SizedBox(height: 16),
                                            OutlinedButton.icon(
                                                onPressed:
                                                    _locked ? null : _pick,
                                                icon: _picking
                                                    ? const SizedBox.square(
                                                        dimension: 18,
                                                        child:
                                                            ShadeLoadingIndicator(
                                                                strokeWidth: 2))
                                                    : const Icon(
                                                        Icons
                                                            .photo_library_outlined,
                                                        size: 19),
                                                label: Text(hasImage
                                                    ? 'Выбрать другое фото'
                                                    : 'Выбрать фото'),
                                                style: OutlinedButton.styleFrom(
                                                    minimumSize:
                                                        const Size.fromHeight(
                                                            48),
                                                    side: const BorderSide(
                                                        color: _border),
                                                    foregroundColor: _text)),
                                            const SizedBox(height: 28),
                                            const Text('ОФОРМЛЕНИЕ',
                                                style: TextStyle(
                                                    color: _secondary,
                                                    fontSize: 11,
                                                    fontWeight: FontWeight.w600,
                                                    letterSpacing: 1.4)),
                                            const SizedBox(height: 12),
                                            LayoutBuilder(
                                                builder:
                                                    (context, area) => Wrap(
                                                            spacing: 8,
                                                            runSpacing: 8,
                                                            children: [
                                                              for (final frame
                                                                  in AvatarFrame
                                                                      .values)
                                                                SizedBox(
                                                                    width: (area.maxWidth -
                                                                            8) /
                                                                        2,
                                                                    child: _frameOption(
                                                                        frame))
                                                            ])),
                                            if (hasImage) ...[
                                              const SizedBox(height: 14),
                                              TextButton.icon(
                                                  onPressed:
                                                      _locked ? null : _remove,
                                                  icon: const Icon(
                                                      Icons
                                                          .delete_outline_rounded,
                                                      size: 18),
                                                  label: const Text(
                                                      'Удалить фото'),
                                                  style: TextButton.styleFrom(
                                                      foregroundColor:
                                                          _secondary))
                                            ],
                                            if (_error != null) ...[
                                              const SizedBox(height: 14),
                                              Semantics(
                                                  liveRegion: true,
                                                  child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              14),
                                                      decoration: BoxDecoration(
                                                          color: _surface,
                                                          borderRadius:
                                                              BorderRadius
                                                                  .circular(14),
                                                          border: Border.all(
                                                              color:
                                                                  _border)),
                                                      child: Text(_error!,
                                                          style:
                                                              const TextStyle(
                                                                  color: _text,
                                                                  fontSize: 13,
                                                                  height:
                                                                      1.5))))
                                            ],
                                          ]))),
                              Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(24, 12, 24, 16),
                                  child: SizedBox(
                                      width: double.infinity,
                                      child: FilledButton(
                                          onPressed: _locked || !_changed
                                              ? null
                                              : _save,
                                          style: FilledButton.styleFrom(
                                              backgroundColor: _text,
                                              foregroundColor: Colors.black,
                                              minimumSize:
                                                  const Size.fromHeight(50)),
                                          child: _busy
                                              ? Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.center,
                                                  children: [
                                                      const SizedBox.square(
                                                          dimension: 16,
                                                          child:
                                                              ShadeLoadingIndicator(
                                                                  strokeWidth:
                                                                      2,
                                                                  color: Colors
                                                                      .black)),
                                                      const SizedBox(width: 10),
                                                      const Text('Сохраняем…')
                                                    ])
                                              : const Text('Сохранить',
                                                  style: TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600))))),
                            ])))))));
  }

  Widget _avatarPreview(double side) => SizedBox.square(
      dimension: side,
      child: Material(
          type: MaterialType.transparency,
          child: _source != null && !_removed
              ? AvatarFrameDecoration(
                  frame: _frame,
                  size: side,
                  child: _cropView(side -
                      2 * AvatarFrameDecoration.inset(_frame, side)))
              : AvatarView(
                  name: widget.initialName,
                  image: _removed ? null : widget.initialImage,
                  frame: _frame,
                  size: side)));

  Widget _frameOption(AvatarFrame frame) {
    final selected = frame == _frame;
    final label = switch (frame) {
      AvatarFrame.none => 'None',
      AvatarFrame.minimal => 'Minimal',
      AvatarFrame.silver => 'Silver',
      AvatarFrame.graphite => 'Graphite'
    };
    return Semantics(
        selected: selected,
        button: true,
        label: 'Рамка $label',
        child: Material(
            color: Colors.transparent,
            child: InkWell(
                onTap: _locked
                    ? null
                    : () {
                        if (_frame == frame) return;
                        ShadeMotion.selection(context);
                        setState(() => _frame = frame);
                      },
                borderRadius: BorderRadius.circular(14),
                child: AnimatedContainer(
                    duration: ShadeMotion.duration(context, 180),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                        color: selected ? _surface : Colors.black,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color:
                                selected ? const Color(0xFF77777E) : _border)),
                    child: Row(children: [
                      SizedBox.square(
                          dimension: 32,
                          child: _source != null && !_removed
                              ? AvatarFrameDecoration(
                                  frame: frame,
                                  size: 32,
                                  child: ClipOval(
                                      child: CustomPaint(
                                          painter: _CropPainter(
                                              _source!, _crop!.rect, true))))
                              : AvatarView(
                                  name: widget.initialName,
                                  size: 32,
                                  frame: frame,
                                  image: _removed
                                      ? null
                                      : widget.initialImage)),
                      const SizedBox(width: 8),
                      Expanded(
                          child: Text(label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style:
                                  const TextStyle(fontSize: 12, color: _text))),
                      if (selected)
                        const Icon(Icons.check_rounded, size: 14, color: _text)
                    ])))));
  }

  Widget _cropView(double side) => Focus(
      autofocus: true,
      onKeyEvent: (_, event) {
        if (_locked || _preview || event is! KeyDownEvent) {
          return KeyEventResult.ignored;
        }
        final delta = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowLeft => const Offset(-8, 0),
          LogicalKeyboardKey.arrowRight => const Offset(8, 0),
          LogicalKeyboardKey.arrowUp => const Offset(0, -8),
          LogicalKeyboardKey.arrowDown => const Offset(0, 8),
          _ => null
        };
        if (delta == null) return KeyEventResult.ignored;
        setState(() => _crop!.pan(delta, side));
        return KeyEventResult.handled;
      },
      child: Semantics(
          label:
              'Круглое кадрирование. Перемещайте фото одним пальцем, масштабируйте двумя.',
          child: GestureDetector(
              key: const ValueKey('avatar-crop'),
              onScaleStart:
                  _locked || _preview ? null : (_) => _startZoom = _crop!.zoom,
              onScaleUpdate: _locked || _preview
                  ? null
                  : (d) => setState(() {
                        _crop!.setZoom(_startZoom * d.scale);
                        _crop!.pan(d.focalPointDelta, side);
                      }),
              child: ClipOval(
                  clipBehavior: Clip.antiAlias,
                  child: CustomPaint(
                      painter: _CropPainter(_source!, _crop!.rect, _preview),
                      size: Size.square(side))))));
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final Rect crop;
  final bool preview;
  _CropPainter(this.image, this.crop, this.preview);
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawColor(_surface, BlendMode.src);
    canvas.drawImageRect(image, crop, Offset.zero & size,
        Paint()..filterQuality = FilterQuality.high);
    if (!preview) {
      final paint = Paint()
        ..color = Colors.white.withValues(alpha: .2)
        ..strokeWidth = .7;
      for (final n in [1, 2]) {
        final p = n / 3;
        canvas.drawLine(Offset(size.width * p, 0),
            Offset(size.width * p, size.height), paint);
        canvas.drawLine(Offset(0, size.height * p),
            Offset(size.width, size.height * p), paint);
      }
      canvas.drawCircle(
          size.center(Offset.zero),
          size.width / 2 - .75,
          Paint()
            ..color = Colors.white.withValues(alpha: .5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.crop != crop || old.preview != preview;
}
