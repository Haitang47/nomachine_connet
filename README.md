# NoMachine 双 WiFi 操作步骤

目标：你带着笔记本在两个房间切换时，不再每次给 Orin 接显示屏确认 WiFi、IP 或 hostname。

## A. 第一次配置 Orin

这一步只需要做一次。前提是你现在能进入 Orin：

- 可以临时接显示屏键盘。
- 或者现在还能 SSH 到 Orin。
- 或者用 U 盘把这个目录拷到 Orin 上。

### 1. 把脚本放到 Orin 上

如果当前还能 SSH 到 Orin，在笔记本运行：

```bash
scp /home/jht/nomachine/orin-one-time-setup.sh \
  /home/jht/nomachine/orin-auto-wifi.sh \
  nv@ORIN当前IP:~/
```

把 `ORIN当前IP` 换成你现在能连上的 Orin IP。

如果不能 SSH，就临时接显示屏，把这两个文件拷到 Orin 的 home 目录：

```text
orin-one-time-setup.sh
orin-auto-wifi.sh
```

### 2. 在 Orin 上运行配置

在 Orin 终端运行：

```bash
chmod +x ~/orin-one-time-setup.sh ~/orin-auto-wifi.sh
sudo env IOTSWARM_SSID='iotswarm(5g)' IOTSWARM_PSK='iotswarm的密码' \
  IOTLAB_SSID='IoTLab(5g)' IOTLAB_PSK='IoTLab的密码' \
  ~/orin-one-time-setup.sh
```

如果你的 WiFi 实际名字不是括号版本，而是下划线版本，就改成：

```bash
sudo env IOTSWARM_SSID='iotswarm_5G' IOTSWARM_PSK='iotswarm的密码' \
  IOTLAB_SSID='IoTLab_5G' IOTLAB_PSK='IoTLab的密码' \
  ~/orin-one-time-setup.sh
```

### 3. 重启 Orin

```bash
sudo reboot
```

重启后，Orin 会保存两个 WiFi，并尽量自动连当前能看到的 WiFi。Orin 的统一 hostname 会被设置成：

```text
onboard-nx
```

所以笔记本上优先用：

```text
onboard-nx.local
```

### 4. 断电重启后还要不要再跑脚本

不用。

`orin-one-time-setup.sh` 是一次性配置脚本。它会把 WiFi、hostname、NoMachine/avahi 服务配置写进系统，断电重启后仍然有效。

它还会安装一个开机服务：

```bash
systemctl status orin-auto-wifi.service
```

这个服务会在 Orin 每次开机后运行一次，扫描 `iotswarm` 和 `IoTLab`，然后连接当前能看到且信号更强的那个 WiFi。

## B. 平时用脚本连接 NoMachine

在笔记本上操作。

### 1. 进入目录

```bash
cd /home/jht/nomachine
```

### 2. 看当前笔记本在哪个 WiFi

```bash
./nomachine-wifi.sh status
```

你会看到类似：

```text
WiFi connection: iotswarm_5G
WiFi IPv4:       192.168.230.18
Matched profile: iotswarm
```

### 3. 探测 Orin 是否可达

```bash
./nomachine-wifi.sh probe
```

如果看到某个地址是 `open`，说明 NoMachine server 可达。

### 4. 自动打开 NoMachine

```bash
./nomachine-wifi.sh connect
```

脚本会按当前 WiFi 自动选择：

| 笔记本当前 WiFi | 脚本使用的候选地址 |
| --- | --- |
| `iotswarm_5G` / `iotswarm(5g)` | `onboard-nx.local`，然后 `192.168.230.x` |
| `IoTLab_5G` / `IoTLab(5g)` | `onboard-nx.local`，然后 `192.168.220.x` |

## C. 手动打开 NoMachine 连接

如果你不想用脚本，也可以手动打开 NoMachine。

### 1. 新建连接

NoMachine 里选择：

```text
Protocol: NX
Host: onboard-nx.local
Port: 默认
User: Orin 的系统用户名
Password: Orin 的系统密码
```

### 2. 如果 `onboard-nx.local` 连不上

按当前 WiFi 改 Host：

| 笔记本当前 WiFi | 手动 Host 备选 |
| --- | --- |
| `iotswarm_5G` / `iotswarm(5g)` | `192.168.230.x` |
| `IoTLab_5G` / `IoTLab(5g)` | `192.168.220.x` |

如果不知道 `x` 是多少，在笔记本运行：

```bash
cd /home/jht/nomachine
./nomachine-wifi.sh scan
```

输出里带 `(this computer)` 的是笔记本自己，不要填那个。

## D. 如果连不上，按这个顺序查

### 1. 笔记本是否连对 WiFi

```bash
./nomachine-wifi.sh status
```

确认 `Matched profile` 是你所在房间对应的 WiFi。

### 2. Orin 是否在同一个网络

先试：

```bash
ping onboard-nx.local
```

如果不通，扫当前网段：

```bash
./nomachine-wifi.sh scan
```

如果扫不到 Orin，说明 Orin 可能连到了另一个 WiFi。

### 3. Orin 可能连到了上一次的 WiFi

这种情况下，笔记本脚本无法远程切换 Orin 的 WiFi。处理办法：

1. 临时接显示屏或网线进 Orin。
2. 确认 Orin 已经跑过 `orin-one-time-setup.sh`。
3. 确认两个 WiFi 的 SSID 和密码写对。
4. 确认开机自动选 WiFi 服务已启用：

```bash
systemctl status orin-auto-wifi.service
systemctl is-enabled orin-auto-wifi.service
```

5. 重启 Orin 再试。

### 4. NoMachine server 是否启动

进入 Orin 后运行：

```bash
sudo systemctl status nxserver
sudo systemctl enable --now nxserver
```

## E. 需要改 IP 时

如果 Orin 在某个 WiFi 下 IP 变了，改笔记本上的配置文件：

```bash
gedit /home/jht/nomachine/nomachine-wifi.conf
```

把对应 WiFi 那一行的 IP 换成新的：

```text
iotswarm|...|onboard-nx.local 192.168.230.67|...
iotlab|...|onboard-nx.local 192.168.220.201|...
```

最稳的办法是在两个路由器上给 Orin 做 DHCP 地址保留，让它每次都拿固定 IP。

## F. 更省心的方案

如果可以安装 Tailscale，推荐在 Orin 上也安装并登录同一个账号。

之后 NoMachine 直接连接 Orin 的 Tailscale IP 或 MagicDNS 名字，不再管 Orin 当前连的是 `iotswarm` 还是 `IoTLab`。
# nomachine_connet
