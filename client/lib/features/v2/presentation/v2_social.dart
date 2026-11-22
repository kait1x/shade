import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:shade/core/theme/shade_theme.dart';
import 'package:shade/core/widgets/shade_motion.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shade/core/services/device_v2/crypto.dart';
import 'package:shade/core/services/device_v2/repository.dart';
import 'package:shade/core/widgets/avatar_view.dart';
import 'package:shade/features/stickers/collection.dart';
import 'package:shade/features/stickers/repository.dart';
import 'package:shade/features/web/presentation/alpha_avatar_editor.dart';
import 'package:shade/core/database/database_service.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart'
    show databaseServiceProvider;
import 'v2_providers.dart';

class PublicProfile {
  final String name;
  final AvatarFrame frame;
  final Uint8List? image;
  final int revision;
  PublicProfile(Map<String, dynamic> json)
      : name = json['displayName'] as String? ?? '',
        frame = AvatarFrame.values.firstWhere((f) => f.name == json['frame'],
            orElse: () => AvatarFrame.none),
        image = json['image'] is String
            ? base64Decode(json['image'] as String)
            : null,
        revision = json['revision'] as int? ?? 0;
}

class V2Social implements StickerBackend {
  final V2ChatRepository repo;
  final DatabaseService database;
  V2Social(this.repo, this.database);
  Future<Map<String, dynamic>> request(String method, String path,
          [Object? body]) =>
      repo.transport.profileRequest(method, path,
          body: body,
          account: repo.account,
          id: repo.session.id,
          privateKey: repo.session.signingPrivateKey);
  Future<PublicProfile> profile(String name) async {
    final origin = repo.transport.origin;
    try {
      final data =
          await request('GET', '/user/${Uri.encodeComponent(name)}/avatar');
      await database.cacheAvatarProfile(repo.account, origin, name, data);
      return PublicProfile(data);
    } catch (_) {
      final cached =
          await database.readAvatarProfile(repo.account, origin, name);
      if (cached == null) rethrow;
      return PublicProfile(cached);
    }
  }

  Future<void> name(String name) async {
    await request('PUT', '/profile/name', {'displayName': name});
  }

  Future<void> avatar(
      int revision, AvatarFrame frame, bool replace, Uint8List? image) async {
    if (replace && image != null) {
      final encoded = base64Encode(image);
      final id = randomHex(16);
      for (var start = 0; start < encoded.length; start += 65536) {
        await request('POST', '/profile/avatar/chunk', {
          'uploadId': id,
          'offset': start,
          'total': encoded.length,
          'chunk': encoded.substring(start, min(start + 65536, encoded.length)),
          'frame': frame.name,
          'revision': revision
        });
      }
    } else {
      await request('PUT', '/profile/avatar', {
        if (replace) 'image': null,
        'frame': frame.name,
        'revision': revision
      });
    }
  }

  @override
  Future<Collection> load(String name, bool owner) async =>
      Collection(await request(
          'GET',
          owner
              ? '/stickers/inventory'
              : '/user/${Uri.encodeComponent(name)}/stickers'));

  @override
  Future<Map<String, dynamic>> save(int rev, List<Placement> wall) {
    // Match JSON.stringify on the relay, including integral coordinates.
    num coordinate(double value) {
      final rounded = double.parse(value.toStringAsFixed(6));
      return rounded == rounded.truncateToDouble() ? rounded.toInt() : rounded;
    }

    return request('PUT', '/stickers/wall', {
      'wall': [
        for (var i = 0; i < wall.length; i++)
          wall[i].json(i).map((key, value) =>
              MapEntry(key, value is double ? coordinate(value) : value))
      ],
      'revision': rev
    });
  }

  @override
  Future<void> gift(
      String to, String art, String note, String requestId) async {
    await request('POST', '/stickers/gift', {
      'toUsername': to,
      'stickerId': art,
      'note': note,
      'requestId': requestId
    });
  }
}

final v2SocialProvider = Provider<V2Social?>((ref) {
  if (ref.watch(v2SyncProvider) == null) return null;
  final repo = ref.read(v2SessionProvider.notifier).repository;
  return repo == null
      ? null
      : V2Social(repo, ref.read(databaseServiceProvider));
});
final v2EmailProvider = FutureProvider.autoDispose<String?>((ref) async {
  final social = ref.watch(v2SocialProvider);
  if (social == null) return null;
  final session = await social.repo.transport.session();
  return session['account'] == social.repo.account
      ? session['email'] as String?
      : null;
});

final publicProfileProvider = FutureProvider.autoDispose
    .family<PublicProfile?, String>((ref, name) async {
  final social = ref.watch(v2SocialProvider);
  if (social == null) return null;
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 2), link.close);
  ref.onDispose(timer.cancel);
  return social.profile(name);
});

Future<String?> _editText(
    BuildContext context, String title, String initial, int limit) async {
  var value = initial;
  return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
              title: Text(title),
              content: TextFormField(
                  initialValue: initial,
                  autofocus: true,
                  maxLength: limit,
                  onChanged: (v) => value = v),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Отмена')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, value.trim()),
                    child: const Text('Сохранить'))
              ]));
}

class V2ProfileAction extends StatelessWidget {
  const V2ProfileAction(this.icon, this.label, this.onTap,
      {super.key, this.primary = false});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final active = onTap != null;
    final highlighted = active && primary;
    final foreground = !active
        ? ShadeColors.textMuted
        : highlighted
            ? Colors.black
            : ShadeColors.textPrimary;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(
          color: highlighted ? Colors.transparent : ShadeColors.greyBorder),
    );
    return ShadeTapScale(
      child: Material(
        color: highlighted ? ShadeColors.textPrimary : ShadeColors.surfaceCard,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: shape,
          onTap: active
              ? () {
                  ShadeMotion.selection(context);
                  onTap!();
                }
              : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: foreground, size: 21),
              const SizedBox(height: 9),
              Text(label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: foreground)),
            ]),
          ),
        ),
      ),
    );
  }
}

class ProfileEditorControl extends ConsumerWidget {
  final String account;
  final Widget? avatar;
  const ProfileEditorControl(this.account, {super.key, this.avatar});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final social = ref.watch(v2SocialProvider);
    final result = ref.watch(publicProfileProvider(account));
    final profile = result.asData?.value;
    if (social == null || profile == null) {
      return avatar ??
          V2ProfileAction(
            Icons.edit_outlined,
            'Имя',
            social != null && result.hasError
                ? () => ref.invalidate(publicProfileProvider(account))
                : null,
            primary: true,
          );
    }
    final preview = avatar;
    if (preview != null) {
      return Tooltip(
        message: 'Изменить аватар',
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () async {
            await Navigator.of(context).push(MaterialPageRoute<void>(
              builder: (_) => AlphaAvatarEditor(
                initialName: profile.name.isEmpty ? account : profile.name,
                initialImage: profile.image,
                initialFrame: profile.frame,
                save: ({required frame, required replaceImage, image}) =>
                    social.avatar(profile.revision, frame, replaceImage, image),
              ),
            ));
            if (context.mounted) ref.invalidate(publicProfileProvider(account));
          },
          child: Stack(clipBehavior: Clip.none, children: [
            preview,
            Positioned(
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: const Color(0xff111113),
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0xff29292d), width: 2),
                ),
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(Icons.edit_outlined, size: 15),
                ),
              ),
            ),
          ]),
        ),
      );
    }
    return V2ProfileAction(Icons.edit_outlined, 'Имя', () async {
      final value =
          await _editText(context, 'Отображаемое имя', profile.name, 64);
      if (value == null || value.isEmpty || !context.mounted) return;
      try {
        await social.name(value);
        if (context.mounted) ref.invalidate(publicProfileProvider(account));
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Не удалось сохранить имя')),
          );
        }
      }
    }, primary: true);
  }
}

class PeerProfile extends ConsumerStatefulWidget {
  final String peer;
  const PeerProfile(this.peer, {super.key});
  @override
  ConsumerState<PeerProfile> createState() => _PeerProfileState();
}

class _PeerProfileState extends ConsumerState<PeerProfile> {
  static const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true));
  late final String noteKey;
  late Future<String?> note;
  @override
  void initState() {
    super.initState();
    final repo = ref.read(v2SocialProvider)!.repo;
    noteKey = 'v2.note.${repo.transport.origin}.${repo.account}.${widget.peer}';
    note = storage.read(key: noteKey);
  }

  @override
  Widget build(BuildContext context) {
    final peer = widget.peer;
    final result = ref.watch(publicProfileProvider(peer));
    final profile = result.asData?.value;
    final social = ref.watch(v2SocialProvider)!;
    return Scaffold(
        appBar: AppBar(title: const Text('Профиль собеседника')),
        body: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Center(
                  child: AvatarView(
                      name: peer,
                      size: 96,
                      image: profile?.image,
                      frame: profile?.frame ?? AvatarFrame.none)),
              Text(profile?.name.isNotEmpty == true ? profile!.name : '@$peer',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall),
              if (profile?.name.isNotEmpty == true)
                Center(child: SelectableText('@$peer')),
              if (result.hasError)
                TextButton(
                    onPressed: () =>
                        ref.invalidate(publicProfileProvider(peer)),
                    child: const Text('Загрузить профиль')),
              FutureBuilder<String?>(
                  future: note,
                  builder: (ctx, snap) => ListTile(
                      leading: const Icon(Icons.note_alt_outlined),
                      title: const Text('Личная заметка'),
                      subtitle: Text(snap.data ?? 'Видна только вам'),
                      onTap: snap.connectionState != ConnectionState.done
                          ? null
                          : () async {
                              final value = await _editText(context,
                                  'Личная заметка', snap.data ?? '', 500);
                              if (value == null) return;
                              try {
                                await storage.write(key: noteKey, value: value);
                                if (mounted)
                                  setState(() => note = Future.value(value));
                              } catch (_) {
                                if (ctx.mounted)
                                  ScaffoldMessenger.of(ctx).showSnackBar(
                                      const SnackBar(
                                          content: Text(
                                              'Не удалось сохранить заметку')));
                              }
                            })),
              ListTile(
                  leading: const Icon(Icons.verified_user_outlined),
                  title: const Text('Сверить код безопасности'),
                  onTap: () async {
                    final code = await _editText(
                        context, 'Код из профиля собеседника', '', 96);
                    if (code == null || !mounted) return;
                    try {
                      await ref.read(v2ChatListProvider.notifier).addContact(
                          peer,
                          code.toLowerCase().replaceAll(RegExp(r'\s+'), ''));
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Код подтверждён')));
                    } catch (_) {
                      if (context.mounted)
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text(
                                'Не удалось подтвердить код. Проверьте код и подключение.')));
                    }
                  }),
              FilledButton.icon(
                  icon: const Icon(Icons.card_giftcard),
                  label: const Text('Подарить стикер'),
                  onPressed: () async {
                    final sent = await showDialog<bool>(
                        context: context,
                        builder: (_) => GiftDialog(peer, backend: social));
                    if (sent == true && mounted) setState(() => wallVersion++);
                  }),
              StickerCollection(
                  key: ValueKey(wallVersion),
                  username: peer,
                  owner: false,
                  backend: social)
            ]));
  }

  int wallVersion = 0;
}
