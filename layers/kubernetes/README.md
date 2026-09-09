# layers/kubernetes — 裸金属镜像上的 k8s 节点层

把 `openstack-magnum-images` 放进 VM 节点镜像的那套东西——containerd、crun 默认 handler、
gVisor、Kata 4.1.0 的五个 handler、cni-plugins、crictl、kubeadm/kubelet/kubectl、内核参数、
预拉的控制面镜像——写进一张已经装好的裸金属镜像里。产物是 `<基础镜像>-v<k8s 版本>`,
基础镜像照旧保留。

## 和首启装是同一份脚本

这一层**没有自己的安装器**。Magnum 驱动在普通镜像上首启装 k8s 用的脚本
(magnum-cluster-api `data/node-bootstrap/install.sh`)有一个 image 模式:在 chroot 里写同样的
文件,不碰构建机的内核(不 modprobe、不 sysctl、不 remount /dev/shm、不起服务)。这里跑的就是它,
按 tag + sha256 钉在 `layer.yaml`。所以一台预装镜像的裸金属和一台首启装的裸金属,落下来的文件一样;
两份实现迟早漂移,这是不再写第三份的理由。

## 锁文件:构建当天不解析任何东西

```
layer.yaml                  层声明:脚本来源与校验和、runtimes、gvisor 平台、发行版包名、Glance 属性
resolve.sh <k8s>            解析 → lock/<k8s>/artifacts.yaml + images.yaml(顺便把产物拉进缓存)
resolve-packages.sh <k8s> <image>
                            在基础镜像的 chroot 里问 apt/dnf → lock/<k8s>/packages-<image>.yaml
verify.sh <rootfs> <k8s>    离线校验,读镜像、对锁,输出 manifest 字段
lock/<k8s>/                 生成物,进仓库
```

`artifacts.yaml` 里每一项都是上游 URL 去掉 scheme 的路径 + sha256;缓存目录
`upstream/cache/layers/kubernetes/<k8s>/mirror/` 按同样的路径摆放,于是脚本自己的 URL 拼接在
`NODE_BOOTSTRAP_MIRROR=file:///run/layer/mirror` 下原样命中,脚本一行不用改。上游发布了校验文件的
(dl.k8s.io、containerd、runc、cni、cri-tools、gvisor)解析时对过再记;没有的(crun、kata)记下
当天拉到的 sha256——这仍然能把"URL 换了字节"变成构建失败。

组件版本默认取钉住的那份脚本自己的默认值(和首启装一致),要故意偏离就给 `resolve.sh` 传环境变量,
锁会记下来。控制面镜像列表问 kubeadm 本人(`kubeadm config images list`),pause 镜像问 containerd 本人
(`containerd config default`),digest 从 registry 的 manifest 接口拿(registry.k8s.io 一律 307,要跟跳转)。

发行版包按基础镜像各算各的:Ubuntu live-server ISO 的 pool 只有 186 个包,conntrack/socat/zstd 一个
都没有,所以 `--print-uris` 从 archive 拿 URL 和哈希(现在 apt 给的是 SHA512,解析时下载核对后记 sha256);
Rocky DVD 什么都有,`dnf download --resolve` 只对着 DVD 解,锁里记的是 ISO 内路径,构建机不联网也能取。

## 构建时怎么进镜像

`pipelines/distro-iso/build.sh` 的 `layer` 阶段:把基础 raw 稀疏复制一份,loop 挂载,绑定 /proc /sys /dev,
把缓存目录只读绑定到镜像的 `/run/layer`,然后 **`unshare -n` 断网**进 chroot 跑脚本。镜像里没有的东西
就拿不到,锁没记的就进不来。跑完清掉 `/run/layer`、临时 containerd 的目录和导入日志——verify 会检查
这些痕迹不在。

预拉镜像的办法:脚本在 chroot 里把 containerd 当普通进程起来,`ctr -n k8s.io images import` 七个 OCI
归档,再停掉。归档由 `ci/fetch-layer.sh` 用锁里那份 containerd 二进制临时起一个进程拉取——不依赖
构建机上有 containerd(控制节点跑的是 cri-o)。拉的时候把 tag 挪到 linux/amd64 那一个 manifest 上再导出:
直接导出 index 会去找没拉的架构和 provenance attestation 的 blob 而失败,而只导出 `name@sha256` 又会丢掉
kubelet 要找的 tag 名。

## 校验(11 条,读镜像、对锁)

kubeadm/kubelet/kubectl 版本;containerd/runc/crun/crictl 版本;containerd **自己渲染**的 handler 集合
(drop-in 有错字会被静默忽略,所以不看文件看渲染结果);默认 handler 真的执行 crun;gvisor 二进制、版本
与平台;kata 两个 shim 与两个 tarball 的 sha256、`/dev/shm` 的 fstab 与 private 单元;七个控制面镜像的
index digest 在 content store 里;两个单元 enabled;modules-load/sysctl/cni;conntrack/socat/ethtool;
没有构建残留。manifest 里的 `k8s_version`、`kata_handlers`、`gvisor_platform`、`images_preloaded` 等
字段由这一步**读回**填入,推 Glance 时按 `layer.yaml` 的 `properties_from_manifest` 打成属性。

## gVisor 平台

VM 节点镜像用 systrap(不依赖嵌套虚拟化);物理机有真 KVM,这里用 `kvm`(`layer.yaml` 一个字段,
verify 从 `/etc/containerd/runsc.toml` 读回钉住)。

## 用法

```bash
layers/kubernetes/resolve.sh 1.37.0                            # 一次,联网,写 lock/1.37.0/{artifacts,images}.yaml
sudo layers/kubernetes/resolve-packages.sh 1.37.0 ubuntu-26.04-baremetal   # 每个基础镜像一次
sudo layers/kubernetes/resolve-packages.sh 1.37.0 rocky-10-baremetal
sudo ci/fetch-layer.sh kubernetes 1.37.0 ubuntu-26.04-baremetal rocky-10-baremetal
BAREMETAL_ADMIN_PASSWORD='...' sudo ./build.sh ubuntu-26.04-baremetal --layer kubernetes=1.37.0
```

基础 raw 已在 `dist/` 时直接复用,否则先装基础再叠层。CI 的 `k8s_versions` 输入按版本各加一行矩阵。

## 在 KVM 上验证一张裸金属镜像(Nova 门禁的前提)

真正的消费方是 Ironic + Magnum 裸金属 nodegroup,但一张带层的镜像想先在虚机上开一次,
要过三关,每一关都是 2026-09-09 实测踩出来的:

1. **串口**:镜像的 grub/getty 在 `ttyS1`(HPE iLO),Nova 虚机只有 `ttyS0`,grub 找不到
   `serial --unit=1` 会停在菜单,控制台也一片空白。测试副本要把 `99-baremetal.cfg` 里的
   `ttyS1`/`--unit=1` 改成 `ttyS0`/`--unit=0` 再 `update-grub`(或直接建一份 ttyS0 变体)。
2. **config drive**:镜像的 cloud-init 只认 `[ConfigDrive, NoCloud, None]`,不找 metadata 服务,
   所以 Glance 记录要 `img_config_drive=mandatory`。而且要 **`hw_machine_type=q35`**:计算节点是
   QEMU 8.2,默认 i440fx 挂的 IDE 光驱这台 7.0 内核根本探测不到(`ata_piix` 找不到 ATAPI 设备,
   6.8 内核的云镜像同机能看到),q35 的 SATA 光驱才行。
3. **调度**:`hypervisor_type=qemu` 才会落到 KVM 节点(生产记录刻意不带,见 push-to-glance.sh)。

加上 `k8s_version=<版本>`,Magnum driver 就会跳过 nodeBootstrap,直接用镜像里的栈。
