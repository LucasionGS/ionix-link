# Installs the desktop side of Ionix Link: the daemon/CLI, its user unit and the
# udev rule that lets it make the phone desktop's touchscreen.
# The phone app in app/ is built with Flutter and is not part of this package.

PREFIX  ?= /usr
PKGNAME ?= ionix-link
BINDIR   = $(DESTDIR)$(PREFIX)/bin
UNITDIR  = $(DESTDIR)$(PREFIX)/lib/systemd/user
UDEVDIR  = $(DESTDIR)$(PREFIX)/lib/udev/rules.d
LICDIR   = $(DESTDIR)$(PREFIX)/share/licenses/$(PKGNAME)
DOCDIR   = $(DESTDIR)$(PREFIX)/share/doc/$(PKGNAME)

.PHONY: install uninstall apk

install:
	install -Dm755 bin/ionix-link $(BINDIR)/ionix-link
	install -Dm644 systemd/ionix-link.service $(UNITDIR)/ionix-link.service
	install -Dm644 udev/70-ionix-link-uinput.rules $(UDEVDIR)/70-ionix-link-uinput.rules
	install -Dm644 PROTOCOL.md $(DOCDIR)/PROTOCOL.md
	install -Dm644 LICENSE $(LICDIR)/LICENSE

uninstall:
	rm -f $(BINDIR)/ionix-link $(UNITDIR)/ionix-link.service $(UDEVDIR)/70-ionix-link-uinput.rules
	rm -rf $(LICDIR) $(DOCDIR)

# Debug APK of the phone app, at app/build/app/outputs/flutter-apk/app-debug.apk
apk:
	cd app && flutter build apk --debug
