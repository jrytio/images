#!/usr/bin/env bash
# Bakes the packages every CAPI node needs into the Ubuntu 24.04 minimal
# cloud image, and emits the image, its package manifest and SHA256SUMS.
#
# Consumed by jrytio/infra stacks/20-image via a pinned URL + sha256.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=image.env
. "$here/image.env"

work="${WORKDIR:-$PWD/out}"
rm -rf "$work"; mkdir -p "$work"; cd "$work"

echo "==> fetching $UPSTREAM_URL"
curl -fsSL --retry 3 -o upstream.img "$UPSTREAM_URL"
echo "$UPSTREAM_SHA256  upstream.img" | sha256sum -c -
cp upstream.img "$OUT_NAME"

# Two facts about the GitHub runner, not about the image: Ubuntu ships
# /boot/vmlinuz-* mode 0600 and supermin cannot read it to build the
# appliance, and there is no /dev/kvm so the direct backend runs under TCG
# (slower, correct).
sudo chmod 0644 /boot/vmlinuz-* 2>/dev/null || true
export LIBGUESTFS_BACKEND=direct

# One script rather than a chain of --run-command, so the quoting stays
# readable and the steps stay ordered.
cat > customize.sh <<'GUEST'
#!/bin/sh
set -eu

# Printed unconditionally: when an apt step fails in an appliance the cause
# is almost always here, and a build log without it is a guessing game.
echo "=== appliance network ==="
ip -4 addr 2>/dev/null || true
ip route 2>/dev/null || true
echo "--- /etc/resolv.conf ---"
cat /etc/resolv.conf 2>/dev/null || echo "(absent or dangling symlink)"
getent hosts archive.ubuntu.com || echo "(resolution failed)"
echo "========================="

# The cloud image points /etc/resolv.conf at a systemd-resolved stub that
# does not exist offline. libguestfs normally installs a working one for the
# duration; if it has not, write resolvers that slirp can NAT. Only touched
# when resolution is actually broken -- clobbering a working file was the
# first version's bug.
RESTORE_RESOLV=0
if ! getent hosts archive.ubuntu.com >/dev/null 2>&1; then
  rm -f /etc/resolv.conf
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
  RESTORE_RESOLV=1
  getent hosts archive.ubuntu.com || {
    echo "FATAL: no DNS inside the appliance; --network is not working" >&2
    exit 1; }
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends __PACKAGES__

# dpkg's postinst normally enables the unit, but deb-systemd-helper's
# behaviour in an offline chroot is not something to take on trust: enable
# it explicitly, fall back to the symlink, then refuse to ship an image
# where it is missing. A node whose agent never starts stalls CAPMOX
# provisioning with no error near the cause.
SYSTEMD_OFFLINE=1 systemctl enable qemu-guest-agent 2>/dev/null || true
if ! ls /etc/systemd/system/*.wants/qemu-guest-agent.service >/dev/null 2>&1; then
  mkdir -p /etc/systemd/system/multi-user.target.wants
  ln -sf /lib/systemd/system/qemu-guest-agent.service \
     /etc/systemd/system/multi-user.target.wants/qemu-guest-agent.service
fi
ls /etc/systemd/system/*.wants/qemu-guest-agent.service >/dev/null 2>&1 || {
  echo "FATAL: qemu-guest-agent is not enabled in the built image" >&2; exit 1; }

dpkg-query -W -f='${Package}\t${Version}\n' > /etc/infra-image.manifest

# The whole point of baking: no apt lists on the node. Skipping this would
# just move the ~0.18 GiB from first boot into every clone's rootfs.
apt-get clean
rm -rf /var/lib/apt/lists/*

if [ "$RESTORE_RESOLV" = 1 ]; then
  rm -f /etc/resolv.conf
  ln -s ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
# Clones must not share a machine-id (it seeds DHCP identity and journald).
: > /etc/machine-id
GUEST

sed -i "s|__PACKAGES__|${PACKAGES}|" customize.sh

cat > infra-image <<EOF
upstream_url=$UPSTREAM_URL
upstream_sha256=$UPSTREAM_SHA256
packages=$PACKAGES
source_repo=${GITHUB_REPOSITORY:-local}
source_commit=${GITHUB_SHA:-unknown}
EOF

echo "==> customizing"
sudo -E virt-customize --network -a "$OUT_NAME" \
  --run customize.sh \
  --copy-in infra-image:/etc

echo "==> extracting manifest"
sudo -E virt-cat -a "$OUT_NAME" /etc/infra-image.manifest > "${OUT_NAME%.img}.manifest"

# Fail here rather than publish an image the consumer's tests will reject.
for p in $PACKAGES; do
  grep -qE "^${p}[[:space:]]" "${OUT_NAME%.img}.manifest" || {
    echo "FATAL: $p missing from the built image" >&2; exit 1; }
done

rm -f upstream.img customize.sh infra-image
sha256sum "$OUT_NAME" "${OUT_NAME%.img}.manifest" > SHA256SUMS

echo "==> built"
cat SHA256SUMS
ls -l
