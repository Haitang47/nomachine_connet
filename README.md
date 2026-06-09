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
chmod +x orin-one-time-setup.sh orin-auto-wifi.sh

sudo env IOTSWARM_SSID='iotswarm_5G' IOTSWARM_PSK='Sensornetwork' \
  IOTLAB_SSID='IoTLab_5G' IOTLAB_PSK='Sensornetwork1!' \
  ./orin-one-time-setup.sh
```

新版脚本会自动关闭其他 WiFi 的 autoconnect，避免开机连回 `53XXX`。
如果开机太早没扫到目标 WiFi，服务会自动重试。
开机选中一个 WiFi 后，本次开机会锁定它，不会因另一个 WiFi 信号变强而主动切过去。

检查：

```bash
hostname
systemctl is-enabled orin-auto-wifi.service
```

期望结果：

```text
onboard-nx
enabled
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

手动打开 NoMachine 时，Host 优先填：

```text
onboard-nx.local
```

如果不行：

```bash
./nomachine-wifi.sh scan
```

然后按当前 WiFi 填：

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

Orin：

```bash
nmcli -t -f NAME,TYPE connection show --active
nmcli dev wifi list | grep -E 'iotswarm|IoTLab'
systemctl is-enabled orin-auto-wifi.service
journalctl -u orin-auto-wifi.service -b --no-pager
sudo systemctl enable --now nxserver
```

`orin-auto-wifi.service` 显示 `inactive (dead)` 是正常的，它是开机运行一次。

## 4. 不重启切换房间

在 Orin 上运行，自动重新选择当前更强的 WiFi：

```bash
sudo systemctl restart orin-auto-wifi.service
journalctl -u orin-auto-wifi.service -b --no-pager | tail -30
nmcli -t -f NAME,TYPE connection show --active
```

强制切到 `iotswarm_5G`：

```bash
sudo nmcli connection modify iotswarm_5G connection.autoconnect yes
sudo nmcli connection modify IoTLab_5G connection.autoconnect no
sudo nmcli connection down IoTLab_5G
sudo nmcli connection up iotswarm_5G
```

强制切到 `IoTLab_5G`：

```bash
sudo nmcli connection modify IoTLab_5G connection.autoconnect yes
sudo nmcli connection modify iotswarm_5G connection.autoconnect no
sudo nmcli connection down iotswarm_5G
sudo nmcli connection up IoTLab_5G
```

切完后，笔记本也连同一个 WiFi，再运行：

```bash
cd /home/jht/nomachine
./nomachine-wifi.sh connect
```
