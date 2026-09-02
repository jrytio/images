# images

Cloud images built for [`jrytio/infra`](https://github.com/jrytio/infra).

This repository is **public for one reason**: OpenTofu's
`proxmox_virtual_environment_download_file` takes a bare `url` and supports
no authentication of any kind (verified against the provider schema — the
resource has no header or credential attribute). Proxmox must therefore be
able to fetch the image anonymously. Nothing here is secret: it is a stock
Ubuntu image plus two packages and the RKE2 canal images.

## `ubuntu-2404-k8s`

Ubuntu 24.04 **minimal** cloud image with `qemu-guest-agent` and `iptables`
installed and the apt lists cleaned.

Those two packages were previously installed by `preRKE2Commands` on every
downstream CAPI node's first boot. Both failure modes are expensive:

- **`qemu-guest-agent`** — CAPMOX blocks machine readiness until the agent
  answers `cloud-init status`. Without it, provisioning stalls.
- **`iptables`** — an RKE2 requirement the minimal image lacks. Without the
  binary the CNI portmap plugin fails every hostPort pod (`rke2-traefik`)
  *after* calico allocates an IP, and the sandbox retries at 1/s, draining
  the cluster's entire /24 of IPAM leases in minutes. It looks like an IPAM
  bug, not a missing package.

Baking them also removes an `apt-get update` from the node-provisioning
path and the ~0.18 GiB of `/var/lib/apt/lists` it left on a 6.57 GiB
rootfs.

### `rke2-images-canal` airgap tarball

The RKE2 canal (CNI) images are baked into
`/var/lib/rancher/rke2/agent/images/`, which rke2 imports into containerd
at startup — before anything needs the network. Without this, a fresh
node deadlocks for ~5–6 minutes: the node's registry mirrors resolve to
core's MetalLB LB IP, kube-proxy DNATs that to traefik *pod* IPs, and pod
IPs only route once canal is up — so every pull, including canal's own,
blackholes through TCP timeouts until containerd falls back to the
upstream endpoint. Measured on a live autoscale event 2026-09-02: every
first-batch image on a fresh node took 5–6 min (a 321 KB pause image
included), then 1–5 s each once canal was running.

### The trade this makes

Installing at first boot tracked the archive; a baked image freezes these
two packages until the next build. That is why the package list is kept to
what actually breaks when absent — everything else should stay on the
node's own update path. Rebuild (`workflow_dispatch`) when the upstream
pin in `images/ubuntu-2404-k8s/image.env` moves, either package needs a
security update, or infra bumps its downstream RKE2 version (bump
`RKE2_VERSION`/`CANAL_IMAGES_SHA256` to match — stale canal images are
degraded-not-broken: unmatched tags pull the slow way).

### Consuming a build

Each run publishes one release tagged `ubuntu-2404-k8s-<date>.<run>` with
three assets: the `.img` (qcow2), a `.manifest` of every installed package
extracted from the finished image, and `SHA256SUMS`.

`jrytio/infra` pins the asset URL and its sha256 in
`stacks/20-image/variables.tf`. A build here changes nothing until that pin
is bumped in a PR. `tests/02-image.sh` there re-derives the manifest and
`SHA256SUMS` from the pinned URL and checks that the file Proxmox actually
holds hashes to the pinned value, so a mismatched or hand-edited image
fails verification.

### Building locally

Needs `qemu-utils` and root (it maps the qcow2 with `qemu-nbd` and chroots into it):

    images/ubuntu-2404-k8s/build.sh

The build fails rather than publishes if either package is missing from the
finished image or if `qemu-guest-agent` is not enabled in it.

### Traps this build already hit

- **`qemu-img convert -O qcow2` drops compression.** The upstream image is
  zlib-compressed qcow2 (253 MiB for a 3.5 GiB volume); converting without
  `-c` published a 677 MB artifact, 2.5x upstream, for an image whose whole
  point is being smaller. The build now fails above 400 MiB.
- **libguestfs is not usable on a GitHub runner here.** `virt-customize`'s
  appliance came up with only `lo` — no NIC at all — so `--install` could
  never reach the archive, and no resolver setting fixes a missing
  interface. Hence `qemu-nbd` + chroot, which also skips the TCG penalty
  from having no `/dev/kvm`.
- **Do not "enable" qemu-guest-agent.** Its unit ships an empty `[Install]`
  section, so `systemctl enable` is a no-op and cannot produce a wants
  symlink. The udev rule starts it when the virtio port appears. An earlier
  gate asserted the symlink and failed on correct images.
- **`qemu-nbd -d` returns before the kernel detaches.** Converting straight
  after fails with "Failed to get shared write lock"; wait for the device
  size to read 0.
