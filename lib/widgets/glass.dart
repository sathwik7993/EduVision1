import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The ambient background every screen sits on: near-white, with a few large
/// out-of-focus colour blobs settling into place behind it.
///
/// The blobs are what give the glass something to refract. Frosted panels over
/// a flat white background just look like grey rectangles -- the colour behind
/// them is the whole effect.
///
/// The drift runs **once** on entry and then stops. An infinitely repeating
/// full-screen gradient repaint is a real battery cost on the low-end Android
/// hardware this app targets, and buys almost nothing visually at a 24-second
/// cycle. It also means the widget tree actually reaches a settled state.
class AmbientBackground extends StatefulWidget {
  const AmbientBackground({super.key, required this.child, this.animate = true});

  final Widget child;

  /// Set false on heavy screens (e.g. the live camera preview) to skip the
  /// entrance drift entirely and paint the blobs at their resting position.
  final bool animate;

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  late final Animation<double> _drift = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.emphasized,
  );

  @override
  void initState() {
    super.initState();
    if (widget.animate) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(AmbientBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animate != oldWidget.animate && !widget.animate) {
      _controller.value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: AppColors.canvas,
      child: Stack(
        children: [
          // RepaintBoundary keeps the drifting blobs from repainting the
          // foreground content on every frame.
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _drift,
                builder: (context, _) =>
                    CustomPaint(painter: _BlobPainter(_drift.value)),
              ),
            ),
          ),
          Positioned.fill(child: widget.child),
        ],
      ),
    );
  }
}

class _BlobPainter extends CustomPainter {
  _BlobPainter(this.t);

  /// 0 at page entry, 1 at the resting position.
  final double t;

  static const _blobs = <({Color color, Offset origin, double radius, double phase})>[
    (color: AppColors.primary, origin: Offset(0.12, 0.08), radius: 0.55, phase: 0.0),
    (color: AppColors.violet, origin: Offset(0.92, 0.22), radius: 0.48, phase: 0.33),
    (color: AppColors.teal, origin: Offset(0.72, 0.88), radius: 0.52, phase: 0.66),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final shortest = size.shortestSide;

    for (final blob in _blobs) {
      // Each blob eases in from a small offset along its own angle and comes to
      // rest at its origin -- a settle, not an orbit.
      final angle = blob.phase * 2 * math.pi;
      final travel = 34 * (1 - t);
      final center = Offset(
        blob.origin.dx * size.width + travel * math.cos(angle),
        blob.origin.dy * size.height + travel * math.sin(angle),
      );
      // Grow slightly as they settle, so the colour blooms rather than slides.
      final radius = blob.radius * shortest * (0.88 + 0.12 * t);

      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              blob.color.withValues(alpha: 0.20 * t),
              blob.color.withValues(alpha: 0.0),
            ],
          ).createShader(Rect.fromCircle(center: center, radius: radius)),
      );
    }
  }

  @override
  bool shouldRepaint(_BlobPainter oldDelegate) => oldDelegate.t != t;
}

/// A frosted panel. This is the core surface of the app.
class GlassCard extends StatelessWidget {
  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.radius = AppRadius.lg,
    this.blur = 24,
    this.opacity = 0.66,
    this.shadows = AppShadows.card,
    this.onTap,
    this.border = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final double blur;
  final double opacity;
  final List<BoxShadow> shadows;
  final VoidCallback? onTap;
  final bool border;

  @override
  Widget build(BuildContext context) {
    final shape = BorderRadius.circular(radius);

    Widget surface = DecoratedBox(
      decoration: BoxDecoration(borderRadius: shape, boxShadow: shadows),
      child: ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: shape,
              // A soft top-left to bottom-right falloff imitates light
              // catching the edge of a real pane.
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppColors.glassTint.withValues(alpha: opacity + 0.12),
                  AppColors.glassTint.withValues(alpha: opacity - 0.06),
                ],
              ),
              border: border
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.65),
                      width: 1,
                    )
                  : null,
            ),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );

    if (onTap != null) {
      surface = _PressScale(onTap: onTap!, borderRadius: shape, child: surface);
    }
    return surface;
  }
}

/// Scales content down slightly while held. Cheap, but it is most of what
/// makes taps feel responsive rather than instant-and-flat.
class _PressScale extends StatefulWidget {
  const _PressScale({
    required this.child,
    required this.onTap,
    required this.borderRadius,
  });

  final Widget child;
  final VoidCallback onTap;
  final BorderRadius borderRadius;

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1.0,
        duration: AppMotion.fast,
        curve: AppMotion.curve,
        child: widget.child,
      ),
    );
  }
}

/// Translucent app bar that lets the ambient background show through.
class GlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassAppBar({super.key, required this.title, this.actions, this.leading});

  final String title;
  final List<Widget>? actions;
  final Widget? leading;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: AppBar(
          title: Text(title),
          actions: actions,
          leading: leading,
          backgroundColor: Colors.white.withValues(alpha: 0.55),
        ),
      ),
    );
  }
}

/// Scaffold preset: ambient background + glass app bar + body behind the bar.
class GlassScaffold extends StatelessWidget {
  const GlassScaffold({
    super.key,
    required this.body,
    this.title,
    this.actions,
    this.floatingActionButton,
    this.animateBackground = true,
    this.bottomBar,
  });

  final Widget body;
  final String? title;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final bool animateBackground;
  final Widget? bottomBar;

  @override
  Widget build(BuildContext context) {
    return AmbientBackground(
      animate: animateBackground,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        extendBody: true,
        appBar: title == null
            ? null
            : GlassAppBar(title: title!, actions: actions),
        body: body,
        bottomNavigationBar: bottomBar,
        floatingActionButton: floatingActionButton,
      ),
    );
  }
}

/// Small translucent pill used for status ("Verified", "Low confidence").
class GlassBadge extends StatelessWidget {
  const GlassBadge({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
  }
}

/// Staggered fade-and-rise used to bring page content in. Applied with an
/// increasing [index] down a column, it produces the cascade that reads as
/// "smooth" on page entry.
class EntranceFade extends StatelessWidget {
  const EntranceFade({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.slow + Duration(milliseconds: 70 * index),
      curve: AppMotion.emphasized,
      builder: (context, value, child) => Opacity(
        opacity: value.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 18 * (1 - value)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}
