# Ionix Link: structure

Phone companion for the Ionix desktop. The wire contract is `PROTOCOL.md`; this file covers where code goes.

## Tree

```
bin/ionix-link                 Desktop daemon + CLI, one stdlib-only Python 3 file, executable
systemd/ionix-link.service     User unit, graphical-session.target, Restart=on-failure
PROTOCOL.md                    Wire spec (framing, handshake, every message, files, control socket)
STRUCTURE.md                   This file
README.md                      For users
Makefile                       Installs the desktop side (daemon, unit, licence)
PKGBUILD, packaging/aur/       ionix-link-git, same scheme as ionix-quickshell (r<count>.<hash>)
app/                           Flutter app (android + linux), package ionix_link
  lib/main.dart                Startup order only
  lib/link/                    Layer 1: connection core, no widgets
    link.dart                  Barrel: the only import for ui/ and platform/
    link_manager.dart          `Link` static manager: init, current host, status, plugin clients
    protocol/                  constants.dart (limits, core types, plugin names), errors.dart (exception
                               hierarchy + LinkErrorCode), message.dart, frame_codec.dart, link_crypto.dart
    models/                    paired_host, discovered_host, pairing_uri, plugin_info, device_identity, ready_info,
                               link_theme (the desktop's palette; LinkTheme.ionix is the default)
    connection/                link_connection.dart (one socket), link_session.dart (reconnect + attach),
                               link_status.dart, discovery.dart (UDP), pairing.dart (QR and code flows)
    store/link_store.dart      link.json + flutter_secure_storage keys
    plugins/                   plugin_client.dart (base) + one <name>_client.dart per plugin, models inside
  lib/platform/                Layer 3: OS glue behind `LinkPlatform`
    link_platform.dart         Interface + PlatformDevice
    android_platform.dart      The real one
    fallback_platform.dart     No-op for the Linux build
    platform_glue.dart         Subscribes Link streams to the platform (notifications, ring, battery, clipboard)
  lib/ui/                      Layer 2: widgets only
    app.dart                   IonixLinkApp (MaterialApp, routes)
    theme.dart                 buildTheme(LinkTheme) + IonixTokens: the whole look (glass, pills, bar), built
                               from the desktop's theme at runtime; no colour is named anywhere else
    sources.dart               UiSources: where pages get their data (Link by default, fakes in the preview)
    preview/                   preview_main.dart + fakes: every page with fake data, for headless screenshots
    plugin_pages.dart          Registry of dashboard tiles → pages
    pages/                     home, media, commands, clipboard, input, screen, notifications, settings
    pages/pair/                pair_page (start + nearby), qr_scan_page, code_confirm_page
    widgets/                   adaptive_scaffold (one pane / two panes on the hinge / tabletop), backdrop,
                               ion_card and the other shared pieces of the glass look, touchpad
  assets/fonts/                JetBrains Mono Nerd Font (OFL), the shell's font
  test/protocol_vectors_test.dart   PROTOCOL.md test vectors and codec cases
  test/link_e2e_test.dart      Against a daemon; skipped unless IONIX_LINK_E2E_DIR is set
```

## Boundaries

| From | May import | Never |
|---|---|---|
| `link/**` | `dart:*`, `package:flutter/foundation.dart`, `crypto`, `flutter_secure_storage`, `path_provider` | widgets, `material_ui`, `services.dart`, anything in `ui/` or `platform/` |
| `platform/**` | `link/link.dart`, platform packages, `package:flutter/services.dart` | `ui/`, files under `link/` other than the barrel |
| `ui/**` | `link/link.dart`, `platform/link_platform.dart`, `material_ui`, `mobile_scanner` | platform packages, files under `link/` other than the barrel, other `ui` pages' private state |
| `main.dart` | all three layers' entry files | logic |

- Widgets import `package:material_ui/material_ui.dart` (Flutter 3.50 template), not `package:flutter/material.dart`.
- Colours only in `ui/theme.dart`. State: `ValueListenable`/`ChangeNotifier`/streams from `link/`, read with `ValueListenableBuilder`/`StreamBuilder`. No state framework.
- The link layer never touches the OS. Everything the OS must do in reaction to the desktop goes through `PlatformGlue`.
- Exceptions: the link layer throws only `LinkException` subclasses; the UI shows `message` in a snackbar.
- Daemon: one asyncio loop, no blocking calls, no pip modules. Every tool is found through `tool()`, so `IONIX_LINK_BIN_<TOOL>` can fake it.

## Where does new X go?

| New… | Desktop (`bin/ionix-link`) | Phone |
|---|---|---|
| Plugin | `Plugin` subclass + entry in `PLUGINS` + `DEFAULT_CONFIG.plugins` key | `link/plugins/<name>_client.dart` (extends `PluginClient`), name in `LinkPlugins`, instance in `Link` + `Link.clients`, export in `link.dart`; page in `ui/pages/`, entry in `PluginPages.all` |
| Message in a plugin | `handle()` branch of that plugin | `static const type...` + method on its client |
| Core message type | `T_*` constant, `Connection.handle` | `LinkTypes` |
| Built-in command | `CommandsPlugin.BUILTINS` | nothing (icon must be in `LinkCommand.knownIcons`) |
| CLI command | `cmd_<name>`, `COMMANDS`, `HELP`, `USAGE`, and a control `cmd` in `ControlServer.dispatch` + PROTOCOL.md §9 | — |
| Setting (desktop) | `DEFAULT_CONFIG` + a line below | — |
| Setting (phone) | — | field in `link.json` via `LinkStore` (link) or a page in `ui/pages/settings_page.dart` |
| OS capability | — | method on `LinkPlatform`, both implementations, wiring in `PlatformGlue` |
| Error code | `ERR_*` (+ `FATAL_ERRORS`) | `LinkErrorCode` |

Every protocol change lands in `PROTOCOL.md` in the same commit. A breaking one bumps `PROTOCOL`/`LinkProtocol.version`.

## Extension points

- **Plugins (both sides).** `Plugin.available()/caps()/start()/stop()/on_ready()/handle()/on_close()` on the desktop; `PluginClient.onAttach()/onDetach()` + `listen()/request()/send()` on the phone. Negotiation in `ready` means a plugin one side lacks simply isn't there.
- **Caps** within a plugin (`media`: `players`, `volume`) let a feature ship on one side first.
- **`PluginPages.all`**: the dashboard renders whatever is registered and negotiated.
- **`LinkPlatform`**: a new OS (iOS later) is one more implementation.
- **Control socket `subscribe`**: the desktop shell (Quickshell) can follow state live later without polling `state.json`.

## Desktop config files

`$XDG_CONFIG_HOME/ionix/link/config.json` (all optional; defaults in `DEFAULT_CONFIG`):

```json
{ "name": "", "discovery": true,
  "plugins": { "screen": false },
  "notifications": { "ignoreApps": ["Spotify"] } }
```

`$XDG_CONFIG_HOME/ionix/link/commands.json`:

```json
{ "commands": [
  { "id": "backup", "title": "Run backup", "icon": "folder", "confirm": true, "group": "Tasks",
    "exec": ["systemctl", "--user", "start", "backup.service"], "timeout": 10, "showOutput": false },
  { "id": "say-hi", "title": "Say hi", "icon": "terminal", "exec": "notify-send Hi && paplay /usr/share/sounds/freedesktop/stereo/bell.oga" },
  { "id": "poweroff", "hidden": true }
] }
```

`exec` as a list is argv; as a string it runs under `sh -c`. `timeout` defaults to 10 s. A user entry with a built-in's id replaces it; `"hidden": true` removes it.

Environment overrides (daemon): `IONIX_LINK_PORT`, `IONIX_LINK_BIND`, `IONIX_LINK_NAME`, `IONIX_LINK_DISCOVERY`, `IONIX_LINK_DATA_DIR`, `IONIX_LINK_STATE_DIR`, `IONIX_LINK_CONFIG_DIR`, `IONIX_LINK_SOCKET`, `IONIX_LINK_THEME_DIR`, `IONIX_LINK_THEME_NAME_FILE`, `IONIX_LINK_POWER_SUPPLY_DIR`, `IONIX_LINK_DEBUG`, `IONIX_LINK_BIN_<TOOL>`.

## Pub packages (main session adds them; `flutter pub add <name>`)

| Package | Layer | Why |
|---|---|---|
| `crypto` | link | SHA-256 and HMAC; Dart's SDK has neither |
| `flutter_secure_storage` | link | Device keys in the Android Keystore (libsecret on Linux) |
| `path_provider` | link | App support dir for `link.json` |
| `mobile_scanner` | ui | QR scanning (CameraX + ML Kit), no Linux support, hence `LinkPlatform.canScanQr` |
| `flutter_foreground_task` | platform | Foreground service keeping the process and socket alive in the background |
| `flutter_local_notifications` | platform | Mirrored desktop notifications, ping/clipboard messages, permission request |
| `battery_plus` | platform | Battery level + charging stream for `status.battery` |
| `device_info_plus` | platform | Phone model and name for `hello`/`pair.request` |
| `flutter_ringtone_player` | platform | Find-my-phone ring on the alarm stream |

Clipboard uses Flutter's own `Clipboard` (`services.dart`); no package.

## Android changes (main session applies them)

`app/android/app/src/main/AndroidManifest.xml`, inside `<manifest>`:

```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE"/>
<uses-permission android:name="android.permission.CHANGE_WIFI_STATE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"/>
<uses-permission android:name="android.permission.WAKE_LOCK"/>
<uses-permission android:name="android.permission.VIBRATE"/>
<uses-permission android:name="android.permission.CAMERA"/>
<uses-feature android:name="android.hardware.camera" android:required="false"/>
```

inside `<application>`:

```xml
<service
  android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
  android:foregroundServiceType="connectedDevice"
  android:exported="false"/>
```

`connectedDevice` needs one of `CHANGE_NETWORK_STATE`/`CHANGE_WIFI_STATE` at runtime on Android 14+ (both are normal permissions). Avoid `dataSync`: Android 15 caps it at 6 h a day.

`app/android/app/build.gradle.kts`: `minSdk = 23` (flutter_secure_storage), and for flutter_local_notifications `compileOptions { isCoreLibraryDesugaringEnabled = true }` plus `dependencies { coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4") }` (check the plugin's README for the current version).

## Packaging and the ISO (later)

`PKGBUILD` (working tree, for the ISO) and `packaging/aur/PKGBUILD` (`ionix-link-git`), installing `bin/ionix-link` → `/usr/bin`, `systemd/ionix-link.service` → `/usr/lib/systemd/user/`. Depends: `python`, `openssl`, `systemd`. Optdepends: `qrencode`, `playerctl`, `wireplumber`, `libpulse` (pactl), `wl-clipboard`, `wtype`, `grim`, `libnotify`, `hyprland`, `wlr-randr`. In ionix-iso: `LOCAL_PACKAGES` in `aur/build-aur.sh`, a `packages.x86_64` line, and enabling the unit through a skel `graphical-session.target.wants` link.

## Work split

Shared files, edited **only by the main session**: `app/pubspec.yaml`, `app/pubspec.lock`, `app/android/**`, `PROTOCOL.md`, `STRUCTURE.md`, `README.md`, packaging. A parcel that finds the contract wrong or incomplete reports it instead of changing `PROTOCOL.md` or another parcel's public signatures.

### Parcel A: desktop daemon

Owns `bin/ionix-link`, `systemd/`. Implements every `raise NotImplementedError` and `TODO(builder)`, keeping the outline (class and function names may gain helpers, not lose the structure).
Verify: a scratch dir with every `IONIX_LINK_*_DIR`/`SOCKET` override and a free `IONIX_LINK_PORT`; `ionix-link daemon` in the background; `status`, `pair` (QR prints), `commands`; a throwaway stdlib Python test client (in the scratchpad, not the repo) that pairs with the token, does hello/auth, and exercises each plugin; the vectors of PROTOCOL.md §3.2/§4.4/§5 checked against `encode_message`, `pairing_code`, `auth_mac`. Fake `grim`/`wtype`/`notify-send` through `IONIX_LINK_BIN_*`. Never run against the real session's notification server or pointer without saying so.

### Parcel B: link layer

Owns `app/lib/link/**`, `app/test/protocol_vectors_test.dart`. Public signatures in the skeletons are the contract Parcel C compiles against: implement them, add private helpers freely, do not rename or remove public members (adding is fine; report additions).
Verify: `dart analyze` clean; `flutter test` passes the vectors; a pure-Dart scratch script (scratchpad) that drives `Link`-level pairing + one request against Parcel A's daemon when available, or against a minimal fake.

### Parcel C: UI and platform

Owns `app/lib/ui/**`, `app/lib/platform/**`, `app/lib/main.dart`. Codes only against `link/link.dart` (bodies may throw until B lands, so build UI against the signatures and test with B's real code after integration).
Verify: `dart analyze` clean; `flutter run -d linux` headless (Xvfb or cage) with `FallbackPlatform`, screenshots of pair, home and one plugin page; Android behaviour (foreground service, notifications, ringing) checked on a device or emulator after integration.
