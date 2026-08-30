#!/usr/bin/env bash
# Bakes the packages every CAPI node needs into the Ubuntu 24.04 minimal
# cloud image, and emits the image, its package manifest and SHA256SUMS.
#
# Consumed by jrytio/infra stacks/20-image via a pinned URL + sha256.
#
# Why qemu-nbd + chroot rather than libguestfs: virt-customize's appliance
# came up with only `lo` on a GitHub runner, so `--install` could not reach
# the archive and no resolver setting could fix it. Mapping the qcow2 with
# qemu-nbd and chrooting into it uses the runner's own network, needs no
# appliance, and runs at native speed instead of under TCG.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=image.env
. "$here/image.env"

work="${WORKDIR:-$PWD/out}"
rm -rf "$work"; mkdir -p "$work"; cd "$work"

NBD=/dev/nbd0
MNT="$work/mnt"

cleanup() {
  set +e
  if [ -d "$MNT" ]; then
    for d in dev/pts dev proc sys; do umount -l "$MNT/$d" 2>/dev/null; done
    umount -l "$MNT" 2>/dev/null
  fi
  qemu-nbd -d "$NBD" >/dev/null 2>&1
}
trap cleanup EXIT

echo "==> fetching $UPSTREAM_URL"
curl -fsSL --retry 3 -o upstream.img "$UPSTREAM_URL"
echo "$UPSTREAM_SHA256  upstream.img" | sha256sum -c -
cp upstream.img raw.qcow2

echo "==> mapping the image"
sudo modprobe nbd max_part=8
sudo qemu-nbd -c "$NBD" -f qcow2 raw.qcow2
# Give the kernel a moment to publish the partition nodes.
for _ in $(seq 1 20); do [ -e "${NBD}p1" ] && break; sleep 0.5; done

# The cloud image carries an EFI and a bcachefs/boot partition alongside
# root; pick the ext4 one rather than assuming p1 keeps its number.
ROOT=""
for p in "${NBD}"p*; do
  if [ "$(lsblk -no FSTYPE "$p" 2>/dev/null)" = "ext4" ]; then ROOT="$p"; break; fi
done
[ -n "$ROOT" ] || { echo "FATAL: no ext4 root partition in the image" >&2; exit 1; }
echo "    root partition: $ROOT"

mkdir -p "$MNT"
sudo mount "$ROOT" "$MNT"
sudo mount --bind /dev "$MNT/dev"
sudo mount --bind /dev/pts "$MNT/dev/pts"
sudo mount -t proc proc "$MNT/proc"
sudo mount -t sysfs sys "$MNT/sys"

# The image points /etc/resolv.conf at a systemd-resolved stub that does not
# exist offline. Swap in the runner's resolver for the build, restore the
# symlink afterwards so a booted node still uses systemd-resolved.
sudo rm -f "$MNT/etc/resolv.conf"
sudo cp /etc/resolv.conf "$MNT/etc/resolv.conf"

# dpkg must not start services in a chroot: 101 means "forbidden".
printf '#!/bin/sh\nexit 101\n' | sudo tee "$MNT/usr/sbin/policy-rc.d" >/dev/null
sudo chmod +x "$MNT/usr/sbin/policy-rc.d"

sudo tee "$MNT/tmp/customize.sh" >/dev/null <<GUEST
#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends $PACKAGES

# dpkg's postinst normally enables the unit, but deb-systemd-helper's
# behaviour in a chroot is not something to take on trust: enable it
# explicitly, fall back to the symlink, then refuse to ship an image where
# it is missing. A node whose agent never starts stalls CAPMOX provisioning
# with no error anywhere near the cause.
SYSTEMD_OFFLINE=1 systemctl enable qemu-guest-agent 2>/dev/null || true
if ! ls /etc/systemd/system/*.wants/qemu-guest-agent.service >/dev/null 2>&1; then
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /lib/systemd/system/qemu-guest-agent.service \\
     /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service
fi
ls /etc/systemd/system/*.wants/qemu-guest-agent.service >/dev/null 2>&1 || {
  echo "FATAL: qemu-guest-agent is not enabled in the built image" >&2; exit 1; }

dpkg-query -W -f='\${Package}\t\${Version}\n' > /etc/infra-image.manifest

# The whole point of baking: no apt lists on the node. Skipping this would
# just move the ~0.18 GiB from first boot into every clone's rootfs.
apt-get clean
rm -rf /var/lib/apt/lists/*
GUEST
sudo chmod +x "$MNT/tmp/customize.sh"

echo "==> installing $PACKAGES"
sudo chroot "$MNT" /tmp/customize.sh

sudo cp "$MNT/etc/infra-image.manifest" "${OUT_NAME%.img}.manifest"
sudo chown "$(id -u):$(id -g)" "${OUT_NAME%.img}.manifest"

sudo tee "$MNT/etc/infra-image" >/dev/null <<EOF
upstream_url=$UPSTREAM_URL
upstream_sha256=$UPSTREAM_SHA256
packages=$PACKAGES
source_repo=${GITHUB_REPOSITORY:-local}
source_commit=${GITHUB_SHA:-unknown}
EOF

sudo rm -f "$MNT/usr/sbin/policy-rc.d" "$MNT/tmp/customize.sh"
sudo rm -f "$MNT/etc/resolv.conf"
sudo ln -s ../run/systemd/resolve/stub-resolv.conf "$MNT/etc/resolv.conf"
# Clones must not share a machine-id (it seeds DHCP identity and journald).
sudo truncate -s 0 "$MNT/etc/machine-id"
# Discard freed blocks so the convert below can actually drop them.
sudo fstrim "$MNT" || true

sync
cleanup
trap - EXIT

# Rewrites the qcow2 without the clusters the install churned through.
echo "==> compacting"
qemu-img convert -O qcow2 raw.qcow2 "$OUT_NAME"
rm -f raw.qcow2 upstream.img
rmdir "$MNT" 2>/dev/null || true

# Fail here rather than publish an image the consumer's tests will reject.
for p in $PACKAGES; do
  grep -qE "^${p}[[:space:]]" "${OUT_NAME%.img}.manifest" || {
    echo "FATAL: $p missing from the built image" >&2; exit 1; }
done

sha256sum "$OUT_NAME" "${OUT_NAME%.img}.manifest" > SHA256SUMS
echo "==> built"
cat SHA256SUMS
ls -l
