#!/usr/bin/env python3
"""Minimal Ionix Link daemon per PROTOCOL.md, for app/test/link_e2e_test.dart. Stdlib Python only.

Usage: fake_daemon.py STATE_DIR PORT

Listens on 127.0.0.1:PORT (TLS + UDP discovery) and runs an imposter TLS server with another certificate on
127.0.0.2:PORT. Writes STATE_DIR/info.json (port, fingerprint, hostId, pairing URI) once listening, and
STATE_DIR/code.txt with the last pairing-B code. Pairing B is accepted automatically 0.5 s after pair.confirm.

Switches, as files in STATE_DIR checked on every use:
  window-closed   tokenless pair.request gets pair.reject {reason: "not_open"}
  forge-announce  each discovery query is first answered by an announce with a wrong fingerprint
  forge-only      ... and only by that one
debug.* requests (after ready) drive the rest of the test: stats, theme, drop, close, forget, unpair, ring.
"""
import asyncio
import hashlib
import hmac
import json
import os
import secrets
import ssl
import struct
import subprocess
import sys
import time

STATE, PORT = sys.argv[1], int(sys.argv[2])
os.makedirs(STATE, exist_ok=True)


def make_cert(name):
  cert, key = os.path.join(STATE, name + "-cert.pem"), os.path.join(STATE, name + "-key.pem")
  if not os.path.exists(cert):
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes",
                    "-keyout", key, "-out", cert, "-days", "3650", "-subj", "/CN=ionix-link " + name],
                   check=True, capture_output=True)
  return cert, key


def flag(name):
  return os.path.exists(os.path.join(STATE, name))


CERT, KEY = make_cert("fake")
IMPOSTER_CERT, IMPOSTER_KEY = make_cert("imposter")
with open(CERT) as f:
  FP_RAW = hashlib.sha256(ssl.PEM_cert_to_DER_cert(f.read())).digest()
FP = FP_RAW.hex()
HOST_ID = secrets.token_hex(16)
HOST_NAME = "fakeix"
DAEMON_CAPS = {"notifications": ["dismiss", "phone"], "media": ["players", "volume", "art"], "commands": [], "clipboard": [],
               "input": ["pointer", "keyboard"], "screen": ["jpeg"], "status": ["volume"], "theme": ["wallpaper"],
               "share": ["text", "files"]}
WALLPAPER = bytes.fromhex("ffd8ffe0") + b"fake wallpaper" * 8000 + bytes.fromhex("ffd9")  # > 64 KiB on purpose
devices = {}  # deviceId -> key bytes
token = {"value": secrets.token_hex(16)}
stats = {"moves": 0, "dx": 0.0, "dy": 0.0, "scrolls": 0, "buttons": [], "acks": [], "clipboard": None,
         "battery": None, "ring": None, "connections": 0, "hellos": 0, "queries": [], "phone": [], "notificationCaps": None,
         "share": {"texts": [], "files": [], "cancelled": 0}}
uploads = {}  # share transfer id -> {name, size, got, hash}
theme = {"accent": "#9b59b6"}
live = {}  # deviceId -> Conn


def theme_obj():
  colors = {"bgDeep": "#101018", "accent": theme["accent"]}
  body = {"name": "fakeix", "colors": colors, "flat": False, "radius": {"sm": 6, "pill": 12, "panel": 18}}
  body["revision"] = hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()
  body["wallpaper"] = hashlib.sha256(WALLPAPER + theme["accent"].encode()).hexdigest()
  return body


def frame(msg, data=None):
  js = json.dumps(msg, separators=(",", ":")).encode()
  if data is None:
    return struct.pack(">IB", 1 + len(js), 0) + js
  return struct.pack(">IBH", 3 + len(js) + len(data), 1, len(js)) + js + data


class Conn:
  def __init__(self, reader, writer):
    self.r, self.w = reader, writer
    self.state = "open"
    self.device = None
    self.nonce = None
    self.next_id = 0
    self.waiting = {}
    self.plugins = []
    self.seq = 0
    stats["connections"] += 1

  def send(self, typ, body=None, re=None, id=None, data=None):
    msg = {"type": typ, "body": body or {}}
    if re is not None: msg["re"] = re
    if id is not None: msg["id"] = id
    self.w.write(frame(msg, data))

  def error(self, code, message, re=None, fatal=False):
    self.send("error", {"code": code, "message": message, "fatal": fatal}, re=re)

  async def request(self, typ, body=None):
    self.next_id += 1
    fut = asyncio.get_running_loop().create_future()
    self.waiting[self.next_id] = fut
    self.send(typ, body, id=self.next_id)
    return await asyncio.wait_for(fut, 10)

  async def run(self):
    try:
      while True:
        head = await self.r.readexactly(5)
        length, kind = struct.unpack(">IB", head)
        limit = 8 * 1024 * 1024 if self.state == "ready" else 65536
        if length > limit:
          self.error("too_large", "Frame too large.", fatal=True)
          break
        payload = await self.r.readexactly(length - 1)
        data = None
        if kind == 1:
          (hl,) = struct.unpack(">H", payload[:2])
          payload, data = payload[2:2 + hl], payload[2 + hl:]
        elif kind != 0:
          self.error("bad_frame", "Unknown kind.", fatal=True)
          break
        msg = json.loads(payload)
        if await self.handle(msg, data) == "close":
          break
    except (asyncio.IncompleteReadError, ConnectionError, ssl.SSLError):
      pass
    finally:
      if self.device and live.get(self.device) is self:
        del live[self.device]
      await self.close()

  async def close(self):
    try:
      await self.w.drain()
      self.w.close()
      await asyncio.wait_for(self.w.wait_closed(), 2)
    except Exception:
      pass

  async def handle(self, msg, data):
    typ, body, mid = msg.get("type"), msg.get("body") or {}, msg.get("id")
    if "re" in msg:
      fut = self.waiting.pop(msg["re"], None)
      if fut and not fut.done(): fut.set_result(msg)
      return
    if typ == "ping":
      self.send("pong", {}, re=mid)
      return
    if self.state != "ready" and typ not in ("hello", "auth", "pair.request"):
      self.error("not_authenticated", "Authenticate first.", fatal=True)
      return "close"
    if typ == "pair.request":
      return await self.pair(body, mid)
    if typ == "hello":
      stats["hellos"] += 1
      dev = body.get("deviceId")
      if dev not in devices:
        self.error("unknown_device", "This phone is not paired.", fatal=True)
        return "close"
      self.device, self.hello = dev, body
      stats["notificationCaps"] = next((p.get("caps") for p in body.get("plugins", []) if p.get("name") == "notifications"), None)
      self.nonce = secrets.token_bytes(32)
      self.state = "challenged"
      self.send("challenge", {"nonce": self.nonce.hex()})
      return
    if typ == "auth":
      want = hmac.new(devices[self.device], self.nonce + FP_RAW, hashlib.sha256).hexdigest()
      if self.state != "challenged" or not hmac.compare_digest(want, str(body.get("mac", "")).lower()):
        self.error("auth_failed", "Wrong key.", fatal=True)
        return "close"
      old = live.get(self.device)
      if old:
        old.error("replaced", "Replaced.", fatal=True)
        await old.close()
      live[self.device] = self
      self.state = "ready"
      phone = {p["name"]: p for p in self.hello.get("plugins", [])}
      self.plugins = [{"name": n, "version": 1, "caps": c} for n, c in DAEMON_CAPS.items() if n in phone]
      self.send("ready", {"protocol": 1, "hostId": HOST_ID, "hostName": HOST_NAME, "daemonVersion": "fake",
                          "plugins": self.plugins})
      names = {p["name"] for p in self.plugins}
      if "status" in names: self.send("status.host", {"hostName": HOST_NAME, "volume": 0.5, "muted": False})
      if "media" in names:
        self.send("media.players", {"players": [{"name": "spotify", "identity": "Spotify", "status": "playing",
                                                 "title": "Song", "artist": "A", "album": "B", "length": 200000,
                                                 "position": 1000, "positionTime": int(time.time() * 1000),
                                                 "canSeek": True, "artUrl": "file:///fake/cover.png"}],
                                    "active": "spotify"})
        self.send("media.volume", {"volume": 0.5, "muted": False})
      if "theme" in names: self.send("theme.changed", theme_obj())
      return
    return await self.plugin(typ, body, mid, data)

  async def pair(self, body, mid):
    if body.get("token"):
      if body["token"] != token["value"]:
        self.send("pair.reject", {"reason": "token_invalid"}, re=mid)
        return
      token["value"] = secrets.token_hex(16)  # consumed
      self.accept(body["deviceId"], mid)
      return
    if not body.get("commit"):
      self.send("pair.reject", {"reason": "protocol"}, re=mid)
      return
    if flag("window-closed"):
      self.send("pair.reject", {"reason": "not_open"}, re=mid)
      return
    # Commit-then-reveal (PROTOCOL.md 4.3): challenge with Nd, then expect pair.confirm {nonce: Np} next.
    nd = secrets.token_bytes(32)
    self.send("pair.challenge", {"nonce": nd.hex()}, re=mid)
    head = await asyncio.wait_for(self.r.readexactly(5), 10)
    length, _ = struct.unpack(">IB", head)
    confirm = json.loads(await self.r.readexactly(length - 1))
    np_hex = str(confirm.get("body", {}).get("nonce", ""))
    if confirm.get("type") != "pair.confirm" or hashlib.sha256(bytes.fromhex(np_hex)).hexdigest() != body["commit"]:
      self.send("pair.reject", {"reason": "bad_commit"}, re=confirm.get("id"))
      return
    digest = hashlib.sha256(FP_RAW + bytes.fromhex(np_hex) + nd).digest()
    code = "%06d" % (struct.unpack(">I", digest[:4])[0] % 1000000)
    with open(os.path.join(STATE, "code.txt"), "w") as f:
      f.write(code)
    self.send("pair.pending", {"timeoutSec": 60})
    await asyncio.sleep(0.5)
    self.accept(body["deviceId"], confirm["id"])

  def accept(self, device, re):
    key = secrets.token_bytes(32)
    devices[device] = key
    self.send("pair.accept", {"key": key.hex(), "hostId": HOST_ID, "hostName": HOST_NAME, "fingerprint": FP}, re=re)

  async def plugin(self, typ, body, mid, data):
    reply = lambda b, t=None: self.send(t or typ, b, re=mid)
    if typ == "input.move":
      stats["moves"] += 1; stats["dx"] += body["dx"]; stats["dy"] += body["dy"]
    elif typ == "input.scroll":
      stats["scrolls"] += 1
    elif typ == "input.button":
      stats["buttons"].append([body["button"], body["action"], stats["moves"]])
    elif typ == "status.battery":
      stats["battery"] = body
    elif typ == "screen.ack":
      stats["acks"].append(body["seq"])
      if body["seq"] < 3: self.screen_frame()
    elif typ == "commands.list":
      reply({"commands": [{"id": "hello", "title": "Say hello", "icon": "terminal", "confirm": False, "group": "Tests"}]})
    elif typ == "commands.run":
      if body.get("id") != "hello": self.error("not_found", "No command with id \"%s\"." % body.get("id"), re=mid)
      else: reply({"ok": True, "exitCode": 0, "detached": False})
    elif typ == "notifications.list":
      reply({"notifications": [{"id": 1, "app": "test", "summary": "Hi", "body": "there", "urgency": "normal",
                                "time": int(time.time() * 1000)}]})
    elif typ in ("notifications.phonePosted", "notifications.phoneRemoved"):
      stats["phone"].append({"type": typ, "body": body})
    elif typ == "debug.phoneDismiss":
      reply({"ok": True}); self.send("notifications.phoneDismiss", {"key": body["key"]})
    elif typ == "clipboard.pull":
      reply({"text": "from desktop"})
    elif typ == "clipboard.push":
      stats["clipboard"] = body["text"]; reply({"ok": True})
    elif typ == "share.text":
      text = body["text"].strip()
      opened = text.startswith("http") and " " not in text
      stats["share"]["texts"].append({"text": body["text"], "subject": body.get("subject"), "opened": opened})
      reply({"action": "opened" if opened else "copied"})
    elif typ == "share.begin":
      tid = secrets.token_hex(8)
      uploads[tid] = {"name": body["name"], "size": body["size"], "got": 0, "hash": hashlib.sha256()}
      reply({"transfer": tid})
    elif typ == "share.chunk":
      up = uploads.get(body["transfer"])
      if up is None: self.error("not_found", "No such transfer.", re=mid)
      elif body["offset"] != up["got"]:
        uploads.pop(body["transfer"]); self.error("invalid_argument", "Wrong offset.", re=mid)
      else:
        up["got"] += len(data); up["hash"].update(data)
        await asyncio.sleep(0.05)  # a link that is not instant, so a cancel can land between chunks
        reply({"received": up["got"]})
    elif typ == "share.end":
      up = uploads.pop(body["transfer"], None)
      if up is None: self.error("not_found", "No such transfer.", re=mid)
      else:
        ok = up["got"] == up["size"] and up["hash"].hexdigest() == body["sha256"]
        stats["share"]["files"].append({"name": up["name"], "size": up["got"], "ok": ok, "sha256": up["hash"].hexdigest()})
        if ok: reply({"path": "/home/fake/Downloads/" + up["name"], "name": up["name"]})
        else: self.error("failed", "Damaged.", re=mid)
    elif typ == "share.cancel":
      if uploads.pop(body["transfer"], None) is not None: stats["share"]["cancelled"] += 1
      reply({})
    elif typ == "screen.outputs":
      reply({"outputs": [{"name": "HEADLESS-1", "description": "Fake", "x": 0, "y": 0, "width": 1920, "height": 1080,
                          "scale": 1.0, "focused": True}]})
    elif typ == "screen.start":
      self.seq = 0
      reply({"width": 960, "height": 540})
      self.screen_frame()
    elif typ == "screen.stop":
      reply({"ok": True})
    elif typ == "theme.get":
      reply(theme_obj())
    elif typ == "theme.wallpaper":
      t = theme_obj()
      self.send("theme.wallpaper", {"format": "jpeg", "w": 1080, "h": 608, "wallpaper": t["wallpaper"]}, re=mid,
                data=WALLPAPER + theme["accent"].encode())
    elif typ == "media.art":
      stats["art"] = stats.get("art", 0) + 1
      self.send("media.art", {"format": "jpeg", "w": 512, "h": 512, "artUrl": "file:///fake/cover.png"}, re=mid,
                data=bytes.fromhex("ffd8ffe0") + b"fake cover" + bytes.fromhex("ffd9"))
    elif typ == "debug.stats":
      reply(stats)
    elif typ == "debug.theme":
      theme["accent"] = body["accent"]; reply({"ok": True}); self.send("theme.changed", theme_obj())
    elif typ == "debug.drop":
      reply({"ok": True}); await self.w.drain(); self.w.transport.abort(); return "close"
    elif typ == "debug.close":
      reply({"ok": True}); return "close"
    elif typ == "debug.forget":
      devices.pop(self.device, None); reply({"ok": True}); await self.w.drain(); self.w.transport.abort(); return "close"
    elif typ == "debug.unpair":
      devices.pop(self.device, None); reply({"ok": True}); self.send("pair.unpair", {}); return
    elif typ == "debug.ring":
      reply({"ok": True})
      asyncio.ensure_future(self.ring())
    elif mid is not None:
      self.error("unknown_type", "Unknown " + typ, re=mid)

  async def ring(self):
    try:
      stats["ring"] = (await self.request("status.ring")).get("body")
    except Exception as e:
      stats["ring"] = str(e)

  def screen_frame(self):
    self.seq += 1
    self.send("screen.frame", {"output": "HEADLESS-1", "w": 960, "h": 540, "seq": self.seq, "format": "jpeg",
                               "time": int(time.time() * 1000)}, data=bytes([0xff, 0xd8, self.seq, 0xff, 0xd9]))


class Discovery(asyncio.DatagramProtocol):
  def connection_made(self, transport):
    self.t = transport

  def datagram_received(self, data, addr):
    try:
      q = json.loads(data)
    except ValueError:
      return
    if q.get("ionixlink") != 1 or q.get("type") != "discover": return
    if q.get("want") not in (None, HOST_ID): return
    stats["queries"].append(q)
    announce = {"ionixlink": 1, "type": "announce", "hostId": HOST_ID, "hostName": HOST_NAME, "port": PORT,
                "fingerprint": FP, "protocol": 1, "protocolMin": 1}
    if flag("forge-announce") or flag("forge-only"):
      self.t.sendto(json.dumps(dict(announce, fingerprint="ab" * 32)).encode(), addr)
    if not flag("forge-only"):
      self.t.sendto(json.dumps(announce).encode(), addr)


async def main():
  ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
  ctx.minimum_version = ssl.TLSVersion.TLSv1_2
  ctx.load_cert_chain(CERT, KEY)
  server = await asyncio.start_server(lambda r, w: Conn(r, w).run(), "127.0.0.1", PORT, ssl=ctx, ssl_shutdown_timeout=1)
  imposter_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
  imposter_ctx.load_cert_chain(IMPOSTER_CERT, IMPOSTER_KEY)
  imposter = await asyncio.start_server(lambda r, w: Conn(r, w).run(), "127.0.0.2", PORT, ssl=imposter_ctx,
                                        ssl_shutdown_timeout=1)
  await asyncio.get_running_loop().create_datagram_endpoint(Discovery, local_addr=("127.0.0.1", PORT))
  uri = ("ionixlink://pair?v=1&host=%s&name=%s&port=%d&fp=%s&token=%s&exp=%d&addr=10.255.255.1&addr=127.0.0.1"
         % (HOST_ID, HOST_NAME, PORT, FP, token["value"], int(time.time() * 1000) + 120000))
  with open(os.path.join(STATE, "info.json"), "w") as f:
    json.dump({"port": PORT, "fingerprint": FP, "hostId": HOST_ID, "uri": uri}, f)
  print("listening", PORT, FP, flush=True)
  async with server, imposter:
    await server.serve_forever()


asyncio.run(main())
