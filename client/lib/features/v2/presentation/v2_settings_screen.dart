import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shade/core/theme/shade_theme.dart';

import 'v2_push.dart';

class V2SettingsScreen extends ConsumerWidget {
  const V2SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final push = ref.watch(androidPushProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Настройки')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: EdgeInsets.fromLTRB(
                16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom),
            children: [
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  ListTile(
                    leading: const Icon(Icons.devices_outlined),
                    title: const Text('Устройства'),
                    subtitle: const Text('Подключение и перенос переписки'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push('/devices'),
                  ),
                  if (push != null) ...[
                    const Divider(
                        height: 1, indent: 56, color: ShadeColors.greyBorder),
                    SwitchListTile(
                      secondary: const Icon(Icons.notifications_outlined),
                      title: const Text('Уведомления о сообщениях'),
                      value: push.enabled,
                      onChanged: push.busy
                          ? null
                          : (value) async {
                              try {
                                await push.setEnabled(value);
                              } catch (error) {
                                if (!context.mounted) return;
                                ScaffoldMessenger.of(context)
                                    .showSnackBar(SnackBar(
                                  content: Text(error is StateError
                                      ? error.message
                                      : 'Не удалось изменить уведомления. Проверьте разрешения и подключение.'),
                                ));
                              }
                            },
                    ),
                  ],
                ]),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
