# NoMachine 双 WiFi 快速操作

WiFi 名字按你的实际情况写成：

```text
iotswarm_5g
IoTLab_5g
```

## 1. 在 Orin 上做一次

外接显示屏进入 Orin，把这两个文件放到同一个目录：

```text
orin-one-time-setup.sh
orin-auto-wifi.sh
```

假设目录是：

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

运行一次性配置：

```bash
chmod +x orin-one-time-setup.sh orin-auto-wifi.sh

sudo env IOTSWARM_SSID='iotswarm_5g' IOTSWARM_PSK='Sensornetwork' \
  IOTLAB_SSID='IoTLab_5g' IOTLAB_PSK='Sensornetwork1!' \
  ./orin-one-time-setup.sh
```

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
iotswarm_5g -> 192.168.230.x
IoTLab_5g   -> 192.168.220.x
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
systemctl is-enabled orin-auto-wifi.service
journalctl -u orin-auto-wifi.service -b --no-pager
sudo systemctl enable --now nxserver
```

`orin-auto-wifi.service` 显示 `inactive (dead)` 是正常的，它是开机运行一次。
