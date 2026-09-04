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

- MAAS 3.2 or newer (custom image support); tested on 3.7.2
- curtin 21.0 or newer
- The curtin preseed from this repository installed on the MAAS region controller

---

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
| `PVE_REPO` | `pve-no-subscription` | `pve-no-subscription`, `pve-enterprise` or `pve-test` |
| `PVE_REPO_URI` | `http://download.proxmox.com/debian/pve` | APT repository URI |
| `PVE_KEYRING_URL` | derived from `DEBIAN_SERIES` | Proxmox archive keyring |
| `PVE_EXTRA_PACKAGES` | `ifupdown2 open-iscsi chrony …` | Extra packages to bake in |

> `vlan` and `vzdump` **conflict** with `pve-manager` — do not add them.
> ifupdown2 provides VLAN support natively.

### Image and build

| Variable | Default | Meaning |
|---|---|---|
| `IMAGE_NAME` | `proxmox-ve-9` | MAAS name (`custom/<name>`) and preseed filename |
| `ARCH` / `SUBARCH` | `amd64` / `generic` | Target architecture |
| `BOOT` | `uefi` | Boot mode baked into the image |
| `DISK_SIZE` | `16G` | Build VM disk. Upstream's 4G cannot fit Debian + Proxmox |
| `BUILD_CPUS` / `BUILD_MEM` | `4` / `4096` | Build VM resources |
| `TIMEOUT` | `3h` | Packer build timeout |
| `PM_REF` | pinned SHA | `canonical/packer-maas` revision |

### Speed

| Variable | Default | Meaning |
|---|---|---|
| `DEBIAN_IMAGE_CHANNEL` | `stable` | `stable` uses a fixed URL so Packer's cache works; `daily` is upstream's default and changes every day |
| `GZIP_LEVEL` | `6` | Tarball compression. Upstream uses 9 |
| `APT_PROXY` | *(empty)* | Local APT cache, e.g. `http://10.0.2.2:3142` — see `make deps-cache` |

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
| `PVE_ENABLED` | `true` | Set to `false` to disable all first-boot automation |
| `PVE_FQDN` | *(empty)* | Override the detected FQDN |

### Credentials

| Option | Default | Meaning |
|---|---|---|
| `PVE_ROOT_PASSWORD_HASH` | *(empty)* | `root@pam` password hash — generate with `openssl passwd -6` |
| `PVE_ROOT_PASSWORD` | *(empty)* | Plaintext alternative; prefer the hash |

### Networking

| Option | Default | Meaning |
|---|---|---|
| `PVE_NET_MANAGE` | `true` | Set to `false` to configure `/etc/network/interfaces` yourself |
| `PVE_NET_BRIDGE` | `vmbr0` | Bridge name |
| `PVE_NET_UPLINK` | *(auto)* | Bridge port; defaults to the interface holding the default route |
| `PVE_NET_MODE` | `auto` | `auto`, `static` or `dhcp` |
| `PVE_NET_APPLY` | `reboot` | `reboot`, `reload` (`ifreload -a`) or `none` |
| `PVE_NET_VLAN_AWARE` | `false` | Make the bridge VLAN-aware (`bridge-vids 2-4094`) |
| `PVE_NET_EXTRA` | *(empty)* | Raw text appended to `/etc/network/interfaces` |

### Cluster

| Option | Default | Meaning |
|---|---|---|
| `PVE_CLUSTER_MODE` | `none` | `none`, `create` or `join` |
| `PVE_CLUSTER_NAME` | *(empty)* | Cluster name, for `create` |
| `PVE_CLUSTER_PEER` | *(empty)* | Address of an existing member, for `join` |
| `PVE_CLUSTER_PEER_PASSWORD` | *(empty)* | That node's `root@pam` password |
| `PVE_CLUSTER_PEER_PASSWORD_FILE` | *(empty)* | Read the password from a file instead |
| `PVE_CLUSTER_FINGERPRINT` | *(empty)* | The peer's certificate SHA-256 fingerprint |
| `PVE_CLUSTER_FINGERPRINT_DISCOVER` | `true` | Read the fingerprint from the peer if not supplied (trust on first use) |
| `PVE_CLUSTER_LINK0` / `LINK1` | *(empty)* | This node's corosync link addresses |
| `PVE_CLUSTER_NODEID` / `VOTES` | *(empty)* | Passed through to Proxmox |
| `PVE_CLUSTER_WAIT` | `900` | Seconds to wait for the peer's API to answer |
| `PVE_CLUSTER_RETRIES` | `5` | Join attempts, 30 s apart |
| `PVE_CLUSTER_WIPE_SECRETS` | `true` | Scrub passwords from `conf.d` after joining |

### Storage

| Option | Default | Meaning |
|---|---|---|
| `PVE_THINPOOL` | `auto` | `auto` (the VG with the most free space), `off`, or a VG name |
| `PVE_THINPOOL_NAME` | `data` | Thin pool logical volume name |
| `PVE_THINPOOL_STORAGE` | `local-lvm` | Proxmox storage id |
| `PVE_THINPOOL_MIN_GB` | `16` | Skip the stage below this much free space |
| `PVE_THINPOOL_DISK` | *(empty)* | Build a new VG from this whole disk instead |
| `PVE_THINPOOL_VG` | `pve` | VG name used with `PVE_THINPOOL_DISK` |

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
`proxmox-ve`:

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
package from 2020 — the image breaks silently. A major jump therefore waits on upstream
support. In order:

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

A build takes roughly 11 minutes on a 4-vCPU builder, most of it installing packages
inside the build VM. These optimisations are on by default:

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

For repeated builds, a local APT cache removes about 700 MB of downloads:

```bash
sudo make deps-cache                              # installs apt-cacher-ng
sudo make image APT_PROXY=http://10.0.2.2:3142
```

`10.0.2.2` is the build host as seen from Packer's user-mode network. When a proxy is
configured, Debian repositories are rewritten from `https` to `http` so the cache can
serve them; package signatures are still verified.

---

## Repository layout

```
Makefile                         build / preseed / upload targets
scripts/install-deps.sh          build host dependencies
scripts/customize-proxmox.sh.in  template for the script that runs inside the build VM
scripts/deploy-cluster.sh        deploy a whole cluster through MAAS
scripts/verify-image.sh          check a built image's contents
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

This repository was tested end to end against live hardware-backed infrastructure:

| | |
|---|---|
| Image | proxmox-ve 9.2.0 / pve-manager 9.2.11 / kernel 7.0.14-15-pve |
| MAAS | 3.7.2 (snap) on Ubuntu 24.04, region + rack |
| Deployment | `custom/proxmox-ve-9`, amd64/generic, LVM layout with a 12 GiB root |
| Result | Two-node cluster, `Quorate: Yes`, `local-lvm` thin pool on both nodes |
| Automation | Bridge conversion, root password, node identity, cluster create and join — all without logging in |

Not yet exercised: `PVE_CLUSTER_LINK0` (a separate corosync network), the
`pve-enterprise` repository, arm64, and `deploy-cluster.sh` beyond `--dry-run`.

---

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
