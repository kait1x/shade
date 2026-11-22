import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shade/core/widgets/shade_tab_dock.dart';

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
        extendBody: true,
        resizeToAvoidBottomInset: false,
        body: navigation,
        bottomNavigationBar: MediaQuery.viewInsetsOf(context).bottom > 0
            ? null
            : ShadeTabDock(
                selectedIndex: index, onSelected: navigation.goBranch),
      ),
    );
  }
}
