# maas-proxmox

Build **Proxmox VE** images that [MAAS](https://maas.io) can deploy to bare metal, with
first-boot automation that configures the node and joins it to a Proxmox cluster —
without anyone logging in.

Target: **Proxmox VE 9.x** on Debian 13 "Trixie". Older and newer releases are a
variable change away (see [Moving to a new Proxmox release](#moving-to-a-new-proxmox-release)).

*Türkçe dokümantasyon: [README.tr.md](README.tr.md)*

---

## Table of contents

- [What this does](#what-this-does)
- [Prebuilt images](#prebuilt-images)
- [Why Debian + the Proxmox repository, and not the Proxmox ISO](#why-debian--the-proxmox-repository-and-not-the-proxmox-iso)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Build configuration](#build-configuration)
- [First-boot behaviour](#first-boot-behaviour)
- [Configuration reference](#configuration-reference)
- [Deploying a cluster](#deploying-a-cluster)
- [Networking](#networking)
- [Storage](#storage)
- [Four traps this image works around](#four-traps-this-image-works-around)
- [Moving to a new Proxmox release](#moving-to-a-new-proxmox-release)
- [Build performance](#build-performance)
- [arm64](#arm64)
- [Release automation](#release-automation)
- [Repository layout](#repository-layout)
- [Troubleshooting](#troubleshooting)
- [Verified status](#verified-status)
- [Licensing](#licensing)
- [References](#references)

---

## What this does

MAAS provisions bare-metal machines from images. It ships images for Ubuntu and a few
other distributions, but not for Proxmox VE. This repository produces one.

`make image` builds a tarball that you upload to MAAS as a custom image. After that,
deploying a machine in MAAS gives you a fully configured Proxmox VE node:

| Step | Who does it |
|---|---|
| Partition the disk, write the image, configure networking, inject SSH keys | MAAS / curtin |
| Set hostname, regenerate node-unique identifiers | cloud-init + this image |
| Convert the management interface into a `vmbr0` bridge | this image |
| Set the `root@pam` password | this image |
| Create an LVM-thin pool and register it as `local-lvm` | this image |
| Create a Proxmox cluster, or join an existing one | this image |

Everything after the MAAS handoff is driven by a single systemd service,
`pve-maas-init`, configured through cloud-init user-data supplied at deploy time.
The image itself carries no cluster identity, no hostname and no credentials, so the
same image can build any number of independent clusters.

---

## Why Debian + the Proxmox repository, and not the Proxmox ISO

There are two plausible ways to get Proxmox VE into MAAS, and the choice shapes
everything else.

**Option A — install the Proxmox ISO under automation, capture the raw disk (`.dd.gz`).**
You get Proxmox's native layout: ZFS-on-root if you want it, `local-lvm` preconfigured.
But MAAS writes a `dd` image to the disk verbatim. Its storage layouts, its partitioning
UI and much of the curtin flow stop applying. Proxmox does not ship cloud-init on the
host, so MAAS's metadata — hostname, network configuration, SSH keys, user-data —
has to be bolted on afterwards. Growing the root filesystem becomes your problem.

**Option B — start from the Debian cloud image and install `proxmox-ve` on top of it.**
This is a
[configuration Proxmox supports and documents](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie).
The result is an ordinary Debian root filesystem, so MAAS's normal `tgz` custom-image
path applies unchanged: MAAS partitions the disk according to whatever storage layout
you configured, curtin installs the bootloader, and cloud-init consumes MAAS metadata
the way it does for Ubuntu.

**This repository takes option B.** The cost is that `local-lvm` is not preconfigured —
the image creates the thin pool on first boot from whatever free space MAAS left in the
volume group — and ZFS-on-root is not available. In exchange, MAAS stays in control of
the parts MAAS is good at, and moving between Proxmox releases is a variable change
rather than a rewrite.

---

## How it works

### Build pipeline

```
Debian 13 cloud image (qcow2, official)
   │
   ├─ canonical/packer-maas, "debian" template   (QEMU + KVM)
   │     ├─ cloud-init / netplan / curtin compatibility      [upstream]
   │     ├─ disk, cpu and memory patch (4G -> 16G)           [this repo]
   │     └─ customize-proxmox.sh                             [this repo]
   │           ├─ add the Proxmox APT repository and keyring
   │           ├─ install proxmox-default-kernel and proxmox-ve
   │           ├─ remove the Debian kernel and os-prober
   │           ├─ wipe the pmxcfs node identity
   │           ├─ disable networking.service, clear interfaces{,.new}
   │           └─ install the overlay:
   │                 /usr/local/sbin/pve-maas-init
   │                 /etc/pve-maas/pve-maas.conf
   │                 /etc/systemd/system/pve-maas-init.service
   │                 /curtin/curtin-hooks
   │
   └─ proxmox-ve-9.tar.gz   ──►   maas boot-resources create
```

The upstream [`canonical/packer-maas`](https://github.com/canonical/packer-maas)
repository is cloned at build time and pinned to a tested commit. It is *not* vendored;
this repository applies a small, explicit patch to its Packer template and supplies the
customization script through the template's `customize_script` variable.

### Deployment flow

```
MAAS: Deploy  (osystem=custom, distro_series=proxmox-ve-9, user_data=…)
   │
   ├─ PXE boot into the ephemeral environment
   ├─ curtin: partition, extract the image
   ├─ curtin: /curtin/curtin-hooks  ── skip kernel install
   │                                └─ pin interface names by MAC
   ├─ reboot into Proxmox VE
   │
   └─ first boot
        ├─ cloud-init: hostname, network (netplan), SSH keys,
        │              write /etc/pve-maas/conf.d/*.conf from user-data
        └─ pve-maas-init.service
              hosts → identity → rootpw → network → cluster → storage
```

`pve-maas-init` is a state machine. Each stage records completion in
`/var/lib/pve-maas/<stage>.done`, so a stage that reboots the node (the network stage
does, by default) resumes at the next stage on the following boot, and a stage that
fails is retried on the next boot rather than leaving the node half-configured.

---

## Requirements

**Build host** — where `make image` runs:

- Ubuntu 22.04 or newer (24.04 LTS is what this was developed and tested on), x86_64
- **Access to `/dev/kvm`.** If the build host is itself a virtual machine, nested
  virtualization must be enabled and the CPU type must pass the virtualization flags
  through (on Proxmox: `--cpu host`). Without KVM the build falls back to full
  emulation and is not practical.
- 4+ vCPU, 8+ GB RAM, 25+ GB free disk
- `sudo` (the build runs as root — it uses `qemu-nbd`, FUSE mounts and `tar --xattrs`)

**Deployment side:**

- MAAS 3.2 or newer is the documented minimum for custom images. **Only 3.7.2 was
  tested**, with the snap packaging; the deb packaging's preseed path is untested.
- curtin 21.0 or newer
- The curtin preseed from this repository installed on the MAAS region controller

---

## Prebuilt images

Images are built and published automatically:

**→ [Download the latest image](https://gitea.mynodes.xyz/ilker/maas-proxmox/releases)**

Each release carries the image, its SHA-256 checksum, the build's metadata
(`image-info.txt`) and `SOURCES.md`, the corresponding-source offer required by the
licences of the packages inside it. The builds are **unofficial** and not affiliated
with Proxmox Server Solutions GmbH.

```bash
curl -LO https://gitea.mynodes.xyz/ilker/maas-proxmox/releases/download/<tag>/maas-image-pve-<version>-amd64.tar.gz
curl -LO https://gitea.mynodes.xyz/ilker/maas-proxmox/releases/download/<tag>/maas-image-pve-<version>-amd64.tar.gz.sha256
sha256sum -c maas-image-pve-<version>-amd64.tar.gz.sha256

maas $PROFILE boot-resources create name='custom/proxmox-ve-9' \
    title='Proxmox VE 9' architecture='amd64/generic' \
    filetype='tgz' content@=maas-image-pve-<version>-amd64.tar.gz
```

You still need the curtin preseed on your MAAS region controller — see
[Quick start](#quick-start) step 5. Downloading an image skips only steps 1-3.

Prefer building it yourself if you would rather not trust someone else's binary;
that is what the rest of this document is about.

## Quick start

```bash
# 1. Install build dependencies (packer, qemu, ovmf, nbdkit, fuse2fs, …)
sudo ./scripts/install-deps.sh

# 2. Build the image  (~11 minutes)
sudo make image
#    -> build/proxmox-ve-9.tar.gz

# 3. Check the result
make verify

# 4. Generate the MAAS curtin preseed
make preseed
#    -> build/curtin_userdata_custom_amd64_generic_proxmox-ve-9

# 5. Install the preseed on the MAAS region controller
sudo make install-preseed
#    default: /var/snap/maas/current/preseeds/
#    for a deb-packaged MAAS: MAAS_PRESEED_DIR=/etc/maas/preseeds

# 6. Upload the image to MAAS
make upload MAAS_PROFILE=admin
```

Steps 5 and 6 run against the MAAS region controller, so either run them there or copy
the two artifacts across.

**The preseed is not optional.** Without it, curtin tries to install a kernel over APT
during deployment and the deployment fails. See
[Four traps this image works around](#four-traps-this-image-works-around).

Then deploy a machine:

```bash
maas $PROFILE machine deploy $SYSTEM_ID \
    osystem=custom distro_series=proxmox-ve-9 \
    user_data="$(base64 -w0 maas/examples/01-first-node.yaml)"
```

…or pick **Custom → Proxmox VE 9** in the MAAS web UI. For a whole cluster, use
[`scripts/deploy-cluster.sh`](scripts/deploy-cluster.sh).

---

## Build configuration

All of these are `make` variables — `sudo make image DISK_SIZE=24G`, and so on.

### Version selection

| Variable | Default | Meaning |
|---|---|---|
| `PVE_VERSION` | `9` | Proxmox VE major version; used in the image name |
| `DEBIAN_SERIES` | `trixie` | Debian codename that Proxmox release is built on |
| `DEBIAN_VERSION` | `13` | Debian major version number |
| `PVE_REPO` | `pve-no-subscription` | `pve-no-subscription`, `pve-enterprise` or `pve-test`. *Only `pve-no-subscription` was tested.* |
| `PVE_REPO_URI` | `http://download.proxmox.com/debian/pve` | APT repository URI |
| `PVE_KEYRING_URL` | derived from `DEBIAN_SERIES` | Proxmox archive keyring |
| `PVE_EXTRA_PACKAGES` | `ifupdown2 open-iscsi chrony …` | Extra packages to bake in |

> `vlan` and `vzdump` **conflict** with `pve-manager` — do not add them.
> ifupdown2 provides VLAN support natively.

### Image and build

| Variable | Default | Meaning |
|---|---|---|
| `IMAGE_NAME` | `proxmox-ve-9` | MAAS name (`custom/<name>`) and preseed filename |
| `ARCH` / `SUBARCH` | `amd64` / `generic` | Target architecture. `arm64` is wired up but **never built or deployed** — see [arm64](#arm64). |
| `BOOT` | `uefi` | Boot mode baked into the image. *Only UEFI was tested.* |
| `DISK_SIZE` | `16G` | Build VM disk. Upstream's 4G cannot fit Debian + Proxmox |
| `BUILD_CPUS` / `BUILD_MEM` | `4` / `4096` | Build VM resources |
| `TIMEOUT` | `3h` | Packer build timeout |
| `PM_REF` | pinned SHA | `canonical/packer-maas` revision |

### Speed

| Variable | Default | Meaning |
|---|---|---|
| `DEBIAN_IMAGE_CHANNEL` | `stable` | `stable` uses a fixed URL so Packer's cache works; `daily` is upstream's default and changes every day. *Only `stable` was tested.* |
| `GZIP_LEVEL` | `6` | Tarball compression. Upstream uses 9 |
| `APT_PROXY` | *(empty)* | Local APT cache, e.g. `http://10.0.2.2:3142` — see `make deps-cache`. *Untested.* |

### MAAS

| Variable | Default | Meaning |
|---|---|---|
| `MAAS_PROFILE` | `admin` | `maas` CLI profile name |
| `MAAS_PRESEED_DIR` | `/var/snap/maas/current/preseeds` | Preseed directory |

### Targets

```
make deps             install build dependencies (root)
make deps-cache       install a local APT cache to speed up rebuilds (root)
make image            build the image (root)
make verify           check the built image's contents
make check-upstream   compare repository versions against the built image
make preseed          generate the MAAS curtin preseed
make install-preseed  install the preseed on this host (root)
make upload           upload the image to MAAS
make lint             syntax-check the scripts
make clean            remove intermediates
make distclean        remove build/ entirely
```

---

## First-boot behaviour

`pve-maas-init.service` is enabled in the image and runs the following stages in order,
each exactly once:

| Stage | What it does |
|---|---|
| `hosts` | Writes `<management-ip> <fqdn> <hostname>` into `/etc/hosts` — `pvecm` requires the node name to resolve to a real address. Disables cloud-init's `manage_etc_hosts` so it is not reverted on later boots, fixes postfix's `myhostname`, and restarts the Proxmox services so they pick up the correct identity. |
| `identity` | Regenerates node-unique identifiers that must not be shared between nodes cloned from one image — currently the iSCSI initiator name. |
| `rootpw` | Sets the `root@pam` password. Without it the Proxmox web UI cannot be used and the node cannot be a join target for other nodes. |
| `network` | Converts the interface MAAS configured into a `vmbr0` bridge, disables the netplan/systemd-networkd configuration, and enables ifupdown2. |
| `cluster` | Creates a cluster or joins an existing one. |
| `storage` | Creates an LVM-thin pool in the free space of the volume group and registers it as `local-lvm`. |

Progress and failures:

```bash
systemctl status pve-maas-init
journalctl -u pve-maas-init -b
ls -l /var/lib/pve-maas/          # <stage>.done files; "complete" when finished
cat /etc/pve-maas/image-info      # which image this node was built from
```

If a stage fails, the service exits non-zero and the remaining stages are retried on the
next boot. To force a stage to run again, delete its `.done` file along with `complete`
and restart the service.

---

## Configuration reference

Defaults live in `/etc/pve-maas/pve-maas.conf` (do not edit it). Per-node settings go
into `/etc/pve-maas/conf.d/*.conf`, which cloud-init writes from the user-data you pass
at deploy time. Files in `conf.d` override the defaults.

```yaml
#cloud-config
write_files:
  - path: /etc/pve-maas/conf.d/50-pve.conf
    permissions: "0600"
    owner: root:root
    content: |
      PVE_ROOT_PASSWORD_HASH='$6$...'
      PVE_CLUSTER_MODE=join
      PVE_CLUSTER_PEER=192.0.2.11
      PVE_CLUSTER_PEER_PASSWORD='...'
```

### General

| Option | Default | Meaning |
|---|---|---|
| `PVE_ENABLED` | `true` | Set to `false` to disable all first-boot automation. *Untested.* |
| `PVE_FQDN` | *(empty)* | Override the detected FQDN. *Untested — detection was used.* |

### Credentials

| Option | Default | Meaning |
|---|---|---|
| `PVE_ROOT_PASSWORD_HASH` | *(empty)* | `root@pam` password hash — generate with `openssl passwd -6` |
| `PVE_ROOT_PASSWORD` | *(empty)* | Plaintext alternative; prefer the hash. *Untested — only the hash was exercised.* |

### Networking

| Option | Default | Meaning |
|---|---|---|
| `PVE_NET_MANAGE` | `true` | Set to `false` to configure `/etc/network/interfaces` yourself. *`false` untested.* |
| `PVE_NET_BRIDGE` | `vmbr0` | Bridge name. *Only the default was tested.* |
| `PVE_NET_UPLINK` | *(auto)* | Bridge port; defaults to the interface holding the default route. *Only auto-detection was tested.* |
| `PVE_NET_MODE` | `auto` | `auto`, `static` or `dhcp`. *Only `auto` resolving to static was tested; the DHCP path is untested.* |
| `PVE_NET_APPLY` | `reboot` | `reboot`, `reload` (`ifreload -a`) or `none`. *Only `reboot` was tested.* |
| `PVE_NET_VLAN_AWARE` | `false` | Make the bridge VLAN-aware (`bridge-vids 2-4094`). *Untested.* |
| `PVE_NET_EXTRA` | *(empty)* | Raw text appended to `/etc/network/interfaces`. *Untested.* |

### Cluster

| Option | Default | Meaning |
|---|---|---|
| `PVE_CLUSTER_MODE` | `none` | `none`, `create` or `join` |
| `PVE_CLUSTER_NAME` | *(empty)* | Cluster name, for `create` |
| `PVE_CLUSTER_PEER` | *(empty)* | Address of an existing member, for `join` |
| `PVE_CLUSTER_PEER_PASSWORD` | *(empty)* | That node's `root@pam` password |
| `PVE_CLUSTER_PEER_PASSWORD_FILE` | *(empty)* | Read the password from a file instead. *Untested.* |
| `PVE_CLUSTER_FINGERPRINT` | *(empty)* | The peer's certificate SHA-256 fingerprint |
| `PVE_CLUSTER_FINGERPRINT_DISCOVER` | `true` | Read the fingerprint from the peer if not supplied (trust on first use). *Untested — the fingerprint was always supplied.* |
| `PVE_CLUSTER_LINK0` / `LINK1` | *(empty)* | This node's corosync link addresses. *Untested.* |
| `PVE_CLUSTER_NODEID` / `VOTES` | *(empty)* | Passed through to Proxmox. *Untested.* |
| `PVE_CLUSTER_WAIT` | `900` | Seconds to wait for the peer's API to answer |
| `PVE_CLUSTER_RETRIES` | `5` | Join attempts, 30 s apart. *The retry path is untested — the first attempt succeeded.* |
| `PVE_CLUSTER_WIPE_SECRETS` | `true` | Scrub passwords from `conf.d` after joining |

### Storage

| Option | Default | Meaning |
|---|---|---|
| `PVE_THINPOOL` | `auto` | `auto` (the VG with the most free space), `off`, or a VG name. *Only `auto` was tested.* |
| `PVE_THINPOOL_NAME` | `data` | Thin pool logical volume name. *Only the default was tested.* |
| `PVE_THINPOOL_STORAGE` | `local-lvm` | Proxmox storage id. *Only the default was tested.* |
| `PVE_THINPOOL_MIN_GB` | `16` | Skip the stage below this much free space |
| `PVE_THINPOOL_DISK` | *(empty)* | Build a new VG from this whole disk instead. *Untested.* |
| `PVE_THINPOOL_VG` | `pve` | VG name used with `PVE_THINPOOL_DISK`. *Untested.* |

Worked examples: [`maas/examples/`](maas/examples/).

---

## Deploying a cluster

`pvecm add` prompts for a password interactively, which makes it unusable from a script.
This image uses the API endpoint that does the same job non-interactively:

```bash
pvesh create /cluster/config/join --hostname <peer> --password <pw> --fingerprint <fp>
```

### By hand

Deploy the first node with `PVE_CLUSTER_MODE=create`
([example](maas/examples/01-first-node.yaml)), then read its certificate fingerprint:

```bash
openssl s_client -connect <first-node>:8006 </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2
```

and deploy the remaining nodes with `PVE_CLUSTER_MODE=join` plus that fingerprint
([example](maas/examples/02-join-node.yaml)).

A joining node waits for the peer's port 8006 to answer (`PVE_CLUSTER_WAIT`, 15 minutes
by default) and retries a failed join five times, so you can start several deployments at
once without ordering them carefully.

### With the helper script

[`scripts/deploy-cluster.sh`](scripts/deploy-cluster.sh) automates the whole flow: it
deploys the first node, waits for it, reads the fingerprint, and deploys the rest.

Run it **on the MAAS region controller** — it needs the `maas` CLI profile and network
access to the nodes' port 8006.

```bash
# Show what it would deploy, without deploying anything
./deploy-cluster.sh --name pve-prod --nodes pve1,pve2,pve3 --dry-run

# Deploy
./deploy-cluster.sh --name pve-prod --nodes pve1,pve2,pve3
```

The first host in `--nodes` creates the cluster; the rest join it.

### Several independent clusters

The image carries no cluster identity — it comes entirely from deploy-time user-data.
The same image and the same preseed can build any number of unrelated clusters, with no
rebuild:

```bash
./deploy-cluster.sh --name pve-prod --nodes pve1,pve2,pve3
./deploy-cluster.sh --name pve-dr   --nodes dr1,dr2,dr3
```

Each cluster gets its own root password (generated and printed if you do not supply one).
MAAS tags are a convenient way to keep the groups apart:

```bash
maas $PROFILE tag create name=pve-prod
maas $PROFILE tag update-nodes pve-prod add=$SYSTEM_ID
maas $PROFILE machines read tags=pve-prod | jq -r '.[].hostname'
```

### Security notes

- The peer's `root@pam` password **must be plaintext** — the join API does not accept a
  hash. It is stored in MAAS user-data, where anyone with MAAS access can read it. Use a
  short-lived password and change it after the cluster is up.
- Without `PVE_CLUSTER_FINGERPRINT` the fingerprint is read from the peer on first
  contact, which is trust-on-first-use and open to interception. Supply it explicitly in
  production; `deploy-cluster.sh` always does.
- Prefer `PVE_ROOT_PASSWORD_HASH` over `PVE_ROOT_PASSWORD` for the node's own password.
- With no `PVE_ROOT_PASSWORD*` at all, root stays locked: no `root@pam` web login, and
  the node cannot be a join target.
- A two-node cluster loses quorum when either node goes down. Use three nodes or a
  QDevice in production — that is a Proxmox property, not a limitation of this image.

---

## Networking

### Who owns the network, and when

The image ships with `networking.service` (ifupdown2) **disabled** and an
`/etc/network/interfaces` containing nothing but loopback. On the first boot MAAS owns
the network entirely, through the netplan configuration curtin wrote and
systemd-networkd. Only once `pve-maas-init` reaches its network stage does it write the
`vmbr0` configuration, disable netplan and networkd, and enable ifupdown2.

That order matters. If ifupdown2 were enabled in the image it would start with the stale
interface definition baked in at build time and take the real interface down before the
automation ever ran.

### The bridge

The network stage reads the live configuration — the interface holding the default
route, its address, gateway and DNS — and writes a Proxmox-style bridge:

```
auto lo
iface lo inet loopback

iface enp6s18 inet manual

auto vmbr0
iface vmbr0 inet static
        address 192.0.2.20/24
        gateway 192.0.2.1
        bridge-ports enp6s18
        bridge-stp off
        bridge-fd 0

source /etc/network/interfaces.d/*
```

`PVE_NET_APPLY=reboot` (the default) reboots the node once to apply this, after
cloud-init has already told MAAS the deployment succeeded. `reload` uses ifupdown2's
`ifreload -a` and avoids the reboot at the cost of a brief interruption.

### Complex topologies

For bonds, VLANs or multiple bridges, set `PVE_NET_MANAGE=false` and write
`/etc/network/interfaces` yourself through cloud-init — see
[`maas/examples/04-advanced-network.yaml`](maas/examples/04-advanced-network.yaml).

---

## Storage

`local` (directory storage on `/var/lib/vz`) works out of the box. `local-lvm` is
created on first boot from free space in the volume group, which means **MAAS has to
leave some**.

Choose the LVM storage layout in MAAS and make the root logical volume smaller than the
disk:

```bash
maas $PROFILE machine set-storage-layout $SYSTEM_ID \
    storage_layout=lvm lv_size=12884901888     # 12 GiB root
```

The rest of the volume group is then turned into a thin pool named `data` and registered
as `local-lvm`. With less than `PVE_THINPOOL_MIN_GB` free the stage is skipped silently
and the node runs with directory storage only.

To use a whole separate disk instead:

```
PVE_THINPOOL_DISK=/dev/sdb
PVE_THINPOOL_VG=pve
```

`storage.cfg` is cluster-wide, so a node joining an existing cluster does not overwrite a
`local-lvm` that is already defined — it adds itself to that storage's node list instead.

---

## Four traps this image works around

Each of these fails **silently**: no error, no failed unit, just a node that does not
work. They are documented here because anyone building a similar image will hit them.

### 1. `kernel: null` in the curtin preseed

The image already contains the Proxmox kernel, so curtin should not install one. Recent
curtin supports `kernel: null` for exactly this. The curtin that ships with MAAS may not:

```
install_kernel -> config.merge_config(mapping, kernel_cfg.get('mapping', {}))
AttributeError: 'NoneType' object has no attribute 'get'
```

Instead, the image ships `/curtin/curtin-hooks`. When that file exists, curtin runs it in
place of its built-in hooks; the hook neutralises the kernel-installation step and calls
the built-in hooks itself. This works regardless of curtin version and removes the
deployment's dependency on reaching `download.proxmox.com`.

### 2. `pvenetcommit.service`

Proxmox stages network changes in `/etc/network/interfaces.new`, and `pvenetcommit`
**moves that file over `interfaces` on every boot**, before `sysinit.target`:

```
ExecStart=sh -c 'if [ -f ${FN}.new ]; then mv ${FN}.new ${FN}; fi'
```

A `.new` file created during the build and left in the image silently overwrites the
node's configuration on its first boot. It is removed at build time, and again after the
network stage writes the real configuration.

### 3. Interface names differ between commissioning and deployment

MAAS commissions machines in an Ubuntu ephemeral environment and records the interface
name it sees there — for example `enp6s18`. The deployed Debian 13 system may use a
different udev naming scheme and call the same card `ens18`. cloud-init then tries to
rename it, fails, and **leaves the interface down**:

```
Failed to rename devices: [busy] Error renaming mac=… from ens18 to enp6s18
```

The node loses its network moments after cloud-init fetches its metadata — late enough
that MAAS still reports a successful deployment.

`curtin-hooks` writes the MAC-to-name mapping from MAAS's own network configuration into
`/etc/systemd/network/10-maas-<name>.link`, so udev names the card correctly from the
start and no rename is attempted.

### 4. systemd ordering — both a cycle and a deadlock

Ordering `pve-maas-init.service` `After=cloud-final.service` while it is
`WantedBy=multi-user.target` creates a dependency cycle. systemd resolves it by
**deleting our job**:

```
multi-user.target: Found ordering cycle on pve-maas-init.service/start
multi-user.target: Found dependency on cloud-final.service/start
multi-user.target: Found dependency on multi-user.target/start
Job pve-maas-init.service/start deleted to break ordering cycle
```

The service never runs, and nothing reports an error.

Waiting for cloud-init inside the script instead removes the cycle but introduces a
runtime deadlock if the unit is `Type=oneshot`, because such a unit blocks
`multi-user.target`, which `cloud-final.service` is ordered after:

```
cloud-final.service    waiting
pve-maas-init.service  running
multi-user.target      waiting
```

The unit is therefore `Type=simple`, with no cloud-init ordering at all, and the script
calls `cloud-init status --wait` itself. Stage tracking uses `/var/lib/pve-maas/*.done`
rather than systemd state, so nothing is lost by dropping `RemainAfterExit`.

---

## Moving to a new Proxmox release

Check what is available without building anything:

```bash
make check-upstream
```

It prints the current `proxmox-ve` / `pve-manager` versions in the configured repository
next to the metadata of the image you have (`/etc/pve-maas/image-info`).

### Within the same Debian base (9.2 → 9.3 → …)

Nothing to change. No package versions are pinned; every build takes the current
`proxmox-ve`.

*Partly verified:* the mechanism is — five builds were made and each installed
whatever the repository offered at the time. An actual minor-version step (a rebuild
that picks up a newer Proxmox than the previous image) has not happened yet.*

```bash
sudo make image && make verify && make upload
```

The image name and preseed filename stay the same, so the MAAS record is updated in
place.

### A major release that changes the Debian base (e.g. PVE 10 on Debian 14)

**This is not automatic**, and changing the variables in this repository is not enough.
The upstream packer-maas template contains hard-coded conditions on the Debian version:

```
debian/scripts/networking.sh:  if [ ${DEBIAN_VERSION} == '12' ] || [ ${DEBIAN_VERSION} == '13' ]
debian/scripts/setup-boot.sh:  if [ ${DEBIAN_VERSION} == '13' ]
```

An unknown version falls through to the `else` branch, which installs a cloud-init
package from 2020 — the image breaks silently.

*This is read from the upstream source, not observed: no build against an unsupported
Debian version was attempted.* A major jump therefore waits on upstream support.
In order:

1. Does `canonical/packer-maas` handle the new Debian? (look at the `DEBIAN_VERSION`
   conditions in `debian/scripts/`)
2. Has Proxmox published the keyring?
   `https://enterprise.proxmox.com/debian/proxmox-archive-keyring-<suite>.gpg`
3. Are the packages there?
   `curl -s http://download.proxmox.com/debian/pve/dists/<suite>/Release | grep Components`
4. Then:

```bash
sudo make image PVE_VERSION=10 DEBIAN_SERIES=forky DEBIAN_VERSION=14 PM_REF=main
make preseed PVE_VERSION=10
```

The preseed filename changes too (`…_proxmox-ve-10`) — install it on the region
controller.

### Upstream pinning

`PM_REF` points at a tested `canonical/packer-maas` commit. Leaving it at `main` means an
upstream change can break your build without warning. To move it forward: build with
`PM_REF=main`, **deploy the result and verify it**, then record the new SHA in the
Makefile.

---

## Build performance

A build takes about 11 minutes on a 4-vCPU builder, most of it installing packages
inside the build VM. Measured on the host described under
[Verified status](#verified-status): 15 min 55 s before these optimisations,
10 min 36 s after. The individual contributions were not measured separately.
All of them are on by default:

- **`eatmydata`** — drops dpkg's per-package `fsync` calls. Safe here: the build VM's
  disk is thrown away.
- **Deferred initramfs** — `update-initramfs` is diverted during installation and run
  exactly once at the end, instead of being triggered by the kernel, firmware and dkms
  packages in turn.
- **Stable cloud image** — a fixed URL means Packer's cache actually hits; upstream's
  `daily` image changes every day, costing a ~350 MB download per build and making
  builds non-reproducible.
- **`GZIP_LEVEL=6`** — upstream uses `--best` (9). With `pigz` this is noticeably faster
  for a few percent more size.

For repeated builds, a local APT cache should remove roughly 700 MB of downloads.
*This path is untested and the figure is an estimate from package sizes, not a
measurement:*

```bash
sudo make deps-cache                              # installs apt-cacher-ng
sudo make image APT_PROXY=http://10.0.2.2:3142
```

`10.0.2.2` is the build host as seen from Packer's user-mode network. When a proxy is
configured, Debian repositories are rewritten from `https` to `http` so the cache can
serve them; package signatures are still verified.

---

## arm64

Proxmox VE 9.2 added **official** arm64 support — same code base, same
repositories, same release lifecycle as x86-64, with full support on NVIDIA Grace
and Vera platforms and best-effort on other UEFI Armv8-A/Armv9-A hardware. The
`pve-no-subscription` repository carries `proxmox-ve`, `pve-manager`,
`proxmox-default-kernel` and `pve-qemu-kvm` for arm64.

This repository is wired for it:

```bash
sudo WITH_ARM64=1 ./scripts/install-deps.sh    # adds qemu-system-arm, AAVMF
sudo make image ARCH=arm64
make preseed ARCH=arm64                        # -> ..._arm64_generic_proxmox-ve-9
make upload ARCH=arm64
```

The firmware is selected from the **target** architecture (`AAVMF` for arm64,
`OVMF` for amd64) and padded to 64 MiB as QEMU's arm64 `virt` machine requires;
KVM is used only when the host and target architectures match.

**This has never been run.** Nothing here has been built for arm64, let alone
deployed, and it is listed under [Not verified](#not-verified) for that reason.
Two things stand between the code and a usable image:

- **Build speed.** On an x86_64 builder an arm64 build runs under TCG emulation
  with no KVM. Expect it to be several times slower than the ~11 minutes an amd64
  build takes; how much slower has not been measured. The I/O optimisations
  (`eatmydata`, deferred initramfs) help less when the bottleneck is CPU.
- **Somewhere to deploy it.** An arm64 image needs arm64 machines behind MAAS to
  be worth anything, and none were available to test against.

If you want arm64 seriously, put a native arm64 builder behind a second runner
rather than emulating. That removes the speed problem entirely and lets the same
pipeline build both architectures.

## Release automation

[`.gitea/workflows/build-image.yml`](.gitea/workflows/build-image.yml) builds the image
on a self-hosted runner and publishes it as a release.

It runs **daily**, but rebuilds only when there is a reason to. Proxmox publishes
roughly weekly — the trixie repository currently holds 56 `pve-manager` and 28
`proxmox-kernel` versions — so an unconditional daily build would produce about
45 GB a month of near-identical artifacts. A check that finds nothing costs about
30 seconds.

A rebuild is triggered when any of these holds:

| Trigger | Why |
|---|---|
| `pve-manager` differs from the published image | The obvious one |
| `proxmox-default-kernel` differs | Kernel security fixes do not bump `pve-manager`, and those matter most |
| The newest release is older than `MAX_AGE_DAYS` (30) | Debian base security updates bump neither of the above; without a floor an image could sit unchanged for months |
| Manual dispatch with `force` | Escape hatch |

The comparison reads `image-info.txt` from the last release rather than guessing from
tag names, so it reflects what is actually inside the published image.
[`scripts/ci/decide-build.sh`](scripts/ci/decide-build.sh) can be run by hand to see the
decision without triggering anything.

Releases are tagged `pve-<version>-<date>` and pruned to the newest
`KEEP_RELEASES` (3) — at ~1.5 GB each, unbounded retention fills the server.

### Runner

The runner is registered in **host mode**: steps run directly on the build machine as
root, because the build needs `/dev/kvm`, `qemu-nbd`, FUSE and root privileges, all of
which a container would have to be granted anyway. The consequence is worth stating
plainly: anything able to dispatch a workflow in this repository gets root on the build
machine. Do not attach this runner to a repository that accepts outside contributions.

Checkout is a plain `git clone`, not `actions/checkout` — the latter is a JavaScript
action and a host-mode runner has no Node.js runtime.

## Repository layout

```
Makefile                         build / preseed / upload targets
scripts/install-deps.sh          build host dependencies
scripts/customize-proxmox.sh.in  template for the script that runs inside the build VM
scripts/deploy-cluster.sh        deploy a whole cluster through MAAS
scripts/verify-image.sh          check a built image's contents
scripts/ci/                      release pipeline helpers (decision, artifacts, publish, prune)
.gitea/workflows/                Gitea Actions pipeline
overlay/                         files baked into the image
  usr/local/sbin/pve-maas-init   first-boot state machine
  etc/pve-maas/pve-maas.conf     defaults, with every option documented
  etc/systemd/system/…           pve-maas-init.service
  curtin/curtin-hooks            skips kernel install, pins interface names
maas/curtin_userdata_custom.in   MAAS curtin preseed template
maas/examples/*.yaml             cloud-init user-data examples
build/                           generated artifacts (git-ignored)
```

The overlay is embedded into the generated customization script as a base64 payload
rather than served over Packer's HTTP server, which keeps the build self-contained.

---

## Troubleshooting

**Deployment ends in "Failed deployment".**
Read the installation log:

```bash
maas $PROFILE node-script-result download $SYSTEM_ID current-installation \
    filetype=txt filters=/tmp/install.log output=all | tail -60
```

The most common cause is a missing or misnamed preseed. The filename must match the
uploaded image exactly: `curtin_userdata_custom_<arch>_<subarch>_<image-name>`. Use what
`make preseed` produces.

**MAAS says "Deployed" but the node is unreachable.**
Look at the console (`qm terminal <vmid>` on Proxmox, or your BMC). A login prompt means
the system booted and the problem is networking. Inspect the disk from rescue mode:

```bash
maas $PROFILE machine rescue-mode $SYSTEM_ID
# then, over SSH to the ephemeral environment:
mount /dev/vgroot/lvroot /mnt/t
cat /mnt/t/etc/network/interfaces            # was vmbr0 written?
ls -l /mnt/t/var/lib/pve-maas/               # which stages completed?
cat /mnt/t/var/log/cloud-init-output.log     # did user-data arrive?
journalctl -D /mnt/t/var/log/journal -u pve-maas-init
```

An empty `/var/lib/pve-maas/` means the service never ran — check for the systemd
ordering cycle described above.

**Deployed but the web UI rejects the login.**
Was a root password supplied? `journalctl -u pve-maas-init -b | grep rootpw`. Check the
bridge with `ip -br addr`.

**A node did not join the cluster.**
`journalctl -u pve-maas-init -b`. Common causes: the peer is unreachable on 8006, the
root password is wrong, the fingerprint does not match, or the peer's own `/etc/hosts`
is wrong so `pvecm` fails there. To retry without redeploying:

```bash
rm -f /var/lib/pve-maas/cluster.done /var/lib/pve-maas/complete
systemctl start pve-maas-init
```

**The node reports the build hostname.**
It should not — the pmxcfs database is removed from the image and regenerated from the
current hostname on first boot. If it happens, `/var/lib/pve-cluster/config.db` survived
the build; check the "resetting node identity" step in the build log.

**The build reports that `proxmox-ve` cannot be found.**
`DEBIAN_SERIES` and `PVE_REPO` disagree. Verify:
`curl -s http://download.proxmox.com/debian/pve/dists/<suite>/Release | grep Components`

**Do not delete or replace a boot resource while a machine is using it.**
MAAS loses the machine's boot files and it can end up stuck in "Failed to exit rescue
mode", with GRUB reporting `invalid magic number`.

---

## Verified status

Be sceptical of anything not listed under **Verified**. Individual options are also
marked *Untested* in the tables above where that applies.

### Test environment

| | |
|---|---|
| Build host | Ubuntu 24.04.1, x86_64, 8 vCPU / 31 GB, nested KVM |
| MAAS | 3.7.2 (snap), region + rack on Ubuntu 24.04 |
| Nodes | 2 × (2 vCPU, 6 GB RAM, 32 GiB disk), UEFI, Secure Boot off, virtio |
| Network | Single flat isolated subnet; MAAS acting as gateway and DHCP |
| Image | proxmox-ve 9.2.0 / pve-manager 9.2.11 / kernel 7.0.14-15-pve |
| Storage layout | MAAS `lvm`, 12 GiB root LV, ~19 GiB left free in the VG |

### Verified

Each of these was observed working on the running system, not merely assumed:

| Area | Evidence |
|---|---|
| Build | Completes on a KVM-capable Ubuntu 24.04 host; 10 min 36 s with the speed options on, 15 min 55 s without |
| Image contents | `make verify` — 22 checks, all passing |
| Preseed install | `make preseed` and `make install-preseed` run on the MAAS region controller |
| Upload | Image accepted by MAAS as `custom/proxmox-ve-9`, one complete resource set, SHA-256 matching the built file |
| Deployment | `custom/proxmox-ve-9`, amd64/generic, UEFI, LVM layout — reaches `Deployed` |
| `curtin-hooks` — kernel | Deployment no longer fails in "Configuring OS"; no kernel installed over APT |
| `curtin-hooks` — interface naming | `/etc/systemd/network/10-maas-enp6s18.link` written; the interface comes up as `enp6s18` and cloud-init attempts no rename |
| Node identity reset | Both nodes report their MAAS hostname; `/etc/pve/nodes/` holds `maas-node8` and `maas-node9`, not the build hostname |
| `hosts` stage | `/etc/hosts` maps the management IP to the FQDN; the Proxmox banner shows the correct address |
| `identity` stage | iSCSI initiator names regenerated and **different on each node** (`…:01:bfeec443aec7` vs `…:01:4b22246737a`) |
| `rootpw` stage | `PVE_ROOT_PASSWORD_HASH` lands in `/etc/shadow`; the web UI answers on 8006 |
| `network` stage | `vmbr0` up with the management address, `bridge-ports` set to the real interface, node reachable afterwards |
| `cluster` stage — create | `pvecm status`: cluster formed, `Quorate: Yes` |
| `cluster` stage — join | Second node joined on the first attempt in 36 s; both nodes independently report `Nodes: 2`, `Quorate: Yes` |
| `PVE_CLUSTER_WIPE_SECRETS` | Both password fields in `conf.d` scrubbed after joining |
| `storage` stage | `data` thin pool created from free VG space, registered as `local-lvm`, active on both nodes |
| Cluster-wide storage safety | The joining node detected the existing `local-lvm` and added itself to its node list instead of overwriting it |
| Stage resumption | The network stage reboots the node; remaining stages continue on the next boot and completed stages are skipped |
| `deploy-cluster.sh` | `--help` and `--dry-run` against the live MAAS; user-data rendered correctly for a three-node cluster |
| `make check-upstream` | Repository side — reports current `proxmox-ve` / `pve-manager` / `proxmox-default-kernel` versions |

### Not verified

Not known to be broken — simply never exercised. Treat as untested code.

**Options** — see the *Untested* markers in the tables above. In short: every
`PVE_NET_*` value other than the tested defaults, `PVE_CLUSTER_LINK0`/`LINK1`,
fingerprint discovery (TOFU), `PVE_CLUSTER_PEER_PASSWORD_FILE`, the join retry path,
plaintext `PVE_ROOT_PASSWORD`, `PVE_ENABLED=false`, `PVE_FQDN`, and every
`PVE_THINPOOL_*` value other than `auto` with the defaults.

**Build variants**

- `pve-enterprise` and `pve-test` repositories
- **arm64** — the Makefile and scripts handle it (firmware selection, MAAS
  architecture, the Debian-kernel check), but no arm64 image has been built and
  none deployed. See [arm64](#arm64).
- BIOS boot (`BOOT=bios`)
- `DEBIAN_IMAGE_CHANNEL=daily`
- `APT_PROXY` and `make deps-cache`. The ~700 MB figure quoted under
  [Build performance](#build-performance) is an estimate from download sizes, not a
  measurement.
- A non-default `IMAGE_NAME`

**Make targets** — `make upload` (the image was uploaded with the equivalent `maas`
command, not through the target), `make deps-cache`, `make clean`, `make distclean`, and
the image side of `make check-upstream`.

**Features added after the last build** — `/etc/pve-maas/image-info` and therefore the
image side of `make check-upstream`. The code is written and syntax-checked; no built
image contains the file yet.

**`deploy-cluster.sh` beyond `--dry-run`.** The underlying mechanism (create, read
fingerprint, join) is verified, but the script's own deploy path has never run.

**Environments** — MAAS releases other than 3.7.2, a deb-packaged MAAS (only the snap
preseed path was used), MAAS storage layouts other than `lvm`, bonded or VLAN-tagged
networking, IPv6 (the network stage writes an `inet6` stanza when a global address
exists; that branch never ran), and real bare metal — the nodes tested were virtual
machines.

**Scale** — two nodes. Concurrent joins by several nodes at once, and clusters larger
than two, are untested.

## Licensing

**AGPL-3.0-or-later.** See [LICENSE](LICENSE).

This is not a free choice. The project builds on
[`canonical/packer-maas`](https://github.com/canonical/packer-maas), which Canonical
distributes under the AGPLv3, and parts of this repository are derived from it:

- `maas/curtin_userdata_custom.in` is adapted from upstream's
  `debian/curtin_userdata_custom_amd64`. Several `late_commands` are copied verbatim —
  the PXE-disable call, the `mount --bind` of the target, the cloud.cfg rewrite and the
  `zz-update-grub` fix.
- `overlay/curtin/curtin-hooks` follows upstream's `debian/scripts/curtin-hooks`:
  the same imports, the same
  `load_command_environment` → `load_command_config` → `builtin_curthooks` → `cleanup`
  structure, and a near-identical `cleanup()`. The kernel-disabling and
  interface-pinning functions are original.

Because those are derivative works, the AGPLv3's copyleft carries over and the project
cannot be released under a permissive licence, or under the plain GPL.

The upstream template itself is **not vendored**. It is cloned at build time and pinned
by `PM_REF`; the Makefile applies a small, explicit patch to it.

In practice AGPLv3 asks very little of anyone using this. It is build tooling, not a
network service: building images, uploading them to MAAS and running the resulting
Proxmox nodes triggers no obligation. Section 13 — the clause AGPL is known for — only
applies to someone who offers a *modified version of this software* to others over a
network.

## References

- [MAAS — Build custom images](https://canonical.com/maas/docs/how-to-build-custom-images)
- [Proxmox VE — Install on Debian 13](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_13_Trixie)
- [Proxmox VE — Cluster Manager](https://pve.proxmox.com/wiki/Cluster_Manager)
- [`pvecm(1)`](https://pve.proxmox.com/pve-docs/pvecm.1.html)
- [`canonical/packer-maas`](https://github.com/canonical/packer-maas)
