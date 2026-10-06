# Build settings.  Do not edit: put overrides in config-local.sh.

# Where things go.  $WORK needs about 25 GB.
WORK=${WORK:-$TOP/work}
OUT=${OUT:-$TOP/out}

# ClusterHAT (ClusterCTRL) images: https://clusterhat.com/setup-software
CH_BASE=${CH_BASE:-https://dist.8086.net/clusterctrl}
CH_RELEASE=${CH_RELEASE:-bookworm}
CH_DATE=${CH_DATE:-2025-11-24}
CH_REV=${CH_REV:-1}
CH_FLAVOUR=${CH_FLAVOUR:-lite}
# CBRIDGE (nodes bridged to the LAN) or CNAT
CH_TYPE=${CH_TYPE:-CBRIDGE}
CH_NAME=$CH_DATE-$CH_REV-$CH_RELEASE-ClusterCTRL-arm64-$CH_FLAVOUR
CTRL_IMAGE_URL=${CTRL_IMAGE_URL:-$CH_BASE/$CH_RELEASE/$CH_DATE/$CH_NAME-$CH_TYPE.img.xz}
NODE_ROOT_URL=${NODE_ROOT_URL:-$CH_BASE/usbboot/$CH_RELEASE/$CH_DATE/$CH_NAME-usbboot.tar.xz}

# Lustre and the Lustre-patched e2fsprogs
LUSTRE_GIT=${LUSTRE_GIT:-git://git.whamcloud.com/fs/lustre-release.git}
LUSTRE_REF=${LUSTRE_REF:-master}
E2FS_GIT=${E2FS_GIT:-git://git.whamcloud.com/tools/e2fsprogs.git}
E2FS_TAG=${E2FS_TAG:-v1.47.3-wc3}

# Kernel release the server nodes run, e.g. 6.12.109+rpt-rpi-v8.  Empty:
# the newest linux-image-rpi-v8 in the Raspberry Pi archive.  Lustre must
# have an ldiskfs patch series for it.
NODE_KREL=${NODE_KREL:-}

# Client VMs run the Debian cloud kernel of this suite
DEBIAN_SUITE=${DEBIAN_SUITE:-bookworm}
DEBIAN_MIRROR=${DEBIAN_MIRROR:-http://deb.debian.org/debian}
VM_DISK=${VM_DISK:-2G}

# Free space left in the controller image beyond what the build puts in.
# Raspberry Pi OS grows the root filesystem to the whole card on first boot.
IMAGE_SLACK_MB=${IMAGE_SLACK_MB:-1024}
# xz-compress the finished image (slow on a Pi): yes or no
COMPRESS=${COMPRESS:-yes}
# GitHub release assets must stay under 2 GiB
XZ_LEVEL=${XZ_LEVEL:-6}

# Account created on the controller's first boot, so that it comes up
# without anyone at the console.  The password is public knowledge and sshd
# is enabled: change it (passwd) once the controller is on a network you do
# not control.  Set DEFAULT_USER empty to get Raspberry Pi OS's own
# first-boot prompt (or Raspberry Pi Imager's settings) instead.
DEFAULT_USER=${DEFAULT_USER-lustre}
DEFAULT_PASSWORD=${DEFAULT_PASSWORD-lustre}

# The controller is meant to run headless: sshd is enabled and the serial
# console (GPIO 14/15, 115200) is switched on.  By default the first user
# is logged in on that console without a password, which lets scripts
# drive it; anyone with access to the pins gets a shell.  "no" asks for
# a login as usual.
SERIAL_AUTOLOGIN=${SERIAL_AUTOLOGIN:-yes}

JOBS=${JOBS:-$(nproc)}
