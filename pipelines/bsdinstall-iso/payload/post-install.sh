#!/bin/sh
# The post-install part of the scripted bsdinstall: runs chrooted in the
# freshly installed system, from the answer file's CD (label FBSDOEM,
# mounted at /media/oem by the installerconfig). Offline - the installer
# VM reaches nothing.
#
# oem.env on the CD carries ADMIN_USER, ADMIN_HASH (SHA-512 crypt of the
# console password), SERIAL_IO (the console UART's I/O port) and
# SERIAL_TTY (its tty). Output goes to the installer's console, which the
# build records.

set -eux
# The installer's PATH has no /usr/local; packages' tools (visudo) live
# there.
export PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin
SEED=/media/oem
. $SEED/oem.env

# ---- packages the system needs that are not in the base system, from the
# CD: pkg and sudo (+ gettext-runtime) as the DVD carries them, dhcpcd from
# the release's frozen package set (pinned in upstream/sources.yaml). The
# files are named <name>-<version>.pkg so pkg add finds dependencies.
if ! pkg -N >/dev/null 2>&1; then
	mkdir -p /tmp/pkg-bootstrap
	tar -xf $SEED/pkgs/pkg-[0-9]*.pkg -C /tmp/pkg-bootstrap /usr/local/sbin/pkg-static
	/tmp/pkg-bootstrap/usr/local/sbin/pkg-static add $SEED/pkgs/pkg-[0-9]*.pkg
	rm -rf /tmp/pkg-bootstrap
fi
env ASSUME_ALWAYS_YES=yes pkg add $SEED/pkgs/sudo-[0-9]*.pkg $SEED/pkgs/dhcpcd-[0-9]*.pkg
pkg query '%n %v' sudo dhcpcd | sed 's/^/oem-version: /'

# ---- the local login: the account for the person at the machine when
# nothing else works. root stays locked; the admin has sudo through wheel.
echo "$ADMIN_HASH" | pw useradd -n "$ADMIN_USER" -c "Administrator" -m -G wheel -s /bin/sh -H 0
echo '*' | pw usermod root -H 0
echo '%wheel ALL=(ALL:ALL) ALL' >/usr/local/etc/sudoers.d/wheel
chmod 0440 /usr/local/etc/sudoers.d/wheel
visudo -cf /usr/local/etc/sudoers

# ---- the consoles. The kernel: the BMC's serial port as the primary
# console (boot messages, single-user prompt), the screen as the second.
# The loader: the UEFI console, which the firmware shows on the screen and
# redirects to the BMC's serial port (HPE Gen10 does by default) - with
# console="comconsole,efi" the loader writes the serial port a second time
# and every character of its menu arrives doubled; comconsole is for
# firmware that does not redirect (loader.efi(8)). A getty on that port;
# the loader menu waits 5 seconds.
cat >>/boot/loader.conf <<EOF
# Console (bsdinstall-iso): the kernel on the BMC's serial-over-LAN port
# ($SERIAL_TTY, $SERIAL_IO) first and the screen second; the loader on the
# UEFI console, which the firmware redirects to that port.
boot_multicons="YES"
boot_serial="YES"
hw.uart.console="io:$SERIAL_IO,br:115200"
console="efi"
# For firmware that does not redirect: console="comconsole,efi" with
comconsole_speed="115200"
comconsole_port="$SERIAL_IO"
autoboot_delay="5"
EOF
if grep -q "^$SERIAL_TTY[[:space:]]" /etc/ttys; then
	sed -i '' -E "s|^$SERIAL_TTY[[:space:]].*|$SERIAL_TTY	\"/usr/libexec/getty 3wire.115200\"	vt100	on  secure|" /etc/ttys
else
	printf '%s\t"/usr/libexec/getty 3wire.115200"\tvt100\ton  secure\n' "$SERIAL_TTY" >>/etc/ttys
fi
# The other COM port gets a getty too (if it exists): a login still works
# if a BMC or BIOS setting uses it.
for other in ttyu0 ttyu1; do
	[ "$other" = "$SERIAL_TTY" ] && continue
	sed -i '' -E "s|^$other[[:space:]].*|$other	\"/usr/libexec/getty 3wire.115200\"	vt100	onifexists secure|" /etc/ttys
done
grep -E "^ttyu[01]" /etc/ttys

# ---- services. nuageinit (the base system's cloud-init) reads the config
# drive Ironic writes; growfs grows the root into the disk, without adding
# a swap partition; interfaces the network data does not name ask DHCP in
# the background.
sysrc hostname="freebsd" sshd_enable=YES nuageinit_enable=YES growfs_enable=YES \
    growfs_swap_size=0 ifconfig_DEFAULT="DHCP" dumpdev=AUTO

# ---- nuageinit on bare metal: the network (bond, VLAN, DHCPv6) and its
# built-in default password (see each file).
install -m 0444 $SEED/payload/rc.conf.d-nuageinit /etc/rc.conf.d/nuageinit
install -d /usr/local/libexec
install -m 0555 $SEED/payload/nuageinit-netdata /usr/local/libexec/nuageinit-netdata
install -m 0555 $SEED/payload/nuageinit_default_password /usr/local/etc/rc.d/nuageinit_default_password
# dhcpcd: SLAAC addresses from the MAC (EUI-64) - Neutron's port security
# lets only those out; the interfaces it serves come from the network data.
sed -i '' -E 's/^slaac[[:space:]]+private/slaac hwaddr/' /usr/local/etc/dhcpcd.conf
grep -q '^slaac hwaddr' /usr/local/etc/dhcpcd.conf

# ---- the file systems by GPT label, not by device name: bsdinstall writes
# /etc/fstab with the build VM's names (/dev/vtbd0p2), and on the server
# the disk behind the RAID controller is da0 - the first Server09 boot
# stopped at mountroot> ("Mounting from ufs:/dev/vtbd0p2 failed with error
# 19"). The official images use /dev/gpt/<label> the same way.
fstab_by_label() {
	local dev mnt rest label disk idx
	: >/tmp/fstab.new
	while read -r dev mnt rest; do
		case "$dev" in
		/dev/*p[0-9]*)
			case "$mnt" in
			/) label=rootfs ;;
			/boot/efi) label=efiboot0 ;;
			none) label=swapfs ;;
			*) label=$(echo "$mnt" | tr -c 'a-z0-9\n' '_' | sed 's/^_//') ;;
			esac
			disk=${dev#/dev/}; idx=${disk##*p}; disk=${disk%p*}
			gpart modify -i "$idx" -l "$label" "$disk"
			printf '/dev/gpt/%s\t%s\t%s\n' "$label" "$mnt" "$rest" >>/tmp/fstab.new
			;;
		*)
			printf '%s\t%s\t%s\n' "$dev" "$mnt" "$rest" >>/tmp/fstab.new
			;;
		esac
	done </etc/fstab
	mv /tmp/fstab.new /etc/fstab
}
fstab_by_label
cat /etc/fstab
if grep -qE '^/dev/(vtbd|ada|da|nvd|nda|mmcsd)[0-9]' /etc/fstab; then
	echo "fstab still names devices" >&2; exit 1
fi

# ---- template identity: the first boot of every machine runs the
# firstboot scripts (nuageinit, growfs, the default password); no SSH host
# keys, no hostid.
touch /firstboot
rm -f /etc/ssh/ssh_host_* /etc/hostid /etc/machine-id
freebsd-version -ku | sed 's/^/freebsd-version: /'
echo OEM-POSTINSTALL-DONE
