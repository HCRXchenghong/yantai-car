# 烟台car-go 手机端

Flutter 控制端，用于连接 ESP32 创建的 `Yantai-Car` Wi-Fi 热点。

## 功能

- WebSocket 建立控制会话；UDP 每 50 ms 发送最新左右轮指令并接收 ACK。
- 摇杆差速控制、实时 RTT 延迟、500 ms 固件失联急停。
- 单独左右电机方向校准，设置保存在手机本地。
- 针对当前车架的摇杆坐标校准：屏幕上/下/左/右对应前进/后退/左转/右转。

## 运行

```bash
flutter pub get
flutter run
```

在手机 Wi-Fi 中加入 `Yantai-Car` 后，使用默认地址 `192.168.4.1` 连接。完整接线、固件烧录和协议说明见仓库根目录 [README](../README.md)。
