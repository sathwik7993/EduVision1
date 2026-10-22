import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_mlkit_document_scanner/google_mlkit_document_scanner.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/scan_result.dart';
import '../services/recognition/mlkit_recognizer.dart';
import '../services/recognition/onnx_recognizer.dart';
import '../services/recognition/sheet_recognizer.dart';
import '../services/roster_service.dart';
import '../services/scan_validator.dart';
import '../services/sheet_service.dart';
import '../services/template_store.dart';
import '../theme/app_theme.dart';
import '../widgets/glass.dart';
import 'review_page.dart';
import 'template_editor_page.dart';

enum _CameraState { initialising, ready, permissionDenied, unavailable }

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

// WidgetsBindingObserver is what fixes the black preview after the app is
// backgrounded: Android tears the camera down and the old code never rebuilt it.
class _ScanPageState extends State<ScanPage> with WidgetsBindingObserver {
  final ImagePicker _picker = ImagePicker();
  final SheetRecognizer _mlKit = MlKitSheetRecognizer();

  /// Loaded only when the active template has field boxes. Null if the model
  /// failed to load, in which case scanning falls back to ML Kit.
  OnnxSheetRecognizer? _onnx;
  SheetTemplate _template = SheetTemplate.defaults;

  SheetRecognizer get _recognizer =>
      _template.hasBoxes && _onnx != null ? _onnx! : _mlKit;

  CameraController? _controller;
  List<CameraDescription> _cameras = const [];
  _CameraState _state = _CameraState.initialising;
  bool _busy = false;
  bool _torchOn = false;
  Offset? _focusPoint;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setUpCamera();
    _loadEngine();
  }

  Future<void> _loadEngine() async {
    final template = await TemplateStore.instance.active();
    if (!mounted) return;
    setState(() => _template = template);
    if (!template.hasBoxes) return;
    try {
      final onnx = await OnnxSheetRecognizer.load();
      if (!mounted) {
        await onnx.dispose();
        return;
      }
      setState(() => _onnx = onnx);
    } on Object catch (e) {
      // A missing or corrupt model must not take scanning down with it.
      debugPrint('Field model failed to load: $e');
      _toast('Handwriting model unavailable — using the printed-text reader.');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _mlKit.dispose();
    _onnx?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _controller = null;
      controller.dispose();
      if (mounted) setState(() => _state = _CameraState.initialising);
    } else if (state == AppLifecycleState.resumed) {
      _setUpCamera();
    }
  }

  Future<void> _setUpCamera() async {
    // The original app declared permission_handler as a dependency but never
    // requested anything, so the first capture failed on a fresh install.
    final status = await Permission.camera.request();
    if (!mounted) return;

    if (!status.isGranted) {
      setState(() => _state = _CameraState.permissionDenied);
      return;
    }

    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) setState(() => _state = _CameraState.unavailable);
        return;
      }

      // `cameras.first` is the front camera on a number of devices, which is
      // useless for scanning paper.
      final back = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );

      final controller = CameraController(
        back,
        // OCR accuracy is resolution-bound. The old ResolutionPreset.high is
        // only 720p, which loses thin pen strokes entirely.
        ResolutionPreset.veryHigh,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      await controller.initialize();
      await controller.setFocusMode(FocusMode.auto);
      await controller.setExposureMode(ExposureMode.auto);
      // Locking to 1x avoids the ultra-wide lens some devices default to,
      // which distorts text at the page edges.
      try {
        await controller.setZoomLevel(1.0);
      } on CameraException {
        // Not fatal -- some devices reject explicit zoom.
      }

      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _controller = controller;
        _torchOn = false;
        _state = _CameraState.ready;
      });
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _state = _CameraState.unavailable);
        _toast('Camera error: ${e.description ?? e.code}');
      }
    }
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final next = !_torchOn;
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = next);
    } on CameraException {
      _toast('Torch is not available on this camera.');
    }
  }

  Future<void> _focusAt(TapDownDetails details, BoxConstraints constraints) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final point = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );
    setState(() => _focusPoint = details.localPosition);

    try {
      await controller.setFocusPoint(point);
      await controller.setExposurePoint(point);
    } on CameraException {
      // Device does not support point focus; ignore.
    }

    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) setState(() => _focusPoint = null);
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (_busy || controller == null || !controller.value.isInitialized) return;

    setState(() => _busy = true);
    try {
      final shot = await controller.takePicture();
      await _process(shot.path);
    } on CameraException catch (e) {
      _toast('Could not capture: ${e.description ?? e.code}');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFromGallery() async {
    if (_busy) return;
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 100,
      );
      if (picked == null) return;
      setState(() => _busy = true);
      await _process(picked.path);
    } on Exception catch (e) {
      _toast('Could not open that image: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// ML Kit's document scanner: edge detection, perspective correction and
  /// its own capture UI, all on-device. Needs Google Play services; without
  /// them the in-app camera plus our own page alignment still works.
  Future<void> _scanDocument() async {
    if (_busy) return;
    final scanner = DocumentScanner(
      options: DocumentScannerOptions(
        mode: ScannerMode.base,
        pageLimit: 1,
        isGalleryImport: true,
      ),
    );
    try {
      final scanned = await scanner.scanDocument();
      final images = scanned.images ?? const [];
      if (images.isEmpty) return;
      setState(() => _busy = true);
      await _process(images.first);
    } on PlatformException catch (e) {
      // Cancelling the scanner also lands here; only report real failures.
      if (!(e.message ?? '').toLowerCase().contains('cancel')) {
        _toast('Document scanner unavailable: ${e.message ?? e.code}');
      }
    } finally {
      await scanner.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _process(String imagePath) async {
    // Without field boxes only ML Kit's printed-text reader can run: slow
    // (three image variants) and blind to handwritten marks. Say so, and
    // offer to set the layout up from this very photo.
    if (!_template.hasBoxes) {
      final choice = await _askSetUpTemplate();
      if (!mounted || choice == null) return;
      if (choice) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => TemplateEditorPage(samplePath: imagePath),
        ));
        await _loadEngine();
        if (!mounted || !_template.hasBoxes) return;
      }
    }
    final template = _template;
    final recognizer = _recognizer;
    final ScanResult validated;
    final Roster roster;
    final Set<String> saved;
    try {
      final result = await recognizer.recognize(imagePath, template: template);
      roster = await RosterService.instance.load();
      saved = {
        for (final row in await SheetService.instance.readAll())
          row.registrationNo.toUpperCase(),
      };
      validated = ScanValidator.validate(
        result,
        template,
        roster: roster,
        alreadySaved: saved,
      );
    } on Object catch (e) {
      _toast('Could not read the sheet: $e');
      return;
    }
    if (!mounted) return;

    // Every scan goes through review. Nothing is written to the workbook
    // straight from OCR any more.
    final committed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReviewPage(
          result: validated,
          engineName: recognizer.displayName,
          engineReadsHandwriting: recognizer.supportsHandwriting,
          template: template,
          roster: roster,
          alreadySaved: saved,
        ),
      ),
    );

    if (committed == true && mounted) {
      _toast('Saved to the results sheet.');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      // The live preview is already expensive to composite; the drifting
      // background blobs behind it would be wasted GPU work.
      animateBackground: false,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildViewfinder(),
          _buildTopBar(),
          _buildControls(),
          if (_busy) const _ProcessingOverlay(),
        ],
      ),
    );
  }

  Widget _buildViewfinder() {
    switch (_state) {
      case _CameraState.initialising:
        return const Center(child: CircularProgressIndicator());

      case _CameraState.permissionDenied:
        return _Message(
          icon: Icons.no_photography_outlined,
          title: 'Camera access needed',
          body: 'EduVision needs the camera to scan exam sheets. '
              'You can still import a photo from your gallery.',
          primaryLabel: 'Open settings',
          onPrimary: openAppSettings,
          // The document scanner runs in Play services' own activity and
          // needs no camera permission from this app.
          secondaryLabel: 'Use the document scanner',
          onSecondary: _scanDocument,
        );

      case _CameraState.unavailable:
        return _Message(
          icon: Icons.videocam_off_outlined,
          title: 'No camera available',
          body: 'This device has no usable camera. Import a photo instead.',
          primaryLabel: 'Pick from gallery',
          onPrimary: _pickFromGallery,
        );

      case _CameraState.ready:
        final controller = _controller!;
        return LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            onTapDown: (d) => _focusAt(d, constraints),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // Cover the whole viewfinder rather than letterboxing, so the
                // teacher frames against what will actually be captured.
                FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: controller.value.previewSize?.height ?? constraints.maxWidth,
                    height: controller.value.previewSize?.width ?? constraints.maxHeight,
                    child: CameraPreview(controller),
                  ),
                ),
                const _FramingGuide(),
                if (_focusPoint != null) _FocusRing(at: _focusPoint!),
              ],
            ),
          ),
        );
    }
  }

  /// True: set up a template from the photo; false: read printed text only.
  Future<bool?> _askSetUpTemplate() => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Set up this sheet first'),
          content: const Text(
            'Handwritten marks are read only after you mark where the boxes '
            'are on your college\'s sheet. It takes about two minutes, once '
            'per layout.\n\nWithout it, only printed text is read: slower, '
            'and marks are often wrong.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Printed text only'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Use this photo to set up'),
            ),
          ],
        ),
      );

  Widget _buildTopBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            _CircleGlassButton(
              icon: Icons.arrow_back,
              onTap: () => Navigator.of(context).maybePop(),
            ),
            const Spacer(),
            // Which layout and engine this scan will use, so a wrong active
            // template is noticed before the teacher scans a whole stack.
            GlassBadge(
              label: _template.hasBoxes
                  ? _template.name
                  : 'No template — printed text only',
              color: _template.hasBoxes ? AppColors.primary : AppColors.inkMuted,
              icon: Icons.grid_view_rounded,
            ),
            const Spacer(),
            _CircleGlassButton(icon: Icons.help_outline, onTap: _showTips),
            if (_state == _CameraState.ready) const SizedBox(width: AppSpacing.sm),
            if (_state == _CameraState.ready)
              _CircleGlassButton(
                icon: _torchOn ? Icons.flash_on : Icons.flash_off,
                active: _torchOn,
                onTap: _toggleTorch,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    if (_state != _CameraState.ready) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.bottomCenter,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: GlassCard(
            radius: AppRadius.xl,
            opacity: 0.55,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _CircleGlassButton(
                  icon: Icons.photo_library_outlined,
                  onTap: _pickFromGallery,
                ),
                _ShutterButton(onTap: _capture, enabled: !_busy),
                _CircleGlassButton(
                  icon: Icons.crop_free_rounded,
                  onTap: _scanDocument,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showTips() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: GlassCard(
          radius: AppRadius.xl,
          opacity: 0.88,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Getting a clean scan',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.md),
              ...[
                'Lay the sheet flat and fill the frame with it.',
                'The frame button opens the document scanner, which finds '
                    'the page edges for you.',
                'Avoid shadows — side lighting beats overhead light.',
                'Hold steady until focus settles, then tap the shutter.',
                'Tap anywhere on the preview to focus on that spot.',
                'Always check the values on the next screen before saving.',
              ].map(
                (tip) => Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 3),
                        child: Icon(Icons.check_circle_outline,
                            size: 18, color: AppColors.primary),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(child: Text(tip)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Corner brackets that show where to place the sheet.
class _FramingGuide extends StatelessWidget {
  const _FramingGuide();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 96, 28, 172),
          child: CustomPaint(painter: _BracketPainter(), child: const SizedBox.expand()),
        ),
      ),
    );
  }
}

class _BracketPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.9)
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const arm = 26.0;
    const inset = 0.0;
    final corners = <(Offset, Offset, Offset)>[
      (const Offset(inset, arm), const Offset(inset, inset), const Offset(arm, inset)),
      (
        Offset(size.width - arm, inset),
        Offset(size.width - inset, inset),
        Offset(size.width - inset, arm)
      ),
      (
        Offset(size.width - inset, size.height - arm),
        Offset(size.width - inset, size.height - inset),
        Offset(size.width - arm, size.height - inset)
      ),
      (
        Offset(arm, size.height - inset),
        Offset(inset, size.height - inset),
        Offset(inset, size.height - arm)
      ),
    ];

    for (final (a, b, c) in corners) {
      canvas.drawPath(Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy)..lineTo(c.dx, c.dy), paint);
    }
  }

  @override
  bool shouldRepaint(_BracketPainter oldDelegate) => false;
}

class _FocusRing extends StatelessWidget {
  const _FocusRing({required this.at});

  final Offset at;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: at.dx - 36,
      top: at.dy - 36,
      child: IgnorePointer(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 1.35, end: 1.0),
          duration: AppMotion.normal,
          curve: AppMotion.curve,
          builder: (context, scale, child) =>
              Transform.scale(scale: scale, child: child),
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.onTap, required this.enabled});

  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.curve,
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled ? AppColors.ink : AppColors.inkFaint,
          boxShadow: AppShadows.raised,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: const Icon(Icons.document_scanner_outlined,
            color: Colors.white, size: 30),
      ),
    );
  }
}

class _CircleGlassButton extends StatelessWidget {
  const _CircleGlassButton({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      onTap: onTap,
      radius: AppRadius.pill,
      opacity: active ? 0.9 : 0.6,
      padding: const EdgeInsets.all(13),
      child: Icon(icon,
          size: 22, color: active ? AppColors.primary : AppColors.ink),
    );
  }
}

class _ProcessingOverlay extends StatelessWidget {
  const _ProcessingOverlay();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white.withValues(alpha: 0.55),
      child: Center(
        child: GlassCard(
          radius: AppRadius.xl,
          opacity: 0.9,
          padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Reading the sheet',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('Aligning the page and reading each field',
                  style: TextStyle(color: AppColors.inkMuted, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  final IconData icon;
  final String title;
  final String body;
  final String primaryLabel;
  final VoidCallback onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: GlassCard(
          radius: AppRadius.xl,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 46, color: AppColors.inkMuted),
              const SizedBox(height: AppSpacing.md),
              Text(title,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: AppSpacing.sm),
              Text(body,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: AppSpacing.lg),
              FilledButton(onPressed: onPrimary, child: Text(primaryLabel)),
              if (secondaryLabel != null) ...[
                const SizedBox(height: AppSpacing.sm),
                TextButton(onPressed: onSecondary, child: Text(secondaryLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
