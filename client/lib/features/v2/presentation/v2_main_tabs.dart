import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shade/core/theme/shade_theme.dart';

class V2MainTabs extends StatelessWidget {
  const V2MainTabs({super.key, required this.navigation});

  final StatefulNavigationShell navigation;

  @override
  Widget build(BuildContext context) {
    final index = navigation.currentIndex;
    return PopScope(
      canPop: index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && index != 0) navigation.goBranch(0);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        body: navigation,
        bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : DecoratedBox(
                decoration: const BoxDecoration(
                  border:
                      Border(top: BorderSide(color: ShadeColors.greyBorder)),
                ),
                child: NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: navigation.goBranch,
                  height: 65,
                  backgroundColor: ShadeColors.surfaceCard,
                  indicatorColor: const Color(0xFF303034),
                  destinations: const [
                    NavigationDestination(
                      icon: Icon(Icons.chat_bubble_outline_rounded),
                      selectedIcon: Icon(Icons.chat_bubble_rounded),
                      label: 'Чаты',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      selectedIcon: Icon(Icons.settings_rounded),
                      label: 'Настройки',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.person_outline_rounded),
                      selectedIcon: Icon(Icons.person_rounded),
                      label: 'Профиль',
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
