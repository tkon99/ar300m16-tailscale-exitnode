#!/usr/bin/env bash
#
# Build a custom OpenWrt firmware image for the GL.iNet GL-AR300M16 (NOR-only)
# with a size-optimized, current-version Tailscale client baked into the
# squashfs — configured as a Tailscale exit node.
#
# Why this exists: the AR300M16 has 16 MB of NOR flash. GL.iNet stock firmware
# leaves ~460 KB of overlay free, so Tailscale (~10 MB compressed / ~27 MB
# installed) can never be opkg-installed. A vanilla OpenWrt image is only
# ~5.5 MB, which leaves just enough room for Tailscale inside the squashfs.
#
# Tested with OpenWrt 22.03.4 / Tailscale v1.102.3 on GL-AR300M16-EXT.
#
set -euo pipefail
cd "$(dirname "$0")"
REPO_ROOT=$PWD

# ---------------------------------------------------------------- config ----
OPENWRT_VERSION=${OPENWRT_VERSION:-22.03.4}
TAILSCALE_VERSION=${TAILSCALE_VERSION:-v1.102.3}
TARGET=${TARGET:-ath79/nand}          # the ar300m NOR profiles live in ath79/nand
PROFILE=${PROFILE:-glinet_gl-ar300m-nor}
LAN_IP=${LAN_IP:-192.168.8.1}         # vanilla OpenWrt defaults to 192.168.1.1,
                                      # which collides with many home LANs
# Root password for the router. If FW_ROOT_PASSWORD is unset a random one is
# generated, used for the image, and printed at the end. The image contains
# only a SHA-512 hash (via /etc/shadow), never the plaintext.
ROOT_PASSWORD=${FW_ROOT_PASSWORD:-$(openssl rand -base64 18 | tr -d '\n')}

WORKDIR=${WORKDIR:-$REPO_ROOT/.build}
OUTDIR=$REPO_ROOT/out
mkdir -p "$WORKDIR" "$OUTDIR"

# Features compiled out of tailscaled to shrink it. Exit-node-critical
# features are deliberately KEPT: advertiseexitnode, osrouter, iptables,
# dns, netstack, useexitnode, useroutes, portmapper, gro, health.
# NOTE: upstream's own "build_dist.sh --extra-small" omits advertiseexitnode
# and iptables — do NOT use it blindly for an exit node.
# unixsocketidentity must NOT be omitted either: with ts_omit_unixsocketidentity
# (verified on v1.102.3) ipn/ipnauth/ipnauth_unix_creds.go is compiled out,
# connections are never classified as unix sockets, and tailscaled's localapi
# denies EVERY client — all `tailscale ...` commands fail with
# "Access denied: status access denied", despite the feature description
# claiming "if omitted, all users have full access".
TS_REMOVE_FEATURES="ssh,webclient,serve,drive,taildrop,appconnectors,relayserver,flashappliance,cloud,aws,kube,bird,synology,networkmanager,resolved,systray,desktop_sessions,dbus,sdnotify,syspolicy,tpm,wakeonlan,qrcodes,colorable,completion,completion_scripts,doctor,acme,bakedroots,captiveportal,clientupdate,identityfederation,outboundproxy,tap,posture,portlist,netlog,capture,webbrowser,hujsonconf,serviceclientprefs,runtimemetrics,usermetrics,debugeventbus,debug,debugportmapper,cliconndiag,remoteconfig,conn25,useproxy"

log() { printf '\n==> %s\n' "$*"; }

# ---------------------------------------------------- 1. OpenWrt imagebuilder
IB_TAR="openwrt-imagebuilder-${OPENWRT_VERSION}-ath79-nand.Linux-x86_64.tar.xz"
IB_DIR="$WORKDIR/openwrt-imagebuilder-${OPENWRT_VERSION}-ath79-nand.Linux-x86_64"
if [ ! -d "$IB_DIR" ]; then
    log "Downloading OpenWrt imagebuilder ${OPENWRT_VERSION}..."
    curl -fLsS -o "$WORKDIR/$IB_TAR" \
        "https://downloads.openwrt.org/releases/${OPENWRT_VERSION}/targets/ath79/nand/$IB_TAR"
    tar -C "$WORKDIR" -xf "$WORKDIR/$IB_TAR"
fi
# imagebuilder needs a tmp/ dir and generates an empty .profiles.mk when perl
# is missing FindBin (e.g. Fedora's minimal perl) — fix both non-interactively.
mkdir -p "$IB_DIR/tmp"
PERL5LIB_DIR="$WORKDIR/perl5lib"
if ! perl -MFindBin -e 1 >/dev/null 2>&1; then
    log "Perl FindBin missing; installing local shim..."
    mkdir -p "$PERL5LIB_DIR"
    cat > "$PERL5LIB_DIR/FindBin.pm" <<'EOF'
package FindBin;
use Cwd qw(abs_path);
use Exporter "import";
our @EXPORT = qw($Bin $RealBin $Script);
($RealBin = abs_path($0)) =~ s{/[^/]+$}{};
$Bin = $RealBin;
($Script = $0) =~ s{.*/}{};
1;
EOF
fi
export PERL5LIB=${PERL5LIB:+$PERL5LIB:}$PERL5LIB_DIR

if [ ! -s "$IB_DIR/.profiles.mk" ]; then
    log "Regenerating imagebuilder profile metadata..."
    (cd "$IB_DIR" && perl scripts/target-metadata.pl profile_mk .targetinfo \
        "${TARGET%%/*}/${TARGET##*/}" > .profiles.mk)
fi

# ------------------------------------------------------------- 2. Go toolchain
if [ -z "${GO_VERSION:-}" ]; then
    GO_VERSION=$(curl -fsSm 15 'https://go.dev/VERSION?m=text' | head -1)
fi
if [ ! -x "$WORKDIR/go/bin/go" ]; then
    log "Installing Go ${GO_VERSION} (local to .build/)... "
    curl -fLsS -o "$WORKDIR/go.tgz" "https://go.dev/dl/${GO_VERSION}.linux-amd64.tar.gz"
    rm -rf "$WORKDIR/go" && tar -C "$WORKDIR" -xzf "$WORKDIR/go.tgz"
fi
export GOMODCACHE=$WORKDIR/go-mod GOPATH=$WORKDIR/go-path GOCACHE=$WORKDIR/go-cache
export PATH="$WORKDIR/go/bin:$PATH"

# ------------------------------------------------------- 3. Tailscale source
TS_SRC="$WORKDIR/tailscale-src"
if [ ! -d "$TS_SRC" ]; then
    log "Cloning Tailscale ${TAILSCALE_VERSION}..."
    git clone --depth 1 --branch "$TAILSCALE_VERSION" \
        https://github.com/tailscale/tailscale.git "$TS_SRC"
fi

# ------------------------------------------- 4. Pick build tags, cross-compile
log "Resolving feature-omission build tags (keeping exit-node features)..."
cd "$TS_SRC"
TS_TAGS=$(go run ./cmd/featuretags --add=cli --remove="$TS_REMOVE_FEATURES") \
    || TS_TAGS=""
if [ -z "$TS_TAGS" ]; then
    echo "WARNING: feature tag selection failed (features renamed upstream?)." >&2
    echo "Falling back to a full-featured (larger) tailscaled." >&2
    TS_TAGS="ts_include_cli"
fi
log "Build tags: $TS_TAGS"

log "Cross-compiling tailscaled for MIPS32 soft-float (mips_24kc)..."
TS_SHORT=${TAILSCALE_VERSION#v}
GOOS=linux GOARCH=mips GOMIPS=softfloat CGO_ENABLED=0 \
    go build \
    -tags "$TS_TAGS" \
    -ldflags "-s -w -X tailscale.com/version.longStamp=${TS_SHORT}-ar300m16 -X tailscale.com/version.shortStamp=${TS_SHORT}" \
    -o "$WORKDIR/tailscaled" \
    ./cmd/tailscaled
file "$WORKDIR/tailscaled"
cd "$REPO_ROOT"

# ------------------------------------------------- 5. Assemble FILES overlay
FILES="$WORKDIR/image-files"
rm -rf "$FILES"
mkdir -p "$FILES/usr/sbin" "$FILES/usr/bin" \
         "$FILES/etc/init.d" "$FILES/etc/uci-defaults"

# procd service for the combined binary (busybox-style argv0 dispatch)
install -m 755 overlay/etc/init.d/tailscale "$FILES/etc/init.d/tailscale"
# combined binary runs as the daemon; a symlink named "tailscale" becomes the CLI
install -m 755 "$WORKDIR/tailscaled" "$FILES/usr/sbin/tailscaled"
ln -s /usr/sbin/tailscaled "$FILES/usr/bin/tailscale"
# enable the service on first boot
install -m 755 overlay/etc/uci-defaults/98-tailscale "$FILES/etc/uci-defaults/"
# LAN address (generated here so LAN_IP stays configurable)
cat > "$FILES/etc/uci-defaults/99-lan-ip" <<EOF
uci set network.lan.ipaddr='${LAN_IP}'
uci commit network
EOF
# root password — SHA-512 hash only, never plaintext, in the generated image
PW_HASH=$(openssl passwd -6 "$ROOT_PASSWORD")
python3 - "$PW_HASH" "$FILES/etc/uci-defaults/97-rootpw" <<'PYEOF'
import sys
h, out = sys.argv[1], sys.argv[2]
assert "'" not in h, "unexpected quote in hash"
prog = 'BEGIN{OFS=":"} $1=="root"{$2=h} {print}'
script = "awk -v h='%s' -F: '%s' /etc/shadow > /etc/shadow.new && mv /etc/shadow.new /etc/shadow\n" % (h, prog)
open(out, "w").write("#!/bin/sh\n" + script)
PYEOF
chmod 755 "$FILES/etc/uci-defaults/97-rootpw"

# ------------------------------------------------------------ 6. Build image
log "Building image (this also validates all package downloads)..."
# kmod-tun is REQUIRED (tailscaled needs /dev/net/tun); iptables-nft lets
# tailscaled program its rules under fw4/nftables — but the userspace compat
# layer alone is NOT enough: without kmod-ipt-nat, kmod-ipt-conntrack,
# kmod-ipt-conntrack-extra and the iptables-mod-conntrack-extra/-ipopt plugin
# packages, tailscaled's ts-postrouting MASQUERADE and connmark rules fail
# ("Chain 'MASQUERADE' does not exist" / "Couldn't load match `connmark'")
# and the exit node joins the tailnet but can never NAT client traffic out.
# Verified live on 22.03.4 / Tailscale v1.102.3.
PACKAGES="luci iptables-nft ip6tables-nft kmod-tun kmod-ipt-nat kmod-ipt-conntrack kmod-ipt-conntrack-extra iptables-mod-conntrack-extra iptables-mod-ipopt"
make -C "$IB_DIR" image PROFILE="$PROFILE" PACKAGES="$PACKAGES" FILES="$FILES"

# --------------------------------------------------------------- 7. Collect
IMG=$(ls "$IB_DIR"/bin/targets/ath79/nand/*-"$PROFILE"-squashfs-sysupgrade.bin | head -1)
cp "$IMG" "$OUTDIR/"
cp "$IB_DIR"/bin/targets/ath79/nand/*-"$PROFILE".manifest "$OUTDIR/" 2>/dev/null || true
( cd "$OUTDIR" && sha256sum ./* > SHA256SUMS )

IMG_BYTES=$(stat -c %s "$IMG")
log "Done."
echo
echo "    Image:      out/$(basename "$IMG")"
echo "    Size:       $IMG_BYTES bytes (flash budget ~16,580,000 for the firmware partition)"
if [ "$IMG_BYTES" -gt 15500000 ]; then
    echo "    WARNING: image is close to / over the NOR firmware partition budget!"
fi
echo "    Root password for the router:  $ROOT_PASSWORD"
echo "    (also stored in out/root-password.txt; the image contains only its hash)"
printf '%s\n' "$ROOT_PASSWORD" > "$OUTDIR/root-password.txt"
chmod 600 "$OUTDIR/root-password.txt"
echo
echo "    Flash from a running OpenWrt/GL.iNet system:"
echo "      scp -O out/$(basename "$IMG") root@<router>:/tmp/fw.bin"
echo "      ssh root@<router> 'sysupgrade -n /tmp/fw.bin'"
echo
echo "    After it reboots (first boot may watchdog-reset once — give it 5 min):"
echo "      ssh root@${LAN_IP}   # password above"
echo "      tailscale up --advertise-exit-node --hostname=ar300m16"
