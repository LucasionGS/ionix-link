# Installs the desktop side of Ionix Link: the daemon/CLI and its user unit.
# The phone app in app/ is built with Flutter and is not part of this package.

PREFIX  ?= /usr
PKGNAME ?= ionix-link
BINDIR   = $(DESTDIR)$(PREFIX)/bin
UNITDIR  = $(DESTDIR)$(PREFIX)/lib/systemd/user
LICDIR   = $(DESTDIR)$(PREFIX)/share/licenses/$(PKGNAME)
DOCDIR   = $(DESTDIR)$(PREFIX)/share/doc/$(PKGNAME)

.PHONY: install uninstall apk

install:
	install -Dm755 bin/ionix-link $(BINDIR)/ionix-link
	install -Dm644 systemd/ionix-link.service $(UNITDIR)/ionix-link.service
	install -Dm644 PROTOCOL.md $(DOCDIR)/PROTOCOL.md
	install -Dm644 LICENSE $(LICDIR)/LICENSE

uninstall:
	rm -f $(BINDIR)/ionix-link $(UNITDIR)/ionix-link.service
	rm -rf $(LICDIR) $(DOCDIR)

# Debug APK of the phone app, at app/build/app/outputs/flutter-apk/app-debug.apk
apk:
	cd app && flutter build apk --debug
