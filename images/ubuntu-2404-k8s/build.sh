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

# Runs in a subshell: an earlier version disabled errexit here and never
# restored it, so every later failure -- including qemu-img convert losing
# its lock -- was ignored and the build published a manifest with no image.
cleanup() { (
  set +e
  if [ -d "$MNT" ]; then
    for d in dev/pts dev proc sys; do sudo umount -l "$MNT/$d" 2>/dev/null; done
    sudo umount -l "$MNT" 2>/dev/null
  fi
  sudo qemu-nbd -d "$NBD" >/dev/null 2>&1
  # -d returns before the kernel has torn the device down; converting while
  # it is still attached fails with "Failed to get shared write lock".
  for _ in $(seq 1 40); do
    [ "$(cat /sys/block/$(basename "$NBD")/size 2>/dev/null || echo 0)" = "0" ] && break
    sleep 0.25
  done
); }
trap cleanup EXIT

echo "==> fetching $UPSTREAM_URL"
curl -fsSL --retry 3 -o upstream.img "$UPSTREAM_URL"
echo "$UPSTREAM_SHA256  upstream.img" | sha256sum -c -
cp upstream.img raw.qcow2

echo "==> mapping the image"
sudo modprobe nbd max_part=8
sudo qemu-nbd -c "$NBD" -f qcow2 raw.qcow2
# Give the kernel a moment to publish the partition nodes.
sudo partprobe "$NBD" 2>/dev/null || true
sudo udevadm settle || true
for _ in $(seq 1 20); do [ -e "${NBD}p1" ] && break; sleep 0.5; done

# The cloud image carries an EFI and a bcachefs/boot partition alongside
# root; pick the ext4 one rather than assuming p1 keeps its number.
#
# Retried: the partition node existing does not mean its FSTYPE is readable
# yet -- lsblk asks udev, which may still be probing, so a single pass can
# see every partition as blank and fail a perfectly good image (a rerun of
# the same commit then succeeds). blkid reads the superblock directly and
# covers the case where udev's db never catches up.
ROOT=""
for _ in $(seq 1 20); do
  for p in "${NBD}"p*; do
    fstype="$(lsblk -no FSTYPE "$p" 2>/dev/null)"
    [ -n "$fstype" ] || fstype="$(sudo blkid -o value -s TYPE "$p" 2>/dev/null)"
    if [ "$fstype" = "ext4" ]; then ROOT="$p"; break 2; fi
  done
  sleep 0.5
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

# QUOTED heredoc, and the package list arrives as arguments. An unquoted
# one expands every $ against the build shell instead of the guest script --
# which under `set -u` killed the build on a diagnostic's own loop variable.
sudo tee "$MNT/tmp/customize.sh" >/dev/null <<'GUEST'
#!/bin/sh
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends "$@"

# Do NOT try to "enable" the unit. qemu-guest-agent.service ships an EMPTY
# [Install] section, so systemctl enable is a genuine no-op and can never
# produce a wants symlink -- verified on a live node, which has the agent
# running and no symlink. What starts it is a udev rule: the unit BindsTo
# the virtio-ports device, and the rule sets SYSTEMD_WANTS when
# org.qemu.guest_agent.0 appears. It appears on every CAPMOX clone because
# template 1500 enables the agent device. Fabricating an enable symlink
# would just fight a mechanism that already works.
#
# So gate on the mechanism actually shipping, not on a symlink. The rule's
# path is whatever dpkg says it is: /lib vs /usr/lib and the 60- prefix are
# not promises.
RULE=$(dpkg -L qemu-guest-agent | grep '/udev/rules.d/.*\.rules$' | head -1)
[ -n "$RULE" ] && [ -f "$RULE" ] || {
  echo "FATAL: qemu-guest-agent shipped no udev rule; nothing would start it" >&2
  exit 1; }
echo "--- $RULE ---"; cat "$RULE"; echo "--- end ---"
# The key is ENV{SYSTEMD_WANTS}, so the brace sits between the name and the
# '=' -- a pattern without it matches nothing, which is what rejected a
# perfectly good image here.
grep -Eq 'SYSTEMD_WANTS\}?="?qemu-guest-agent\.service' "$RULE" || {
  echo "FATAL: the udev rule no longer starts qemu-guest-agent.service" >&2
  exit 1; }

dpkg-query -W -f='${Package}\t${Version}\n' > /etc/infra-image.manifest

# The whole point of baking: no apt lists on the node. Skipping this would
# just move the ~0.18 GiB from first boot into every clone's rootfs.
apt-get clean
rm -rf /var/lib/apt/lists/*
GUEST
sudo chmod +x "$MNT/tmp/customize.sh"

echo "==> installing $PACKAGES"
sudo chroot "$MNT" /tmp/customize.sh $PACKAGES

sudo cp "$MNT/etc/infra-image.manifest" "${OUT_NAME%.img}.manifest"
sudo chown "$(id -u):$(id -g)" "${OUT_NAME%.img}.manifest"

# The canal (CNI) images, baked as an RKE2 airgap tarball. rke2 imports
# every tarball in agent/images/ into containerd at startup, before
# anything needs the network -- which is the point: the node registry
# mirrors resolve to core's MetalLB LB IP, kube-proxy DNATs that to
# traefik POD IPs, and pod IPs only route once canal is up. So on a fresh
# node every pull -- including canal's own -- blackholes for ~5-6 minutes
# of TCP timeouts until containerd falls back to the upstream endpoint.
# Baking canal breaks the cycle: CNI up in seconds, mirrors reachable,
# every other image arrives through the cache at full speed.
#
# The tarball is pinned to one RKE2 version while clusters track infra's;
# skew is degraded-not-broken -- unmatched tags just take the slow
# fallback path again until the next image build catches up.
echo "==> baking rke2 canal images ($RKE2_VERSION)"
curl -fsSL --retry 3 -o rke2-images-canal.linux-amd64.tar.zst \
  "https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}/rke2-images-canal.linux-amd64.tar.zst"
echo "$CANAL_IMAGES_SHA256  rke2-images-canal.linux-amd64.tar.zst" | sha256sum -c -
sudo install -D -m 0644 rke2-images-canal.linux-amd64.tar.zst \
  "$MNT/var/lib/rancher/rke2/agent/images/rke2-images-canal.linux-amd64.tar.zst"
rm -f rke2-images-canal.linux-amd64.tar.zst

# The RKE2 installer and its artifacts, at the exact paths CABPR's
# airGapped mode hard-codes (bootstrap/internal/cloudinit templates run
# `INSTALL_RKE2_ARTIFACT_PATH=/opt/rke2-artifacts sh /opt/install.sh`):
# node provisioning stops depending on github.com being reachable, which
# would otherwise sit on the scale-up critical path. install.sh comes
# from the rke2 repo AT THE VERSION TAG, not get.rke2.io, so the same
# inputs always build the same image. One version per image: install.sh
# in artifact mode installs whatever the directory holds, so a second
# version would need its own dir plus a symlink flip -- rebuild instead.
echo "==> baking rke2 installer + artifacts ($RKE2_VERSION)"
rke2_dl="https://github.com/rancher/rke2/releases/download/${RKE2_VERSION//+/%2B}"
curl -fsSL --retry 3 -o rke2.linux-amd64.tar.gz "$rke2_dl/rke2.linux-amd64.tar.gz"
curl -fsSL --retry 3 -o sha256sum-amd64.txt "$rke2_dl/sha256sum-amd64.txt"
curl -fsSL --retry 3 -o install.sh \
  "https://raw.githubusercontent.com/rancher/rke2/${RKE2_VERSION//+/%2B}/install.sh"
echo "$RKE2_TARBALL_SHA256  rke2.linux-amd64.tar.gz" | sha256sum -c -
echo "$SHA256SUM_FILE_SHA256  sha256sum-amd64.txt" | sha256sum -c -
sudo install -D -m 0644 rke2.linux-amd64.tar.gz "$MNT/opt/rke2-artifacts/rke2.linux-amd64.tar.gz"
sudo install -D -m 0644 sha256sum-amd64.txt "$MNT/opt/rke2-artifacts/sha256sum-amd64.txt"
sudo install -m 0755 install.sh "$MNT/opt/install.sh"
rm -f rke2.linux-amd64.tar.gz sha256sum-amd64.txt install.sh

sudo tee "$MNT/etc/infra-image" >/dev/null <<EOF
upstream_url=$UPSTREAM_URL
upstream_sha256=$UPSTREAM_SHA256
packages=$PACKAGES
rke2_canal_images=$RKE2_VERSION
rke2_artifacts=$RKE2_VERSION
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
# -c is not optional: the upstream image is zlib-compressed qcow2 (253 MiB
# for a 3.5 GiB volume) and converting without it produced a 646 MiB
# artifact -- 2.5x upstream, for an image whose entire point is being
# smaller. Compression costs nothing at run time; PVE converts the disk to
# raw on import either way.
echo "==> compacting"
qemu-img convert -O qcow2 -c raw.qcow2 "$OUT_NAME"
[ -s "$OUT_NAME" ] || { echo "FATAL: $OUT_NAME was not produced" >&2; exit 1; }
rm -f raw.qcow2 upstream.img
rmdir "$MNT" 2>/dev/null || true

# Fail here rather than publish an image the consumer's tests will reject.
for p in $PACKAGES; do
  grep -qE "^${p}[[:space:]]" "${OUT_NAME%.img}.manifest" || {
    echo "FATAL: $p missing from the built image" >&2; exit 1; }
done

sha256sum "$OUT_NAME" "${OUT_NAME%.img}.manifest" > SHA256SUMS
# Tripwire on the size regression above: upstream is ~265 MiB and the
# baked canal tarball ~271 MiB (already zstd, qcow2 -c cannot shrink it),
# so anything past 750 MiB means compression was lost again.
size=$(stat -c %s "$OUT_NAME")
echo "image size: $size bytes"
[ "$size" -lt 786432000 ] || {
  echo "FATAL: $OUT_NAME is ${size}B -- compression was lost" >&2; exit 1; }
echo "==> built"
cat SHA256SUMS
ls -l
