import "dart:async";

import "package:material_ui/material_ui.dart";

import "../../../link/link.dart";
import "../../sources.dart";
import "../../theme.dart";
import "../../widgets/empty_state.dart";
import "../../widgets/ion_card.dart";
import "../../widgets/ion_page.dart";
import "code_confirm_page.dart";
import "qr_scan_page.dart";

/// Pairing start: scan the desktop's QR code (when this device has a camera scanner), pick a desktop found on the
/// network and compare a 6-digit code, or paste the pairing link. Shown on its own when nothing is paired, and
/// pushed from settings otherwise.
class PairPage extends StatefulWidget {
  const PairPage({super.key});

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  final PairSource _source = UiSources.pair;
  final TextEditingController _link = TextEditingController();
  final List<DiscoveredHost> _found = [];
  StreamSubscription<DiscoveredHost>? _scan;
  bool _scanning = false;
  bool _pairing = false;
  String? _linkError;

  @override
  void initState() {
    super.initState();
    _discover();
  }

  @override
  void dispose() {
    _scan?.cancel();
    _link.dispose();
    super.dispose();
  }

  void _discover() {
    _scan?.cancel();
    setState(() {
      _found.clear();
      _scanning = true;
    });
    _scan = _source.discover().listen(
      (host) {
        if (mounted) setState(() => _found.add(host));
      },
      onError: (_) {
        if (mounted) setState(() => _scanning = false);
      },
      onDone: () {
        if (mounted) setState(() => _scanning = false);
      },
    );
  }

  Future<void> _pairWithLink() async {
    setState(() => _linkError = null);
    try {
      final uri = _source.parseUri(_link.text);
      setState(() => _pairing = true);
      final host = await _source.pairWithUri(uri);
      await _source.selectHost(host.id);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } on LinkException catch (e) {
      if (mounted) setState(() => _linkError = e.message);
    } finally {
      if (mounted) setState(() => _pairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    final canPop = Navigator.of(context).canPop();
    return IonPage(
      title: "Pair",
      onBack: canPop ? () => Navigator.of(context).maybePop() : null,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: IonixSpace.maxContent),
          child: ListView(
            padding: EdgeInsets.fromLTRB(14, IonixSpace.sm, 14, IonixSpace.xl + MediaQuery.paddingOf(context).bottom),
            children: [
              IonCard(
                blur: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const IonBadge(icon: Icons.link_rounded, size: 46),
                    const SizedBox(height: IonixSpace.md),
                    Text("Pair with your desktop", style: text.titleLarge),
                    const SizedBox(height: IonixSpace.sm),
                    Text("On the desktop, run this in a terminal and follow what it shows:", style: text.bodyMedium?.copyWith(color: t.dim)),
                    const SizedBox(height: IonixSpace.sm),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(IonixSpace.md),
                      decoration: t.pill(),
                      child: Text("ionix-link pair", style: text.bodyLarge?.copyWith(color: t.textBright, fontWeight: FontWeight.w700)),
                    ),
                    if (_source.canScanQr) ...[
                      const SizedBox(height: IonixSpace.lg),
                      FilledButton.icon(
                        onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const QrScanPage())),
                        icon: const Icon(Icons.qr_code_scanner_rounded),
                        label: const Text("Scan the QR code"),
                      ),
                    ],
                  ],
                ),
              ),
              SectionHeader(
                "On this network",
                trailing: _scanning
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : IconButton(tooltip: "Look again", visualDensity: VisualDensity.compact, icon: const Icon(Icons.refresh_rounded, size: 20), onPressed: _discover),
              ),
              if (_found.isEmpty)
                IonCard(
                  child: Text(
                    _scanning ? "Looking for desktops running Ionix Link…" : "No desktop answered. Make sure it's on the same Wi-Fi and Ionix Link is running, or use the QR code or a pairing link.",
                    style: text.bodyMedium?.copyWith(color: t.dim),
                  ),
                )
              else
                for (final host in _found)
                  Padding(
                    padding: const EdgeInsets.only(bottom: IonixSpace.sm),
                    child: _FoundHost(host: host, compatible: _source.isCompatible(host)),
                  ),
              const SectionHeader("Have a pairing link?"),
              IonCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _link,
                      enabled: !_pairing,
                      minLines: 1,
                      maxLines: 3,
                      keyboardType: TextInputType.url,
                      decoration: InputDecoration(hintText: "ionixlink://pair?…", errorText: _linkError, errorMaxLines: 3),
                    ),
                    const SizedBox(height: IonixSpace.md),
                    FilledButton(
                      onPressed: _pairing ? null : _pairWithLink,
                      child: _pairing ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Text("Pair"),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FoundHost extends StatelessWidget {
  const _FoundHost({required this.host, required this.compatible});

  final DiscoveredHost host;
  final bool compatible;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    return IonCard(
      padding: const EdgeInsets.symmetric(horizontal: IonixSpace.lg, vertical: IonixSpace.md),
      onTap: compatible ? () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CodeConfirmPage(host: host))) : null,
      child: Row(
        children: [
          IonBadge(icon: Icons.desktop_windows_outlined, size: 40, color: compatible ? null : t.orange),
          const SizedBox(width: IonixSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(host.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.titleSmall),
                Text(compatible ? host.address : "Needs a newer Ionix Link on this phone or the desktop", style: text.bodySmall),
              ],
            ),
          ),
          if (compatible) Icon(Icons.chevron_right_rounded, color: t.dim),
        ],
      ),
    );
  }
}
