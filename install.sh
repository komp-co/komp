#!/usr/bin/env sh
# Installs komp: its release for this machine, checked against the sha256
# published beside it, as $KFLAT_HOME/bin/komp ($KFLAT_HOME is ~/.kflat
# unless set). When there is no kflatc beside it yet, `komp toolchain
# install` then adds the newest kflat toolchain.
#
#   curl -fsSL https://github.com/komp-co/komp/releases/latest/download/install.sh | sh
#
# KOMP_VERSION installs another release than the newest; KOMP_RELEASES takes
# them from elsewhere, laid out as GitHub lays out releases.
set -eu

home="${KFLAT_HOME:-$HOME/.kflat}"
releases="${KOMP_RELEASES:-https://github.com/komp-co/komp/releases}"
version="${KOMP_VERSION:-}"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64 | Linux-amd64) target=linux-x86_64 ;;
    Linux-aarch64 | Linux-arm64) target=linux-aarch64 ;;
    *) fail "komp publishes no build for $(uname -s) $(uname -m)" ;;
esac

command -v curl > /dev/null 2>&1 || fail "installing komp needs curl"
if [ -z "$version" ]; then
    landed="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$releases/latest")" ||
        fail "cannot reach $releases/latest"
    version="${landed##*/tag/v}"
    [ "$version" != "$landed" ] || fail "cannot tell the newest release from $releases/latest"
fi

name="komp-$version-$target"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
url="$releases/download/v$version/$name.tar.gz"
curl -fsSL -o "$work/$name.tar.gz" "$url" && curl -fsSL -o "$work/$name.tar.gz.sha256" "$url.sha256" ||
    fail "cannot download $url and its .sha256; is $version a release?"
want="$(cut -d' ' -f1 "$work/$name.tar.gz.sha256")"
got="$( (sha256sum "$work/$name.tar.gz" 2> /dev/null || shasum -a 256 "$work/$name.tar.gz") | cut -d' ' -f1)"
[ "$got" = "$want" ] || fail "$name.tar.gz does not match its published sha256"
tar -xzf "$work/$name.tar.gz" -C "$work" || fail "cannot unpack $name.tar.gz"

mkdir -p "$home/bin"
# Copied beside the old one, then renamed over it: a rename replaces a
# running komp, or the link an earlier install left, whole.
cp "$work/$name/bin/komp" "$home/bin/komp.new"
chmod 755 "$home/bin/komp.new"
mv -f "$home/bin/komp.new" "$home/bin/komp"
echo "installed komp $version as $home/bin/komp"

if [ ! -e "$home/bin/kflatc" ]; then
    KFLAT_HOME="$home" "$home/bin/komp" toolchain install
fi

case ":${PATH:-}:" in
    *":$home/bin:"*) ;;
    *) echo "add $home/bin to PATH, for example in your shell profile:"
       echo "    export PATH=\"$home/bin:\$PATH\"" ;;
esac
