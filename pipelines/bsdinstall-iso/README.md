# bsdinstall-iso — FreeBSD bare-metal images from the official DVD

FreeBSD installed from its official DVD by bsdinstall's own scripted
install (`/etc/installerconfig`, bsdinstall(8) SCRIPTING), offline, in a
QEMU VM; the disk is then checked against the console contract and booted
the way Ironic delivers it before it is shipped.

    ci/fetch-upstream.sh freebsd-15.1-dvd1 freebsd-15.1-dhcpcd
    BAREMETAL_ADMIN_PASSWORD='...' ./build.sh freebsd-15.1-baremetal
    ci/fetch-upstream.sh freebsd-14.5-dvd1 freebsd-14.5-dhcpcd
    BAREMETAL_ADMIN_PASSWORD='...' ./build.sh freebsd-14.5-baremetal

Only the latest minor release of each major (14.x, 15.x): a minor release
is supported for about three months after the next one.

Needs root, `/dev/kvm`, QEMU + OVMF, `xorriso`, `zstd`, `jq`, `openssl`,
`sshpass`, `ssh-keygen`, and a host kernel that can read UFS (`ufs`
module). `INSTALL_ONLY=1` stops after the install, `VERIFY_ONLY=1` re-runs
verify, the boot test and the manifest, `KEEP_INSTALL_MEDIA=1` writes the
remastered DVD and the answer file's CD to `dist/<name>.install/` and
stops (for driving the installer by hand).

## Why the installer, for FreeBSD

FreeBSD has no initramfs: the GENERIC kernel and its modules are the same
on the official cloud image (`VM-IMAGES/.../BASIC-CLOUDINIT`) and on an
installed system. So the Linux argument of this repository - the cloud
image's initramfs cannot reach a hardware RAID controller - does not
apply. The installer is here for the rest of the console contract and for
a system that has never had the cloud image's defaults, which measured on
15.1 (2026-09-24) are: root without a password, `PasswordAuthentication
yes`, and nuageinit's default user `freebsd` with the password `freebsd`
(hard-coded in `/usr/libexec/nuageinit`).

## What the pipeline does

    seed      the answer file's CD (label FBSDOEM): post-install.sh and
              the files it installs, oem.env (admin user, SHA-512 hash of
              the console password, serial port), and packages the base
              system lacks - pkg and sudo (+ gettext-runtime, indexinfo)
              copied off the DVD's own repository, dhcpcd pinned from the
              release's frozen package set (upstream/sources.yaml)
    remaster  the DVD with /etc/installerconfig (images/<name>/
              installerconfig - the file the installer runs unattended)
              and /boot/loader.conf.local added. FreeBSD's ISO keeps its
              El Torito images hidden, so xorriso cannot replay them: the
              boot set-up is rebuilt as the release's own ISO is made -
              BIOS from /boot/cdboot, UEFI from the FAT image the original
              carries, copied byte for byte from where its catalog says
    install   QEMU/OVMF boots the DVD, no NIC. 15.1: pkgbase from the
              DVD's offline repository (the installer's default on the
              DVD); 14.5: the distribution sets. The post-install script
              runs chrooted. The installer reboots when done; -no-reboot
              makes that QEMU's exit
    verify    verify.sh: the disk mounted read-only on the build host
    boottest  boot-test.py: booted as Ironic delivers it
    manifest

Three things about the installer VM that are not obvious:

- **The DVD is on virtio-scsi.** On the q35 SATA CD-ROM, OVMF hangs
  reading this DVD (the original too; QEMU 10.2.1, 2026-09-24) and QEMU
  later crashed.
- **The screen is the installer's primary console, the serial port the
  second.** On a serial primary console `startbsdinstall` asks for the
  terminal type before it looks at installerconfig, and nobody is there to
  answer; `bsdinstall.multicons_disable` keeps a second installer off the
  serial port. The installerconfig sends the installer's own output to
  `/dev/ttyu0` - `/dev/console` reaches only the primary console - so the
  serial log is the build's transcript, ending in `OEM-POSTINSTALL-DONE`.
- **The installer's PATH has no /usr/local**: post-install.sh sets its own
  (visudo is a package's tool).

## The console contract

`verify.sh` (the disk, nothing running) and `boot-test.py` (the running
system). For HPE iLO the declaration says `serial_console: ttyS0`: the
iLO virtual serial port is COM1 (I/O 0x3F8, `ttyu0` on FreeBSD). The BIOS
of Server07 and Server09 says `VirtualSerialPort = Com1Irq4`, COM2 being
the rear DB9 port (`EmbeddedSerialPort = Com2Irq3`). The first version
declared ttyS1, copied from the Linux declarations: on Server09 the VSP
showed nothing, and on Server07 - whose Linux image has its console and
getty on ttyS1 - it shows nothing either.

| what | how | checked by |
| --- | --- | --- |
| local login | `sysadmin` (wheel, sudo with its own password) with the console password from `BAREMETAL_ADMIN_PASSWORD`; root locked | verify (hash), boot test: login **on the serial console** and over SSH, sudo, a wrong password refused |
| kernel console | `boot_serial` + `boot_multicons`, `hw.uart.console="io:0x3F8,br:115200"`: the BMC's port primary, the screen second | verify; boot test: boot messages on COM1, `kern.console` |
| loader | `console="efi"`, `autoboot_delay=5`: the UEFI console, which the firmware shows on the screen and redirects to the BMC's port (HPE Gen10 by default). With `comconsole,efi` the loader writes that port a second time and every character of its menu arrives doubled - seen in the boot test | verify; boot test: the menu on COM1, once |
| getty | `ttyu0 ... on` in `/etc/ttys` | verify; boot test: `login:` on COM1 |
| drivers | storage (ahci, smartpqi, ciss, mrsas, mfi, mpr, mps, nvme) and console (ukbd, hkbd, kbdmux, uart) compiled into GENERIC; NIC drivers and the ice DDP firmware module present | boot test: `kldstat -v -i 1`, with `mlx5en` (a module) as the control that the check can say no; verify: modules |
| layout | GPT, ESP with `EFI/BOOT/BOOTX64.EFI`, one UFS root last, no swap; `growfs` grows it on first boot, `growfs_swap_size=0` | verify; boot test: root grew |
| fstab | by GPT label (`/dev/gpt/rootfs`, `/dev/gpt/efiboot0`), set by post-install with `gpart modify -l`. bsdinstall writes the build VM's device names (`/dev/vtbd0p2`); the server's disk behind Smart Array is `da0`, and the first Server09 boot stopped at `mountroot>` ("Mounting from ufs:/dev/vtbd0p2 failed with error 19"). The QEMU boot test had the disk on virtio-blk too and could not see it; it now boots the disk on SCSI (`da0`) | verify: no device names; boot test: boots from da0 |
| template | `/firstboot` present, no SSH host keys, no hostid, no guest agent | verify; boot test: made on first boot |

`verify.sh` was run against a disk that does not keep the contract (the
customized official cloud image, `openstack-cloud-images`
freebsd-15.1-cloud-kvm): ten checks failed, each for its real reason.

## nuageinit on bare metal

nuageinit (the base system's cloud-init) reads the config drive Ironic
writes as a partition labelled config-2. Two problems with the network
data Ironic writes for a Neutron port group (phy + bond + VLAN), found in
the 15.1 source and still in `main`:

- `config2_network` calls `ethernet_mac_address:lower()` on every link; a
  VLAN link has `vlan_mac_address`, and the Lua error ends nuageinit before
  the hostname, the users and the SSH keys;
- it knows no bond or VLAN and only the network types `ipv4`, `ipv4_dhcp`
  and `ipv6` (the base system has no DHCPv6 client at all), and writes
  IPv6 addresses without a prefix length.

`/etc/rc.conf.d/nuageinit` - sourced by `/etc/rc.d/nuageinit` through
`load_rc_config`, so configuration rather than a changed base system file
(pkgbase and freebsd-update keep replacing theirs) - replaces nuageinit's
start command when a config drive is present: the drive is copied, links
and networks are emptied in the copy's `network_data.json`, nuageinit runs
on the copy (hostname, users, keys, user-data, DNS as usual), and
`/usr/local/libexec/nuageinit-netdata` renders the network from the
original:

| network_data | rc.conf.d |
| --- | --- |
| phy | the interface with that MAC; `up mtu N` |
| bond `802.3ad` / `active-backup` / `balance-rr` / `balance-xor` | `laggN`, `laggproto lacp` / `failover` / `roundrobin` / `loadbalance`; hash `layer2` / `layer2+3` / `layer3+4` -> `l2` / `l2,l3` / `l3,l4`; `lacp_rate fast` -> `lacp_fast_timeout` |
| vlan | `vlans_<parent>`, interface `<parent>.<id>` |
| `ipv4` / `ipv4_dhcp` / `ipv6` | `inet A netmask M` / `DHCP` / `inet6 A prefixlen N` (the address first: ifconfig takes an address family only right after the interface) |
| `ipv6_slaac` / `ipv6_dhcpv6-stateless` / `ipv6_dhcpv6-stateful` | dhcpcd -6 on that interface (`slaac hwaddr`: Neutron's port security passes only EUI-64 addresses) |
| routes | first `0.0.0.0/0` -> `defaultrouter`, first `::/0` -> `ipv6_defaultrouter`, others static routes |

Interfaces the network data does not name get `ifconfig_DEFAULT="DHCP"`.
nuageinit's built-in password is replaced with `*` by the first-boot
script `nuageinit_default_password` before sshd starts (as on the cloud
images). SSH: FreeBSD's default sshd, so `sysadmin` can log in with the
console password, as on the Linux bare-metal images.

The boot test gives the machine this network data - two phy links, a bond
(802.3ad, layer3+4, lacp fast), VLAN 11 with static IPv4/IPv6 and the
default route, VLAN 12 DHCPv6-stateful - plus a third NIC it does not name
for the test's own SSH. There is no LACP partner in QEMU, so the checks are
on configuration: lagg0 with both ports and `LACP_FAST_TIMO`, the VLAN
addresses, the default route, dhcpcd on lagg0.12. Traffic through the
bond is for the real machine (`tests/smoke-baremetal.md`).

## Acceptance on a DL360 (Server09, 2026-09-24)

Ironic direct deploy (`network_interface=neutron`, VIF on the `baremetal`
network, VLAN 17; config drive with meta_data only - the network data is
Ironic's own from the port), both 15.1 and 14.5, with images built
exactly as above with a throwaway console password:

- switch: Et34 from 1G (auxiliary power, off) to **a-10G**; the machine's
  MAC learned on Et34, VLAN 17; Po9's configuration identical before and
  after (NGS writes the same VLAN 17);
- iLO virtual serial port (`ssh Administrator@<iLO>` -> `vsp`): the whole
  boot, `FreeBSD/amd64 (<hostname>) (ttyu0)`, and a **login as sysadmin
  with the console password**; `kern.console` = `ttyu0,ttyv0`;
- `smartpqi0/1: <E208i-p/-a SR Gen10>`, `bxe3: QLogic NetXtreme II
  BCM57810 10GbE`, link up 10000 Mbps; root on da0 by label;
- root grown to 361G up to the 64M config-drive partition Ironic adds
  after it; hostname from the config drive; nuageinit without error;
  Ironic's network data (`ipv4` on the phy link) rendered to
  `ifconfig_bxe3="inet 10.224.0.40 netmask 255.255.255.0 up mtu 1500"`
  and the default route; the gateway and 1.1.1.1 reachable; SSH with the
  keypair (freebsd) and the console password (sysadmin, sudo);
  `freebsd`'s built-in password removed.

When the console shows nothing, the iLO remote console's thumbnail is
readable over HTTPS with a Redfish session (`/images/thumbnail.bmp`, 16-bit
BMP with bit fields that PIL does not read) - that is how the
`mountroot>` screen was found.

Not covered: Server09 has one leg (Et33 is not connected), so the bond /
LACP path ran only in the QEMU boot test.

## Not done yet

- A bond/LACP run on real hardware (a server with both legs cabled).
- Dell iDRAC / Supermicro (`ttyS0`): one more declaration.
