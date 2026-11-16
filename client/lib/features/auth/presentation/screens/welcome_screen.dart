import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shade/core/widgets/shade_logo.dart';
import 'package:shade/features/auth/data/repositories/auth_notifier.dart';
import 'package:shade/main.dart';

/// Google's four-colour G, drawn in the original 24-unit coordinate system.
class _GoogleMark extends CustomPainter {
  const _GoogleMark();
  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final blue = Path()
      ..moveTo(21.6, 12.23)
      ..cubicTo(21.6, 11.52, 21.54, 10.84, 21.42, 10.18)
      ..lineTo(12, 10.18)
      ..lineTo(12, 14.05)
      ..lineTo(17.38, 14.05)
      ..cubicTo(17.15, 15.3, 16.44, 16.36, 15.38, 17.07)
      ..lineTo(15.38, 19.58)
      ..lineTo(18.61, 19.58)
      ..cubicTo(20.5, 17.84, 21.6, 15.28, 21.6, 12.23)
      ..close();
    final green = Path()
      ..moveTo(12, 22)
      ..cubicTo(14.7, 22, 16.96, 21.1, 18.61, 19.58)
      ..lineTo(15.38, 17.07)
      ..cubicTo(14.48, 17.67, 13.33, 18.04, 12, 18.04)
      ..cubicTo(9.39, 18.04, 7.18, 16.28, 6.39, 13.91)
      ..lineTo(3.05, 13.91)
      ..lineTo(3.05, 16.5)
      ..cubicTo(4.7, 19.76, 8.09, 22, 12, 22)
      ..close();
    final yellow = Path()
      ..moveTo(6.39, 13.91)
      ..cubicTo(6.19, 13.31, 6.07, 12.67, 6.07, 12)
      ..cubicTo(6.07, 11.33, 6.19, 10.69, 6.39, 10.09)
      ..lineTo(6.39, 7.5)
      ..lineTo(3.05, 7.5)
      ..cubicTo(2.38, 8.85, 2, 10.38, 2, 12)
      ..cubicTo(2, 13.62, 2.38, 15.15, 3.05, 16.5)
      ..close();
    final red = Path()
      ..moveTo(12, 5.96)
      ..cubicTo(13.47, 5.96, 14.78, 6.47, 15.82, 7.47)
      ..lineTo(18.68, 4.61)
      ..cubicTo(16.95, 3, 14.7, 2, 12, 2)
      ..cubicTo(8.09, 2, 4.7, 4.24, 3.05, 7.5)
      ..lineTo(6.39, 10.09)
      ..cubicTo(7.18, 7.72, 9.39, 5.96, 12, 5.96)
      ..close();
    for (final (path, color) in [
      (blue, 0xff4285f4),
      (green, 0xff34a853),
      (yellow, 0xfffbbc05),
      (red, 0xffea4335)
    ]) {
      canvas.drawPath(path, Paint()..color = Color(color));
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GoogleMark oldDelegate) => false;
}

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
    final compact = MediaQuery.sizeOf(context).height < 740;
    final busy = auth.status == AuthStatus.generatingKeys;
    return Scaffold(
        body: DecoratedBox(
      decoration: const BoxDecoration(color: ShadeColors.black),
      child: SafeArea(
          child: Center(
              child: SingleChildScrollView(
        padding:
            EdgeInsets.fromLTRB(24, compact ? 8 : 20, 24, compact ? 8 : 28),
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
                    ]),
                    SizedBox(height: compact ? 4 : 16),
                    Center(
                        child: Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                border: Border.all(
                                    color: ShadeColors.violet
                                        .withValues(alpha: .15)),
                                color: ShadeColors.surfaceCard),
                            child: const Center(child: ShadeLogo(size: 100)))),
                    SizedBox(height: compact ? 6 : 14),
                    Text('Свои люди.\nЛичные разговоры.',
                        style: TextStyle(
                            fontSize: MediaQuery.sizeOf(context).width < 360
                                ? 32
                                : 36,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -1.3,
                            height: 1.12)),
                    SizedBox(height: compact ? 4 : 12),
                    const Text(
                        'Место для ваших разговоров,\nфотографий и маленьких планов.',
                        style: TextStyle(
                            color: ShadeColors.textSecondary,
                            fontSize: 15,
                            height: 1.6)),
                    SizedBox(height: compact ? 8 : 20),
                    Container(
                        padding: EdgeInsets.all(compact ? 16 : 20),
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
                              SizedBox(height: compact ? 10 : 16),
                              FilledButton.icon(
                                  key: const Key('google-sign-in'),
                                  onPressed: busy ? null : _signIn,
                                  icon: busy
                                      ? const SizedBox(
                                          width: 18,
                                          height: 18,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2))
                                      : const SizedBox.square(
                                          dimension: 20,
                                          child: CustomPaint(
                                              painter: _GoogleMark())),
                                  label: Text(busy
                                      ? (auth.progress ?? 'Подключаем…')
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
                    SizedBox(height: compact ? 6 : 14),
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
                            textAlign: TextAlign.left,
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
