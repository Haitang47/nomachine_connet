# NoMachine 双 WiFi 快速操作

WiFi 名字按实际情况写成：

```text
iotswarm_5G
IoTLab_5G
```

## 1. 在 Orin 上做一次

外接显示屏进入 Orin，把这两个文件放到同一个目录：

```text
orin-one-time-setup.sh
orin-auto-wifi.sh
orin-switch-wifi.sh
orin-cleanup.sh
```

假设目录是：nomachine_connet-main

```bash
cd ~/nomachine_connet-main
```

清理重复 WiFi 连接：

```bash
nmcli -f NAME,UUID,TYPE,AUTOCONNECT connection show | grep -E 'iotswarm|IoTLab'
```

如果同一个 WiFi 出现两行，删掉多余那行的 UUID：

```bash
sudo nmcli connection delete UUID
```

关掉不想自动连接的旧 WiFi，例如 `53XXX`：

```bash
sudo nmcli connection modify '53XXX' connection.autoconnect no
```

运行一次性配置：

```bash
chmod +x orin-one-time-setup.sh orin-auto-wifi.sh orin-switch-wifi.sh orin-cleanup.sh

sudo env IOTSWARM_SSID='iotswarm_5G' IOTSWARM_PSK='Sensornetwork' \
  IOTLAB_SSID='IoTLab_5G' IOTLAB_PSK='Sensornetwork1!' \
  ./orin-one-time-setup.sh
```

新版脚本会自动关闭其他 WiFi 的 autoconnect，避免开机连回 `53XXX`。
如果开机太早没扫到目标 WiFi，服务会自动重试。
默认开机目标是 `auto`，会在两个 WiFi 里选可见的；手动设置目标后就不再按信号强弱猜。

检查：

```bash
hostname
systemctl is-enabled orin-auto-wifi.service
cat /etc/orin-wifi-target
```

期望结果：

```text
onboard-nx
enabled
auto
```

重启：

```bash
sudo reboot
```

以后 Orin 断电重启后不用再跑脚本。

## 2. 在笔记本连接

笔记本连当前房间 WiFi 后运行：

```bash
cd /home/jht/nomachine
./nomachine-wifi.sh status
./nomachine-wifi.sh probe
./nomachine-wifi.sh connect
```

`connect` 会重试几次；如果失败，先看它提示的 `onboard-nx.local resolves to ...` 是不是当前 WiFi 网段。

手动打开 NoMachine 时，Host 优先填：

```text
onboard-nx.local
```

如果不行：

```bash
./nomachine-wifi.sh scan
```

脚本默认只自动连：

```text
onboard-nx.local
```

扫描出来的 IP 只能人工确认后手动填 NoMachine，不要随便写进配置，否则可能连到别人电脑。

按当前 WiFi 判断 IP 范围：

```text
iotswarm_5G -> 192.168.230.x
IoTLab_5G   -> 192.168.50.x
```

不要填带 `(this computer)` 的地址。

## 3. 连不上时查

笔记本：

```bash
cd /home/jht/nomachine
./nomachine-wifi.sh status
ping onboard-nx.local
./nomachine-wifi.sh scan
```

`probe` 会显示 `onboard-nx.local` 解析到的 IP。正常应该是：

```text
iotswarm_5G -> 192.168.230.x
IoTLab_5G   -> 192.168.50.x
```

如果显示 `192.168.1.50`，说明 Orin 把雷达/有线网口地址广播出来了，重新跑第 1 步的 `orin-one-time-setup.sh`。

Orin：

```bash
nmcli -t -f NAME,TYPE connection show --active
nmcli dev wifi list | grep -E 'iotswarm|IoTLab'
iw dev wlan0 get power_save
ip route
systemctl is-enabled orin-auto-wifi.service
journalctl -u orin-auto-wifi.service -b --no-pager
sudo systemctl enable --now nxserver
```

如果一开始能连、过一会 NoMachine 超时，重新跑第 1 步的 `orin-one-time-setup.sh`。新版会关闭 Orin 这两个 WiFi 配置的省电模式。

如果 `probe` 一开始 `open`、几秒后变 `closed`，去 Orin 查：

```bash
sudo systemctl status nxserver --no-pager
iw dev wlan0 get power_save
nmcli -t -f NAME,TYPE connection show --active
ip -br addr
```

`orin-auto-wifi.service` 显示 `inactive (dead)` 是正常的，它是开机运行一次。

## 4. 不重启切换房间

远程控制 Orin 时，切 Orin 的 WiFi 会断开当前 NoMachine。正确流程是：先让 Orin 切目标 WiFi，再把笔记本切到同一个 WiFi 后重连。

只设置下次重启优先连 `IoTLab_5G`，不马上断开：

```bash
sudo orin-switch-wifi target iotlab
cat /etc/orin-wifi-target
```

期望：

```text
IoTLab_5G
```

切到 `iotswarm_5G`：

```bash
sudo orin-switch-wifi iotswarm
```

切到 `IoTLab_5G`：

```bash
sudo orin-switch-wifi iotlab
```

这条命令会马上切 WiFi，也会把下次重启目标写成 `IoTLab_5G`。

如果还没重新跑安装脚本，也可以在脚本目录运行：

```bash
sudo ./orin-switch-wifi.sh iotlab
```

执行后当前 NoMachine 会断开。然后笔记本连目标 WiFi，再运行：

切换成功后，脚本会把另一个 WiFi 设为 `autoconnect no`，并显式 `down` 掉，避免串连。

```bash
cd /home/jht/nomachine
./nomachine-wifi.sh connect
```

## 5. 停用、清理和重新启用

如果不再使用这套 NoMachine WiFi 配置，在 Orin 上执行：

```bash
cd ~/nomachine_connet-main
sudo ./orin-cleanup.sh
```

一次性配置完成后，也可以在任意目录执行：

```bash
sudo orin-wifi-cleanup
```

清理操作会：

- 停止并删除本项目安装的开机 WiFi 服务和辅助脚本；
- 删除 `iotswarm_5G` / `IoTLab_5G` WiFi 配置；
- 恢复首次配置前保存的主机名、Avahi 设置以及 Avahi/NoMachine 服务启用状态；
- 重新允许其余 WiFi 自动连接，并重新打开 WiFi 网络功能。

如需保留两条实验室 WiFi 配置，执行：

```bash
sudo env REMOVE_WIFI_PROFILES=no ./orin-cleanup.sh
```

如需按首次配置前记录的值恢复 WiFi 的自动连接开关、而不把所有剩余 WiFi 都设为自动连接，执行：

```bash
sudo env REENABLE_WIFI_AUTOCONNECT=no ./orin-cleanup.sh
```

以后需要重新启用时，只需重新运行第 1 步的 `orin-one-time-setup.sh`。每次重新启用都会重新保存一份可用于下次清理的恢复记录。

如果 Orin 之前已经运行过旧版本脚本，旧版本没有保存原主机名和服务状态；首次执行新版清理时，WiFi 配置和本项目服务仍会被清理并恢复 WiFi 自动连接，但原主机名无法自动推断。重新运行一次新版的一次性配置后，之后的清理即可完整恢复这些状态。

## 6. `probe` 显示有线雷达地址（例如 `192.168.1.50`）

这不是 WiFi 路由优先级问题，而是 `onboard-nx.local` 被全局 DNS/mDNS 缓存或有线接口的 mDNS 记录解析到了。新版会在一次性配置时自动识别实际 WiFi 网卡，只允许 Avahi 在该网卡发布，并关闭 mDNS 跨接口转发；有线雷达仍保持可用，不会被禁用。

更新脚本后，在 Orin 上重新运行一次第 1 步的一次性配置。然后检查：

```bash
grep -E '^(allow-interfaces|enable-reflector)=' /etc/avahi/avahi-daemon.conf
nmcli -t -f DEVICE,TYPE device status
```

应看到 `allow-interfaces=` 后是 WiFi 网卡名（通常为 `wlan0`），以及 `enable-reflector=no`。笔记本端的新版 `probe` 会优先通过当前 WiFi 网卡查询 mDNS；即使系统仍返回有线地址，它也只会对当前 WiFi 同网段的地址建立 NoMachine 连接。

如果笔记本没有 `avahi-resolve-host-name`，建议安装 `avahi-utils`；脚本没有该工具时仍会拒绝连接到不同网段的地址：

```bash
sudo apt-get install -y avahi-utils
```
