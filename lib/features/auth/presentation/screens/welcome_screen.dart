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
  final _nicknameController = TextEditingController();
  final _focusNode = FocusNode();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _nicknameController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _createProfile() async {
    if (!_formKey.currentState!.validate()) return;

    final nickname = _nicknameController.text.trim().toLowerCase();
    final authNotifier = ref.read(authNotifierProvider.notifier);

    final success = await authNotifier.createSecureProfile(nickname);

    if (!success && mounted) {
      final updatedState = ref.read(authNotifierProvider);
      final errorMsg = updatedState.error ?? 'Не удалось создать профиль';

      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: ShadeColors.surfaceCard,
          title: const Text('Ошибка',
              style: TextStyle(color: ShadeColors.textPrimary)),
          content: Text(errorMsg,
              style: const TextStyle(color: ShadeColors.textSecondary)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child:
                  const Text('OK', style: TextStyle(color: ShadeColors.violet)),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authNotifierProvider);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              ShadeColors.black,
              ShadeColors.surfaceDark,
              ShadeColors.black,
            ],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28.0),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: (MediaQuery.of(context).size.height -
                        MediaQuery.of(context).padding.top -
                        MediaQuery.of(context).padding.bottom -
                        48)
                    .clamp(0.0, double.infinity),
              ),
              child: IntrinsicHeight(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Spacer(flex: 2),

                    // Ghost logo
                    const ShadeLogo(size: 120),

                    const SizedBox(height: 36),

                    // Title
                    const Text(
                      'SHADE',
                      style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w900,
                        color: ShadeColors.textPrimary,
                        letterSpacing: 8,
                      ),
                    ),

                    const SizedBox(height: 8),

                    // Subtitle
                    Text(
                      'Encrypted Messenger',
                      style: TextStyle(
                        fontSize: 14,
                        color: ShadeColors.textSecondary,
                        letterSpacing: 3,
                      ),
                    ),

                    const SizedBox(height: 56),

                    // Form or loader
                    if (authState.status == AuthStatus.generatingKeys)
                      const _LoadingView()
                    else
                      _ProfileForm(
                        formKey: _formKey,
                        nicknameController: _nicknameController,
                        focusNode: _focusNode,
                        onSubmit: _createProfile,
                      ),

                    const Spacer(flex: 2),

                    // Footer
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.lock_rounded,
                          size: 12,
                          color: ShadeColors.greenAccent.withOpacity(0.6),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'RSA 4096 · E2EE',
                          style: TextStyle(
                            fontSize: 11,
                            color: ShadeColors.textMuted,
                            letterSpacing: 1.5,
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 36,
          height: 36,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation<Color>(ShadeColors.violet),
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'Generating 4096-bit keys...',
          style: TextStyle(
            fontSize: 15,
            color: ShadeColors.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'This may take a few seconds',
          style: TextStyle(
            fontSize: 12,
            color: ShadeColors.textMuted,
          ),
        ),
      ],
    );
  }
}

class _ProfileForm extends ConsumerStatefulWidget {
  final GlobalKey<FormState> formKey;
  final TextEditingController nicknameController;
  final FocusNode focusNode;
  final VoidCallback onSubmit;

  const _ProfileForm({
    required this.formKey,
    required this.nicknameController,
    required this.focusNode,
    required this.onSubmit,
  });

  @override
  ConsumerState<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<_ProfileForm> {
  final _formKey = GlobalKey<FormState>();
  final _nicknameController = TextEditingController();
  bool _isFocused = false;
  bool _isSubmitting = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _nicknameController.addListener(() {
      if (_errorText != null) setState(() => _errorText = null);
    });
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  Future<void> _createProfile() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSubmitting = true;
      _errorText = null;
    });

    final nickname = _nicknameController.text.trim().toLowerCase();
    final authNotifier = ref.read(authNotifierProvider.notifier);

    try {
      final success = await authNotifier.createSecureProfile(nickname);

      if (!success && mounted) {
        final updatedState = ref.read(authNotifierProvider);
        setState(() {
          _errorText = updatedState.error ?? 'Не удалось создать профиль';
          _isSubmitting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorText = 'Ошибка: $e';
          _isSubmitting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: widget.formKey,
      child: Column(
        children: [
          // Nickname input with neon border
          AnimatedContainer(
            duration: const Duration(milliseconds: 250),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              boxShadow: _isFocused
                  ? [
                      BoxShadow(
                        color: ShadeColors.violet.withOpacity(0.2),
                        blurRadius: 20,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: TextFormField(
              controller: widget.nicknameController,
              focusNode: widget.focusNode,
              style: const TextStyle(
                color: ShadeColors.textPrimary,
                fontSize: 16,
              ),
              cursorColor: ShadeColors.violet,
              decoration: InputDecoration(
                labelText: 'Никнейм',
                helperText: 'a-z, 0-9, _ • от 3 до 32 символов',
                helperStyle: TextStyle(
                  color: ShadeColors.textMuted,
                  fontSize: 12,
                ),
                labelStyle: TextStyle(
                  color: _isFocused
                      ? ShadeColors.violetLight
                      : ShadeColors.textMuted,
                ),
                prefixIcon: Icon(
                  Icons.alternate_email_rounded,
                  color:
                      _isFocused ? ShadeColors.violet : ShadeColors.textMuted,
                ),
                filled: true,
                fillColor: ShadeColors.surfaceCard,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: ShadeColors.greyBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: ShadeColors.greyBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(
                    color: ShadeColors.violet,
                    width: 1.5,
                  ),
                ),
              ),
              validator: (value) {
                final nick = (value ?? '').trim().toLowerCase();
                if (nick.isEmpty) {
                  return 'Введите никнейм';
                }
                if (nick.length < 3) {
                  return 'Минимум 3 символа (сейчас ${nick.length})';
                }
                if (nick.length > 32) {
                  return 'Максимум 32 символа (сейчас ${nick.length})';
                }
                if (!RegExp(r'^[a-z0-9_]+$').hasMatch(nick)) {
                  final bad = nick
                      .split('')
                      .where((c) => !RegExp(r'[a-z0-9_]').hasMatch(c))
                      .toSet()
                      .join(', ');
                  return 'Недопустимые символы: $bad';
                }
                return null;
              },
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => widget.onSubmit(),
            ),
          ),

          const SizedBox(height: 28),

          // Error message
          if (_errorText != null)
            Container(
              padding: const EdgeInsets.all(12),
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: const Color(0xFFEF4444).withOpacity(0.1),
                borderRadius: BorderRadius.circular(12),
                border:
                    Border.all(color: const Color(0xFFEF4444).withOpacity(0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded,
                      color: Color(0xFFEF4444), size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _errorText!,
                      style: const TextStyle(
                          color: Color(0xFFEF4444), fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),

          // Create button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [ShadeColors.violet, ShadeColors.cyan],
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                ),
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: ShadeColors.violet.withOpacity(0.35),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _createProfile,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: _isSubmitting
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text(
                        'Create Secure Profile',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 0.5,
                        ),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
