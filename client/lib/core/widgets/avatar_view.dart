import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'avatar_frame.dart';
import 'local_avatar_stub.dart' if (dart.library.io) 'local_avatar_native.dart'
    as local;
export 'avatar_frame.dart';

/// A single renderer for profile, chat, contact and editor avatars.
class AvatarView extends StatelessWidget {
  final String name;
  final double size;
  final Uint8List? image;
  final String? imageUrl, localPath;
  final AvatarFrame frame;
  final bool online, saved, loading;
  const AvatarView(
      {super.key,
      required this.name,
      this.size = 52,
      this.image,
      this.imageUrl,
      this.localPath,
      this.frame = AvatarFrame.none,
      this.online = false,
      this.saved = false,
      this.loading = false});
  @override
  Widget build(BuildContext context) {
    final trimmed = name.trim();
    final fallback = ColoredBox(
        color: const Color(0xFF202023),
        child: Center(
            child: saved
                ? Icon(Icons.bookmark_rounded,
                    size: size * .43, color: const Color(0xFFF5F5F7))
                : Text(
                    trimmed.isEmpty
                        ? '?'
                        : trimmed.characters.first.toUpperCase(),
                    textScaler: TextScaler.noScaling,
                    style: TextStyle(
                        fontSize: size * .38,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFF5F5F7)))));
    ImageProvider? provider;
    if (!saved) {
      if (image != null) {
        provider = MemoryImage(image!);
      } else if (localPath != null) {
        provider = local.avatarImage(localPath!);
      } else if (imageUrl?.isNotEmpty == true) {
        provider = NetworkImage(imageUrl!);
      }
    }
    final badge = math.max(8.0, size * .19);
    return Semantics(
        label: saved ? 'Избранное' : 'Аватар $name${online ? ', в сети' : ''}',
        image: true,
        child: SizedBox.square(
            dimension: size,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(
                  child: AvatarFrameDecoration(
                      frame: frame,
                      size: size,
                      child: ClipOval(
                          clipBehavior: Clip.antiAlias,
                          child: provider == null
                              ? fallback
                              : Image(
                                  image: ResizeImage.resizeIfNeeded(
                                      (size *
                                              MediaQuery.devicePixelRatioOf(
                                                  context))
                                          .ceil(),
                                      null,
                                      provider),
                                  fit: BoxFit.cover,
                                  filterQuality: FilterQuality.high,
                                  gaplessPlayback: false,
                                  errorBuilder: (_, __, ___) => fallback,
                                  frameBuilder: (_, child, frame, sync) =>
                                      sync || frame != null
                                          ? child
                                          : Stack(
                                              fit: StackFit.expand,
                                              children: [
                                                  fallback,
                                                  _loader(size)
                                                ]))))),
              if (loading) Positioned.fill(child: _loader(size)),
              if (online && !saved)
                Positioned(
                    right: size * .025,
                    bottom: size * .025,
                    child: Container(
                        width: badge,
                        height: badge,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFF72B58B),
                            border: Border.all(
                                color: Colors.black,
                                width: math.max(1.5, size * .025))))),
            ])));
  }

  Widget _loader(double size) => Center(
      child: SizedBox.square(
          dimension: math.min(18, size * .3),
          child: const ShadeLoadingIndicator(
              strokeWidth: 1.5, color: Color(0xFF8E8E93))));
}

/// The editor and final avatars use exactly the same frame geometry.
class AvatarFrameDecoration extends StatelessWidget {
  final AvatarFrame frame;
  final double size;
  final Widget child;
  const AvatarFrameDecoration(
      {super.key,
      required this.frame,
      required this.size,
      required this.child});
  static double inset(AvatarFrame frame, double size) {
    final width = switch (frame) {
      AvatarFrame.none => 0.0,
      AvatarFrame.minimal => math.max(1.0, size * .012),
      AvatarFrame.silver => math.max(1.5, size * .027),
      AvatarFrame.graphite => math.max(1.5, size * .03)
    };
    return width == 0 ? 0 : width + size * .018;
  }

  @override
  Widget build(BuildContext context) {
    final width = switch (frame) {
      AvatarFrame.none => 0.0,
      AvatarFrame.minimal => math.max(1.0, size * .012),
      AvatarFrame.silver => math.max(1.5, size * .027),
      AvatarFrame.graphite => math.max(1.5, size * .03),
    };
    final color = switch (frame) {
      AvatarFrame.none => Colors.transparent,
      AvatarFrame.minimal => const Color(0xFF53535A),
      AvatarFrame.silver => const Color(0xFFBFC0C5),
      AvatarFrame.graphite => const Color(0xFF3B3C42),
    };

    return Container(
        // Container adds the decoration's border width to this padding.
        padding: EdgeInsets.all(width == 0 ? 0 : size * .018),
        decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: width == 0 ? null : Border.all(color: color, width: width)),
        child: child);
  }
}
