# v0.1: Lustre 2.17.59 on a ClusterHAT

The first image: a Raspberry Pi 4 with a ClusterHAT and four Pi Zero 2 W
becomes a Lustre cluster with two active metadata servers, two active object
storage servers, failover between the nodes of each pair, and eight client
VMs.

**Instructions: [Using the image](https://github.com/ablagodarenko/lustre-clusterhat#using-the-image)**

## Download

`lustre-2_17_59-1-g4a7bddaf15-2025-11-24-1-bookworm-ClusterCTRL-arm64-lite-CBRIDGE.img.xz` (1.1 GB, 7.1 GB unpacked)

    sha256  3083753073d77ea820711feda6b4c6df6eb6033c4051416240deee7011b50c91

Flash it to a 16 GB or larger card with Raspberry Pi Imager ("Use custom");
Imager reads the `.xz` directly. Leave Imager's own user and network settings
empty.

## First boot

The controller comes up unattended as `cbridge` with user `lustre`, password
`lustre` (sudo without a password), SSH enabled and a login on the serial
console (GPIO 14/15, 115200 baud). **Change the password** with `passwd`
unless it stays on a network you trust. Then:

    sudo lustre-cluster nodes deploy      # about 30 minutes
    sudo lustre-cluster servers format    # ERASES the Zeros' SD cards, about 25 minutes
    sudo lustre-cluster up

Each Zero needs an SD card formatted FAT with no files on it, or it will not
boot from USB.

`man lustre-cluster` on the controller describes every command. Later fixes
to the scripts can be installed without reflashing:

    sudo lustre-cluster update

## What is inside

| | |
|---|---|
| Lustre | 2.17.59 (`v2_17_59-1-g4a7bddaf15`, master), servers with ldiskfs |
| e2fsprogs | 1.47.3-wc3 |
| Server nodes | Raspberry Pi OS bookworm arm64, kernel 6.12.109+rpt-rpi-v8 |
| Client VMs | Debian 12 arm64, kernel 6.1.0-50-cloud-arm64 |
| Controller | ClusterCTRL 2025-11-24 (bookworm, arm64, lite, CBRIDGE) |
| Built from | this repository at tag `v0.1` |

The image contains GPL-licensed software. Its sources are the Lustre commit
and e2fsprogs tag above, from git.whamcloud.com, and the kernel packages
named above from the Raspberry Pi and Debian archives; this repository at
`v0.1` rebuilds the image from them.

## Known limitations

- Moving the MGS or an MDT to the other node power-cycles the node it
  leaves, because the unmount hangs on this Lustre version. Expect four to
  seven minutes. OSS moves take seconds.
- Throughput is low: about 6 MB/s for a single writer. Every write is
  mirrored to the partner node over the one USB bus the Zeros share.
- 97 GB usable with 128 GB cards in the OSS nodes.
- Tested on a Pi 4 with a ClusterHAT v2.5 only.
