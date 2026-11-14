import "package:material_ui/material_ui.dart";

import "../../link/link.dart";
import "../../platform/link_platform.dart";
import "../sources.dart";
import "../theme.dart";
import "../ui_settings.dart";
import "../widgets/adaptive_scaffold.dart";
import "../widgets/empty_state.dart";
import "../widgets/ion_card.dart";
import "../widgets/ion_page.dart";
import "pair/pair_page.dart";

/// Settings: the phone's name, paired desktops (select, unpair after a confirm), pairing another one, the phone's
/// notifications on the desktop, touchpad speed, a ring test and the app and protocol version.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return IonPage(
      title: "Settings",
      underDock: true,
      body: ListView(
        padding: EdgeInsets.fromLTRB(14, IonixSpace.xs, 14, dockClearance(context)),
        children: const [
          _Desktops(),
          _Phone(),
          _PhoneNotifications(),
          _Touch(),
          _About(),
        ],
      ),
    );
  }
}

class _Desktops extends StatelessWidget {
  const _Desktops();

  Future<void> _unpair(BuildContext context, PairedHost host) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text("Unpair ${host.name}?"),
        content: const Text("This phone will forget the desktop and the desktop will forget this phone. You can pair again at any time."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text("Cancel")),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text("Unpair")),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await UiSources.home.unpair(host.id);
    } on LinkException catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = IonixTokens.of(context);
    final text = Theme.of(context).textTheme;
    final source = UiSources.home;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader("Desktops"),
        ValueListenableBuilder<List<PairedHost>>(
          valueListenable: source.hosts,
          builder: (context, hosts, _) => ValueListenableBuilder<PairedHost?>(
            valueListenable: source.currentHost,
            builder: (context, current, _) => IonCard(
              blur: true,
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (final host in hosts)
                    ListTile(
                      minTileHeight: 60,
                      leading: Icon(host.id == current?.id ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded, color: host.id == current?.id ? t.accentBright : t.dim),
                      title: Text(host.name, style: text.titleSmall),
                      subtitle: Text(host.id == current?.id ? "Current" : "Tap to connect", style: text.bodySmall),
                      trailing: IconButton(tooltip: "Unpair ${host.name}", icon: const Icon(Icons.link_off_rounded), onPressed: () => _unpair(context, host)),
                      onTap: host.id == current?.id ? null : () => source.selectHost(host.id),
                    ),
                  if (hosts.isEmpty) const Padding(padding: EdgeInsets.all(IonixSpace.lg), child: Text("No desktop is paired yet.")),
                  ListTile(
                    minTileHeight: 56,
                    leading: const Icon(Icons.add_rounded),
                    title: const Text("Pair another desktop"),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PairPage())),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Phone extends StatelessWidget {
  const _Phone();

  Future<void> _rename(BuildContext context) async {
    final controller = TextEditingController(text: UiSources.home.identity.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("This phone's name"),
        content: TextField(controller: controller, autofocus: true, maxLength: 64, decoration: const InputDecoration(hintText: "How desktops see this phone")),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text("Save")),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    try {
      await UiSources.home.setDeviceName(name.isEmpty ? null : name);
      if (context.mounted) showMessage(context, "Desktops see the new name the next time this phone connects.");
    } on LinkException catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final platform = LinkPlatform.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader("This phone"),
        IonCard(
          blur: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              ListTile(
                minTileHeight: 56,
                leading: const Icon(Icons.smartphone_rounded),
                title: Text(UiSources.home.identity.name),
                subtitle: Text(UiSources.home.identity.model),
                trailing: const Icon(Icons.edit_outlined),
                onTap: () => _rename(context),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: platform.ringing,
                builder: (context, ringing, _) => ListTile(
                  minTileHeight: 56,
                  leading: Icon(ringing ? Icons.notifications_off_outlined : Icons.notifications_active_outlined),
                  title: Text(ringing ? "Stop ringing" : "Ring this phone"),
                  subtitle: const Text("Test what \"find my phone\" sounds like."),
                  onTap: () => ringing ? platform.stopRinging() : platform.ring(timeout: const Duration(seconds: 10)),
                ),
              ),
              ListTile(
                minTileHeight: 56,
                leading: const Icon(Icons.notifications_none_rounded),
                title: const Text("Allow notifications"),
                subtitle: const Text("Needed to show your desktop's notifications here."),
                onTap: () async {
                  final granted = await platform.requestNotificationPermission();
                  if (context.mounted) showMessage(context, granted ? "Notifications are on." : "Notifications are off. Turn them on in the system settings.");
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The phone's own notifications on the desktop: one switch (it needs Android's notification access, which only the
/// user can grant) and, once the feature is on, a switch per app that has posted since. Read again whenever the app
/// resumes, because the user comes back from the system settings page.
class _PhoneNotifications extends StatefulWidget {
  const _PhoneNotifications();

  @override
  State<_PhoneNotifications> createState() => _PhoneNotificationsState();
}

class _PhoneNotificationsState extends State<_PhoneNotifications> with WidgetsBindingObserver {
  bool _enabled = false;
  bool _granted = false;
  List<PhoneNotificationApp> _apps = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final platform = LinkPlatform.instance;
    final enabled = await platform.phoneNotificationsEnabled();
    final granted = await platform.notificationAccessGranted();
    final apps = await platform.phoneNotificationApps();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _granted = granted;
      _apps = apps;
    });
  }

  Future<void> _toggle(bool on) async {
    final platform = LinkPlatform.instance;
    await platform.setPhoneNotificationsEnabled(on);
    if (on && !_granted) {
      await platform.openNotificationAccessSettings();
      if (mounted) showMessage(context, "Allow Ionix Link under notification access, then come back.");
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final platform = LinkPlatform.instance;
    if (!platform.canForwardNotifications) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final on = _enabled && _granted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader("Phone notifications"),
        IonCard(
          blur: true,
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: const Text("Phone notifications on the desktop"),
                subtitle: ValueListenableBuilder<PluginInfo?>(
                  valueListenable: Link.notifications.remote,
                  builder: (context, remote, _) => Text(
                    _enabled && !_granted
                        ? "Waiting for notification access. Android asks you to allow Ionix Link."
                        : remote != null && !remote.has(NotificationsClient.capPhone)
                            ? "This desktop cannot show them yet; it needs notify-send (libnotify)."
                            : "Show what this phone gets on your desktop, and close it there to close it here.",
                  ),
                ),
                value: on,
                onChanged: _toggle,
              ),
              if (on && _apps.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(IonixSpace.lg, 0, IonixSpace.lg, IonixSpace.md),
                  child: Text("Apps appear here once they post a notification.", style: text.bodySmall),
                ),
              if (on)
                for (final app in _apps)
                  SwitchListTile(
                    dense: true,
                    title: Text(app.name),
                    subtitle: Text(app.package, style: text.bodySmall),
                    value: app.allowed,
                    onChanged: (value) async {
                      await platform.setPhoneNotificationApp(app.package, value);
                      await _refresh();
                    },
                  ),
            ],
          ),
        ),
      ],
    );
  }
}

class _Touch extends StatelessWidget {
  const _Touch();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader("Touchpad"),
        IonCard(
          blur: true,
          padding: const EdgeInsets.fromLTRB(IonixSpace.lg, IonixSpace.md, IonixSpace.lg, IonixSpace.sm),
          child: ValueListenableBuilder<double>(
            valueListenable: UiSettings.touchSensitivity,
            builder: (context, value, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Pointer speed · ${value.toStringAsFixed(1)}×", style: Theme.of(context).textTheme.titleSmall),
                Slider(value: value, min: 0.5, max: 4, divisions: 14, onChanged: (v) => UiSettings.touchSensitivity.value = v),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _About extends StatelessWidget {
  const _About();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader("About"),
        IonCard(
          blur: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Ionix Link ${Link.appVersion}", style: text.titleSmall),
              const SizedBox(height: IonixSpace.xs),
              Text("Protocol ${LinkProtocol.version}", style: text.bodyMedium),
              const SizedBox(height: IonixSpace.xs),
              ValueListenableBuilder<LinkTheme>(valueListenable: UiSources.theme.theme, builder: (context, theme, _) => Text("Wearing the ${theme.name} theme from your desktop", style: text.bodySmall)),
            ],
          ),
        ),
      ],
    );
  }
}
