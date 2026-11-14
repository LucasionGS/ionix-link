# Ionix Link protocol, version 1

The wire contract between the desktop daemon (`bin/ionix-link`, "the daemon", "D") and the phone app
(`app/`, "the phone", "P"). Both sides code against this file. When the code and this file disagree,
this file is right and the code is a bug, unless the file is changed in the same commit.

## 1. Conventions

| Thing | Rule |
|---|---|
| Byte order | Every multi-byte integer on the wire is **big-endian** (network order). |
| Text | UTF-8, no BOM. |
| JSON | RFC 8259. Compact or not, any key order. A receiver **ignores unknown fields** and treats a missing optional field as `null`/default. A sender omits optional fields rather than sending `null`, unless the table says `null` is meaningful. |
| Binary values in JSON | **Lowercase hex**, no separators, no `0x` (a 32-byte value is 64 characters). Never base64. A receiver accepts uppercase too. |
| Fingerprint | SHA-256 of the daemon certificate's **DER** encoding, 32 bytes, hex in JSON and URIs. |
| Times | Integers, **Unix milliseconds** (UTC), unless the field name ends in `Sec`. |
| Durations / positions | Integers in **milliseconds**. |
| Ids | Message `id`/`re`: integer 1..2147483647. Host and device ids: 16 random bytes, hex (32 characters). |
| Volume | Float, `0.0` = silent, `1.0` = 100 %. Values above `1.0` may be reported (set on the desktop); the phone clamps its slider. |
| Field types below | `str`, `int`, `float` (any JSON number), `bool`, `obj`, `[T]` = array of T, `T?` = optional. Required unless marked `?`. |

## 2. Transport

- **TCP port 47110** (`IONIX_LINK_PORT` overrides on the daemon; the phone takes the port from the pairing URI or the UDP announce). The daemon listens on all addresses (`::` dual-stack, falling back to `0.0.0.0`; `IONIX_LINK_BIND` overrides).
- **TLS 1.2 or later** (1.3 preferred) over every TCP connection. The daemon's certificate is self-signed **ECDSA P-256**, generated once with the `openssl` CLI, stored in the data dir (`cert.pem`, `key.pem` 0600). Validity 10 years. CN `ionix-link <hostId>`. No SNI is needed; the phone connects by IP.
- **The phone has no client certificate.** It authenticates with an HMAC (section 5).
- **Certificate pinning (phone):** the phone accepts the certificate in `SecureSocket.connect(onBadCertificate:)` only if SHA-256 of `cert.der` equals the pinned fingerprint, and **also checks `socket.peerCertificate` after the handshake** (the callback is not called for a certificate that happens to validate). A mismatch closes the socket and is reported as "certificate changed": the phone never re-pins on its own. The only unpinned connection is pairing B's trust-on-first-use (section 4.3).
- One authenticated connection per device. A new one that authenticates for the same `deviceId` replaces the old one, which is closed with `error {code: "replaced", fatal: true}`.
- The daemon holds at most 16 connections that have not reached `ready`, and at most 4 of them per source address; when a new one arrives over either limit, the **oldest** unready connection (of that address, for the per-address limit) is closed to make room, so a peer that only holds connections open cannot keep a real phone out. A connection that has not sent its first frame within 5 s of the TLS handshake is closed. TLS handshakes time out after 5 s, and at most 64 may be in progress at once (further accepts are closed immediately).
- A message the daemon would send whose JSON exceeds 1 MiB is never put on the wire: text fields are cut (notification `summary` to 512 and `body` to 4096 characters, clipboard text so its *escaped* JSON fits) and lists are shortened from the oldest end.
- Only the documented push types run without an `id`. A request type that arrives without one (`commands.run`, `input.text`, `theme.wallpaper`…) is ignored.

## 3. Framing

Every frame:

```
+----------------+-----------+----------------------+
| u32 BE length  | u8 kind   | payload              |
+----------------+-----------+----------------------+
  length = 1 + len(payload)   (counts the kind byte, not itself)
```

| kind | payload |
|---|---|
| `0` JSON | One UTF-8 JSON **message** object (section 3.1). |
| `1` Binary | `u16 BE headerLength` + `headerLength` bytes of UTF-8 JSON message (same shape) + raw data to the end of the frame. |
| other | Protocol error: send `error {code: "bad_frame", fatal: true}` and close. |

Limits (a frame over its limit is answered with `error {code: "too_large", fatal: true}` and the connection closes, without reading the rest):

| Limit | Value |
|---|---|
| `length`, before `ready` | 65 536 (64 KiB) |
| `length`, after `ready` | 8 388 608 (8 MiB) |
| JSON message (kind 0 payload, kind 1 header) | 1 048 576 (1 MiB); kind 1 header also ≤ 65 535 by its type |
| `length` minimum | kind 0: 3 (`{}` plus the kind byte, and a message needs `type`); kind 1: 3 + `headerLength`. Shorter → `bad_frame`. |
| Clipboard / input text | 524 288 bytes UTF-8 (512 KiB) |

### 3.1 Message shape

```json
{ "type": "plugin.verb", "id": 12, "re": 7, "body": { } }
```

| Field | Type | Meaning |
|---|---|---|
| `type` | str | `<plugin>.<verb>`, or a core type (`hello`, `challenge`, `auth`, `ready`, `error`, `ping`, `pong`). |
| `id` | int? | Set on a **request**: the sender wants exactly one reply. Per connection, per direction, the sender's counter starting at 1. Never set on a reply. |
| `re` | int? | Set on a **reply**: the `id` it answers. |
| `body` | obj | Always present on send (`{}` when empty). A receiver treats a missing `body` as `{}`. |

- A message with neither `id` nor `re` is a **push** (fire-and-forget).
- **A reply's `type` is the request's `type`**, unless the tables below name another one, or it is an `error`.
- Every request gets **exactly one** reply. A request type that is unknown, or belongs to a plugin not negotiated on this connection, gets `error {code: "unknown_type" | "plugin_unavailable"}` (not fatal). An unknown or unavailable **push** is ignored (logged at debug level).
- Binary frames are pushes or requests like any other; the data belongs to the header message.

### 3.2 Test vectors

```
kind 0, message {"type":"ping","id":7,"body":{}} (32 bytes):
00000021 00 7b2274797065223a2270696e67222c226964223a372c22626f6479223a7b7d7d

kind 1, header {"type":"screen.frame","body":{"seq":1}} (40 bytes), data ffd8ffd9:
0000002f 01 0028 7b2274797065223a2273637265656e2e6672616d65222c22626f6479223a7b22736571223a317d7d ffd8ffd9
```

## 4. Discovery and pairing

### 4.1 UDP discovery

UDP port 47110 (same number as TCP, `IONIX_LINK_PORT` moves both). IPv4 only in v1. Each datagram is one UTF-8 JSON object, at most 1024 bytes.

Query, phone → `255.255.255.255:47110` (broadcast, `broadcastEnabled`), sent 3 times 300 ms apart:

```json
{ "ionixlink": 1, "type": "discover", "want": "<hostId hex32>" }
```

| Field | Type | Meaning |
|---|---|---|
| `ionixlink` | int | Always `1`. A datagram without it is ignored. |
| `type` | str | `"discover"` |
| `want` | str? | Only this host should answer (refinding a paired host). Absent = every host answers. |

Announce, daemon → the query's source address and port (**unicast**, so the phone needs no multicast lock):

```json
{ "ionixlink": 1, "type": "announce", "hostId": "<hex32>", "hostName": "myeonix", "port": 47110,
  "fingerprint": "<hex64>", "protocol": 1, "protocolMin": 1 }
```

The daemon answers at most 10 queries per second in total, does not answer when `IONIX_LINK_DISCOVERY=0` / config `discovery: false`, and ignores anything else. The phone collects announces for 3 s (scan) or until the wanted host answers (refind, 3 s timeout). An announce is unauthenticated: when refinding, one whose `fingerprint` differs from the pinned one is ignored and the search goes on (the phone shows a warning that something else answered). It never makes the phone forget the host; only the pinned certificate at the TLS handshake decides whether a peer is the host.

### 4.2 Pairing URI (pairing A, QR code)

`ionix-link pair` asks the daemon for a one-time token and prints this as a QR code (`qrencode -t ANSIUTF8`) and as text:

```
ionixlink://pair?v=1&host=<hostId>&name=<hostName>&port=47110&fp=<hex64>&token=<hex32>&exp=<unix ms>&addr=192.168.1.20&addr=10.0.0.4
```

| Param | Required | Meaning |
|---|---|---|
| `v` | yes | URI format version, `1`. A phone rejects a higher one ("update the app"). |
| `host` | yes | Host id, hex32. |
| `name` | yes | Host name, percent-encoded UTF-8. |
| `port` | yes | TCP port. |
| `fp` | yes | Certificate fingerprint, hex64. |
| `token` | yes | One-time token, 16 random bytes, hex32. |
| `exp` | yes | Expiry, Unix ms (now + 120 000). Informational: the daemon enforces it. |
| `addr` | yes, repeated | Every non-loopback, non-link-local address of the host a phone could reach (container and VM bridges and interfaces without carrier are left out), IPv4 first, IPv6 unbracketed and percent-encoded. In preference order. |

Every value is percent-encoded (RFC 3986 query component). Unknown params are ignored. The phone connects to all `addr`s in parallel (3 s timeout each), keeps the first that completes TLS with fingerprint `fp`, closes the rest, and sends `pair.request` with the token.

Only one token exists at a time; a new `pair` replaces the old one. A token is consumed by the `pair.request` that presents it. It also ends when `ionix-link pair` exits (Ctrl-C included). Expired or unknown → `pair.reject {reason: "token_invalid"}`.

### 4.3 Pairing B (no camera, 6-digit code)

Code pairing is only possible **while a pairing window is open**: `ionix-link pair` opens one (the same 2 minutes its QR token lives, closed when the command ends or a phone is paired). Outside a window a tokenless `pair.request` is answered `pair.reject {reason: "not_open"}` at once, and nothing is shown on the desktop.

The code comes from a commit-then-reveal exchange, so neither side can steer it. A man in the middle would have to fix its nonce towards each side before it has seen the other side's:

1. The phone discovers the host (4.1) and connects to `address:port` **without a pin**, recording the fingerprint of the certificate it sees (trust on first use). The announce's `fingerprint` is unauthenticated and proves nothing; the code comparison is what authenticates the certificate.
2. After the TLS handshake the phone generates a fresh 32-byte `Np` and sends `pair.request` with `commit = SHA-256(Np)` and no `token`.
3. The daemon stores the commit, generates a fresh 32-byte `Nd` and replies `pair.challenge {nonce: Nd}`.
4. The phone computes the code (4.4) from the fingerprint it saw, `Np` and `Nd`, shows it, and sends `pair.confirm {nonce: Np}`.
5. The daemon checks `SHA-256(Np) == commit` (no match → `pair.reject {reason: "bad_commit"}`), computes the same code from its **own** certificate, pushes `pair.pending`, and shows a desktop notification: `notify-send --app-name="Ionix Link" --urgency=critical --expire-time=60000 --action=accept=Accept --action=reject=Reject -- "Pair with <name>?" "<model> shows 931 221. Accept only if the codes match."` If `deviceId` is already paired, the body also says `This replaces the paired phone "<its name>".` `ionix-link pair accept|reject` answers the same request from a terminal.
6. Accept → `pair.accept`. Reject → `pair.reject {reason: "rejected"}`. No answer in 60 s → `pair.reject {reason: "timeout"}`. A second code request while one is pending → `pair.reject {reason: "busy"}`. `pair.confirm` must arrive within 10 s of `pair.challenge`.

The daemon accepts at most 3 tokenless `pair.request`s per source address per pairing window; more get `pair.reject {reason: "rate_limited"}`.

`name` and `model` come from an unauthenticated peer: the daemon strips control characters (C0, C1, DEL), bidi controls and line breaks from them before storing or showing them, and always passes `--` before positional arguments of tools it runs.

### 4.4 Pairing code

```
digest = SHA-256( fingerprint_raw (32 bytes) || Np_raw (32 bytes) || Nd_raw (32 bytes) )
code   = (u32 BE of digest[0..4]) mod 1 000 000, zero-padded to 6 digits
```

Displayed as two groups of three (`931 221`). Test vector:

```
fingerprint  a3d2ff5e747654c2fb788234d1347bf975b61e03cafca531a34cc6595277e60b
Np           404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f
commit       ca2a4fe727faaecf16ecd130a86e0885c5540c05375340445071c0657555fd42
Nd           808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f
digest       f46f3e956a64d16be595aa587fb42aef026cdd137a6ead9d8d82e20546cae4cf
u32          4100931221  ->  code "931221"
```

(The fingerprint in the vectors is SHA-256 of the ASCII string `ionix-link test certificate`.)

### 4.5 Pair messages

Allowed before `ready`. After `pair.accept` the connection is back in state `OPEN` (section 5) and the phone may send `hello` on it, or close and reconnect (the v1 app reconnects).

| Type | Dir | Kind | Body |
|---|---|---|---|
| `pair.request` | P→D | request | `token: str?` (pairing A) · `commit: str?` hex64 (pairing B; exactly one of `token`/`commit`) · `deviceId: str` · `name: str` (user-visible phone name, ≤ 64 chars) · `model: str` (e.g. `Pixel 8`) · `protocol: int` |
| `pair.challenge` | D→P | reply to a `pair.request` with `commit` | `nonce: str` hex64 (`Nd`) |
| `pair.confirm` | P→D | request, pairing B only | `nonce: str` hex64 (`Np`). Only valid as the next message after `pair.challenge` on the same connection. |
| `pair.pending` | D→P | push | `timeoutSec: int` (60). Sent for pairing B only, after a valid `pair.confirm`, before the desktop user answers. |
| `pair.accept` | D→P | reply to `pair.request` (A) or `pair.confirm` (B) | `key: str` hex64 (32 fresh random bytes, the device's key) · `hostId: str` · `hostName: str` · `fingerprint: str` hex64 |
| `pair.reject` | D→P | reply to `pair.request` or `pair.confirm` | `reason: str` — `token_invalid` \| `not_open` \| `bad_commit` \| `rejected` \| `timeout` \| `busy` \| `rate_limited` \| `protocol` |
| `pair.unpair` | either | push, authenticated only | `{}`. The receiver deletes the pairing (the phone: host and key; the daemon: the device), then either side closes. The phone shows "Unpaired by <host>". |

Pairing a `deviceId` that is already paired replaces its key and name. The phone's timeout is 30 s for `pair.request` and 130 s for `pair.confirm` (and for a token `pair.request`).

## 5. Handshake

Daemon state per connection:

```
            TLS accepted
                 |
                 v
   +--------> OPEN ----pair.request----> PAIRING --pair.accept/reject--> OPEN
   |             |                                    (pair.reject: daemon closes after 1 s)
   |           hello
   |             v
   |         CHALLENGED ---auth (good)---> READY ----> (closed)
   |             |
   |        auth (bad) / timeout
   |             v
   +------- (error, closed)
```

| Step | Message | Body |
|---|---|---|
| 1 P→D | `hello` (push) | `deviceId: str` · `name: str` · `model: str` · `appVersion: str` · `protocol: int` (highest the phone speaks) · `protocolMin: int?` (lowest, default = `protocol`) · `plugins: [PluginInfo]` (what the phone supports) |
| 2 D→P | `challenge` (push) | `nonce: str` hex64, 32 fresh random bytes |
| 3 P→D | `auth` (push) | `mac: str` hex64 = `HMAC-SHA256(key_raw, nonce_raw ‖ fingerprint_raw)` |
| 4 D→P | `ready` (push) | `protocol: int` (chosen) · `hostId: str` · `hostName: str` · `daemonVersion: str` · `plugins: [PluginInfo]` (negotiated, below) |

`PluginInfo`: `{ "name": str, "version": int, "caps": [str] }`.

Negotiation: the protocol chosen is `min(phone.protocol, daemon max)`; if that is below `max(phone.protocolMin, daemon min)`, the daemon sends `error {code: "protocol_version", details: {min, max}}` (fatal). `ready.plugins` lists each plugin that the daemon has available **and** the phone listed in `hello`, with `version = min(both)` and `caps` = **the daemon's** caps for it. The daemon remembers the phone's caps; each side only uses a cap the other side advertised. A plugin whose tool is missing on the desktop is left out entirely.

Rules:

- Before `READY` the daemon accepts only `hello`, `auth`, `pair.request`, `ping`. Anything else: `error {code: "not_authenticated", fatal: true}`.
- `hello` with an unknown `deviceId`: `error {code: "unknown_device", fatal: true}`. The phone marks the host *forgotten* and stops reconnecting; the UI offers to pair again.
- A wrong `mac`: `error {code: "auth_failed", fatal: true}`. Five failures from one **source address** within 60 s lock that address out for 60 s (`error {code: "rate_limited", fatal: true}`). The limit is per address, not per `deviceId`: a device id is not a secret, and a per-device lockout would let anyone who learned one lock that phone out.
- The MAC is compared in constant time (`hmac.compare_digest`).
- `hello.name` updates the stored device name.
- Handshake timeout: 10 s from TLS accept to `ready` (pairing B: 70 s from `pair.request` to its reply).
- After `ready`: the daemon pushes the current state of each negotiated plugin that has state (`status.host`, `media.players`, `media.volume`); the phone pushes `status.battery`. The phone asks for `notifications.list` and `commands.list` itself.

HMAC test vector (fingerprint as in 4.4):

```
key    000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f
nonce  202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f
mac    7c0ad5f413446203954a9262d09fd5a3df91edb941f35deaf0d44a1a23eb09a3
```

## 6. Keepalive and timeouts

| What | Value |
|---|---|
| Idle before a `ping` | 20 s with nothing **received**, either side, any state |
| Dead peer | 45 s with nothing received: close |
| `ping` | request, body `{}`; reply type **`pong`**, body `{}` |
| Phone request timeout | 15 s default; `commands.run` 30 s; `pair.request` 130 s; `status.ring` (daemon side) 10 s |
| Phone reconnect backoff | 1, 2, 4, 8, 16, 30, 30… s; reset on `ready`. Each attempt: last good address, then every stored address, then a UDP refind. No retry after `unknown_device`, `auth_failed`, `pair.unpair` or a certificate mismatch. |
| TCP connect timeout | 3 s per address |

## 7. Errors

```json
{ "type": "error", "re": 7, "body": { "code": "not_found", "message": "No command with id \"backup\".", "fatal": false, "details": {} } }
```

| Field | Type | Meaning |
|---|---|---|
| `code` | str | One of the table below. A receiver treats an unknown code as `failed`. |
| `message` | str | Human readable, one sentence, says how to fix it where possible. |
| `fatal` | bool? | `true`: the sender closes the connection after this frame. Default `false`. |
| `details` | obj? | Code-specific extras. |

`re` is set when the error answers a request, absent otherwise.

| Code | Fatal | When |
|---|---|---|
| `bad_frame` | yes | Unknown kind, kind 1 header longer than the frame, truncated frame. |
| `too_large` | yes | Frame over its limit. |
| `bad_json` | yes | Payload is not UTF-8 JSON object. |
| `bad_message` | no | Valid JSON but missing `type`, wrong field types, required body field missing. |
| `unknown_type` | no | Request of a type the receiver does not know. |
| `not_authenticated` | yes | Non-handshake message before `ready`. |
| `protocol_version` | yes | No common protocol version. `details: {min: int, max: int}`. |
| `unknown_device` | yes | `hello` from a device that is not paired. |
| `auth_failed` | yes | Bad `mac`. |
| `rate_limited` | yes | Too many auth failures. |
| `replaced` | yes | Another connection authenticated for this device. |
| `plugin_unavailable` | no | Request for a plugin not negotiated on this connection. |
| `invalid_argument` | no | A body field has a bad value (unknown output, scale out of range…). |
| `not_found` | no | Named thing does not exist (command id, player, notification). |
| `busy` | no | Already doing it (a second `screen.start` on another output is *not* busy: it restarts). |
| `timeout` | no | The desktop-side action timed out. |
| `failed` | no | The action ran and failed (tool exit status non-zero). `details.exitCode` when known. |
| `internal` | no | Bug in the receiver. |
| `shutdown` | yes | The daemon is stopping. |

## 8. Plugins

Every plugin has `version: 1` in this protocol. Listed caps are the full set; a side advertises only what it can do.

### 8.1 `notifications`

Desktop notifications mirrored to the phone. The phone lists the plugin (caps `["mirror"]`) to receive them; the daemon advertises caps `["dismiss"]` when it can close them. The daemon watches the session bus with `busctl --user monitor --json=short` for `Notify` calls, their method returns (which carry the id) and `NotificationClosed` signals. Its own pairing prompt and apps in config `notifications.ignoreApps` are not forwarded.

`Notification` object:

| Field | Type | Meaning |
|---|---|---|
| `id` | int | The desktop's notification id (u32). Same id again = an update that replaces it. |
| `app` | str | `app_name`, may be `""`. |
| `appIcon` | str? | Freedesktop icon name or path as sent, else the `image-path` hint; the phone may ignore it. |
| `summary` | str | |
| `body` | str | Plain text: the daemon strips markup (`<b>`, `<a>`…) and decodes entities. |
| `urgency` | str | `low` \| `normal` \| `critical` (hint `urgency` 0/1/2, default `normal`). |
| `time` | int | When the daemon saw it, Unix ms. |

| Type | Dir | Kind | Body |
|---|---|---|---|
| `notifications.posted` | D→P | push | `Notification` |
| `notifications.closed` | D→P | push | `id: int` · `reason: str` — `expired` \| `dismissed` \| `closed` \| `undefined` (NotificationClosed 1..4) |
| `notifications.list` | P→D | request | `{}` → reply `notifications: [Notification]`: ones seen while a phone has been connected and not closed, oldest first, at most 50. The daemon watches the bus only while at least one phone is connected, and forgets the list when the last one leaves. |
| `notifications.dismiss` | P→D | request | `id: int` → reply `ok: bool` (best effort: `CloseNotification` via `busctl --user call`; `false` if the server refused). |

The other direction, the phone's own notifications shown on the desktop, is 8.10.

### 8.2 `media`

Caps: `players` (playerctl present), `volume` (wpctl present), `art` (`players` plus `magick` or `ffmpeg` to scale covers). Present if either of the first two.

`Player` object:

| Field | Type | Meaning |
|---|---|---|
| `name` | str | playerctl instance name (`spotify`, `firefox.instance_1_42`). The handle for commands. |
| `identity` | str | Display name (`Spotify`, `Mozilla Firefox`); falls back to `name`. |
| `status` | str | `playing` \| `paused` \| `stopped` |
| `title` / `artist` / `album` | str | `""` when unknown. |
| `length` | int? | Track length, ms. Absent when unknown. |
| `position` | int? | Position when sampled, ms. |
| `positionTime` | int | When `position` was sampled, Unix ms. The phone extrapolates while `playing`: `position + (now - positionTime)`, capped at `length`. |
| `canSeek` / `canNext` / `canPrevious` / `canPlay` / `canPause` | bool | MPRIS `Can*`. |
| `artUrl` | str? | `mpris:artUrl` as given. The phone never fetches it itself; it asks `media.art`, and keys its cache on this string. |

`Volume` object: `volume: float` · `muted: bool` (default sink, `wpctl get-volume @DEFAULT_AUDIO_SINK@`).

| Type | Dir | Kind | Body |
|---|---|---|---|
| `media.players` | D→P push, P→D request | both | push and reply: `players: [Player]` · `active: str?` (the player playerctl would control by default: the most recently playing). Full list every time, sent on any change, debounced 150 ms. Request body `{}`. |
| `media.control` | P→D | request | `player: str?` (default `active`) · `action: str` — `play` \| `pause` \| `playPause` \| `next` \| `previous` \| `stop` → reply `ok: bool`. `not_found` for an unknown player. |
| `media.seek` | P→D | request | `player: str?` · `position: int` (absolute, ms) → reply `ok: bool` |
| `media.volume` | D→P push, P→D request | both | push and reply: `Volume`. Pushed on change. Request body `{}`. |
| `media.setVolume` | P→D | request | `volume: float?` (absolute, clamped 0..1.5) · `muted: bool?` — at least one → reply `Volume` (new state) |
| `media.art` | P→D | request | `player: str?` (default `active`) · `maxSize: int` (longest edge, px, 64..1024) → reply as a **binary frame**, header body `format: "jpeg"` · `w: int` · `h: int` · `artUrl: str` (the cover this is, so a reply that crosses a track change is recognised), data = the JPEG. Only with cap `art`, else `plugin_unavailable`. `not_found`: unknown player, no `artUrl`, an unreadable or non-regular file, or a scheme other than `file`, `http`, `https`. `failed`: download error, over 16 MiB, or not a JPEG, PNG, GIF, BMP or WebP by its leading bytes (checked before any tool sees it). `timeout`: download over 15 s. The daemon keeps the last 16 scaled covers. |

### 8.3 `commands`

Caps: none (`[]`). Always available. **The phone only ever sends a command id.** Nothing it sends is executed as a shell string.

`Command` object (what the phone sees):

| Field | Type | Meaning |
|---|---|---|
| `id` | str | `[a-z0-9][a-z0-9._-]*`, ≤ 64. |
| `title` | str | |
| `icon` | str | One of `lock`, `bedtime`, `logout`, `restart`, `power`, `terminal`, `play`, `screen`, `volume`, `wifi`, `bolt`, `star`, `apps`, `code`, `folder`. The phone maps them to Material icons; anything else shows `terminal`. |
| `confirm` | bool | The phone asks before sending `commands.run`. |
| `group` | str? | Section heading; absent = "Commands". |

| Type | Dir | Kind | Body |
|---|---|---|---|
| `commands.list` | P→D | request | `{}` → reply `commands: [Command]` |
| `commands.run` | P→D | request | `id: str` → reply `ok: bool` (exit status 0, or still running) · `exitCode: int?` (absent while still running) · `detached: bool` (still running after its timeout; left running) · `output: str?` (last 4096 bytes of stdout+stderr, only for commands with `showOutput`). `not_found` for an unknown id. |
| `commands.changed` | D→P | push | `{}` — the list changed (config edited, `ionix-link` reloaded); the phone re-requests `commands.list`. |

Built-ins (`group: "System"`): `lock` → `ionix-lock` (only if on PATH), `suspend` → `systemctl suspend`, `logout` → `uwsm stop` (confirm), `reboot` → `systemctl reboot` (confirm), `poweroff` → `systemctl poweroff` (confirm), `screen-off` → `hyprctl dispatch dpms off` (only under Hyprland). User file format in STRUCTURE.md.

### 8.4 `clipboard`

Caps: none. Desktop needs `wl-copy`/`wl-paste`. Manual only: nothing syncs by itself.

| Type | Dir | Kind | Body |
|---|---|---|---|
| `clipboard.push` | either | P→D: request; D→P: push | `text: str` (≤ 512 KiB). Desktop side runs `wl-copy`; reply `ok: bool`. On the phone the receiver sets the clipboard and shows "Clipboard from <host>". |
| `clipboard.pull` | P→D | request | `{}` → reply `text: str` (`""` if empty or not text; `wl-paste --no-newline --type text`) |

### 8.5 `input`

Caps: `pointer` (the daemon's virtual pointer bound `zwlr_virtual_pointer_manager_v1`), `keyboard` (`wtype` present). Present if either. Pointer messages are **pushes**: never send them with an `id`. The phone coalesces moves to at most 120 per second.

| Type | Dir | Kind | Body |
|---|---|---|---|
| `input.move` | P→D | push | `dx: float` · `dy: float` — relative, logical px, already scaled by the phone's sensitivity. The daemon keeps sub-pixel remainders. |
| `input.moveAbsolute` | P→D | push | `output: str` · `x: float` · `y: float` — normalised `0..1` within that output (0,0 = top left). Unknown output: ignored. |
| `input.button` | P→D | push | `button: str` — `left` \| `right` \| `middle` · `action: str` — `down` \| `up` \| `click` (down + up) |
| `input.scroll` | P→D | push | `dx: float` · `dy: float` — in px-equivalent units (a wheel notch ≈ 15). Positive `dy` scrolls **down**, positive `dx` right. Sent as finger-source axis events. |
| `input.text` | P→D | request | `text: str` (≤ 512 KiB) → reply `ok: bool` (typed with `wtype`, the text on its stdin) |
| `input.key` | P→D | request | `key: str` (an XKB keysym name: `Return`, `BackSpace`, `Escape`, `Tab`, `Left`, `F5`, `a`…) · `modifiers: [str]?` — `ctrl` \| `alt` \| `shift` \| `super` → reply `ok: bool`. `invalid_argument` for an unknown modifier. |

### 8.6 `screen`

Caps: `jpeg`. Desktop needs `grim` plus `hyprctl` or `wlr-randr` for outputs.

`Output` object: `name: str` (`DP-1`) · `description: str` · `x: int` · `y: int` · `width: int` · `height: int` (logical px, layout coordinates) · `scale: float` · `focused: bool`.

| Type | Dir | Kind | Body |
|---|---|---|---|
| `screen.outputs` | P→D | request | `{}` → reply `outputs: [Output]` |
| `screen.start` | P→D | request | `output: str` · `scale: float` (0.1..1.0, of the logical size) · `quality: int` (1..100) · `maxFps: int` (1..30) → reply `width: int` · `height: int` (frame size). Restarts a running stream with the new values. `invalid_argument` for an unknown output or a value out of range. |
| `screen.frame` | D→P | **binary** push | header body: `output: str` · `w: int` · `h: int` · `seq: int` (1, 2, 3… per stream) · `format: "jpeg"` · `time: int` (capture time). Data: the JPEG (`grim -o <output> -s <scale> -t jpeg -q <quality> -c -`). |
| `screen.ack` | P→D | push | `seq: int` — sent once the phone has decoded and shown frame `seq`. |
| `screen.stop` | P→D | request | `{}` → reply `ok: bool` |
| `screen.stopped` | D→P | push | `reason: str` — `output_gone` \| `capture_failed` \| `stalled` |

Flow control: **one frame in flight**. The daemon sends frame `n+1` only after `screen.ack {seq: n}` and no sooner than `1000 / maxFps` ms after frame `n`. It may capture `n+1` while waiting. No ack within 30 s: the stream stops with `screen.stopped {reason: "stalled"}`. A disconnect stops the stream. A slow link therefore lowers the frame rate, never adds latency.

### 8.7 `status`

Phone caps: `battery`, `ring`. Daemon caps: `battery` (it has a battery), `volume`.

`Battery` object: `level: int` (0..100) · `charging: bool`.

| Type | Dir | Kind | Body |
|---|---|---|---|
| `status.battery` | P→D | push | `Battery`. After `ready` and on change (level step or plug state). |
| `status.host` | D→P push, P→D request | both | push and reply: `hostName: str` · `battery: Battery?` (absent without one; `/sys/class/power_supply/BAT*`) · `volume: float?` · `muted: bool?`. Pushed after `ready` and on change. Request body `{}`. |
| `status.ring` | D→P | request | `{}` → reply `ok: bool` once ringing started (`false` if the phone cannot). The phone rings at alarm volume until the user stops it or 30 s pass. |
| `status.ping` | either | request | `message: str?` → reply `ok: bool`. The receiver shows "Ping from <name>" plus the message. (Not the keepalive `ping`.) |

### 8.8 `theme`

The phone wears the desktop's active theme. Daemon caps: `wallpaper` (it can read the current wallpaper and has a tool to scale it). The phone advertises the plugin with no caps.

The daemon resolves the palette the way the desktop shell does: the built-in base palette below, overridden in order by the `theme` object of `~/.config/quickshell/ionix/theme.json` (a symlink `ionixtheme` repoints, or a generated file for wallpaper-adaptive themes), the theme's enabled `options` overlays, then `theme` in `settings.json`, then `theme` in `config.json` beside it (config wins, as in the shell). `name` is the content of `~/.config/ionix/current-theme` (`"ionix"` if missing). It polls those files' resolved paths and mtimes (2 s) and pushes on any change of the resolved result. `IONIX_LINK_THEME_DIR` and `IONIX_LINK_THEME_NAME_FILE` override the two locations.

`Theme` object:

| Field | Type | Meaning |
|---|---|---|
| `name` | str | Theme name, for display. |
| `colors` | obj | **Always all sixteen keys**, each `"#rrggbb"` lowercase: `bgDeep`, `bgWindow`, `bgCard`, `hover`, `border`, `muted`, `text`, `textBright`, `accent`, `accentBright`, `accentLight`, `green`, `orange`, `red`, `cyan`, `link`. A theme value that is `#aarrggbb` (Qt order) loses its alpha; anything unparseable falls back to the base value. |
| `flat` | bool | The theme's `flat` choice (neutral fills, no glow, thin controls). Default `false`. |
| `radius` | obj | `sm: int` · `pill: int` · `panel: int`, logical px. Defaults 8, 12, 18. |
| `revision` | str | Hex SHA-256 of the canonical JSON of the fields above. Unchanged revision = nothing to do. |
| `wallpaper` | str? | Hex SHA-256 of the current wallpaper file (first output of `awww query`), absent when unknown. A changed value means `theme.wallpaper` would return a different picture. |

Base palette: `bgDeep #0f0a18`, `bgWindow #1a1025`, `bgCard #2d2d3f`, `hover #3a2d50`, `border #4a3d60`, `muted #6b5f80`, `text #c4b5fd`, `textBright #e2d9f3`, `accent #9b59b6`, `accentBright #a855f7`, `accentLight #c084fc`, `green #2ecc71`, `orange #f39c12`, `red #e74c3c`, `cyan #48dbfb`, `link #7c3aed`. The phone uses exactly this until it has ever received a `Theme`.

| Type | Dir | Kind | Body |
|---|---|---|---|
| `theme.changed` | D→P | push | `Theme`. Once after `ready`, then on every change (theme switch, adaptive recolour, wallpaper change). |
| `theme.get` | P→D | request | `{}` → reply `Theme`. |
| `theme.wallpaper` | P→D | request | `maxSize: int` (longest edge, px, 256..2048) → reply as a **binary frame**, header body `format: "jpeg"` · `w: int` · `h: int` · `wallpaper: str` (the hash), data = the JPEG. Only with cap `wallpaper`; otherwise `error {code: "plugin_unavailable"}`. Scaled with `magick` or `ffmpeg`, whichever exists, quality about 80. |

The phone stores the last `Theme` (and wallpaper, if it fetched one) per host and applies it at startup before connecting, so the app stays in the desktop's colours while offline. The phone must keep text readable whatever arrives: it derives on-accent text by contrast, not from a token.

### 8.9 `share`

Phone → desktop sharing, from Android's share sheet. Caps: `text` (the desktop has `wl-copy` or `xdg-open`), `files` (its download directory exists and is writable). Phone caps: none. Everything is a request from the phone; the desktop never starts a transfer.

Consent is on the phone: any app there can start a share, so the app sends nothing until the user taps *Send* on a sheet showing what will go and to which desktop, and the desktop then acts on what arrives (opens a link, saves a file) without asking again.

Where files go: `$IONIX_LINK_DOWNLOAD_DIR`, else `xdg-user-dir DOWNLOAD`, else `~/Downloads`. A file is written to a hidden `.<name>.ionix-link-part` in that directory and linked to its final name only after it verified, so a half-received file is never visible and a failed one leaves nothing. Names are sanitised by the desktop (the phone may send anything): basename only, control and bidi characters and `/` `\` removed, no leading dots, trailing dots and spaces trimmed, at most 200 bytes with the extension kept, `file` if nothing is left. A taken name becomes `name (1).ext`, `name (2).ext`: an existing file, or a symlink, is never replaced or followed.

| Type | Dir | Kind | Body |
|---|---|---|---|
| `share.text` | P→D | request | `text: str` (≤ 512 KiB, not blank) · `subject: str?` → reply `action: "opened" \| "copied"`. If the whole text, trimmed, is one `http`/`https` URL, the desktop opens it with `xdg-open` and notifies "Link from <phone>" (body: the subject, else the URL); if `xdg-open` fails or the text is anything else it goes to the clipboard (`wl-copy`) with the notification "Text from <phone> copied" (body: first line). `failed` if neither worked. |
| `share.begin` | P→D | request | `name: str` · `size: int` (bytes, 0..4 GiB) · `mime: str?` → reply `transfer: str`. `invalid_argument` for a bad name or a size over 4 GiB, `failed` when the download disk cannot hold the file, what open transfers still have to write and a 64 MiB margin, `busy` while another transfer is open **on this connection**, `plugin_unavailable` without cap `files`. |
| `share.chunk` | P→D | **binary** request | header body `transfer: str` · `offset: int`; data ≤ 1 MiB → reply `received: int` (total bytes so far). The phone sends the next chunk only after this reply (one in flight), so a slow link slows the sender instead of queueing. Offsets must be contiguous from 0 and never pass `size`: anything else, a missing data part or a chunk over 1 MiB gets `invalid_argument` **and the transfer is dropped** (part file deleted). `not_found` for an unknown or dropped transfer. |
| `share.end` | P→D | request | `transfer: str` · `sha256: str` (hex of the whole file) → reply `path: str` (where it was saved) · `name: str` (its final name, which may differ from the one sent). Fewer bytes than `size`: `invalid_argument`. Wrong hash: `failed`. Either way the transfer is dropped and nothing is left. On success the desktop shows the notification "<file> from <phone>" with *Open* (`xdg-open` the file) and *Show in folder* (`org.freedesktop.FileManager1.ShowItems`, else `xdg-open` of the folder). One notification per file. |
| `share.cancel` | P→D | request | `transfer: str` → `{}`. Idempotent: an unknown transfer is also `{}`. |

A disconnect cancels the transfer, and so does 60 s without a chunk (time the desktop spends writing does not count). A cancel or disconnect that arrives once the file has been linked into place is too late: the file stays and a waiting `share.end` still gets its reply. While transfers are open, `share.begin` counts the bytes they have still to write against the free space, and the desktop checks the free space again every 64 MiB of a file, failing it with `failed` (part file deleted) before the margin is used up. Part files a killed daemon left behind are deleted when they are over 60 s old and no transfer owns them. While a transfer is open the device's entry in `state.json` (§10) carries `transfers: [{ "id": str, "name": str, "size": int, "received": int }]`, updated at most once a second; the field is absent when idle.

### 8.10 Phone notifications

The phone's notifications shown on the desktop, part of the `notifications` plugin. Phone cap `forward`: the app can forward its notifications (Android, where it can ask for notification access; it is advertised whenever the app is able to, and whether the user has granted access and turned the feature on is the phone's own business: with it off, nothing is sent). Daemon cap `phone`: it can post notifications (`notify-send`, package libnotify). The daemon ignores `phonePosted`/`phoneRemoved` from a phone that did not list `forward`.

| Type | Dir | Kind | Body |
|---|---|---|---|
| `notifications.phonePosted` | P→D | push | `key: str` (Android's `StatusBarNotification` key, 1 to 1024 characters; the phone's identity for the notification) · `app: str` (package) · `appName: str` (label shown to the user) · `title: str` · `text: str` · `time: int` (Unix ms) · `silent: bool?` (low importance: shown with urgency `low`). The same `key` again is an update. |
| `notifications.phoneRemoved` | P→D | push | `key: str`. The phone dismissed or the app withdrew it. |
| `notifications.phoneDismiss` | D→P | push | `key: str`. The user closed it on the desktop (`NotificationClosed` reason 2, "dismissed by the user"). The phone cancels it if Android lets it; a notification that cannot be cancelled is left alone without a reply. Not sent for a close the daemon made itself, or for an expiry. |

Rules:

- The phone sends only text and only after its own filters (apps the user switched off, ongoing and foreground-service notifications, group summaries, its own notifications, `VISIBILITY_SECRET`). Nothing is sent for a phone notification that was already open when the connection began.
- The daemon shows each one through the session's notification server as app name `<appName> · <phone name>` (control characters and line breaks removed), summary `title` (at most 512 characters), body `text` (markup escaped, at most 4096 characters, line breaks kept) and the icon `phone`. It remembers `key → desktop id` per connection, replaces the desktop notification on an update (`replaces_id`), and closes it (`CloseNotification`, which needs `busctl`) on `phoneRemoved`. At most 100 are tracked per phone; the oldest simply stop being tracked.
- When the connection closes, every notification of that phone is closed on the desktop: nothing can dismiss or update a stale one any more.
- **No loop.** The daemon mirrors desktop notifications to the phone (8.1), so it must not mirror these back. Every notification it posts for a phone carries the hint `x-ionix-link`, and `notifications.posted` is never sent for a `Notify` call that has it, nor for an id the daemon tracks as a phone notification. Closing one (by the user, `phoneRemoved` or a disconnect) is not sent as `notifications.closed` either.
- The phone sends a `phonePosted` only while the connection is `ready` and the daemon has cap `phone`; the daemon's message limits (section 2) apply, so `title` and `text` are cut by the phone to 512 and 4096 characters.

## 9. Control socket (CLI ↔ daemon)

`$XDG_RUNTIME_DIR/ionix-link.sock` (`IONIX_LINK_SOCKET` overrides), `AF_UNIX` stream, mode 0600, removed on daemon exit. **Line-delimited JSON**: UTF-8, one object per line, `\n`-terminated, no newline inside an object. Requests on one connection are answered in order. The daemon takes requests from its own user only (`SO_PEERCRED` uid check).

Request: `{ "cmd": str, "args": obj? }`
Response: `{ "ok": true, "result": obj }` or `{ "ok": false, "code": str, "error": str }`

`DEVICE` arguments are resolved by the daemon: an exact id, a unique id prefix of at least 4 characters, or a case-insensitive exact name.

| `cmd` | `args` | `result` |
|---|---|---|
| `version` | — | `version: str` · `protocol: int` |
| `status` | — | the `state.json` object (section 10) |
| `devices` | — | `devices: [Device]` (section 10) |
| `pair` | `wait: bool?` | `uri: str` · `token: str` · `expires: int` · `addresses: [str]`. With `wait`, the connection then carries event lines until one final event, then the daemon closes it: `{"event": "paired", "device": Device}` or `{"event": "expired"}` or `{"event": "replaced"}` (another `pair` took over). |
| `pair.respond` | `accept: bool` | `device: {name, model, code}` of the request answered. `no_pending` if none. |
| `unpair` | `device: str` | `device: Device` (sends `pair.unpair` first if connected) |
| `ring` | `device: str` | `ok: bool` (the phone's reply) |
| `clipboard` | `device: str?` (default: the only connected one) · `text: str` | `device: str` (id it went to) |
| `commands` | — | `commands: [{id, title, icon, confirm, group, source: "builtin" \| "user", exec: [str]}]` |
| `reload` | — | `{}`. Re-reads config and commands, pushes `commands.changed`. |
| `subscribe` | — | `{}`, then a line `{"event": "state", "state": <state.json object>}` on every change until the client closes. For the desktop shell. |

Error `code`s: `bad_request`, `unknown_cmd`, `no_device`, `ambiguous_device`, `not_connected`, `plugin_unavailable`, `no_pending`, `timeout`, `failed`.

## 10. Files

| File | Mode | Owner | Shape |
|---|---|---|---|
| `$XDG_DATA_HOME/ionix/link/host.json` | 0600 | daemon | `{ "version": 1, "hostId": str, "created": int }` |
| `$XDG_DATA_HOME/ionix/link/cert.pem`, `key.pem` | 0644, 0600 | daemon | PEM. Never rewritten once made. |
| `$XDG_DATA_HOME/ionix/link/devices.json` | 0600 | daemon | `{ "version": 1, "devices": [ { "id", "name", "model", "key": hex64, "paired": int, "lastSeen": int? } ] }` |
| `$XDG_STATE_HOME/ionix/link/state.json` | 0644 | daemon, read by the shell | below |
| `$XDG_CONFIG_HOME/ionix/link/config.json` | user | user | STRUCTURE.md |
| `$XDG_CONFIG_HOME/ionix/link/commands.json` | user | user | STRUCTURE.md |

`state.json` (written atomically on every change, and once with `running: false` on exit):

```json
{
  "version": 1,
  "running": true,
  "pid": 1234,
  "updated": 1763150000000,
  "hostId": "…", "hostName": "myeonix", "port": 47110, "fingerprint": "…",
  "plugins": ["notifications", "media", "commands", "clipboard", "input", "screen", "status", "theme", "share"],
  "pairing": null,
  "devices": [
    { "id": "…", "name": "Pixel 8", "model": "Google Pixel 8", "paired": 1763000000000, "lastSeen": 1763150000000,
      "connected": true, "address": "192.168.1.31", "battery": { "level": 81, "charging": false },
      "plugins": ["media", "status"] }
  ]
}
```

`Device` is one entry of `devices` (never the key). `pairing` is `null`, `{ "mode": "qr", "expires": int }`, or `{ "mode": "code", "expires": int, "name": str, "model": str, "code": str }`. `plugins` at the top is what the daemon has available; per device it is what was negotiated. A device that is receiving a shared file (§8.9) also has `transfers: [{ id, name, size, received }]`.
