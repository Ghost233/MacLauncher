import 'package:flutter/material.dart';

/// Design tokens and the app theme. All visual decisions live here:
/// one type scale, one spacing scale, semantic colors.
abstract final class AppTheme {
  // ---- color tokens ----
  static const background = Color(0xFFF5F6F8);
  static const surface = Color(0xFFFFFFFF);
  static const surfaceSubtle = Color(0xFFF9FAFB);
  static const border = Color(0xFFE4E7EB);
  static const borderStrong = Color(0xFFD1D5DB);

  static const textPrimary = Color(0xFF1F2329);
  static const textSecondary = Color(0xFF5F6B7A);
  static const textTertiary = Color(0xFF9AA3AF);

  static const accent = Color(0xFF2563EB);
  static const accentSoft = Color(0xFFEFF4FF);

  static const ok = Color(0xFF16A34A);
  static const okSoft = Color(0xFFE9F7EE);
  static const warn = Color(0xFFB45309);
  static const warnSoft = Color(0xFFFDF3E3);
  static const danger = Color(0xFFDC2626);
  static const dangerSoft = Color(0xFFFDEBEB);
  static const neutral = Color(0xFF6B7280);
  static const neutralSoft = Color(0xFFF1F2F4);

  // ---- spacing scale (4pt grid) ----
  static const gapXs = 4.0;
  static const gapSm = 8.0;
  static const gapMd = 12.0;
  static const gapLg = 16.0;
  static const gapXl = 24.0;

  // ---- type scale ----
  static const pageTitle = TextStyle(
    fontSize: 17,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );
  static const cardTitle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );
  static const sectionLabel = TextStyle(
    fontSize: 11,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.6,
    color: textTertiary,
  );
  static const serviceName = TextStyle(
    fontSize: 13.5,
    fontWeight: FontWeight.w600,
    color: textPrimary,
  );
  static const body = TextStyle(fontSize: 13, color: textPrimary);
  static const caption = TextStyle(fontSize: 12, color: textSecondary);
  static const captionMuted = TextStyle(fontSize: 12, color: textTertiary);
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 12,
    color: textPrimary,
  );
  static const monoMuted = TextStyle(
    fontFamily: 'monospace',
    fontSize: 11,
    color: textTertiary,
  );

  // ---- component styles ----
  static BoxDecoration cardDecoration() => BoxDecoration(
    color: surface,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: border),
  );

  static ThemeData material() {
    final base = ThemeData(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        surface: surface,
      ).copyWith(surface: background),
      appBarTheme: const AppBarTheme(
        backgroundColor: surface,
        foregroundColor: textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: pageTitle,
        toolbarHeight: 52,
        shape: Border(bottom: BorderSide(color: border)),
      ),
      dividerTheme: const DividerThemeData(
        color: border,
        thickness: 1,
        space: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: textPrimary,
        contentTextStyle: const TextStyle(fontSize: 13, color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: accent,
          textStyle: const TextStyle(fontSize: 13),
          minimumSize: const Size(0, 32),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: textSecondary,
          iconSize: 18,
          minimumSize: const Size(32, 32),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : Colors.white,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? ok
              : const Color(0xFFC9CDD4),
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
      ),
    );
  }
}

/// Small colored pill: dot + label. Used for connection/handoff/login-item
/// status where the label text must stay exact for tests and users.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    required this.background,
  });

  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w500,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
