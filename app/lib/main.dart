import "package:material_ui/material_ui.dart";

import "link/link.dart";
import "platform/link_platform.dart";
import "platform/platform_glue.dart";
import "ui/app.dart";

/// Startup order: platform, link layer, glue, UI.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  LinkPlatform.select();
  await LinkPlatform.instance.init();
  final device = await LinkPlatform.instance.device();
  await Link.init(platformName: device.name, model: device.model);
  await PlatformGlue.start();
  runApp(const IonixLinkApp());
}
