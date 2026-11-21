import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/widgets/shade_welcome.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/main.dart';

class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});
  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  final _nickname = TextEditingController();
  final _form = GlobalKey<FormState>();
  @override
  void initState() {
    super.initState();
    _nickname.text = ref.read(authNotifierProvider).nickname ?? '';
  }

  @override
  void dispose() {
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_form.currentState!.validate()) {
      await ref
          .read(authNotifierProvider.notifier)
          .createSecureProfile(_nickname.text.trim().toLowerCase());
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authNotifierProvider);
    final busy = auth.status == AuthStatus.generatingKeys;
    return Form(
      key: _form,
      child: ShadeWelcomeLayout(
        card: (compact) => [
          const Text('Давайте познакомимся',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          const SizedBox(height: 7),
          const Text('По никнейму друзья смогут найти вас.',
              style: TextStyle(
                  color: ShadeColors.textSecondary, fontSize: 12, height: 1.5)),
          SizedBox(height: compact ? 6 : 14),
          TextFormField(
              key: const Key('nickname'),
              controller: _nickname,
              enabled: !busy,
              autocorrect: false,
              maxLength: 32,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                  labelText: 'Ваш никнейм',
                  hintText: 'например, kait1x',
                  counterText: '',
                  prefixIcon: Icon(Icons.alternate_email_rounded, size: 20)),
              validator: (value) => RegExp(r'^[a-z0-9_]{3,32}$')
                      .hasMatch((value ?? '').trim().toLowerCase())
                  ? null
                  : 'От 3 до 32 символов: a–z, 0–9 и _',
              onFieldSubmitted: (_) {
                if (!busy) _signIn();
              }),
          SizedBox(height: compact ? 10 : 16),
          ShadeGoogleButton(
            key: const Key('google-sign-in'),
            onPressed: _signIn,
            progress: busy ? (auth.progress ?? 'Подключаем…') : null,
          ),
          if (auth.error != null)
            Padding(
                padding: const EdgeInsets.only(top: 14),
                child: Text(auth.error!,
                    key: const Key('auth-error'),
                    style: TextStyle(
                        fontSize: 12,
                        height: 1.5,
                        color: Theme.of(context).colorScheme.error))),
        ],
        footer: [
          const Text(
              'История и ключи остаются на этом устройстве.\nВосстановление на новом телефоне пока недоступно.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 11, height: 1.6, color: ShadeColors.textSecondary)),
          const SizedBox(height: 4),
          const ExpansionTile(
              title: Text('Как используется Google-аккаунт',
                  textAlign: TextAlign.left,
                  style: TextStyle(fontSize: 11, color: ShadeColors.textMuted)),
              tilePadding: EdgeInsets.zero,
              dense: true,
              shape: Border(),
              collapsedShape: Border(),
              children: [
                Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                        'Google подтверждает имя, email и фото профиля. Shade не получает пароль Google. Шифрование переписки использует отдельные ключи на вашем устройстве.',
                        style: TextStyle(
                            fontSize: 12,
                            color: ShadeColors.textSecondary,
                            height: 1.6)))
              ]),
        ],
      ),
    );
  }
}
