import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

const stickerNames = {
  'orbit': 'Орбита',
  'moth': 'Лунный мотылёк',
  'comet': 'Комета',
  'ghost': 'Полуночный гость'
};
const _tones = {
  'orbit': Color(0xff6254a5),
  'moth': Color(0xff346e69),
  'comet': Color(0xffb64d40),
  'ghost': Color(0xff394375)
};

void drawPrint(Canvas canvas, Size size, String id) {
  canvas.save();
  canvas.scale(size.width / 200, size.height / 200);
  final p = Paint();
  final paper = RRect.fromRectAndRadius(
      const Rect.fromLTWH(0, 0, 200, 200), const Radius.circular(20));
  canvas.clipRRect(paper);
  canvas.drawRRect(paper, p..color = Colors.white);
  final face = paper.deflate(3);
  canvas.clipRRect(face);
  canvas.drawRRect(
      face,
      p
        ..shader = ui.Gradient.linear(
            const Offset(20, 0),
            const Offset(165, 200),
            [_tones[id] ?? Colors.grey, const Color(0xff121423)]));
  p.shader = null;
  final rng = math.Random(73);
  for (int i = 0; i < 60; i++) {
    canvas.drawCircle(Offset(rng.nextDouble() * 200, rng.nextDouble() * 200),
        rng.nextDouble() * 1.55, p..color = Colors.white54);
  }
  const gold = Color(0xffffdca8), milk = Color(0xfffff1d7);
  if (id == 'orbit') {
    canvas.drawCircle(const Offset(100, 99), 47, p..color = gold);
    canvas.save();
    canvas.translate(100, 100);
    canvas.rotate(-.4);
    canvas.drawArc(
        const Rect.fromLTWH(-78, -16, 156, 32),
        -.55,
        4.28,
        false,
        p
          ..color = const Color(0xffd6b2ff)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8);
    canvas.restore();
    p.style = PaintingStyle.fill;
  } else if (id == 'moth') {
    for (final sign in [-1.0, 1.0]) {
      canvas.save();
      canvas.translate(100, 99);
      canvas.scale(sign, 1);
      final wing = Path()
        ..moveTo(0, 3)
        ..quadraticBezierTo(30, -48, 76, -47)
        ..quadraticBezierTo(68, -4, 39, 10)
        ..quadraticBezierTo(50, 48, 19, 54)
        ..close();
      canvas.drawPath(wing, p..color = milk);
      canvas.drawCircle(
          const Offset(42, -18), 11, p..color = const Color(0xff429a91));
      canvas.drawCircle(const Offset(42, -18), 5, p..color = gold);
      canvas.restore();
    }
    canvas.drawOval(const Rect.fromLTWH(95, 72, 10, 65), p..color = gold);
  } else if (id == 'comet') {
    final tail = Path()
      ..moveTo(45, 132)
      ..quadraticBezierTo(85, 97, 164, 40)
      ..quadraticBezierTo(136, 99, 71, 152)
      ..close();
    canvas.drawPath(tail, p..color = gold);
    canvas.drawCircle(const Offset(67, 130), 23, p..color = milk);
    canvas.drawCircle(
        const Offset(58, 124), 5, p..color = const Color(0xffcc8979));
  } else {
    final ghost = Path()
      ..moveTo(51, 145)
      ..lineTo(56, 93)
      ..cubicTo(59, 34, 139, 34, 145, 94)
      ..lineTo(152, 145)
      ..quadraticBezierTo(139, 132, 125, 148)
      ..quadraticBezierTo(109, 130, 94, 147)
      ..quadraticBezierTo(75, 132, 51, 145);
    canvas.drawPath(ghost, p..color = milk);
    for (final x in [84.0, 112.0]) {
      canvas.drawOval(
          Rect.fromLTWH(x, 86, 10, 17), p..color = const Color(0xff25283c));
    }
  }
  canvas.restore();
}

class PrintArt extends CustomPainter {
  final String id;
  PrintArt(this.id);
  @override
  void paint(Canvas c, Size s) => drawPrint(c, s, id);
  @override
  bool shouldRepaint(PrintArt old) => id != old.id;
}

Widget stamp(String id, {double size = 58}) =>
    CustomPaint(size: Size.square(size), painter: PrintArt(id));

class VinylViewer extends StatefulWidget {
  final String id;
  final String? note, from;
  const VinylViewer(this.id, {this.note, this.from, super.key});
  @override
  State<VinylViewer> createState() => _VinylState();
}

class _VinylState extends State<VinylViewer> with TickerProviderStateMixin {
  late final clock =
      AnimationController(vsync: this, duration: const Duration(seconds: 6));
  late final spring = AnimationController.unbounded(vsync: this)
    ..addListener(() => setState(() {}));
  static final program =
      ui.FragmentProgram.fromAsset('shaders/holo_sticker.frag');
  ui.FragmentShader? foil;
  late ui.Image print;
  Offset tilt = Offset.zero, origin = Offset.zero, axis = Offset.zero;
  double peel = 0;
  @override
  void initState() {
    super.initState();
    final r = ui.PictureRecorder();
    drawPrint(Canvas(r), const Size.square(256), widget.id);
    final pic = r.endRecording();
    print = pic.toImageSync(256, 256);
    pic.dispose();
    program.then((p) {
      if (mounted) setState(() => foil = p.fragmentShader());
    }).catchError((Object _) {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      clock.stop();
    } else if (!clock.isAnimating) {
      clock.repeat();
    }
  }

  @override
  void dispose() {
    clock.dispose();
    spring.dispose();
    foil?.dispose();
    print.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
      backgroundColor: const Color(0xff141416),
      child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(children: [
              Expanded(
                  child: Text(stickerNames[widget.id] ?? '',
                      style: Theme.of(context).textTheme.titleLarge)),
              CloseButton(onPressed: () => Navigator.pop(context))
            ]),
            LayoutBuilder(builder: (ctx, b) {
              final w = math.min(b.maxWidth, 320.0);
              return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanDown: (d) {
                    spring.stop();
                    spring.value = 1;
                    origin = d.localPosition;
                    tilt = Offset.zero;
                    peel = 0;
                    final x = origin.dx / w, y = origin.dy / w;
                    final edge = [x, 1 - x, y, 1 - y];
                    final min = edge.reduce(math.min);
                    axis = min < .18
                        ? [
                            const Offset(1, 0),
                            const Offset(-1, 0),
                            const Offset(0, 1),
                            const Offset(0, -1)
                          ][edge.indexOf(min)]
                        : Offset.zero;
                  },
                  onPanUpdate: (d) {
                    final delta = (d.localPosition - origin) / w;
                    setState(() {
                      if (axis != Offset.zero) {
                        peel = (delta.dx * axis.dx + delta.dy * axis.dy)
                            .clamp(0, .66);
                      } else {
                        tilt = Offset(delta.dx.clamp(-.55, .55),
                            delta.dy.clamp(-.55, .55));
                      }
                    });
                  },
                  onPanEnd: (_) => release(),
                  onPanCancel: release,
                  child: AnimatedBuilder(
                      animation: clock,
                      builder: (_, child) {
                        final t = clock.value * 2 * math.pi,
                            f = spring.value.clamp(0.0, 1.05);
                        final x = tilt.dx * f +
                                (clock.isAnimating ? 0.025 * math.sin(t) : 0),
                            y = tilt.dy * f;
                        return Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.identity()
                              ..setEntry(3, 2, .0016)
                              ..rotateX(-y)
                              ..rotateY(x),
                            child: Container(
                                width: w,
                                height: w,
                                decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    color: const Color(0xfff4f4f0),
                                    boxShadow: const [
                                      BoxShadow(
                                          color: Colors.black54,
                                          blurRadius: 16,
                                          offset: Offset(0, 5))
                                    ]),
                                child: ClipRRect(
                                    borderRadius: BorderRadius.circular(20),
                                    child: CustomPaint(
                                        foregroundPainter: _Curl(print, foil,
                                            axis, peel * f, x, y, t),
                                        child: Align(
                                            alignment:
                                                Alignment(-axis.dx, -axis.dy),
                                            child: SizedBox(
                                                width:
                                                    axis.dx != 0 ? w * .43 : w,
                                                height:
                                                    axis.dy != 0 ? w * .43 : w,
                                                child: Center(
                                                    child:
                                                        Padding(padding: const EdgeInsets.all(16), child: Text(widget.from == null ? 'SHADE' : 'от @${widget.from} · ${widget.note ?? ''}', textAlign: TextAlign.center, style: const TextStyle(color: Color(0xff423f40)))))))))));
                      }));
            }),
            const SizedBox(height: 14),
            const Text('Поверните за центр или потяните край внутрь.',
                textAlign: TextAlign.center)
          ])));
  void release() {
    if (!mounted) return;
    if (MediaQuery.disableAnimationsOf(context)) {
      spring.value = 0;
    } else {
      spring.animateWith(SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 190, damping: 22),
          1,
          0,
          0));
    }
  }
}

class _Curl extends CustomPainter {
  final ui.Image image;
  final ui.FragmentShader? shader;
  final Offset axis;
  final double peel, x, y, t;
  _Curl(this.image, this.shader, this.axis, this.peel, this.x, this.y, this.t);
  @override
  void paint(Canvas c, Size s) {
    final w = s.width, depth = peel * w;
    final angle = axis == Offset.zero ? 0.0 : math.atan2(axis.dy, axis.dx);
    c.save();
    c.translate(w / 2, w / 2);
    c.rotate(angle);
    c.translate(-w / 2, -w / 2);
    void surface() {
      c.save();
      c.translate(w / 2, w / 2);
      c.rotate(-angle);
      c.translate(-w / 2, -w / 2);
      c.drawImageRect(
          image,
          Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
          Offset.zero & s,
          Paint()..filterQuality = FilterQuality.medium);
      final sh = shader;
      if (sh != null) {
        for (final (i, v) in [w, w, x, y, t].indexed) {
          sh.setFloat(i, v);
        }
        c.drawRect(Offset.zero & s, Paint()..shader = sh);
      } else {
        c.drawRect(
            Offset.zero & s,
            Paint()
              ..shader = ui.Gradient.linear(Offset(w * x, 0), Offset(w, w),
                  [Colors.transparent, Colors.white12, Colors.transparent]));
      }
      c.restore();
    }

    c.save();
    c.clipRect(Rect.fromLTRB(depth, 0, w, w));
    surface();
    c.restore();
    if (depth > .1) {
      final radius = depth / math.pi;
      c.drawRect(
          Rect.fromLTWH(depth, 0, radius * 2, w),
          Paint()
            ..shader = ui.Gradient.linear(
                Offset(depth, 0),
                Offset(depth + radius * 2, 0),
                [Colors.black38, Colors.transparent]));
      // Map parallel strips of the printed face around a half cylinder; back-facing strips expose vinyl backing.
      const n = 32;
      for (int i = 0; i < n; i++) {
        final a = i * math.pi / n, b = (i + 1) * math.pi / n;
        final left = depth - radius * math.sin(a),
            right = depth - radius * math.sin(b);
        final src = depth - i * depth / n;
        final dx = (left - right) / (depth / n);
        if (dx.abs() < .0001) continue;
        c.save();
        c.translate(left, 0);
        c.scale(dx, 1);
        c.translate(-src, 0);
        c.clipRect(Rect.fromLTRB(src - depth / n - .2, 0, src + .2, w));
        if (a < math.pi / 2) {
          surface();
        } else {
          c.drawRect(
              Offset.zero & s,
              Paint()
                ..color = Color.lerp(const Color(0xffaca9ac),
                    const Color(0xfffffff9), -math.cos(a))!);
        }
        c.restore();
      }
    }
    c.restore();
  }

  @override
  bool shouldRepaint(_Curl old) => true;
}
