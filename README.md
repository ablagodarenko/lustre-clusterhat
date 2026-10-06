# lustre-clusterhat-image

Builds a Raspberry Pi SD-card image that turns a [ClusterHAT](https://clusterhat.com/)
into a complete small Lustre cluster:

| Where | Role |
|---|---|
| controller (Pi 4) | boots the image; serves the nodes' root over NFS, hosts the client VMs |
| p1 (Pi Zero 2 W) | MGS + MDS: MDT0000 at home here |
| p2 (Pi Zero 2 W) | MDS: MDT0001 at home here |
| p3, p4 (Pi Zero 2 W) | OSS: OST0000 at home on p3, OST0001 on p4 |
| client1..8 | KVM guests on the controller |

Both MDS nodes and both OSS nodes are active. The Zeros share no storage,
so every target is a DRBD device mirrored between the SD cards of its pair
(p1/p2, p3/p4) and either node of the pair can serve it: on request a
node's targets move to its partner, and back.

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
lustre-cluster servers status         # where each target is, mirror state
lustre-cluster servers failover 1     # p1's targets (MGS, MDT0000) move to p2
lustre-cluster servers failover 3 hard  # as if p3 had crashed: OST0000 to p4
lustre-cluster servers failback       # every target back on its home node
lustre-cluster throttle on 8          # 8 MB/s of disk I/O, shared between the OSTs
lustre-cluster throttle off
lustre-cluster benchmark all
lustre-cluster down                   # stop clients and servers, power nodes off
lustre-cluster up
```

`throttle on B` divides a band of B MB/s evenly between the OSTs, for
reads and for writes, so that storage rather than the network is the
bottleneck and the effect of striping shows. It is Lustre's own request
limiter (the NRS TBF policy on the OSS I/O service) with clients switched to
1 MB requests: accurate for streaming I/O, harsher on small files, and per
OSS node - a node serving both OSTs after a failover gets the whole band.

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
  the nodes; nothing moves unless you ask. A move waits for the pair's
  mirrors to be in sync and refuses if the partner is down.
- **MDS moves go through a power cycle.** Unmounting the MGS (and often an
  MDT) hangs on this Lustre version, waiting for exports that are never
  released. After `UMOUNT_TIMEOUT` seconds the node is powered off through
  the ClusterHAT, its partner takes over, and it rejoins as the standby.
  Expect four to six minutes for an MDS failover or failback, during which
  clients block and then recover. OSS moves are clean and take seconds.
- **Mirroring costs throughput and space.** Every write to a target is also
  sent to its partner over the USB bus all four Zeros share, and each OSS
  card holds both OSTs: about 6 MB/s for a single writer and 2 x 50 GB.
- **Throughput.** All four Zeros share one USB 2.0 bus that carries about
  25 MB/s in total, for client traffic and mirroring together. With
  buffered I/O a single client writes far below even that unless
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

Tested on a Pi 4 (8 GB) with a ClusterHAT v2.5 and four Pi Zero 2 W, with
Lustre 2.17.59 from master, node kernel 6.12.109+rpt-rpi-v8 and client
kernel 6.1.0-50-cloud-arm64:

- Full builds on the Pi 4 itself.
- An earlier image (single MDT, no OST mirroring) flashed to a card and
  booted: first-boot setup, `nodes deploy` and `up` worked.
- The current layout, with the `cluster/` scripts installed on a running
  controller: `servers format`, `up`, directories spread over both MDTs,
  `failover` and `failback` of each MDS node and of the OSS nodes with a
  client reading and writing after every move, and `throttle`.

Not tested: an image built with the current layout booted from a card; the
default account and the SSH and serial settings added after the booted
image; a build with the default (newest) node kernel; a Pi 5 controller;
load beyond single-client streaming I/O with the current layout.

Known rough edges of the base image: the bridged controller waits only two
seconds for a DHCP lease and otherwise falls back to 172.19.181.254, in
which case it has no IPv4 address on the LAN, no DNS and the wrong time.
