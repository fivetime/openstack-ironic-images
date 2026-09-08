# distro-iso — bare-metal images from the vendor's own installer

This pipeline installs a distribution from its official installer ISO,
unattended, in a QEMU VM, and ships the resulting disk. It exists because
the VM pipelines in `openstack-cloud-images` — which adapt the daily cloud
images from images.linuxcontainers.org — produce disks that are fine on
KVM and unusable on a machine in a rack. That repository now refuses
`TARGET=baremetal` and points here.

## Why not a cloud image

Measured on the upstream Ubuntu 26.04 cloud disk (2026-09-08, build
`20260907_07:42`), not inferred:

| what | cloud image | why it matters on hardware |
| --- | --- | --- |
| passwords | `/etc/shadow` is all `!`/`*` — **no account has one** | plug in a keyboard and you cannot log in, which is exactly the situation where you needed to |
| serial console | no `console=ttyS*`, no `GRUB_TERMINAL`, no `serial-getty` | iLO/iDRAC serial-over-LAN shows nothing at all |
| grub menu | `GRUB_TIMEOUT=0`, `GRUB_TIMEOUT_STYLE=hidden`, `quiet splash` | no recovery entry, no boot messages, nothing to stop at |
| initramfs | no `ahci`, `smartpqi`, `hpsa`, `megaraid_sas`, `mpt3sas` | the machine never reaches its root filesystem and drops to the dracut shell |
| keyboard in that shell | `hid_generic` is a module and is not in the initramfs | the shell it dropped to cannot be typed into |
| screen in that shell | `mgag200`/`ast` are modules and are not in the initramfs | only the EFI framebuffer, if the firmware left one |
| firmware | `/usr/lib/firmware` is 16 KB (`regulatory.db`) | `bnx2x`, `qed`, `ice`, `cxgb4`, `tg3`, `qla2xxx` cards stay dark |

None of that is a bug. A cloud image's recovery path is "delete the
instance and make another one", so the console is dead weight. A
bare-metal image's recovery path is a person with a monitor and a
keyboard, or the BMC's serial console, and the image has to have kept
that path open.

The kernel modules themselves are *not* the problem: Ubuntu 26.04's
`linux-modules-<v>-generic` carries 329 ethernet drivers across ~50
vendor directories, and 26.04 no longer builds a separate "virtual"
kernel. What is missing is the firmware those drivers load, and the
initramfs entries that decide whether the machine boots at all.

## What the pipeline does

    seed      render the answer file (password hash, serial port) and
              build the CD the installer reads: subiquity takes
              cloud-init's NoCloud seed from a volume labelled CIDATA,
              anaconda takes /ks.cfg from one labelled OEMDRV
    install   QEMU/OVMF boots the ISO's own kernel and initrd directly -
              the options that make the install unattended have to be on
              the kernel command line and there is nobody to type them.
              Ubuntu gets "autoinstall" plus the command line copied out
              of the ISO's grub.cfg; Rocky gets inst.stage2=hd:LABEL=<the
              DVD's label, read with blkid> and inst.ks. The installer
              powers the machine off when it is done, and that is the
              completion signal
    verify    mount the result and check the console contract
    manifest

The installer boots with `console=ttyS0` and QEMU writes that serial
stream to `dist/<name>.install/serial.log`, so a failed build leaves a
readable transcript rather than a screenshot to squint at. Screenshots
are taken every two minutes as well, and a serial log that stops growing
for `INSTALL_STALL` seconds fails the build instead of waiting out the
timeout.

The installer VM's NIC is `restrict=on`: everything installed comes from
the ISO. A build that can reach the archive is a build that depends on
the day it ran.

## The console contract (what verify enforces)

Nine checks, each printing its own verdict - a checker that only speaks
when it is unhappy cannot be told apart from one that did not run. A
failure is a build failure: no image, no manifest, no upload.

    ok   local login: sysadmin has a password
    ok   grub console: tty0 + ttyS1, serial terminal, no quiet/splash
    ok   grub menu waits
    ok   serial-getty@ttyS1 enabled
    ok   early-boot storage drivers (ahci smartpqi hpsa megaraid_sas mpt3sas nvme)
    ok   early-boot console drivers (hid_generic usbhid mgag200 ast)
    ok   linux-firmware landed (bnx2x blobs present)
    ok   template identity (empty machine-id, no ssh host keys)
    ok   cloud-init runs and uses ConfigDrive (growth and networking on)

Five of them are the way they are because an earlier version could not do
its job, and every one of those was found by watching what the stage said
about an image that was actually fine, or actually broken:

- **"`/lib/firmware` is not empty"** passes on a cloud image that ships
  only `regulatory.db`. It now looks for a `bnx2x` blob.
- **A check for `hid_generic.ko`** can never pass: the file is
  `hid-generic.ko`. Module file names are not modprobe names.
- **"the driver is in the initramfs"** can never pass on Rocky, which
  builds `HID_GENERIC` and `USB_HID` into the kernel - there is no module
  to find. The checks now ask whether the driver is available *at early
  boot*: in the initramfs, **or** `=y` in the image's own
  `/boot/config-*`. Hence "early-boot", not "initramfs".
- **Reading `/boot` off the root filesystem** finds nothing when the
  image has a separate `/boot` partition, as the Rocky kickstart does.
  The stage mounts it (from the image's own fstab) before looking.
- **"grep ConfigDrive in cloud.cfg.d"** finds the file this pipeline
  wrote and says nothing about what wins. Subiquity leaves
  `99-installer.cfg` behind, `cloud.cfg.d` is merged in lexicographic
  order, and `99-installer` sorts after `99-datasources`: the installed
  image had `datasource_list: [None]`, whose datasource writes
  `/etc/cloud/cloud-init.disabled` on first boot and turns off `growpart`
  and `resize_rootfs`. Deployed, that machine reads no metadata,
  configures no network, keeps the hostname `baremetal` and never grows
  past 12 GB - and Ironic reports success. The check now computes the
  effective configuration the way cloud-init would and looks at the
  outcome. It failed on the Ubuntu image and passed on the Rocky one,
  which is how we know it discriminates.

Two more things the checks have to know about the RPM side: with BLS the
kernel command line is in `/boot/loader/entries/*.conf` and *not* in
`grub.cfg`, so checking `grub.cfg` alone would pass an image whose entries
say `rhgb quiet`; and `grub.cfg` lives in `/boot/grub2`, not `/boot/grub`.

The checks were verified against a deliberately broken copy (2026-09-08):
four of the eight sabotaged, exactly those four failed, the other four
passed, exit status 1.

## Serial port per vendor

HPE iLO puts serial-over-LAN on `ttyS1`; Dell iDRAC and Supermicro use
`ttyS0`. That is a property of the machine, so it is declared per image
(`serial_console:` in `image.yaml`), not passed at run time. A fleet with
both needs two images; getting it wrong is invisible until the day
somebody needs the console.

## Usage

    ci/fetch-upstream.sh ubuntu-2604-live-server
    BAREMETAL_ADMIN_PASSWORD='...' ./build.sh ubuntu-26.04-baremetal

    ci/fetch-upstream.sh rocky-10-dvd
    BAREMETAL_ADMIN_PASSWORD='...' ./build.sh rocky-10-baremetal

`INSTALL_ONLY=1` stops after the install, `VERIFY_ONLY=1` re-runs verify
and the manifest against the disk already in `dist/`, and
`KEEP_VM_ON_FAILURE=1` leaves the VM up for inspection.

Needs root (loop mounts) and `/dev/kvm`.

## Not done yet

- A CI workflow, with the console password coming from a secret.
- Machines whose BMC uses `ttyS0` (Dell iDRAC, Supermicro). That is one
  more declaration, not a code change.
- A real acceptance run on a DL360: `tests/smoke-baremetal.md` is the
  list, and the switch port negotiating 10G is the judge, not the Ironic
  provision state.
