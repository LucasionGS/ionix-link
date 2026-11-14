# Maintainer: Lucas <lucasion@hotmail.com>
#
# Builds the desktop side of Ionix Link from the working tree; this is what the
# Ionix ISO ships. aur/build-aur.sh copies this directory into a scratch build dir
# first, so makepkg never writes into the git checkout.
#
# Same package name and version scheme as the AUR package (packaging/aur/PKGBUILD),
# so the shipped copy is upgraded by `yay -Syu` once the [ionix] repo is gone.
# The two PKGBUILDs differ only in where the sources come from: keep
# depends/optdepends in sync between them.

pkgname=ionix-link-git
_pkgname=ionix-link
# Placeholder only; pkgver() below overwrites it on every build.
pkgver=r0.0000000
pkgrel=1
pkgdesc="Ionix Link desktop daemon: pair a phone for notifications, media, commands and remote input (git)"
arch=('any')
url="https://github.com/LucasionGS/ionix-link"
license=('MIT')
depends=(
    'python'
    # The daemon's TLS certificate is generated with the openssl CLI.
    'openssl'
    'systemd'
)
optdepends=(
    'qrencode: show the pairing QR code in the terminal'
    'libnotify: confirm a pairing by code from a desktop notification'
    'playerctl: media remote'
    'wireplumber: volume control (wpctl)'
    'libpulse: instant volume updates (pactl subscribe)'
    'wl-clipboard: clipboard push and pull'
    'wtype: typing from the phone keyboard'
    'grim: screen view'
    'hyprland: list monitors for the screen view'
    'wlr-randr: list monitors on other wlroots compositors'
)
provides=("$_pkgname")
conflicts=("$_pkgname")
source=()

# Must match packaging/aur/aur-publish.sh's formula exactly. build-aur.sh strips
# .git from the scratch copy and writes the version to .pkgver beforehand.
pkgver() {
    if [[ -f "$startdir/.pkgver" ]]; then
        cat "$startdir/.pkgver"
    elif git -C "$startdir" rev-parse HEAD >/dev/null 2>&1; then
        printf "r%s.%s" \
            "$(git -C "$startdir" rev-list --count HEAD)" \
            "$(git -C "$startdir" rev-parse --short HEAD)"
    else
        printf '%s' "$pkgver"
    fi
}

package() {
    make -C "$startdir" DESTDIR="$pkgdir" PREFIX=/usr PKGNAME="$pkgname" install
}
