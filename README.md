# openstack-ironic-images

给**物理机**用的镜像:从发行版官方安装介质无人值守装出来,验过"控制台契约"才出厂,
交给 Ironic(以及将来 Nova 的裸金属 flavor)。

虚机和 Incus 系统容器的镜像不在这里,在 `openstack-cloud-images`——那条线从
images.linuxcontainers.org 取现成的云盘再补几个包,省事,但只对虚机成立。

## 为什么不从云镜像派生

云镜像的设计前提是**没人能走到机器跟前**:出了问题就删掉实例重建,所以控制台是多余重量。
裸金属的救援通道恰恰只剩显示器、键盘和 BMC 串口。下面是 2026-09-08 在上游
Ubuntu 26.04 云盘(`images.linuxcontainers.org`,构建 `20260907_07:42`)上实测的,不是推断:

| 项目 | 云镜像实测 | 在物理机上的后果 |
| --- | --- | --- |
| 账号密码 | `/etc/shadow` 全是 `!`/`*`,**没有任何账号有密码** | 插上键盘也登不进去,而需要插键盘的场合正是元数据没生效的时候 |
| 串口控制台 | 没有 `console=ttyS*`、没有 `GRUB_TERMINAL`、没有 `serial-getty` | iLO/iDRAC 的 SOL 一片空白 |
| grub 菜单 | `GRUB_TIMEOUT=0` + `hidden` + `quiet splash` | 没有救援项、没有引导信息、没有可以停下来的地方 |
| initramfs | 没有 `ahci`/`smartpqi`/`hpsa`/`megaraid_sas`/`mpt3sas` | 挂不上根,停在 dracut 的 emergency shell |
| 那个 shell 里的键盘 | `hid_generic` 是模块且不在 initramfs 里 | 屏幕上有提示符,但敲不进字 |
| 那个 shell 里的屏幕 | `mgag200`/`ast` 是模块且不在 initramfs 里 | 只剩 UEFI 那块 framebuffer,看运气 |
| 固件 | `/usr/lib/firmware` 一共 16 KB(只有 `regulatory.db`) | `bnx2x`/`qed`/`ice`/`cxgb4`/`tg3`/`qla2xxx` 这些要主机固件的卡全不亮 |

**内核模块本身不缺**:Ubuntu 26.04 的 `linux-modules-<v>-generic` 里有 329 个网卡驱动、
50 多个厂商目录,26.04 起也不再单独编"virtual"内核。缺的是固件、initramfs 里的条目,
和上面那三条控制台设置——**补包补不回控制台**。

而且更根本的一点:硬件厂商太多,谁也没法把所有服务器都测一遍。所以镜像的驱动覆盖面
**不能靠我们自己列的驱动清单**,要靠发行商:安装器装的就是它给物理机的完整包集
(全内核 + 完整 `linux-firmware`)。流水线的 verify 只负责证明这套东西**没有被裁掉**,
不负责枚举它。

## 目录

```
build.sh              统一入口: ./build.sh <images/ 下的目录> [变体] [--layer kubernetes=<版本>]
lib/                  机制: 日志/磁盘/manifest/Glance 上传/重试/qcow2 覆盖层
pipelines/
  distro-iso/         官方安装介质 → 无人值守安装 → (层) → 控制台契约校验 → raw
images/               一份发行版一个目录,里面是声明 + 应答文件(只描述基础 OS)
layers/
  kubernetes/         k8s 节点层: 声明、锁文件、解析与校验脚本(见其 README)
upstream/sources.yaml 安装 ISO 的 URL/sha256/许可
upstream/cache/       ISO 与层的产物缓存(不进仓库)
ci/                   fetch-upstream.sh(ISO)、fetch-layer.sh(层)
tests/                真机验收清单
```

## 两种产物

| 产物 | 名字 | 给谁 |
| --- | --- | --- |
| 基础镜像 | `<发行版>-baremetal` | Ironic 直接部署;Magnum 用它时由 driver **首启装** k8s(nodeBootstrap) |
| 带 k8s 层的镜像 | `<发行版>-baremetal-v<k8s>` | Magnum 裸金属 worker,**预装**了和 VM 节点镜像相同的一套:containerd、crun、gVisor(kvm 平台)、Kata 五个 handler、cni、crictl、kubeadm/kubelet/kubectl、预拉的控制面镜像 |

两者并存,由 Glance 记录里有没有 `k8s_version` 区分:有,driver 不再首启装。层的安装脚本就是
driver 首启装用的那一份(magnum-cluster-api `data/node-bootstrap/install.sh` 的 image 模式,
按 tag + sha256 钉住),所以预装和首启装落下来的文件一样。层的每个字节都记在
`layers/kubernetes/lock/<k8s>/` 里,构建当天不解析、不信任网络。细节见 `layers/kubernetes/README.md`。

## 用法

```bash
ci/fetch-upstream.sh ubuntu-2604-live-server
BAREMETAL_ADMIN_PASSWORD='...' ./build.sh ubuntu-26.04-baremetal
IMAGE_STORE=rbd pipelines/distro-iso/push-to-glance.sh dist ubuntu-26.04-baremetal

# 带 k8s 层(锁文件已在仓库里;缓存要先拉)
sudo ci/fetch-layer.sh kubernetes 1.37.0 ubuntu-26.04-baremetal
BAREMETAL_ADMIN_PASSWORD='...' sudo ./build.sh ubuntu-26.04-baremetal --layer kubernetes=1.37.0
IMAGE_STORE=rbd pipelines/distro-iso/push-to-glance.sh dist ubuntu-26.04-baremetal-v1.37.0
```

**为什么 `IMAGE_STORE=rbd`。** 曾经有一段时间(2026-09-10 当天)这里写的是 `s3`:Metal3 的
baremetal-operator 准入 webhook 只认 http/https/oci,拒 `glance://`,取镜像时也不带任何凭据,
所以镜像得在 Glance 之外再有一个明文 http 地址——rbd 后端给不出(只会产生 `rbd://`),只有 s3 能。

**同日这个理由就不成立了**:给 BMO 打了补丁让它接受 `glance://`(`fivetime/baremetal-operator`,
分支 `build/v0.14.0-glance`,已上线并端到端验过)。BMO 根本不下载镜像,只把 `spec.image.url` 转交
Ironic,而 Ironic 本来就认 Glance 引用。所以裸金属镜像留在 **rbd** 就行:不用推第二份、不用开放匿名读、
不用担心密钥泄露。细节和端到端记录见 `OpenStack-Helm-Deploy.md` §11.1.15。

⚠ 走 `glance://` 时镜像要能被 conductor 读到:Ironic 的 `is_image_available` 对 public/community 直接放行,
对 private 只放行 `image_owner == conductor_project_id`(本集群 conductor 是 `service` 项目 `7e92eb25…`)。
rbd 后端的镜像设成 public 是安全的——`direct_url` 是 `rbd://`,不含任何凭据。

下面这套 s3 + ACL 因此降级成**备选**:BMO 未打补丁时的退路,也是标准 Ironic 用户会走的路。机制完好,
命令照常可用。推完会把该对象——只有该对象,不是整个桶——设成 `public-read`,再用不带凭据的 HEAD 验一遍。
要 `S3_ENDPOINT` / `S3_BUCKET` / `S3_ACCESS_KEY` / `S3_SECRET_KEY`(和 glance-api 用的同一套凭据,取自
`glance-etc` secret 的 `[s3]` 段);没设就只是警告,镜像照样在桶里,但 BMO 取不到。
补设已推镜像的 ACL:`pipelines/distro-iso/publish-s3-acl.sh <image-id>`。机制见 `lib/s3.sh`。

**走 s3 这条路的镜像必须是 private**,`IMAGE_STORE=s3` 配 `VISIBILITY=public` 会被直接拒掉。原因:
s3 后端的 location URI 长这样 `s3://<access-key>:<secret-key>@host/bucket/<image-id>`,
而本集群 `show_image_direct_url = true`(Nova 的 RBD 写时复制克隆要靠它,见
`nova/image/glance.py:283`——`show_multiple_locations` 关着时 Nova 把 `direct_url`
当成唯一的 location)。Glance 的读路径**没有**策略闸拦这个字段
(`glance/api/v2/images.py:1795`,序列化器只是防御性地吞一个没人抛的 Forbidden),
2026-09-10 用临时 reader 账号实测:`direct_url` 原样返回给普通租户。
同时存在 rbd 副本的镜像是安全的——`[s3] weight = 0`,`sort_image_locations` 会挑
`rbd://`,那个不带密钥;但推送流程会删掉 rbd 副本,于是 s3 成了唯一 location。
镜像 private 不影响用途:Metal3 和 Ironic 都是直接从 RGW 走 HTTP 取,不经 Glance。

`BAREMETAL_ADMIN_PASSWORD` 是**本地控制台密码**——cloud-init 没跑成时,趴在机器前面用的那个。
不进仓库,CI 从 secret 注入。`VERIFY_ONLY=1` 只重跑校验,`INSTALL_ONLY=1` 只装不校验,
`KEEP_VM_ON_FAILURE=1` 失败时留着虚机。需要 root(loop 挂载)和 `/dev/kvm`。

细节、九条校验、以及每条为什么存在,见 `pipelines/distro-iso/README.md`。

## 现状

| 镜像 | 安装器 | 状态 |
| --- | --- | --- |
| `ubuntu-26.04-baremetal` | subiquity | CI 构建、九条校验全过、串口登录实测、已推 Glance、**DL360 Gen10 真机验收通过(2026-09-08)** |
| `rocky-10-baremetal` | kickstart | CI 构建、十条校验全过、串口登录实测、已推 Glance、**DL360 Gen10 真机验收通过(2026-09-08,第二版镜像)** |
| `ubuntu-26.04-baremetal-v1.37.0` | 上者 + k8s 层 | 本地构建,12 条基础 + 12 条层校验全过;**Magnum 在 KVM 上(q35 测试记录)建成 1+1 集群 5 分 44 秒,七种 runtimeClassName 全过,控制面镜像零拉取(2026-09-09)**;真机待验 |
| `rocky-10-baremetal-v1.37.0` | 上者 + k8s 层 | 本地构建,12 + 12 条校验全过(2026-09-09);Magnum/真机待验 |
| `ubuntu-26.04-baremetal-v1.36.4` / `rocky-10-baremetal-v1.36.4` | 上者 + k8s 层 | 2026-09-11 加(平台集群是 1.36,Cilium 还不支持 1.37):12 + 12 条校验全过,已推 Glance;Magnum 端到端见下文更新 |

真机验收(Server07 / dl360-sfmk,Ironic `neutron` 接口 + redfish-virtual-media,root 371 GB Smart Array):
Ironic `active`;交换机 Et29/Et30 **`in Po7` a-10G、Po7 `connected` 20G**;机内 bond0 802.3ad 两成员 10G,
四个 VLAN 子接口地址齐、v4/v6 默认路由各一;`bnx2x smartpqi tg3` 在,`/lib/firmware/bnx2x` 6 个 blob,
initramfs 里 ahci/smartpqi/hpsa/megaraid_sas/mpt3sas/hid-generic/mgag200/ast 全在;根分区扩到 367 GB;
SVI、`1.1.1.1`、`2620:fe::fe`、control1 全通;`serial-getty@ttyS1` active,cmdline `console=tty0 console=ttyS1`;
交换机 MAC 表在业务 VLAN 11 看到机器,不是只在 native 17。判据全部来自 `tests/smoke-baremetal.md`。
Rocky 同机同流程(config drive 改用 `network_data.json`,cloud-init 渲染成 NetworkManager):第一版镜像在真机上
暴露了根分区不扩(缺 `cloud-utils-growpart`)和多出一个 `console=ttyS0`(anaconda 抄安装器参数)两个缺陷——
修复后第二版:根 371 GB、cmdline 只剩 `console=tty0 console=ttyS1`、`growpart` 在、bond 两成员 10G、
MAC 出现在 VLAN 11/12/13/15,其余判据与 Ubuntu 一致。
交换机侧之所以能对上,是 neutron 那边同日的改动(NGS 只写聚合口 + trunk 模型),见
`networking-generic-switch` fork 的 `1a9ca37`/`7e01eaa`。

Glance 里两条记录都**不带 `hypervisor_type`**(裸金属给 Ironic 用,带上会被
`ImagePropertiesFilter` 挡在唯一能用它的节点外),属性各取各的声明:
`os_distro=ubuntu/rocky`、`os_version`、`hw_firmware_type=uefi`。

2026-09-08 的实测:

| | Ubuntu 26.04 | Rocky 10.2 |
| --- | --- | --- |
| 无人值守安装耗时 | 863 秒 | 2337 秒(DVD 10 GB,anaconda 比 subiquity 慢一倍多) |
| initramfs | 109 MB / 1334 模块 | 225 MB / 725 模块 |
| 对照:同版本云镜像的 initramfs | 26 MB,HBA 一个没有 | — |
| `/usr/lib/firmware` | 727 MB | 完整 |
| 串口 ttyS1 登录 | ✅ | ✅,**grub 菜单本身也画在串口上**(倒数 5 秒可按键进救援项) |

真机验收另有一份清单:`tests/smoke-baremetal.md`。判据是交换机口协商到 10G,
不是 Ironic 的 provision state——`active` 不证明这台机器有网。

## CI

`.github/workflows/build-baremetal-images.yaml`,手工触发,矩阵从 `images/*/image.yaml` 发现。
需要:**KVM 可用的 self-hosted runner**、约 30 GB 空闲磁盘,以及仓库 secret
`BAREMETAL_ADMIN_PASSWORD`(本地控制台密码);推 Glance 还要 `OS_*` 那组 secret
和 `OS_GATEWAY_VIP` 变量(runner 没有机房 DNS,网关按 Host 头路由,名字必须留在 URL 里并本地播种)。

ISO 缓存是**按镜像决定**的:GitHub 给一个仓库的缓存总量是 10 GB,而 Rocky 的 DVD 单个就 9.6 GB,
缓存它等于每次运行把别的都挤掉、还未必命中;discover 从 `upstream/sources.yaml` 的 `size_bytes`
判断,只缓存小于 5 GB 的。失败时安装期的**串口日志**和截图会作为 artifact 传上来——
串口日志是主要诊断手段,截图只用于"机器根本没来得及说话"的情况。

## 待办
- 在新仓库配 `OS_*` 那组 secret,之后 CI 就能一步到位推 Glance(`push_to_glance=true`);
  现在是从控制节点手工推的(`pipelines/distro-iso/push-to-glance.sh dist [镜像名...]`)。
- DL360 上的真机验收。
- 别的机型:iDRAC/超微是 `ttyS0`,要各自一份声明(见 `pipelines/distro-iso/README.md`)。
