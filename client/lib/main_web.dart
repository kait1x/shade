import 'package:flutter/material.dart';
import 'core/theme/shade_theme.dart';
import 'core/widgets/shade_logo.dart';

// Intentionally no auth, database, key storage or relay imports. The current
// single-identity protocol cannot enroll a browser alongside an Android device.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ShadeWebBeta());
}

class ShadeWebBeta extends StatelessWidget {
  const ShadeWebBeta({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Shade Web Beta',
        debugShowCheckedModeBanner: false,
        theme: buildShadeTheme(),
        home: const _BetaHome(),
      );
}

class _BetaHome extends StatelessWidget {
  const _BetaHome();

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: ShadeLogo(size: 64),
                  ),
                  const SizedBox(height: 24),
                  Text('Shade',
                      style: Theme.of(context).textTheme.displaySmall),
                  const SizedBox(height: 8),
                  const Text('WEB BETA · IPHONE',
                      style: TextStyle(
                          color: ShadeColors.textMuted, letterSpacing: 2)),
                  const SizedBox(height: 32),
                  const _InfoCard(
                    icon: Icons.lock_outline_rounded,
                    title: 'Переписка пока недоступна',
                    text:
                        'Эта версия проверяет установку и интерфейс на iPhone. '
                        'Вход через Google и чаты откроются после безопасного '
                        'подключения устройств к аккаунту.',
                  ),
                  const SizedBox(height: 16),
                  const _InfoCard(
                    icon: Icons.phone_iphone_rounded,
                    title: 'Любое устройство может быть первым',
                    text: 'iPhone, компьютер или Android — каждому устройству '
                        'нужны собственные ключи. Новая модель аккаунта пока '
                        'проверяется локально. Эта оболочка не меняет ваши ключи и историю.',
                  ),
                  const SizedBox(height: 24),
                  OutlinedButton.icon(
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      builder: (_) => const SafeArea(
                        child: SingleChildScrollView(
                          padding: EdgeInsets.fromLTRB(24, 16, 24, 32),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text('Установить Shade',
                                  style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w600)),
                              SizedBox(height: 20),
                              Text('1. Откройте эту страницу в Safari.\n\n'
                                  '2. Нажмите «Поделиться».\n\n'
                                  '3. Выберите «На экран Домой» → «Добавить».\n\n'
                                  '4. Запустите Shade с домашнего экрана.'),
                              SizedBox(height: 20),
                              Text(
                                  'Установка не включает переписку. Это оболочка Beta.',
                                  style:
                                      TextStyle(color: ShadeColors.textMuted)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('Установить на iPhone'),
                  ),
                  const SizedBox(height: 24),
                  const Text('Безопасность прежде всего',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  const Text(
                      'Действующий сервер ещё использует один ключ аккаунта. '
                      'Google подтверждает личность, но не разрешает добавлять '
                      'ключи устройств. Криптографическая привязка и восстановление '
                      'должны пройти проверку до включения чатов.',
                      style: TextStyle(
                          color: ShadeColors.textSecondary, height: 1.5)),
                ],
              ),
            ),
          ),
        ),
      );
}

class _InfoCard extends StatelessWidget {
  const _InfoCard(
      {required this.icon, required this.title, required this.text});
  final IconData icon;
  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: ShadeColors.surfaceCard,
          border: Border.all(color: ShadeColors.greyBorder),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, color: ShadeColors.textSecondary),
          const SizedBox(height: 16),
          Text(title,
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(text,
              style: const TextStyle(
                  color: ShadeColors.textSecondary, height: 1.5)),
        ]),
      );
}
