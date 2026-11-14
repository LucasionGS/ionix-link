import "dart:async";

import "package:material_ui/material_ui.dart";

import "../../../link/link.dart";
import "../../sources.dart";
import "../../theme.dart";
import "../../widgets/empty_state.dart";
import "../../widgets/ion_card.dart";
import "../../widgets/ion_page.dart";

/// Pairing by code: asks [host] to pair, shows the 6-digit code large, and waits while the person checks that the
/// desktop shows the same one and accepts. Cancel gives up.
class CodeConfirmPage extends StatefulWidget {
  const CodeConfirmPage({super.key, required this.host});

  /// The desktop picked from the nearby list.
  final DiscoveredHost host;

  @override
  State<CodeConfirmPage> createState() => _CodeConfirmPageState();
}

class _CodeConfirmPageState extends State<CodeConfirmPage> {
  final PairSource _source = UiSources.pair;
  CodeAttempt? _attempt;
  String? _error;
  Timer? _poll;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void dispose() {
    _poll?.cancel();
    if (!_done) _attempt?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    setState(() {
      _error = null;
      _attempt = null;
    });
    try {
      final attempt = await _source.pairWithCode(widget.host);
      if (!mounted) {
        await attempt.cancel();
        return;
      }
      setState(() => _attempt = attempt);
      _poll = Timer.periodic(const Duration(milliseconds: 400), (_) {
        if (mounted) setState(() {});
      });
      final paired = await attempt.result;
      _done = true;
      await _source.selectHost(paired.id);
      if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
    } on LinkPairingException catch (e) {
      if (!mounted || e.reason == "cancelled") return;
      setState(() => _error = switch (e.reason) {
            LinkPairingException.reasonNotOpen => "${widget.host.name} isn't accepting phones right now. Run ionix-link pair in a terminal there, then try again.",
            "rejected" => "${widget.host.name} said no. Start again if that was a mistake.",
            "timeout" => "Nobody accepted on ${widget.host.name} in time.",
            "busy" => "${widget.host.name} is already pairing with another phone. Try again in a minute.",
            _ => e.message,
          });
    } on LinkException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      _poll?.cancel();
    }
  }

  static String _spaced(String code) => code.length == 6 ? "${code.substring(0, 3)} ${code.substring(3)}" : code;

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    final attempt = _attempt;
    final Widget body;
    if (_error != null) {
      body = EmptyState(icon: Icons.link_off_rounded, title: "Couldn't pair", message: _error, actionLabel: "Try again", action: _begin, tint: t.orange);
    }
    else if (attempt == null || attempt.code == null) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: IonixSpace.lg),
            Text(attempt == null ? "Contacting ${widget.host.name}…" : "Making a code with ${widget.host.name}…", style: text.bodyMedium),
          ],
        ),
      );
    }
    else {
      body = Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(IonixSpace.xl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: IonCard(
              blur: true,
              padding: const EdgeInsets.all(IonixSpace.xl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("Check the code", style: text.titleLarge),
                  const SizedBox(height: IonixSpace.sm),
                  Text("${widget.host.name} should show the same one.", textAlign: TextAlign.center, style: text.bodyMedium?.copyWith(color: t.dim)),
                  const SizedBox(height: IonixSpace.xl),
                  Text(_spaced(attempt.code!), style: text.displaySmall?.copyWith(fontSize: 40, letterSpacing: 4, color: t.accentLight)),
                  const SizedBox(height: IonixSpace.xl),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                      const SizedBox(width: IonixSpace.md),
                      Flexible(child: Text(attempt.isPending ? "Waiting for you to accept on ${widget.host.name}…" : "Asking ${widget.host.name} to show its code…", style: text.bodyMedium)),
                    ],
                  ),
                  const SizedBox(height: IonixSpace.xl),
                  OutlinedButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text("Cancel")),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return IonPage(title: widget.host.name, onBack: () => Navigator.of(context).maybePop(), body: body);
  }
}
