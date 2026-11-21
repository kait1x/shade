import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/features/profile/data/avatar_repository.dart';

export 'shade_states.dart';

/// Connects the existing UI API to the shared avatar renderer and profile cache.
class ShadeAvatar extends ConsumerWidget {
  final String name;
  final String? username, imageUrl;
  final double size;
  final bool saved, online;
  const ShadeAvatar(
      {super.key,
      required this.name,
      this.username,
      this.size = 52,
      this.imageUrl,
      this.saved = false,
      this.online = false});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = username == null || saved
        ? null
        : ref.watch(avatarProfileProvider(username!));
    final data = profile?.valueOrNull;
    return AvatarView(
        name: data?.displayName.isNotEmpty == true ? data!.displayName : name,
        size: size,
        image: data?.image,
        // A legacy Google URL can outlive an explicit removal. Once connected
        // to a profile, use only its authoritative/cached photo.
        imageUrl: profile == null ? imageUrl : data?.imageUrl,
        frame: data?.frame ?? AvatarFrame.none,
        saved: saved,
        online: online,
        loading: profile?.isLoading == true && data == null);
  }
}
