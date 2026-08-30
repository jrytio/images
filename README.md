# images

Cloud images built for [`jrytio/infra`](https://github.com/jrytio/infra).

This repository is **public for one reason**: OpenTofu's
`proxmox_virtual_environment_download_file` takes a bare `url` and supports
no authentication of any kind (verified against the provider schema — the
resource has no header or credential attribute). Proxmox must therefore be
able to fetch the image anonymously. Nothing here is secret: it is a stock
Ubuntu image plus two packages.

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

### The trade this makes

Installing at first boot tracked the archive; a baked image freezes these
two packages until the next build. That is why the package list is kept to
what actually breaks when absent — everything else should stay on the
node's own update path. Rebuild (`workflow_dispatch`) when the upstream
pin in `images/ubuntu-2404-k8s/image.env` moves or either package needs a
security update.

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
