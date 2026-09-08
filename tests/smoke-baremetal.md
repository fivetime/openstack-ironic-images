# 裸金属镜像验收清单

**`active` 不证明这台机器有网。** 云镜像缺网卡固件时,机器 POST 正常、从盘启动、Ironic 一切绿,
交换机上却是成员口 `notconnect`、只剩 1G 辅助供电。所以验收从交换机看起,不从 Ironic 看起。

按顺序做,任何一步不过就停下来查,别继续往下走。

## 1. 交换机(最先看,判据最硬)

```
show interfaces status | include Et<成员口>|Po<号>
show port-channel <号> detailed
show mac address-table interface Port-Channel<号>
```

- 两个成员口都要 `connected` 且协商到 **a-10G**。只有一个口是 1G、另一个 `notconnect`,
  说明系统没起来或者网卡固件缺失(关机时 533FLR-T 的 port2 靠辅助供电亮 1G,很像"有链路")。
- 做了 bond 的话 Po 要 `connected`、带宽 20G,两成员 `LACP Active`;
  停在 `in LACP fallback individual mode` 说明系统侧没有起 LACP。
- MAC 表里要能看到机器 MAC 出现在**业务 VLAN**,只出现在 native VLAN 说明子接口没配起来。

## 2. 网络可达

- `ping` 交付地址的 v4 和 v6。
- 机器内 ping 交换机 SVI、公网(`1.1.1.1` / `2620:fe::fe`)、以及集群里一台已知主机。
- **交换机自己 ping 机器不算数**:SVI 在不在同一子网决定它走路由还是 ARP,结果不可比。

## 3. 系统内

- `ip -br a`:bond 和各 VLAN 子接口地址齐全。
- 默认路由只有预期的那一条;IPv6 尤其要检查有没有被 RA 塞进多余的 `::/0`。
- `lsmod | grep -E 'bnx2x|hpsa|smartpqi|tg3'`:接线网卡和 RAID 控制器的驱动都在。
- `lsinitrd /boot/initr*-$(uname -r)* | grep -E '/(ahci|smartpqi|hpsa|megaraid_sas|mpt3sas)\.ko'`
  (Debian 系叫 `initrd.img-<ver>`,RPM 系叫 `initramfs-<ver>.img`):
  存储驱动在 initramfs 里。这些全是模块(virtio 才是编进内核的),initramfs 里没有就根本进不到这一步——
  机器会停在 dracut 的 emergency shell,构建流水线已经在出厂前断言过一次。
  注意有的驱动是**编进内核**的(例如 Rocky 的 `hid_generic`/`usb_hid`),那样 initramfs 里就没有
  对应的 `.ko`,要去 `/boot/config-$(uname -r)` 里看 `=y`——"不在 initramfs 里"不等于"不可用"。
- `ls /lib/firmware/bnx2x/` 非空。
- 根分区已扩到整盘。
- `cloud-init status` 为 `done`,`/var/log/cloud-init.log` 无 ERROR。

## 4. 常见误判

| 现象 | 先查 | 不要先查 |
| --- | --- | --- |
| Ironic `active` 但机器不通 | 交换机口速率 | Ironic 日志 |
| 只有一个口 1G | 系统是否真的起来了 | 交换机配置 |
| 部署"成功"但盘没动 | `--deploy-interface` 是否显式 direct | 硬件 |
| 停在 dracut/initramfs 提示符 | initramfs 里有没有这台机器的 HBA 驱动 | 分区表、镜像内容 |
| 报镜像找不到 | token 是不是 system scope | Glance |
