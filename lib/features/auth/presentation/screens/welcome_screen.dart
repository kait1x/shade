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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(updatedState.error ?? 'Failed to create profile.'),
          backgroundColor: const Color(0xFFEF4444),
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

class _ProfileForm extends StatefulWidget {
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
  State<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends State<_ProfileForm> {
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(() {
      setState(() => _isFocused = widget.focusNode.hasFocus);
    });
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
                labelText: 'Nickname',
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
                if (nick.length < 3 || nick.length > 32) {
                  return 'От 3 до 32 символов';
                }
                if (!RegExp(r'^[a-z0-9_]+$').hasMatch(nick)) {
                  return 'Только a-z, 0-9, _';
                }
                return null;
              },
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => widget.onSubmit(),
            ),
          ),

          const SizedBox(height: 28),

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
                onPressed: widget.onSubmit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.transparent,
                  shadowColor: Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                child: const Text(
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
