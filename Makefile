# Copyright (C) 2026 Ilker Manap
# SPDX-License-Identifier: AGPL-3.0-or-later

# maas-proxmox - Proxmox VE icin MAAS'a yuklenebilir Packer imaji
#
# Hizli baslangic (build host uzerinde, root olarak):
#   sudo ./scripts/install-deps.sh
#   sudo make image
#   make preseed
#   make upload MAAS_PROFILE=admin
#
SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---------------------------------------------------------------- surum ayarlari
# Proxmox VE ana surumu. Yeni bir PVE surumu ciktiginda genelde sadece
# PVE_VERSION + DEBIAN_SERIES/DEBIAN_VERSION degistirmek yeterlidir.
PVE_VERSION      ?= 9
DEBIAN_SERIES    ?= trixie
DEBIAN_VERSION   ?= 13

# Proxmox APT deposu: pve-no-subscription | pve-enterprise | pve-test
PVE_REPO         ?= pve-no-subscription
PVE_REPO_URI     ?= http://download.proxmox.com/debian/pve
PVE_KEYRING_URL  ?= https://enterprise.proxmox.com/debian/proxmox-archive-keyring-$(DEBIAN_SERIES).gpg

# proxmox-ve disinda imaja girecek ek paketler
# NOT: 'vlan' ve 'vzdump' pve-manager ile catisir (Conflicts) - eklemeyin.
# VLAN destegini ifupdown2 kendisi saglar.
PVE_EXTRA_PACKAGES ?= ifupdown2 open-iscsi chrony postfix lvm2 thin-provisioning-tools \
                      ethtool bridge-utils ipmitool nvme-cli lsscsi sudo

# ---------------------------------------------------------------- imaj ayarlari
ARCH             ?= amd64
SUBARCH          ?= generic
BOOT             ?= uefi
TIMEOUT          ?= 3h
PACKER_LOG       ?= 0

# Build VM kaynaklari. Upstream sablon 4G/2CPU/2GB ile gelir; Debian cloud image
# (~3G) + Proxmox VE (~3G) 4G'ye sigmaz, bu yuzden sablonu yamiyoruz.
# Sonuc tgz yalnizca kullanilan dosyalari icerdiginden buyuk disk imaji sismez.
DISK_SIZE        ?= 16G
BUILD_CPUS       ?= 4
BUILD_MEM        ?= 4096

# --- derleme hizi -------------------------------------------------------------
# stable | daily
#   stable: cloud.debian.org/.../trixie/latest  (sabit URL -> packer onbellegi
#           calisir, tekrarlanan derlemelerde ~350MB indirme yok, tekrarlanabilir)
#   daily : upstream sablonun varsayilani (her gun degisir, onbellek isabet etmez)
DEBIAN_IMAGE_CHANNEL ?= stable

# Tarball sikistirma seviyesi. Upstream --best (9) kullaniyor; 6 belirgin daha
# hizli ve imaj yalnizca ~%2-3 buyuyor. pigz varsa cok cekirdekli calisir.
GZIP_LEVEL       ?= 6

# Yerel APT onbellegi (or. apt-cacher-ng): http://10.0.2.2:3142
# Packer'in user-mode aginda build VM host'u 10.0.2.2 olarak gorur.
# Bos birakilirsa proxy kullanilmaz.  Bkz: make deps-cache
APT_PROXY        ?=

IMAGE_NAME       ?= proxmox-ve-$(PVE_VERSION)
IMAGE_TITLE      ?= Proxmox VE $(PVE_VERSION) (Debian $(DEBIAN_VERSION))

# ---------------------------------------------------------------- yollar
WORKDIR          ?= $(CURDIR)/build
PM_REPO          ?= https://github.com/canonical/packer-maas.git
# Test edilmis upstream commit'e sabitlenmistir. 'main' birakmak, upstream'de
# yapilan bir degisikligin derlemeyi haber vermeden bozmasi anlamina gelir.
# Ileri tasimak icin: PM_REF=main ile derleyip test edin, sonra yeni SHA'yi buraya yazin.
PM_REF           ?= c23d5dd985f52b2eaccc893e886213a424a243a5
PM               := $(WORKDIR)/packer-maas
TPL              := $(PM)/debian

OVERLAY_TGZ      := $(WORKDIR)/pve-maas-overlay.tar.gz
CUSTOMIZE        := $(WORKDIR)/customize-proxmox.sh
OUTPUT           ?= $(WORKDIR)/$(IMAGE_NAME).tar.gz
PRESEED          := $(WORKDIR)/curtin_userdata_custom_$(ARCH)_$(SUBARCH)_$(IMAGE_NAME)

# ---------------------------------------------------------------- MAAS ayarlari
MAAS_PROFILE     ?= admin
MAAS_ARCH        ?= $(ARCH)/$(SUBARCH)
MAAS_IMAGE_NAME  ?= custom/$(IMAGE_NAME)
# MAAS snap kurulumu icin: /var/snap/maas/current/preseeds
MAAS_PRESEED_DIR ?= /var/snap/maas/current/preseeds

OVMF_DIR         ?= /usr/share/OVMF
OVMF_SFX         ?= $(shell test -f $(OVMF_DIR)/OVMF_CODE.fd && echo "" || echo "_4M")

# ---------------------------------------------------------------- hedefler
.PHONY: help deps deps-cache check-upstream checkout overlay customize image verify preseed install-preseed upload clean distclean lint

help:
	@echo "maas-proxmox - Proxmox VE $(PVE_VERSION) MAAS imaji"
	@echo
	@echo "  make deps             Build host bagimliliklarini kur (root gerekir)"
	@echo "  make deps-cache       Yerel APT onbellegi kur (derlemeyi hizlandirir)"
	@echo "  make image            Imaji derle -> $(OUTPUT)   (root gerekir)"
	@echo "  make verify           Uretilen imajin icerigini dogrula"
	@echo "  make check-upstream   Depodaki surumleri elimizdeki imajla karsilastir"
	@echo "  make preseed          MAAS curtin preseed dosyasini uret"
	@echo "  make install-preseed  Preseed'i $(MAAS_PRESEED_DIR) altina kopyala (root)"
	@echo "  make upload           Imaji MAAS'a yukle (MAAS_PROFILE=$(MAAS_PROFILE))"
	@echo "  make clean            Ara dosyalari sil"
	@echo "  make distclean        build/ dizinini tamamen sil"
	@echo
	@echo "Onemli degiskenler:"
	@echo "  PVE_VERSION=$(PVE_VERSION)  DEBIAN_SERIES=$(DEBIAN_SERIES)  PVE_REPO=$(PVE_REPO)"
	@echo "  IMAGE_NAME=$(IMAGE_NAME)  ARCH=$(ARCH)  BOOT=$(BOOT)"
	@echo "  OUTPUT=$(OUTPUT)"

deps:
	./scripts/install-deps.sh

# --- packer-maas deposunu getir -----------------------------------------------
$(PM)/.git:
	@mkdir -p $(WORKDIR)
	git clone $(PM_REPO) $(PM)

# PM_REF bir dal, etiket ya da commit SHA olabilir.
checkout: $(PM)/.git
	@cd $(PM) && git fetch -q --all --tags && git checkout -q -f $(PM_REF) \
	    && (git symbolic-ref -q HEAD >/dev/null && git pull -q --ff-only || true)
	@echo "packer-maas: $$(cd $(PM) && git rev-parse --short HEAD) ($(PM_REF))"

# --- imaja gomulecek overlay ---------------------------------------------------
overlay: $(OVERLAY_TGZ)

$(OVERLAY_TGZ): $(shell find overlay -type f 2>/dev/null)
	@mkdir -p $(WORKDIR)
	COPYFILE_DISABLE=1 tar czf $@ -C overlay --no-xattrs --exclude='.keep' .
	@echo "overlay: $@ ($$(du -h $@ | cut -f1))"

# --- packer'in VM icinde calistiracagi customize script -------------------------
customize: $(CUSTOMIZE)

$(CUSTOMIZE): scripts/customize-proxmox.sh.in $(OVERLAY_TGZ)
	@mkdir -p $(WORKDIR)
	@sed -e 's|@@PVE_SUITE@@|$(DEBIAN_SERIES)|g' \
	     -e 's|@@PVE_REPO@@|$(PVE_REPO)|g' \
	     -e 's|@@PVE_REPO_URI@@|$(PVE_REPO_URI)|g' \
	     -e 's|@@PVE_KEYRING_URL@@|$(PVE_KEYRING_URL)|g' \
	     -e 's|@@PVE_VERSION@@|$(PVE_VERSION)|g' \
	     -e 's|@@PVE_EXTRA_PACKAGES@@|$(PVE_EXTRA_PACKAGES)|g' \
	     -e 's|@@PM_REF@@|$(PM_REF)|g' \
	     $< > $@
	@echo '__PVE_MAAS_OVERLAY__' >> $@
	@base64 < $(OVERLAY_TGZ) >> $@
	@chmod +x $@
	@echo "customize script: $@"

# --- imaj derleme ---------------------------------------------------------------
image: checkout $(CUSTOMIZE)
	@if [ "$$(id -u)" -ne 0 ]; then echo "HATA: 'make image' root gerektirir (sudo make image)"; exit 1; fi
	@command -v packer >/dev/null || { echo "HATA: packer yok, once 'make deps'"; exit 1; }
	@echo "==> Sablon yamalaniyor: disk=$(DISK_SIZE) cpus=$(BUILD_CPUS) mem=$(BUILD_MEM)"
	sed -i -E 's|^([[:space:]]*disk_size[[:space:]]*=[[:space:]]*).*|\1"$(DISK_SIZE)"|' $(TPL)/debian-cloudimg.pkr.hcl
	sed -i -E 's|^([[:space:]]*cpus[[:space:]]*=[[:space:]]*).*|\1$(BUILD_CPUS)|' $(TPL)/debian-cloudimg.pkr.hcl
	sed -i -E 's|^([[:space:]]*memory[[:space:]]*=[[:space:]]*).*|\1$(BUILD_MEM)|' $(TPL)/debian-cloudimg.pkr.hcl
ifeq ($(strip $(DEBIAN_IMAGE_CHANNEL)),stable)
	@echo "==> Kararli Debian cloud image kullanilacak (packer onbellegi isabet eder)"
	sed -i -E 's|/daily/latest/|/latest/|g; s|-daily\.qcow2|.qcow2|g' $(TPL)/debian-cloudimg.pkr.hcl
	@grep -nE 'iso_url|iso_checksum' $(TPL)/debian-cloudimg.pkr.hcl
endif
	sed -i -E 's|--best --force|-$(GZIP_LEVEL) --force|' $(PM)/scripts/fuse-tar-root
	@grep -nE 'disk_size|^  cpus|^  memory' $(TPL)/debian-cloudimg.pkr.hcl
	cp -v $(OVMF_DIR)/OVMF_CODE$(OVMF_SFX).fd $(TPL)/OVMF_CODE.fd
	cp -v $(OVMF_DIR)/OVMF_VARS$(OVMF_SFX).fd $(TPL)/OVMF_VARS.fd
	rm -rf $(TPL)/output-cloudimg $(TPL)/seeds-cloudimg.iso
	cd $(TPL) && PACKER_LOG=$(PACKER_LOG) packer init .
	cd $(TPL) && PACKER_LOG=$(PACKER_LOG) packer build \
	    -var debian_series=$(DEBIAN_SERIES) \
	    -var debian_version=$(DEBIAN_VERSION) \
	    -var architecture=$(ARCH) \
	    -var boot_mode=$(BOOT) \
	    -var ovmf_suffix=$(OVMF_SFX) \
	    -var host_is_arm=false \
	    -var timeout=$(TIMEOUT) \
	    -var customize_script=$(CUSTOMIZE) \
	    -var filename=$(OUTPUT) \
	    -var http_proxy=$(APT_PROXY) \
	    .
	@ls -lh $(OUTPUT)

# --- MAAS preseed ---------------------------------------------------------------
preseed: $(PRESEED)

$(PRESEED): maas/curtin_userdata_custom.in
	@mkdir -p $(WORKDIR)
	@sed -e 's|@@IMAGE_NAME@@|$(IMAGE_NAME)|g' \
	     -e 's|@@ARCH@@|$(ARCH)|g' \
	     $< > $@
	@echo "preseed: $@"
	@echo "  -> MAAS region controller uzerinde $(MAAS_PRESEED_DIR)/ altina kopyalayin"

install-preseed: $(PRESEED)
	@if [ "$$(id -u)" -ne 0 ]; then echo "HATA: root gerekir"; exit 1; fi
	install -D -m 0644 $(PRESEED) $(MAAS_PRESEED_DIR)/$(notdir $(PRESEED))
	@echo "kuruldu: $(MAAS_PRESEED_DIR)/$(notdir $(PRESEED))"

# --- MAAS'a yukleme -------------------------------------------------------------
upload:
	@test -f $(OUTPUT) || { echo "HATA: $(OUTPUT) yok, once 'make image'"; exit 1; }
	maas $(MAAS_PROFILE) boot-resources create \
	    name='$(MAAS_IMAGE_NAME)' \
	    title='$(IMAGE_TITLE)' \
	    architecture='$(MAAS_ARCH)' \
	    filetype='tgz' \
	    content@=$(OUTPUT)

verify:
	@test -f $(OUTPUT) || { echo "HATA: $(OUTPUT) yok, once 'make image'"; exit 1; }
	./scripts/verify-image.sh $(OUTPUT)

# Depoda hangi surumler var, elimizdeki imaj hangi surumde?
check-upstream:
	@echo "==> Depoda mevcut ($(PVE_REPO_URI) $(DEBIAN_SERIES) $(PVE_REPO)):"
	@curl -fsS $(PVE_REPO_URI)/dists/$(DEBIAN_SERIES)/$(PVE_REPO)/binary-$(ARCH)/Packages.gz 2>/dev/null \
	  | gunzip \
	  | awk '/^Package: (proxmox-ve|pve-manager|proxmox-default-kernel)$$/{p=$$2; next} \
	         /^Version: /{if(p!=""){print p" "$$2; p=""}}' \
	  | sort -V | awk '{v[$$1]=$$2} END{for(k in v) printf "      %-24s %s\n", k, v[k]}' \
	  || echo "      (depoya erisilemedi)"
	@echo "==> Yerel imajda ($(OUTPUT)):"
	@if [ -f $(OUTPUT) ]; then \
	    tar xzf $(OUTPUT) -O ./etc/pve-maas/image-info 2>/dev/null | sed 's/^/      /' \
	      || echo "      (image-info okunamadi - imaj bu ozellikten once mi derlendi?)"; \
	  else echo "      (imaj yok - once 'make image')"; fi

# Yerel APT onbellegi - tekrarlanan derlemelerde ~700MB indirmeyi ortadan kaldirir.
# Kurduktan sonra:  sudo make image APT_PROXY=http://10.0.2.2:3142
deps-cache:
	@if [ "$$(id -u)" -ne 0 ]; then echo "HATA: root gerekir (sudo make deps-cache)"; exit 1; fi
	DEBIAN_FRONTEND=noninteractive apt-get install -y apt-cacher-ng
	systemctl enable --now apt-cacher-ng
	@echo
	@echo "Hazir. Derlemede kullanmak icin:"
	@echo "  sudo make image APT_PROXY=http://10.0.2.2:3142"
	@echo "(10.0.2.2 = packer user-mode aginda build host'un adresi)"

lint:
	@bash -n scripts/customize-proxmox.sh.in && echo "customize-proxmox.sh.in: OK"
	@bash -n overlay/usr/local/sbin/pve-maas-init && echo "pve-maas-init: OK"
	@command -v shellcheck >/dev/null && shellcheck -S warning \
	    overlay/usr/local/sbin/pve-maas-init scripts/install-deps.sh || true

clean:
	rm -f $(OVERLAY_TGZ) $(CUSTOMIZE) $(PRESEED)
	rm -rf $(TPL)/output-cloudimg $(TPL)/seeds-cloudimg.iso \
	       $(TPL)/OVMF_CODE.fd $(TPL)/OVMF_VARS.fd

distclean:
	rm -rf $(WORKDIR)
