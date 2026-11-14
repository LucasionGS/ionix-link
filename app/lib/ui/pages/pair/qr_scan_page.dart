import "package:mobile_scanner/mobile_scanner.dart";
import "package:material_ui/material_ui.dart";

import "../../../link/link.dart";
import "../../sources.dart";
import "../../theme.dart";
import "../../widgets/empty_state.dart";
import "../../widgets/ion_card.dart";
import "../../widgets/ion_page.dart";

/// Camera view that takes the first `ionixlink://` code, pairs with it and shows what went wrong in plain words.
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  final PairSource _source = UiSources.pair;
  final MobileScannerController _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_busy) return;
    String? value;
    for (final code in capture.barcodes) {
      final raw = code.rawValue;
      if (raw != null && raw.startsWith("${PairingUri.scheme}://")) {
        value = raw;
        break;
      }
    }
    if (value == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final uri = _source.parseUri(value);
      final host = await _source.pairWithUri(uri);
      await _source.selectHost(host.id);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } on LinkException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    return IonPage(
      title: "Scan",
      onBack: () => Navigator.of(context).maybePop(),
      body: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: t.rPanel,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    MobileScanner(
                      controller: _controller,
                      onDetect: _onDetect,
                      errorBuilder: (context, error) => const EmptyState(
                        icon: Icons.no_photography_outlined,
                        title: "Can't use the camera",
                        message: "Allow camera access for Ionix Link in the system settings, or paste the pairing link instead.",
                      ),
                    ),
                    if (_busy) ColoredBox(color: t.bgDeep.withValues(alpha: 0.7), child: const Center(child: CircularProgressIndicator())),
                  ],
                ),
              ),
            ),
            const SizedBox(height: IonixSpace.md),
            IonCard(
              child: Text(
                _error ?? (_busy ? "Pairing…" : "Point the camera at the QR code that \"ionix-link pair\" shows on your desktop."),
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(color: _error == null ? t.text : t.orange),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
