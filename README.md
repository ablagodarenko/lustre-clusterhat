# lustre-clusterhat-image

Builds a Raspberry Pi SD-card image that turns a [ClusterHAT](https://clusterhat.com/)
into a complete small Lustre cluster:

| Where | Role |
|---|---|
| controller (Pi 4) | boots the image; serves the nodes' root over NFS, hosts the client VMs |
| p1, p2 (Pi Zero 2 W) | MGS + MDS, active/standby; MGT and MDT mirrored between their SD cards with DRBD |
| p3, p4 (Pi Zero 2 W) | OSS, one OST each on the local SD card |
| client1..8 | KVM guests on the controller |

The build

1. fetches the ClusterHAT controller image and node (usbboot) root from
   `dist.8086.net`,
2. fetches Lustre and the Lustre-patched e2fsprogs from `git.whamcloud.com`,
3. builds Lustre server packages (ldiskfs) for the nodes' Raspberry Pi kernel
   and client packages for the Debian cloud kernel the VMs run,
4. assembles one controller image containing the node root, the client VM
   image, QEMU and the `lustre-cluster` command.

Everything is compiled inside chroots; nothing is installed on the build
host except by `build.sh deps`.

## Building

On an aarch64 Debian or Raspberry Pi OS host (a Pi 4 works), as root, with
about 25 GB free:

```sh
git clone <this repository> && cd lustre-clusterhat-image
sudo ./build.sh deps      # debootstrap, git, curl, xz, rsync, fdisk
sudo ./build.sh           # all stages; several hours on a Pi 4
```

The image appears in `out/`. Stages are resumable: `./build.sh list` shows
them, `./build.sh 40 60 80` re-runs the named ones. Logs are in `work/log/`.

Settings are in `config.sh`; put overrides in `config-local.sh`, for example:

```sh
LUSTRE_REF=v2_17_0                  # tag, branch or commit
NODE_KREL=6.12.109+rpt-rpi-v8       # pin the node kernel
COMPRESS=no
SERIAL_AUTOLOGIN=yes                # passwordless login on the serial console
DEFAULT_USER=                       # no built-in account: prompt on first boot
```

Lustre must have an ldiskfs patch series for the node kernel; the build
stops if no ldiskfs module comes out.

## Using the image

Flash it to the controller's card or SSD. It boots unattended: the first
boot creates the user `lustre` with password `lustre` (sudo without a
password), and SSH and the serial console on GPIO 14/15 are enabled.
**Change the password** with `passwd` unless the controller stays on a
network you trust; anyone who can reach it can log in. Settings made with
Raspberry Pi Imager override the built-in account. Put an SD card in each
Zero, **formatted FAT with no files on it** (see below), and boot the
controller. Then, on the controller:

```sh
sudo lustre-cluster nodes deploy      # give each Zero its root, boot them (~30 min)
sudo lustre-cluster servers format    # DESTROYS the Zeros' SD cards (~20 min)
sudo lustre-cluster up                # start servers, start and mount clients
```

Afterwards:

```sh
lustre-cluster servers status
lustre-cluster servers failover       # move MGT+MDT to the other MDS node
lustre-cluster benchmark all
lustre-cluster down                   # stop clients and servers, power nodes off
lustre-cluster up
```

Clients are `client1`..`client8` at 172.19.180.101-108 with the file system
on `/mnt/lustre`; from the controller, `ssh -i /root/.ssh/lustre-clusterhat
root@172.19.180.101`. Runtime settings (number and size of clients, file
system name, partition sizes) can be overridden in
`/etc/lustre-clusterhat.conf`; the defaults are in `cluster/config.sh`.

## Things worth knowing

- **SD cards and USB boot.** A Zero's boot ROM tries the SD card first and
  falls back to USB boot only if the card has a FAT partition without boot
  files, or there is no card. A card with no FAT partition (exFAT included)
  hangs the node. `servers format` keeps a small empty FAT partition at the
  start of each card for this reason.
- **Power the Zeros on one at a time.** The scripts do. Several starting
  together can brown out the controller's USB bus.
- **Failover is driven from the controller.** There is no cluster manager on
  the nodes. If the active MDS node does not release its targets in time it
  is powered off through the ClusterHAT and rejoins as the standby.
- **Throughput.** All four Zeros share one USB 2.0 bus that carries about
  25 MB/s in total. A single client writes far below that unless
  `llite.*.unstable_stats` is set to 0 in the VM.
- **Memory.** The Zeros have 512 MB. The node root drops the KMS overlay and
  sets `gpu_mem=16`; with the defaults the MDS fails with -ENOMEM.
- **Do not upgrade the node or VM kernel.** The Lustre modules only load on
  the kernels they were built for; the node kernel package is held.

## Releasing an image

A built image carries no keys, accounts or host-specific files: the
controller's SSH key and every machine's host keys are created on first
boot. An image that has been booted does, so publish only what comes out of
`out/`. `out/` also gets a `.sha256` file for the image.

The image contains GPL-licensed binaries built from the sources named in
`/etc/lustre-clusterhat-release` inside it (Lustre commit, e2fsprogs tag,
kernel releases); this repository at the matching tag is the way to rebuild
them. Say which tag an image was built from when you publish it.

## Layout

```
build.sh, lib.sh, config.sh   driver, helpers, build settings
stages/                       the build, in order
cluster/                      what runs on the controller (lustre-cluster)
files/                        systemd units and module options for the image
```

## Status

Tested on a Pi 4 (8 GB) with a ClusterHAT v2.5 and four Pi Zero 2 W:

- A full build on the Pi 4 itself (Lustre 2.17.59 from master, node kernel
  6.12.109+rpt-rpi-v8, client kernel 6.1.0-50-cloud-arm64) produced a
  7.2 GB image.
- The image's `/opt/lustre-clusterhat` and `/var/lib/lustre-clusterhat` were
  copied onto a running controller and exercised there: `init`,
  `nodes deploy`, `servers start`, `clients start|mount`,
  `servers failover`, `servers failover hard`, `down` and `up` all worked,
  with eight clients recovering after each failover.

- The image was then flashed to a 32 GB card and booted on the Pi 4. The
  first-boot service ran, the root filesystem grew to the card, and
  `nodes deploy` followed by `up` brought the cluster up on the existing
  targets with all eight clients mounted. One Zero did not appear on USB
  after its first boot and needed a power cycle; `nodes` now retries that.
  SSH and the serial console were off in that image and have been enabled
  in the build since.

Not tested: an image built after those last changes, `servers format` from
this repository's copy of the scripts, a build with the default (newest)
node kernel, xz compression of the output, and a Pi 5 controller.

Known rough edges of the base image: the bridged controller waits only two
seconds for a DHCP lease and otherwise falls back to 172.19.181.254, in
which case it has no IPv4 address on the LAN, no DNS and the wrong time.
