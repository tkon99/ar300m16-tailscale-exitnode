# GL.iNet AR300M16 — OpenWrt + Tailscale exit-node firmware builder

One script that builds a **custom OpenWrt 22.03.4 image for the GL.iNet
GL-AR300M16 (NOR-only, incl. -EXT)** with a size-optimized, **current-version
Tailscale client baked into the firmware**, ready to run as a **Tailscale exit
node**.

## Why this exists

The AR300M16 has a 16 MB NOR flash chip. GL.iNet's stock 4.3.27 firmware uses
15.6 MB of it, leaving ~460 KB of free overlay — Tailscale needs ~10 MB
compressed, so it can **never** be installed via opkg on the stock firmware,
and GL.iNet doesn't ship it for this model.

A vanilla OpenWrt image for this device is only ~5.5 MB. Baking a
feature-trimmed Tailscale (built from current source, combined
busybox-style binary) into the squashfs brings the total to ~11.8 MB —
comfortably inside the ~15.8 MB firmware partition.

## What you get

- OpenWrt 22.03.4 with LuCI (web UI) at `192.168.8.1` (changeable, so it won't
  collide with home networks on `192.168.1.0/24`)
- Tailscale (default: v1.102.3, override with `TAILSCALE_VERSION=...`) as one
  combined `tailscale`/`tailscaled` binary, MIPS32 soft-float, statically linked
- `tailscaled` running at boot via procd; exit-node advertisement is one
  command after first login
- iptables-nft compatibility layer (Tailscale programs its exit-node
  NAT/masquerade rules through it under fw4/nftables)
- kmod-tun included
- Root password of your choice (or auto-generated random) baked in as a hash

## Requirements

- Linux x86_64 with `bash`, `curl`, `git`, `tar`, `perl`, `python3`,
  `openssl`, `make`, `file`
- ~2 GB free disk and internet access (downloads the OpenWrt imagebuilder,
  a Go toolchain into `.build/`, and the Tailscale source — all local to the
  build directory; nothing is installed system-wide)
- On minimal-Perl distros (e.g. Fedora) the missing `FindBin` module is
  worked around automatically with a local shim

## Usage

```sh
chmod +x build.sh                # in case the download lost the exec bit
./build.sh                       # random root password, printed at the end
FW_ROOT_PASSWORD='hunter2' ./build.sh
LAN_IP=192.168.9.1 ./build.sh    # different LAN address
TAILSCALE_VERSION=v1.102.3 ./build.sh
```

Output lands in `out/`: the `...-squashfs-sysupgrade.bin` image, its manifest,
`SHA256SUMS`, and `root-password.txt` (mode 600).

## Flashing

From a **running OpenWrt or GL.iNet system**:

```sh
scp -O out/openwrt-*-squashfs-sysupgrade.bin root@192.168.8.1:/tmp/fw.bin
#                     ^^^ -O! GL.iNet busybox has no SFTP server
ssh root@192.168.8.1 'sysupgrade -n /tmp/fw.bin'   # -n = wipe settings
```

From a **bricked device / U-Boot mode** (this bootloader survives any firmware
flash):

1. Set your PC's Ethernet to static `192.168.1.2/24`, cable to the **LAN** port
2. Hold **Reset**, power on, keep holding until the LED has flashed ~5×
3. Browse to `http://192.168.1.1`, upload the sysupgrade.bin, wait ~3 minutes

The AR300M16 has a **NOR/NAND slider switch** on the case edge. The M16 has no
NAND chip — the switch must be in the **NOR** position (away from the reset
button) or the router will not boot, which looks exactly like a brick.

## First boot & exit-node setup

The first boot may watchdog-reset once on these boxes — give it 5 minutes
before declaring failure.

```sh
ssh root@192.168.8.1                # password from out/root-password.txt
tailscale up --advertise-exit-node --hostname=ar300m16
# open the printed login URL, approve the device, then in the Tailscale
# admin console: Machines -> ar300m16 -> "..." -> Enable exit node
```

Connect the router's **WAN** port to any internet uplink (e.g. your home
router) — the exit node egresses through it.

**Performance expectation:** the QCA9533 is a 650 MHz MIPS CPU doing
userspace crypto. Expect roughly **10–25 Mbps** through the exit node.

## Build-tag caveat (important)

Upstream's own `build_dist.sh --extra-small` currently selects tags that
**omit `advertiseexitnode` and `iptables`** — a binary built that way will
join your tailnet but cannot act as an exit node. This repo passes its own
`--remove` list to `cmd/featuretags`, keeping all exit-node-critical features
(`advertiseexitnode`, `osrouter`, `iptables`, `dns`, `netstack`,
`useexitnode`, `useroutes`, `portmapper`, ...) while dropping ~53 irrelevant
ones (SSH server, web client, Serve/Funnel, Taildrop, Drive, cloud/K8s
integrations, desktop bits...). If a future Tailscale renames features and tag
selection fails, the script falls back to a full (larger, still fitting)
build rather than a broken one.

## Rollback

GL.iNet stock firmware can always be restored via the U-Boot web page
(see above) — get the AR300M16 image from
[dl.gl-inet.com](https://dl.gl-inet.com/?model=ar300m16) (or the
[community mirror](https://gl-fw.remotetohome.io/) of GL.iNet's archive).

## Security notes

- The image contains a **SHA-512 hash** of the root password (via
  `/etc/shadow`), never the plaintext. Don't publish built images if you set
  your own password.
- Tailscale state lives in `/var/lib/tailscale` (tmpfs on OpenWrt) — the
  device re-authenticates after each reboot via its stored keys in flash;
  if you want fully persistent state, move `--state` to a USB stick mount.

## Credits

Built on [OpenWrt](https://openwrt.org), [Tailscale](https://tailscale.com),
and GL.iNet's otherwise excellent little router. See `LICENSE` (MIT).
