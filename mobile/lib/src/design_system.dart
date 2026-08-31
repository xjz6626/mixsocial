import 'package:flutter/material.dart';

/// Shared layout thresholds. Keeping them here prevents individual screens
/// from inventing different definitions of phone, tablet, and wide layouts.
abstract final class AppBreakpoints {
  static const double navigationRail = 840;
  static const double extendedNavigationRail = 1180;
  static const double wideFeed = 1240;
}

enum AppNavigationLayout { bottomBar, rail, extendedRail }

enum AppThemePreference {
  system('跟随系统', Icons.brightness_auto_outlined, ThemeMode.system),
  light('浅色', Icons.light_mode_outlined, ThemeMode.light),
  dark('深色', Icons.dark_mode_outlined, ThemeMode.dark);

  const AppThemePreference(this.label, this.icon, this.themeMode);

  final String label;
  final IconData icon;
  final ThemeMode themeMode;
}

AppNavigationLayout navigationLayoutForWidth(double width) {
  if (width >= AppBreakpoints.extendedNavigationRail) {
    return AppNavigationLayout.extendedRail;
  }
  if (width >= AppBreakpoints.navigationRail) {
    return AppNavigationLayout.rail;
  }
  return AppNavigationLayout.bottomBar;
}

int feedColumnCountForWidth(double width) {
  if (width >= AppBreakpoints.wideFeed) return 4;
  if (width >= AppBreakpoints.navigationRail) return 3;
  return 2;
}

abstract final class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

abstract final class AppRadii {
  static const double sm = 10;
  static const double md = 16;
  static const double lg = 22;
}

ThemeData buildAppTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xff4263eb),
    brightness: brightness,
    dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
  );
  final base = ThemeData(
    colorScheme: colors,
    brightness: brightness,
    useMaterial3: true,
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: dark
        ? const Color(0xff0d1017)
        : const Color(0xfff7f8fc),
  );
  final textTheme = base.textTheme.copyWith(
    headlineSmall: base.textTheme.headlineSmall?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -.3,
    ),
    titleLarge: base.textTheme.titleLarge?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -.2,
    ),
    titleMedium: base.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
    ),
    labelLarge: base.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w600,
    ),
  );
  final hairline = colors.outlineVariant.withValues(alpha: dark ? .42 : .58);

  return base.copyWith(
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      centerTitle: false,
      elevation: 0,
      scrolledUnderElevation: 0,
      toolbarHeight: 64,
      titleSpacing: AppSpacing.xl,
      backgroundColor: Colors.transparent,
      foregroundColor: colors.onSurface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: colors.onSurface,
        fontSize: 22,
      ),
    ),
    cardTheme: CardThemeData(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      margin: EdgeInsets.zero,
      color: dark ? const Color(0xff171b24) : colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        side: BorderSide(color: hairline),
      ),
    ),
    dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: dark ? const Color(0xff12161e) : colors.surface,
      indicatorColor: colors.primaryContainer,
      height: 72,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
        (states) => textTheme.labelMedium?.copyWith(
          color: states.contains(WidgetState.selected)
              ? colors.onSurface
              : colors.onSurfaceVariant,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w700
              : FontWeight.w500,
        ),
      ),
    ),
    navigationRailTheme: NavigationRailThemeData(
      elevation: 0,
      backgroundColor: dark ? const Color(0xff12161e) : colors.surface,
      indicatorColor: colors.primaryContainer,
      selectedIconTheme: IconThemeData(color: colors.onPrimaryContainer),
      unselectedIconTheme: IconThemeData(color: colors.onSurfaceVariant),
      selectedLabelTextStyle: textTheme.labelLarge?.copyWith(
        color: colors.onSurface,
      ),
      unselectedLabelTextStyle: textTheme.labelLarge?.copyWith(
        color: colors.onSurfaceVariant,
        fontWeight: FontWeight.w500,
      ),
      minWidth: 80,
      minExtendedWidth: 224,
      useIndicator: true,
    ),
    searchBarTheme: SearchBarThemeData(
      elevation: const WidgetStatePropertyAll<double>(0),
      backgroundColor: WidgetStatePropertyAll<Color>(
        colors.surfaceContainerHigh,
      ),
      surfaceTintColor: const WidgetStatePropertyAll<Color>(Colors.transparent),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
          side: BorderSide(color: hairline),
        ),
      ),
      padding: const WidgetStatePropertyAll<EdgeInsets>(
        EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      ),
    ),
    inputDecorationTheme: InputDecorationThemeData(
      filled: true,
      fillColor: colors.surfaceContainerHigh,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.lg,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
        borderSide: BorderSide(color: colors.primary, width: 1.5),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        textStyle: textTheme.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.md),
        ),
        side: BorderSide(color: colors.outlineVariant),
        textStyle: textTheme.labelLarge,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size.square(48)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      showDragHandle: true,
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.lg),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.inverseSurface,
      contentTextStyle: textTheme.bodyMedium?.copyWith(
        color: colors.onInverseSurface,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.md),
      ),
    ),
  );
}

/// A common full-page state for empty results and recoverable failures.
class AppStateView extends StatelessWidget {
  const AppStateView({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.actionIcon = Icons.refresh_rounded,
    this.onAction,
    this.iconColor,
    this.compact = false,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final IconData actionIcon;
  final VoidCallback? onAction;
  final Color? iconColor;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      label: '$title。$message',
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(compact ? AppSpacing.xl : AppSpacing.xxl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surfaceContainerHigh,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: EdgeInsets.all(
                      compact ? AppSpacing.lg : AppSpacing.xl,
                    ),
                    child: Icon(
                      icon,
                      size: compact ? 30 : 42,
                      color: iconColor ?? colors.primary,
                    ),
                  ),
                ),
                SizedBox(height: compact ? AppSpacing.lg : AppSpacing.xl),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: compact
                      ? Theme.of(context).textTheme.titleMedium
                      : Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),
                if (onAction != null && actionLabel != null) ...<Widget>[
                  const SizedBox(height: AppSpacing.xl),
                  FilledButton.tonalIcon(
                    onPressed: onAction,
                    icon: Icon(actionIcon),
                    label: Text(actionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class AppLoadingView extends StatelessWidget {
  const AppLoadingView({
    super.key,
    this.title = '正在加载内容',
    this.message = '正在连接内容源，请稍候',
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      container: true,
      liveRegion: true,
      label: '$title。$message',
      child: ExcludeSemantics(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox.square(
                  dimension: 36,
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: colors.primary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xl),
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: AppSpacing.sm),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
