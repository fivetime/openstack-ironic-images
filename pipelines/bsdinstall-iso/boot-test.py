#!/usr/bin/env python3
"""Boot a FreeBSD bare-metal image the way Ironic delivers it, and check it.

Usage: boot-test.py <disk.raw> <workdir> <serial_console>
       (BAREMETAL_ADMIN_PASSWORD, ADMIN_USER in the environment)

Exit 0 only when every check passed. The disk is never written: QEMU
boots a qcow2 overlay 8 GiB bigger than the image, as a server's disk is.

What it stands in for:
- the BMC's serial-over-LAN: the declared port (COM2 for ttyS1) is a
  socket; the loader and the kernel must talk there, and the local login
  must work there with the console password;
- Ironic's config drive (a config-2 partition on the real disk; a config-2
  CD here - nuageinit finds either by label) with network_data.json of the
  shape Ironic writes for a Neutron port group: two phy links, a bond
  (802.3ad, layer3+4, lacp fast) and VLANs on it - one with static IPv4
  and IPv6 and the default route, one DHCPv6-stateful. No user_data, so
  nuageinit creates its default user with its built-in password;
- a third NIC the network data does not name (ifconfig_DEFAULT: DHCP) for
  the test's own SSH, forwarded from the host.
There is no LACP partner, so lagg0 has no active port: the checks are on
configuration, not traffic.
"""
import json, os, re, secrets, shlex, shutil, socket, subprocess, sys, tempfile, time

OVMF_CODE = os.environ.get("OVMF_CODE", "/usr/share/OVMF/OVMF_CODE_4M.fd")
OVMF_VARS = os.environ.get("OVMF_VARS", "/usr/share/OVMF/OVMF_VARS_4M.fd")
ADMIN = os.environ.get("ADMIN_USER", "sysadmin")
PW = os.environ["BAREMETAL_ADMIN_PASSWORD"]

disk, work, serial_console = sys.argv[1], sys.argv[2], sys.argv[3]
com = {"ttyS0": 1, "ttyS1": 2}[serial_console]
if os.path.exists(work):
    shutil.rmtree(work)
os.makedirs(work)
sockdir = tempfile.mkdtemp(prefix="bt-")
con_sock = os.path.join(sockdir, "console.sock")
key = os.path.join(work, "id_ed25519")
HOST = "bmtest-" + secrets.token_hex(3)
MAC1, MAC2, MAC3 = "20:67:7c:00:be:01", "20:67:7c:00:be:02", "52:54:00:00:be:03"

subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "boottest", "-f", key], check=True)
pub = open(key + ".pub").read().strip()
cd = os.path.join(work, "cd", "openstack", "latest")
os.makedirs(cd)
json.dump({"uuid": "0b0e5b1e-0000-4000-8000-000000000003", "hostname": HOST, "name": HOST,
           "public_keys": {"boottest": pub}, "meta": {}}, open(os.path.join(cd, "meta_data.json"), "w"))
json.dump({
    "links": [
        {"id": "nic1", "type": "phy", "ethernet_mac_address": MAC1, "mtu": 1500},
        {"id": "nic2", "type": "phy", "ethernet_mac_address": MAC2, "mtu": 1500},
        {"id": "bond0", "type": "bond", "bond_links": ["nic1", "nic2"], "bond_mode": "802.3ad",
         "bond_xmit_hash_policy": "layer3+4", "bond_miimon": 100, "bond_lacp_rate": "fast",
         "ethernet_mac_address": MAC1, "mtu": 1500},
        {"id": "k8s-ctl", "type": "vlan", "vlan_link": "bond0", "vlan_id": 11,
         "vlan_mac_address": MAC1, "mtu": 1500},
        {"id": "tenant", "type": "vlan", "vlan_link": "bond0", "vlan_id": 12,
         "vlan_mac_address": MAC1, "mtu": 1500}],
    "networks": [
        {"id": "k8s-ctl-v4", "type": "ipv4", "link": "k8s-ctl", "ip_address": "10.32.0.27",
         "netmask": "255.255.240.0",
         "routes": [{"network": "0.0.0.0", "netmask": "0.0.0.0", "gateway": "10.32.0.1"}]},
        {"id": "k8s-ctl-v6", "type": "ipv6", "link": "k8s-ctl", "ip_address": "fc00:1:1::27",
         "netmask": "ffff:ffff:ffff:ffff::", "routes": []},
        {"id": "tenant-v6", "type": "ipv6_dhcpv6-stateful", "link": "tenant",
         "ip_address": "2001:db8:12::27", "netmask": "ffff:ffff:ffff:ffff::", "routes": []}],
    "services": [{"type": "dns", "address": "192.0.2.53"}]},
    open(os.path.join(cd, "network_data.json"), "w"))
subprocess.run(["xorrisofs", "-quiet", "-R", "-J", "-V", "config-2", "-o",
                os.path.join(work, "config-2.iso"), os.path.join(work, "cd")], check=True)
GROW = 8 << 30
ovl = os.path.join(work, "overlay.qcow2")
subprocess.run(["qemu-img", "create", "-q", "-f", "qcow2", "-F", "raw", "-b",
                os.path.abspath(disk), ovl, str(os.path.getsize(disk) + GROW)], check=True)
subprocess.run(["cp", OVMF_VARS, os.path.join(work, "vars.fd")], check=True)
with socket.socket() as s:
    s.bind(("127.0.0.1", 0))
    ssh_port = s.getsockname()[1]
serial_args = []
for n in (1, 2):
    if n == com:
        serial_args += ["-chardev", f"socket,id=con,path={con_sock},server=on,wait=off,"
                        f"logfile={work}/console.log", "-serial", "chardev:con"]
    else:
        serial_args += ["-serial", "null"]
qemu = subprocess.Popen([
    "qemu-system-x86_64", "-machine", "q35,accel=kvm", "-cpu", "host", "-m", "2048", "-smp", "2",
    "-display", "none", "-vga", "std", *serial_args,
    "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
    "-drive", f"if=pflash,format=raw,file={work}/vars.fd",
    # The disk on SCSI: da0, as behind the server's RAID controller, not
    # the build VM's vtbd0 - a name baked into the image fails here too.
    "-device", "virtio-scsi-pci,id=scsi0",
    "-drive", f"if=none,id=d0,format=qcow2,file={ovl}", "-device", "scsi-hd,drive=d0,bus=scsi0.0,bootindex=0",
    "-drive", f"if=none,id=cd0,format=raw,readonly=on,file={work}/config-2.iso",
    "-device", "scsi-cd,drive=cd0,bus=scsi0.0",
    "-netdev", "user,id=n1,restrict=on", "-device", f"virtio-net-pci,netdev=n1,mac={MAC1}",
    "-netdev", "user,id=n2,restrict=on", "-device", f"virtio-net-pci,netdev=n2,mac={MAC2}",
    "-netdev", f"user,id=n3,restrict=on,hostfwd=tcp:127.0.0.1:{ssh_port}-:22",
    "-device", f"virtio-net-pci,netdev=n3,mac={MAC3}",
], stdout=open(os.path.join(work, "qemu.log"), "w"), stderr=subprocess.STDOUT)

SSH_OPTS = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
            "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10", "-p", str(ssh_port)]

def ssh_key(cmd, timeout=120):
    p = subprocess.run(["ssh", *SSH_OPTS, "-i", key, "-o", "BatchMode=yes", "freebsd@127.0.0.1", cmd],
                       capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout.strip()

def ssh_admin(cmd, password=PW, timeout=120):
    p = subprocess.run(["sshpass", "-e", "ssh", *SSH_OPTS, "-o", "PubkeyAuthentication=no",
                        "-o", "PreferredAuthentications=keyboard-interactive,password",
                        "-o", "NumberOfPasswordPrompts=1", f"{ADMIN}@127.0.0.1", cmd],
                       capture_output=True, text=True, timeout=timeout, env={**os.environ, "SSHPASS": password})
    return p.returncode, p.stdout.strip()

def as_root(cmd):
    # shlex, not json: a JSON string is double-quoted for the remote login
    # shell, which expanded the command's own $variables before sudo ran it.
    return ssh_admin(f"echo '{PW}' | sudo -S -p '' sh -c {shlex.quote(cmd)}")

def console_log():
    try:
        raw = open(os.path.join(work, "console.log"), "rb").read().decode(errors="replace")
    except OSError:
        return ""
    return re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", raw).replace("\r", "")

fails = []
def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}" + (f": {detail}" if detail else ""), flush=True)
    if not ok:
        fails.append(name)

try:
    # ---- the serial console: loader, kernel, getty - and a login there.
    t0 = time.time()
    while time.time() - t0 < 900 and qemu.poll() is None and "login:" not in console_log():
        time.sleep(5)
    log = console_log()
    check(f"loader menu on the serial console ({serial_console}), once", "Autoboot in" in log
          and "AAuuttoobboooott" not in log, f"{len(log)} bytes")
    check("kernel on the serial console", "FreeBSD is a registered trademark" in log or "Copyright (c)" in log)
    check(f"login prompt on {serial_console}", "login:" in log, f"{int(time.time()-t0)}s after power on")
    logged_in = False
    if "login:" in log:
        c = socket.socket(socket.AF_UNIX)
        c.connect(con_sock)
        c.settimeout(2)
        def expect(pat, timeout):
            buf, t = b"", time.time()
            while time.time() - t < timeout:
                try:
                    buf += c.recv(4096)
                except socket.timeout:
                    pass
                if re.search(pat, buf):
                    return buf
            return None
        c.sendall(b"\r")
        expect(rb"login: ", 20)
        c.sendall(ADMIN.encode() + b"\r")
        if expect(rb"Password:", 30):
            c.sendall(PW.encode() + b"\r")
            if expect(rb"[$#] ", 30):
                c.sendall(b"echo SERIAL-$(id -un)-OK\r")
                logged_in = expect(("SERIAL-" + ADMIN + "-OK").encode(), 20) is not None
                c.sendall(b"exit\r")
        c.close()
    check(f"local login on {serial_console} with the console password", logged_in)

    # ---- SSH: the default user with the keypair, the admin with its password.
    up = False
    while time.time() - t0 < 1200 and qemu.poll() is None:
        try:
            if ssh_key("true", timeout=30)[0] == 0:
                up = True
                break
        except subprocess.TimeoutExpired:
            pass
        time.sleep(10)
    check("freebsd (nuageinit's default user) reachable over SSH with the keypair", up)
    rc, out = ssh_admin("id -un")
    check(f"{ADMIN} logs in over SSH with the console password", rc == 0 and out == ADMIN, out)
    rc, out = as_root("id -u")
    check(f"{ADMIN} becomes root with sudo", rc == 0 and out.endswith("0"), out[-20:])
    if not (up and rc == 0):
        raise SystemExit(1)

    # ---- drivers compiled into the kernel: kldstat -v lists the modules
    # inside the kernel file (id 1); mlx5en is a module in GENERIC, the
    # control that the check can say no.
    rc, out = as_root("kldstat -v -i 1")
    inkernel = set(re.findall(r"^\s+\d+\s+(\S+)$", out, re.M))
    def has(name):
        return any(m == name or m.startswith(name + "/") or m.endswith("/" + name) for m in inkernel)
    storage = ["ahci", "smartpqi", "ciss", "mrsas", "mfi", "mpr", "mps", "nvme"]
    consoles = ["ukbd", "hkbd", "kbdmux", "uart"]
    missing = [d for d in storage + consoles if not any(d in m for m in inkernel)]
    check("storage and console drivers compiled into the kernel", not missing and len(inkernel) > 50,
          f"{len(inkernel)} modules in the kernel; missing: {missing or 'none'}")
    check("control: mlx5en is not in the kernel (the check can fail)", not any("mlx5en" in m for m in inkernel))
    rc, out = as_root("sysctl -n kern.console")
    tty = {"ttyS0": "ttyu0", "ttyS1": "ttyu1"}[serial_console]
    check(f"{tty} is a kernel console", tty in out.split("/")[0].split(","), out)

    # ---- nuageinit and the network rendered from network_data.json
    rc, hostname = ssh_key("hostname")
    check("hostname from the config drive", hostname == HOST, hostname)
    rc, out = as_root("grep -nE 'lua|error|attempt to' /var/log/nuageinit.log || true")
    check("nuageinit ran without a Lua error", out.strip() == "", out[:200])
    rc, out = as_root("ifconfig -v lagg0")
    check("bond -> lagg0 (lacp, l3,l4 hash, fast timeout, both ports, MTU)",
          "laggproto lacp" in out and "lagghash l3,l4" in out and "LACP_FAST_TIMO" in out
          and out.count("laggport:") == 2 and "mtu 1500" in out,
          " ".join(l.strip() for l in out.splitlines() if "lagg" in l or "flags=" in l)[:240])
    rc, out = as_root("ifconfig lagg0.11")
    check("VLAN 11 with the static IPv4 and IPv6 (prefix length from the netmask)",
          "inet 10.32.0.27 netmask 0xfffff000" in out and "inet6 fc00:1:1::27 prefixlen 64" in out
          and "vlan: 11" in out, " | ".join(l.strip() for l in out.splitlines() if "inet" in l or "vlan:" in l))
    # dhcpcd is the only DHCP client: IPv6 on the interfaces the renderer
    # lists (the DHCPv6 network's VLAN only), IPv4 on the interfaces rc
    # configures by DHCP (here the unnamed NIC, ifconfig_DEFAULT).
    rc, out = as_root("ifconfig lagg0.12 | grep 'vlan: 12'; cat /etc/rc.conf.d/dhcpcd; "
                      "sed -n '/^# dhcpcd-rc/,$p' /var/run/dhcpcd.conf")
    check("VLAN 12 (DHCPv6-stateful): dhcpcd runs IPv6 there and nowhere else",
          "vlan: 12" in out and 'dhcpcd_ipv6_interfaces="lagg0.12"' in out
          and "noipv4\nnoipv6\ninterface lagg0.12\nipv6" in out,
          " | ".join(l.strip() for l in out.splitlines() if l.strip()))
    rc, out = as_root("service dhclient status vtnet2; pgrep -x dhclient >/dev/null && echo DHCLIENT-RUNNING; "
                      "ifconfig vtnet2 inet; v=$(pkg query %v dhcpcd); echo dhcpcd $v $(pkg version -t $v 10.5.2)")
    check("dhcpcd, not dhclient, holds IPv4 on the unnamed NIC (rc.d/dhclient redirected)",
          "DHCPv4 on vtnet2: dhcpcd is running" in out and "DHCLIENT-RUNNING" not in out and "inet " in out,
          " | ".join(l.strip() for l in out.splitlines() if "DHCP" in l or "inet " in l))
    check("dhcpcd is 10.5.2 or later", re.search(r"^dhcpcd \S+ [=>]$", out, re.M) is not None,
          next((l for l in out.splitlines() if l.startswith("dhcpcd ")), out))
    rc, out = as_root("route -n get default | sed -n 's/.*gateway: //p'")
    check("IPv4 default route from the network data", out.strip() == "10.32.0.1", out)
    rc, out = as_root("cat /etc/rc.conf.d/network; grep -c ifconfig_vtnet2 /etc/rc.conf.d/network || true")
    check("the unnamed NIC left to ifconfig_DEFAULT", out.strip().endswith("0"))

    # ---- accounts, growth, identity
    rc, out = as_root("pw usershow freebsd | cut -d: -f2; pw usershow root | cut -d: -f2")
    check("nuageinit's built-in password removed; root locked", out.split() == ["*", "*"], out)
    check("the built-in password 'freebsd' does not log in",
          subprocess.run(["sshpass", "-p", "freebsd", "ssh", *SSH_OPTS, "-o", "PubkeyAuthentication=no",
                          "-o", "NumberOfPasswordPrompts=1", "freebsd@127.0.0.1", "true"],
                         capture_output=True).returncode != 0)
    rc, out = ssh_key("df -k / | tail -1 | awk '{print $2}'")
    size = int(out) * 1024 if out.isdigit() else 0
    check("root filesystem grew into the larger disk (growfs)", size > os.path.getsize(disk),
          f"root {size >> 20} MiB, image {os.path.getsize(disk) >> 20} MiB")
    rc, out = as_root("test -e /firstboot && echo present; cat /etc/hostid; ls /etc/ssh/ssh_host_*_key.pub | wc -l")
    lines = out.split()
    check("first boot completed; hostid and SSH host keys made on this boot",
          "present" not in lines and len(lines) >= 2 and lines[-1].isdigit() and int(lines[-1]) > 0, out)
    check(f"a wrong password is refused for {ADMIN} (control)", ssh_admin("true", password=PW + "x")[0] != 0)
    if fails:
        rc, out = as_root("tail -30 /var/log/nuageinit.log; cat /etc/rc.conf.d/network /etc/rc.conf.d/routing /etc/rc.conf.d/dhcpcd; "
                          "cat /var/run/dhcpcd.ipv4; tail -12 /var/run/dhcpcd.conf; tail -30 /var/log/daemon.log")
        print("\n".join("    " + l for l in out.splitlines()))
finally:
    hold = int(os.environ.get("BOOTTEST_HOLD", "0"))
    if hold:
        # Debugging: keep the machine up (SSH on 127.0.0.1:<port>, key in the work dir).
        print(f"  (holding the VM {hold}s: ssh -p {ssh_port} -i {key} freebsd@127.0.0.1)", flush=True)
        time.sleep(hold)
    if qemu.poll() is None:
        qemu.terminate()
        try:
            qemu.wait(30)
        except subprocess.TimeoutExpired:
            qemu.kill()
    shutil.rmtree(sockdir, ignore_errors=True)
    try:
        os.remove(ovl)
    except OSError:
        pass
print("RESULT:", "PASS" if not fails else "FAIL " + ", ".join(fails))
sys.exit(1 if fails else 0)
