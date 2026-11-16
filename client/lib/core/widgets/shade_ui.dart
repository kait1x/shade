import 'package:flutter/material.dart';

import 'avatar_view.dart';
export 'shade_states.dart';

class ShadeAvatar extends StatelessWidget {
  const ShadeAvatar({
    super.key,
    required this.name,
    this.username,
    this.imageUrl,
    this.size = 52,
    this.saved = false,
    this.online = false,
  });
  final String name;
  final String? username, imageUrl;
  final double size;
  final bool saved, online;
  @override
  Widget build(BuildContext context) => AvatarView(
    name: name,
    size: size,
    imageUrl: imageUrl,
    saved: saved,
    online: online,
  );
}
