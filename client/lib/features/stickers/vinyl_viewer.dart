import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'aluminium.dart';
import 'vinyl.dart' show loadVinyl, stickerNames;
import 'vinyl_mesh.dart';

enum VinylPhase { attached, peeling, held, returning }

class VinylViewer extends StatefulWidget {
  final String id;
  final String? from, note;
  const VinylViewer(this.id, {this.from, this.note, super.key});
  @override
  State<VinylViewer> createState() => _VinylViewerState();
}

class _VinylViewerState extends State<VinylViewer>
    with TickerProviderStateMixin {
  late final spring = AnimationController.unbounded(vsync: this)
    ..addListener(refresh);
  late final turn = AnimationController.unbounded(vsync: this)
    ..addListener(refresh);
  late final travel = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 560))
    ..addListener(refresh);
  ui.Image? front, back, foldBack;
  String? error;
  VinylPhase phase = VinylPhase.attached;
  Offset axis = const Offset(1, 0), origin = Offset.zero, tilt = Offset.zero;
  double peel = 0, dragTurn = 0;
  bool edge = false, busy = false;
  void refresh() {
    if (mounted) setState(() {});
  }

  bool get reduced => MediaQuery.disableAnimationsOf(context);
  @override
  void initState() {
    super.initState();
    loadVinyl(widget.id).then((image) {
      if (!mounted) {
        image.dispose();
        return;
      }
      front = image;
      back = reverseImage(false);
      foldBack = reverseImage(true);
      refresh();
    }).catchError((Object e) {
      if (mounted) setState(() => error = 'Не удалось загрузить наклейку');
    });
  }

  ui.Image reverseImage(bool folded) {
    final image = front!;
    const n = 768.0;
    final r = ui.PictureRecorder();
    final c = Canvas(r);
    const rect = Rect.fromLTWH(0, 0, n, n);
    c.saveLayer(rect, Paint());
    c.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.linear(Offset.zero, const Offset(700, 768),
              const [Color(0xfffaf9f4), Color(0xffe2dfd5)]));
    final random = math.Random(3),
        ink = Paint()..color = const Color(0x105d574e);
    for (var i = 0; i < 2000; i++) {
      c.drawCircle(
          Offset(random.nextDouble() * n, random.nextDouble() * n), .7, ink);
    }
    c.save();
    if (folded) {
      c.translate(n / 2, n / 2);
      c.rotate(math.atan2(axis.dy, axis.dx));
      c.scale(-1, 1);
      c.translate(-n / 2, -n / 2);
    }
    final width = folded ? n * .35 : n * .57;
    final text = TextPainter(
        text: TextSpan(
            children: [
              TextSpan(
                  text: widget.from == null ? 'SHADE' : 'от @${widget.from}',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: folded ? 25 : 42)),
              TextSpan(
                  text:
                      '\n\n${widget.note?.isNotEmpty == true ? widget.note! : "На память"}',
                  style: TextStyle(fontSize: folded ? 22 : 34, height: 1.45))
            ],
            style: const TextStyle(
                fontFamily: 'Roboto', color: Color(0xff484338))),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.center,
        maxLines: 12,
        ellipsis: '…')
      ..layout(minWidth: width, maxWidth: width);
    text.paint(
        c, Offset(folded ? n * .12 : (n - width) / 2, (n - text.height) / 2));
    c.restore();
    c.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        rect,
        Paint()..blendMode = BlendMode.dstIn);
    c.restore();
    final pic = r.endRecording();
    final result = pic.toImageSync(768, 768);
    pic.dispose();
    return result;
  }

  Future<void> detach() async {
    if (busy || front == null || phase == VinylPhase.held) return;
    busy = true;
    phase = VinylPhase.peeling;
    final start = peel;
    travel.value = 0;
    final animation = Tween<double>(begin: start, end: .85)
        .animate(CurvedAnimation(parent: travel, curve: Curves.easeInOutCubic));
    void tick() {
      peel = animation.value;
      refresh();
    }

    travel.addListener(tick);
    if (reduced) {
      travel.value = 1;
    } else {
      await travel.forward();
    }
    travel.removeListener(tick);
    if (!mounted) return;
    setState(() {
      phase = VinylPhase.held;
      peel = 0;
      tilt = Offset.zero;
      turn.value = 0;
    });
    busy = false;
  }

  Future<void> attach() async {
    if (busy || phase != VinylPhase.held) return;
    busy = true;
    phase = VinylPhase.returning;
    await turn.animateTo(0,
        duration: Duration(milliseconds: reduced ? 0 : 280),
        curve: Curves.easeOut);
    if (!mounted) return;
    if (reduced) {
      travel.value = 0;
    } else {
      await travel.reverse();
    }
    if (!mounted) return;
    setState(() {
      phase = VinylPhase.attached;
      peel = 0;
      tilt = Offset.zero;
      spring.value = 0;
    });
    busy = false;
  }

  void release() {
    if (phase == VinylPhase.held) return;
    if (edge && peel > .35) {
      detach();
      return;
    }
    if (reduced) {
      spring.value = 0;
      return;
    }
    spring.animateWith(SpringSimulation(
        const SpringDescription(mass: 1, stiffness: 170, damping: 22),
        1,
        0,
        0));
  }

  @override
  void dispose() {
    spring.dispose();
    turn.dispose();
    travel.dispose();
    front?.dispose();
    back?.dispose();
    foldBack?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final held = phase == VinylPhase.held || phase == VinylPhase.returning;
    final backside = math.cos(turn.value) < 0;
    return Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        backgroundColor: const Color(0xff151516),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: SingleChildScrollView(
            padding: const EdgeInsets.all(18),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Row(children: [
                Expanded(
                    child: Text(stickerNames[widget.id] ?? '',
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w600))),
                CloseButton(onPressed: () => Navigator.pop(context))
              ]),
              const SizedBox(height: 14),
              LayoutBuilder(builder: (ctx, b) {
                final w = b.maxWidth;
                return SizedBox.square(
                    dimension: w,
                    child: Stack(clipBehavior: Clip.none, children: [
                      Positioned(
                          left: 0,
                          right: 0,
                          top: w * .18,
                          height: w * .69,
                          child: const ReferenceLid()),
                      GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onPanDown: busy
                              ? null
                              : (d) {
                                  origin = d.localPosition;
                                  if (held) {
                                    turn.stop();
                                    dragTurn = turn.value;
                                    return;
                                  }
                                  spring.stop();
                                  spring.value = 1;
                                  peel = 0;
                                  tilt = Offset.zero;
                                  final p =
                                          (origin - Offset(w * .21, w * .235)) /
                                              (w * .58),
                                      h = p.dx < .2
                                          ? 1.0
                                          : p.dx > .8
                                              ? -1.0
                                              : 0.0,
                                      v = p.dy < .2
                                          ? 1.0
                                          : p.dy > .8
                                              ? -1.0
                                              : 0.0;
                                  edge = h != 0 || v != 0;
                                  if (edge) {
                                    axis = Offset(h, v) / Offset(h, v).distance;
                                    foldBack?.dispose();
                                    foldBack = reverseImage(true);
                                  }
                                },
                          onPanUpdate: busy
                              ? null
                              : (d) {
                                  final delta = (d.localPosition - origin) / w;
                                  setState(() {
                                    if (held) {
                                      turn.value =
                                          dragTurn + delta.dx * math.pi * 2;
                                      tilt = Offset(0, delta.dy.clamp(-.9, .9));
                                    } else if (edge) {
                                      peel = (delta.dx * axis.dx +
                                              delta.dy * axis.dy)
                                          .clamp(0, .8);
                                    } else {
                                      tilt = Offset(delta.dx.clamp(-.45, .45),
                                          delta.dy.clamp(-.45, .45));
                                    }
                                  });
                                },
                          onPanEnd: busy ? null : (_) => release(),
                          onPanCancel: busy ? null : release,
                          child: SizedBox.square(
                              dimension: w,
                              child: front == null
                                  ? Center(
                                      child: error == null
                                          ? const CircularProgressIndicator()
                                          : Text(error!))
                                  : held
                                      ? Transform(
                                          alignment: Alignment.center,
                                          transform: Matrix4.identity()
                                            ..setEntry(3, 2, .0013)
                                            ..translate(
                                                0.0,
                                                -w * .1 * travel.value,
                                                40 * travel.value)
                                            ..rotateX(-tilt.dy)
                                            ..rotateY(turn.value),
                                          child: Transform(
                                              alignment: Alignment.center,
                                              transform: Matrix4.identity()
                                                ..rotateY(
                                                    backside ? math.pi : 0),
                                              child: CustomPaint(
                                                  painter: LooseVinyl(
                                                      backside ? back! : front!,
                                                      backside,
                                                      travel.value),
                                                  size: Size.square(w))))
                                      : Transform(
                                          alignment: Alignment.center,
                                          transform: Matrix4.identity()
                                            ..setEntry(3, 2, .0012)
                                            ..rotateY(tilt.dx * spring.value)
                                            ..rotateX(-tilt.dy * spring.value),
                                          child: CustomPaint(
                                              foregroundPainter: VinylMesh(
                                                  front!,
                                                  foldBack!,
                                                  axis,
                                                  peel *
                                                      (busy
                                                          ? 1
                                                          : spring.value
                                                              .clamp(0, 1.0)),
                                                  tilt),
                                              size: Size.square(w))))),
                    ]));
              }),
              const SizedBox(height: 12),
              Text(
                  held
                      ? (backside ? 'Обратная сторона' : 'Лицевая сторона')
                      : 'Потяните край внутрь, чтобы снять наклейку',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xffa5a5aa)),
                  textAlign: TextAlign.center),
              const SizedBox(height: 12),
              Wrap(alignment: WrapAlignment.center, spacing: 8, children: [
                if (held)
                  OutlinedButton.icon(
                      onPressed: busy
                          ? null
                          : () => turn.animateTo(turn.value + math.pi,
                              duration:
                                  Duration(milliseconds: reduced ? 0 : 500),
                              curve: Curves.easeInOutCubic),
                      icon: const Icon(Icons.flip, size: 18),
                      label: const Text('Перевернуть')),
                FilledButton.icon(
                    onPressed: busy || front == null
                        ? null
                        : held
                            ? attach
                            : detach,
                    icon: Icon(held ? Icons.check : Icons.open_with, size: 18),
                    label: Text(held ? 'Приклеить обратно' : 'Отклеить'))
              ])
            ])));
  }
}

class LooseVinyl extends CustomPainter {
  final ui.Image image;
  final bool back;
  final double lift;
  LooseVinyl(this.image, this.back, this.lift);
  @override
  void paint(Canvas c, Size s) {
    final rect = Rect.fromLTWH(
            s.width * .07, s.height * .07, s.width * .86, s.height * .86),
        src = Rect.fromLTWH(
            0, 0, image.width.toDouble(), image.height.toDouble());
    c.save();
    c.translate(0, 8 + lift * 9);
    c.drawImageRect(
        image,
        src,
        rect,
        Paint()
          ..colorFilter =
              const ColorFilter.mode(Color(0x38000000), BlendMode.srcIn)
          ..imageFilter = ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10));
    c.restore();
    c.saveLayer(Offset.zero & s, Paint());
    c.drawImageRect(
        image, src, rect, Paint()..filterQuality = FilterQuality.high);
    c.drawRect(
        rect,
        Paint()
          ..blendMode = BlendMode.srcATop
          ..shader = ui.Gradient.linear(
              rect.topLeft,
              rect.bottomRight,
              const [Colors.transparent, Color(0x20ffffff), Colors.transparent],
              [0, .45, 1]));
    c.restore();
  }

  @override
  bool shouldRepaint(LooseVinyl old) =>
      old.image != image || old.lift != lift || old.back != back;
}
