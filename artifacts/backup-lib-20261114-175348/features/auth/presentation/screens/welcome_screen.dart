import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/widgets/shade_logo.dart';
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
    return Scaffold(
        body: DecoratedBox(
      decoration: const BoxDecoration(
          gradient: RadialGradient(
              center: Alignment(-.7, -.8),
              radius: 1.3,
              colors: [Color(0xFF242424), ShadeColors.black],
              stops: [0, .8])),
      child: SafeArea(
          child: Center(
              child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Form(
              key: _form,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Row(children: [
                      ShadeLogo(size: 30),
                      SizedBox(width: 8),
                      Text('shade',
                          style: TextStyle(
                              fontSize: 24,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -1)),
                      Spacer(),
                      Icon(Icons.lock_outline_rounded,
                          color: ShadeColors.textMuted, size: 18)
                    ]),
                    const SizedBox(height: 28),
                    Center(
                        child: Container(
                            width: 134,
                            height: 134,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: ShadeColors.violet
                                        .withValues(alpha: .15)),
                                gradient: RadialGradient(colors: [
                                  ShadeColors.violet.withValues(alpha: .16),
                                  ShadeColors.violet.withValues(alpha: .015)
                                ])),
                            child: const Center(child: ShadeLogo(size: 138)))),
                    const SizedBox(height: 20),
                    Text('Свои люди.\nЛичные разговоры.',
                        style: TextStyle(
                            fontSize: MediaQuery.sizeOf(context).width < 360
                                ? 32
                                : 36,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -1.3,
                            height: 1.12)),
                    const SizedBox(height: 12),
                    const Text(
                        'Место для ваших разговоров,\nфотографий и маленьких планов.',
                        style: TextStyle(
                            color: ShadeColors.textSecondary,
                            fontSize: 15,
                            height: 1.6)),
                    const SizedBox(height: 26),
                    Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                            color:
                                ShadeColors.surfaceCard.withValues(alpha: .9),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: ShadeColors.greyBorder)),
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text('Давайте познакомимся',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700)),
                              const SizedBox(height: 7),
                              const Text('По никнейму друзья смогут найти вас.',
                                  style: TextStyle(
                                      color: ShadeColors.textSecondary,
                                      fontSize: 12,
                                      height: 1.5)),
                              const SizedBox(height: 20),
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
                                      prefixIcon: Icon(
                                          Icons.alternate_email_rounded,
                                          size: 20)),
                                  validator: (value) =>
                                      RegExp(r'^[a-z0-9_]{3,32}$').hasMatch(
                                              (value ?? '')
                                                  .trim()
                                                  .toLowerCase())
                                          ? null
                                          : 'От 3 до 32 символов: a–z, 0–9 и _',
                                  onFieldSubmitted: (_) {
                                    if (!busy) _signIn();
                                  }),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                  key: const Key('google-sign-in'),
                                  onPressed: busy ? null : _signIn,
                                  icon: busy
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : const Icon(Icons.login_rounded,
                                          size: 19),
                                  label: Text(busy
                                      ? 'Подключаем…'
                                      : 'Продолжить с Google'),
                                  style: FilledButton.styleFrom(
                                      backgroundColor: const Color(0xFFF1F1F1),
                                      foregroundColor: ShadeColors.black,
                                      minimumSize: const Size.fromHeight(52),
                                      textStyle: const TextStyle(
                                          fontFamily: 'Roboto',
                                          fontWeight: FontWeight.w700,
                                          fontSize: 14))),
                              if (auth.error != null)
                                Padding(
                                    padding: const EdgeInsets.only(top: 14),
                                    child: Text(auth.error!,
                                        key: const Key('auth-error'),
                                        style: TextStyle(
                                            fontSize: 12,
                                            height: 1.5,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .error))),
                            ])),
                    const SizedBox(height: 20),
                    const Text(
                        'История и ключи остаются на этом устройстве.\nВосстановление на новом телефоне пока недоступно.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.6,
                            color: ShadeColors.textSecondary)),
                    const SizedBox(height: 4),
                    const ExpansionTile(
                        title: Text('Как используется Google-аккаунт',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 11, color: ShadeColors.textMuted)),
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
                  ])),
        ),
      ))),
    ));
  }
}
