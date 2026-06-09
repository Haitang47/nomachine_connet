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
chmod +x orin-one-time-setup.sh orin-auto-wifi.sh orin-switch-wifi.sh

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
