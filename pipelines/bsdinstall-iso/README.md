# bsdinstall-iso — FreeBSD bare-metal images from the official DVD

FreeBSD installed from its official DVD by bsdinstall's own scripted
install (`/etc/installerconfig`, bsdinstall(8) SCRIPTING), offline, in a
QEMU VM; the disk is then checked against the console contract and booted
the way Ironic delivers it before it is shipped.

    ci/fetch-upstream.sh freebsd-15.1-dvd1 freebsd-15.1-dhcpcd
    BAREMETAL_ADMIN_PASSWORD='...' ./build.sh freebsd-ufs-15.1-baremetal
    ci/fetch-upstream.sh freebsd-14.5-dvd1 freebsd-14.5-dhcpcd
    BAREMETAL_ADMIN_PASSWORD='...' ./build.sh freebsd-ufs-14.5-baremetal

    # the same with a ZFS root (see "ZFS root" below)
    BAREMETAL_ADMIN_PASSWORD='...' ./build.sh freebsd-zfs-15.1-baremetal
    BAREMETAL_ADMIN_PASSWORD='...' ./build.sh freebsd-zfs-14.5-baremetal

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
              copied off the DVD's own repository, dhcpcd 10.5.2 pinned
              from the latest package set (upstream/sources.yaml; the
              release sets' 10.3.x crashes, see "DHCP" below), and the
              DHCP glue (dhcpcd-rc, rc.conf.d/dhclient, rc.conf.d/dhcpcd)
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
              (a ZFS root: its pool imported read-only)
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
| `ipv4` / `ipv6` | `inet A netmask M` / `inet6 A prefixlen N` (the address first: ifconfig takes an address family only right after the interface) |
| `ipv4_dhcp` | `DHCP`: rc starts rc.d/dhclient for it, which dhcpcd serves (see "DHCP" below) |
| `ipv6_slaac` / `ipv6_dhcpv6-stateless` / `ipv6_dhcpv6-stateful` | the interface in `dhcpcd_ipv6_interfaces` (`/etc/rc.conf.d/dhcpcd`, always written, empty too): dhcpcd runs IPv6 there and on no other interface (`slaac hwaddr`: Neutron's port security passes only EUI-64 addresses) |
| routes | first `0.0.0.0/0` -> `defaultrouter`, first `::/0` -> `ipv6_defaultrouter`, others static routes |

Interfaces the network data does not name get `ifconfig_DEFAULT="DHCP"` (IPv4 by dhcpcd, as for
`ipv4_dhcp`).
nuageinit's built-in password is replaced with `*` by the first-boot
script `nuageinit_default_password` before sshd starts (as on the cloud
images). SSH: FreeBSD's default sshd, so `sysadmin` can log in with the
console password, as on the Linux bare-metal images.

## DHCP: dhcpcd is the only client

Before, two clients: the base system's dhclient (DHCPv4 only) for the interfaces rc configures by DHCP,
and dhcpcd `-6` for the DHCPv6/SLAAC interfaces. Now one dhcpcd manager serves both, through three
files that are byte-identical in `openstack-cloud-images` (pipelines/freebsd-cloud/payload):

- rc asks for DHCP on an interface configured `DHCP` (`ifconfig_<if>`, `ifconfig_DEFAULT`) by starting
  `/etc/rc.d/dhclient <if>`: netif with `synchronous_dhclient=YES`, devd (`service dhclient quietstart`)
  on link-up. `/usr/local/etc/rc.conf.d/dhclient` - sourced by that script through `load_rc_config`
  after it has defined itself - replaces its start, stop and status with
  `/usr/local/libexec/dhcpcd-rc ipv4-start|ipv4-stop|ipv4-status <if>`. Its start_precmd still runs and
  still refuses an interface that is not DHCP. No base system file is changed (pkgbase replaces those).
- `/usr/local/etc/rc.conf.d/dhcpcd`: `dhcpcd_enable=YES`, `dhcpcd_flags="-b -f /var/run/dhcpcd.conf"`,
  `dhcpcd_ipv6_interfaces` (default `ALL`; the renderer's list in `/etc/rc.conf.d/dhcpcd` is read
  first and wins), and the manager's configuration written before it starts.
- `dhcpcd-rc`: the configuration is `/usr/local/etc/dhcpcd.conf`, then a global `noipv4` (and, unless
  ALL, `noipv6` plus `interface <if>` / `ipv6` for each listed interface), then `interface <if>` /
  `ipv4` for each interface rc asked DHCP for (kept in `/var/run/dhcpcd.ipv4`, emptied at boot).
  `ipv4-start` records the interface, rewrites the configuration and runs `dhcpcd -n <if>` (reload
  and rebind; the interface's IPv6 restarts too) - nothing when it is recorded already and the manager
  runs, since netif and devd both ask. `ipv4-stop` removes it and runs `dhcpcd -4 -k <if>` (the IPv4
  lease only). `lockf` serializes them.

So each interface gets exactly what it got before: IPv4 where rc would have run dhclient, IPv6 where
the network data asks for DHCPv6/SLAAC. `-b` sends the manager to the background at once; rc's
`defaultroute` still waits up to 30 s for the default route when an interface is DHCP, as with
dhclient. `synchronous_dhclient=YES` because a NIC that reports no link change (a virtio NIC under QEMU)
leaves nobody to ask again after `service netif restart` - dhclient had the same gap - and asking no
longer blocks the boot.

**No IPv4LL (`noipv4ll` in `/usr/local/etc/dhcpcd.conf`).** dhcpcd's default gives an interface
configured DHCP that gets no lease a 169.254/16 address - and a default route through it. On
Server09 (2026-09-26, the first freebsd-zfs deployment) seven NICs are unwired and left to
`ifconfig_DEFAULT="DHCP"`; bxe0-2 came up for a moment while initialising, dhcpcd gave bxe0 and bxe1
IPv4LL addresses and put the default route on bxe0 (`default link#5 bxe0`, "bxe0: changing default
route"), before rc's routing added the network data's `defaultrouter` ("route already in table").
Replies left through a NIC with no carrier; the switch saw nothing on Et34 and the machine was
unreachable. dhclient never did IPv4LL, so the UFS images accepted on Server09 before the dhcpcd
change did not show it. Confirmed on the machine: `noipv4ll`, dhcpcd restarted (it withdrew its
default route), the static one added - reachable, from outside too. The boot test now has a fourth
NIC on a QEMU hub with nothing else on it (a link, no DHCP server) left to `ifconfig_DEFAULT`, and
checks that no interface has a 169.254 address and the default route is the network data's.
dhcpcd-rc also waits for the manager's control socket before `dhcpcd -n`: asked the moment the
manager started, one command failed (`dhcpcd_control_read: Invalid argument`) and that dhcpcd went on
to start as another daemon.

**dhcpcd 10.5.2 or later.** 10.3.x (the 14.5 and 15.1 release sets) dies of SIGSEGV when an IPv4
address it manages is deleted from outside - `service netif restart` does - with dhcpcd's default
configuration too, so it is dhcpcd, not this arrangement. 10.5.2 survives and leases the address again
(tested 2026-09-25 on 15.1). It is pinned from `latest` by sha256; a Hashed file there is removed when
latest moves on, so a 404 means updating the entry. `verify.sh` and post-install check the version.

**MTU.** A DHCP-given MTU (option 26) is put by dhcpcd on the routes it adds only - its choice on
the BSDs - while dhclient set it on the interface. On Nova (the same dhcpcd, openstack-cloud-images,
2026-09-25) the old image's interface had `mtu 1442` from Neutron and the first dhcpcd-only build
`mtu 1500`: the routes were right, but what takes its MTU from the interface (a VLAN or bridge on it, a
jail's epair, the connected route of an address added by hand) would lose everything over 1442. The hook
`/usr/local/libexec/dhcpcd-hooks/10-mtu` (payload/dhcpcd-hook-mtu) sets `new_interface_mtu` on the
interface as dhclient-script did. On bare metal the network data's link MTU is rendered anyway (`up
mtu N`); the hook matters for an interface configured by DHCP.

The boot test checks the bare-metal side of this (the renderer's list, IPv6 on VLAN 12 only, IPv4 on the
unnamed NIC by dhcpcd with no dhclient running, the version). Deleting the address and
`service netif restart` are checked by openstack-cloud-images' boot test, which reaches the guest
through the guest agent; here root goes over SSH on the very NIC those would take down.

The boot test gives the machine this network data - two phy links, a bond
(802.3ad, layer3+4, lacp fast), VLAN 11 with static IPv4/IPv6 and the
default route, VLAN 12 DHCPv6-stateful - plus a third NIC it does not name
for the test's own SSH. There is no LACP partner in QEMU, so the checks are
on configuration: lagg0 with both ports and `LACP_FAST_TIMO`, the VLAN
addresses, the default route, dhcpcd's IPv6 on lagg0.12 only and IPv4 on the unnamed NIC. Traffic
through the bond is for the real machine (`tests/smoke-baremetal.md`).

## ZFS root (the freebsd-zfs-* images)

`freebsd-zfs-{15.1,14.5}-baremetal` are the UFS images (`freebsd-ufs-{15.1,14.5}-baremetal`) with a
ZFS root and nothing else changed: the same answer file but for the partitioning, the same
post-install, console contract, network renderer and DHCP. The names put the file system before
the version since 2026-09-25; until then the UFS images were `freebsd-{15.1,14.5}-baremetal`,
renamed in Glance too. The declaration says `root_fs: zfs`; the build passes it on (seed `oem.env`,
verify, boot test, manifest `root_fs`), and verify.sh checks that the disk agrees.

- **Install:** bsdinstall's zfsboot, driven by `ZFSBOOT_*` in the answer file's preamble
  (`ZFSBOOT_DISKS=vtbd0` is what selects it instead of `PARTITIONS`): GPT with freebsd-boot
  (`gptboot0`), the ESP (`efiboot0`) and the pool's partition (`zfs0`) last, `BIOS+UEFI`, no swap
  (`ZFSBOOT_SWAP_SIZE=0`); pool `zroot`, boot environment `zroot/ROOT/default` and zfsboot's usual
  datasets, compression on, atime off, 4K sectors. The installer exports the pool at the end.
- **fstab:** zfsboot writes the ESP as `/dev/gpt/efiboot0` already, and the root is the pool's
  `bootfs`, not an fstab line - so the device-name problem the UFS images had (`/dev/vtbd0p2`)
  cannot arise; the post-install check still runs.
- **Growth:** FreeBSD's `rc.d/growfs` handles a ZFS root in 14.5 and 15.1 alike: it takes the
  pool's vdev (`gpt/zfs0`), finds its partition through `glabel status`, `gpart resize`s it and
  runs `zpool online -e` - the pool grows up to Ironic's config-drive partition as a UFS root does.
- **Pool GUID:** every machine starts with the build's pool, GUID included. Two disks of one
  machine carrying the same pool GUID (the image deployed again onto another disk, the old one still
  there) would leave the root pool's import to chance, so a firstboot rc.d script,
  `/usr/local/etc/rc.d/zpool_reguid` (`zpool_reguid_enable=YES`), runs `zpool reguid` on the root
  pool once. The pool name stays `zroot`.
- **A rebuild (or any deployment onto a disk that had a ZFS image before):** growfs grows the
  partition to the same end as the previous deployment did, and the previous pool's labels L2/L3
  are still there - Ironic's rebuild does not clean, and its metadata cleaning wipes only the disk's
  first and last megabytes, while those labels sit before the config-drive partition. `zpool
  online -e` reads them, finds another pool (another GUID after zpool_reguid, a newer txg) and ZFS
  suspends the pool: `Pool 'zroot' has encountered an uncorrectable I/O failure and has been
  suspended` (Server09, 2026-09-26, after a rebuild and again after undeploy + deploy). Reproduced
  in QEMU with the agent's steps (the image written byte for byte, `sgdisk -e`, a config-2 partition
  at the end) and the control that tells it apart: the same with everything past the image zeroed
  before the second deploy boots. Fix: `/usr/local/libexec/zfs-growfs-prepare`, run by growfs as its
  `start_precmd` (`/usr/local/etc/rc.conf.d/growfs`), zeroes the last 2 MiB of the free space the
  partition is about to grow into, through a temporary partition (ZFS holds the root partition open
  exclusively), and deletes it. Not an rc.d script with `BEFORE: growfs`: `/usr/local/etc/rc.d`
  runs only after FILESYSTEMS, when growfs (`BEFORE: root`) is long done - the first attempt did
  exactly that and never ran. The boot test deploys the image a second time onto the same raw disk
  after the reboot (written over, `sgdisk -e`) and checks that it comes up, the pool healthy and
  grown, the prepare step on the console. Confirmed on Server09 by a rebuild onto a disk that had
  the suspended pool's labels.
- **verify.sh** imports the pool on the build host read-only, **under another name**, with
  `cachefile=none`, searching only the image's partition (`-d`), and **without `-f`** - a pool the
  installer did not export does not import, and that fails the build. It mounts
  `ROOT/default` (which holds /etc, /boot, /usr/local and /var/db) and exports the pool again. The
  build host needs zfs (the module and zpool/zfs; CI installs `zfsutils-linux`). A build host with
  pools of its own - this one has one - is not touched: nothing scans beyond the loop device.
  ZFS checks on top of the UFS ones: ZFS last partition, clean read-only import, bootfs, compression,
  no swap partition, no root line in fstab, `zfs_load`/`zfs_enable`, zpool_reguid enabled.
- **boot test**, on top of the UFS checks: root mounted from `zroot/ROOT/default`, the pool grown
  past the image size, `zpool reguid` in the pool's history, then **a reboot** - the first boot
  made a new hostid - and back with the same hostid and pool GUID, the pool healthy and the root
  from the boot environment.

Test builds (2026-09-25, a throwaway console password): 15.1 and 14.5 pass all 61 checks; pool
8 GiB -> 15.5 GiB in the boot test, back in 75 s after the reboot. With the two fixes above (commit
7a445b3) they pass 65.

**Acceptance on Server09 (2026-09-26)**, both versions, built from 7a445b3 with a throwaway console
password and deployed by Ironic *rebuild* onto the disk the earlier ZFS deployments had used (the
stale labels there): the machine up; `da0` behind the E208i (RAID 0 logical drive), the pool's
partition grown from 7.7 GiB to 372 GiB up to Ironic's 64 MiB config-2 partition, `zroot` ONLINE
with no errors, root from `zroot/ROOT/default`, `zpool reguid` in the pool's history at the first
boot; `kern.console` ttyu0 (the iLO VSP) first; bxe3 at 10Gbase-T with the network data's address,
the default route via 10.224.0.1 on bxe3, no 169.254 address, one dhcpcd and no dhclient; the
gateway (0.2 ms), 1.1.1.1 and DNS reachable; `freebsd` and root without a usable password,
`sysadmin` in wheel; nuageinit without a Lua error. A reboot: SSH back 273 s after the command (the
DL360's POST; 50 s of FreeBSD), the same hostid and pool GUID, the pool healthy. The first builds of
these images (without the fixes) failed here as described above: unreachable (IPv4LL), and after
a rebuild or a redeploy their pool suspended.

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
