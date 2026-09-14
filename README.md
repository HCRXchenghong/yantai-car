# 烟台 car-go：ESP32 双路 PWM 差速小车

手机通过 ESP32 建立的 Wi-Fi 热点控制差速小车。控制会话使用 WebSocket，方向指令使用 UDP，因此每个 50 ms 周期只发送最新状态；固件会返回 ACK 供 App 显示 RTT 延迟，并在 500 ms 没有控制包时自动停车。

> 当前实物板已确认是经典 ESP32-D0WD-V3，而不是 ESP32-S3。仓库仍提供 ESP32-S3 的 PlatformIO 环境，供更换板子时使用。

## 目录

```text
firmware/                 ESP32 Arduino / PlatformIO 固件
  esp32s3_car.ino         主程序（名称沿用，兼容经典 ESP32 和 S3）
  config.example.h        可公开的配置模板
  config.h                本机私有配置，包含实际 Wi-Fi 密码，不提交 Git
mobile_app/               Flutter Android / iOS 控制端（显示名：烟台car-go）
```

## 接线

| ESP32 | 车控板 | 说明 |
|---|---|---|
| GPIO4 | 左电机 PWM 输入 | 默认左路 |
| GPIO5 | 右电机 PWM 输入 | 默认右路 |
| GND | GND | 必须共地 |

PWM 是 50 Hz RC/舵机式信号：1000 µs 为反转、1500 µs 为停止、2000 µs 为正转。ESP32 只能输出 3.3 V 逻辑；车控板若要求 5 V 输入，请使用电平转换，不能把 5 V 接到 ESP32 GPIO。

## 配置与烧录固件

先创建本机配置。这个文件不进 Git，避免把热点密码公开到 GitHub：

```bash
cp firmware/config.example.h firmware/config.h
```

在 `firmware/config.h` 中设置 GPIO、Wi-Fi 密码、PWM 中位值和必要的单路反向。当前实车默认使用 GPIO4（左）和 GPIO5（右）。

### Arduino IDE

安装 ESP32 开发板支持及下列库：

- ESP32Servo
- WebSockets（Links2004）
- ArduinoJson

将 `firmware/esp32s3_car.ino` 与本机 `firmware/config.h` 放在同一个 Arduino 草图目录中，选择 **ESP32 Dev Module**。本机已知稳定上传速率为 **115200**。

### PlatformIO

```bash
cd firmware
pio run -e esp32dev
pio run -e esp32dev --target upload
pio device monitor
```

ESP32-S3 使用 `esp32-s3-devkitc-1` 环境。

上电后，串口会显示热点与控制端口。默认 App 地址为 `192.168.4.1`，WebSocket 端口 `81`，UDP 控制端口 `4210`。

## 手机端

1. 手机连接小车 Wi-Fi 热点。
2. 打开 `烟台car-go`，连接 `192.168.4.1`。
3. 控制页中，上/下/左/右为前进/后退/左转/右转，松手自动回中。
4. 首次测试请将车轮架空；在右上角“电机校准”中单独测试每个电机。只有该轮物理方向相反时，才切换那一侧的反向开关。

构建 App：

```bash
cd mobile_app
flutter pub get
flutter test
flutter build apk --debug
```

输出文件为 `mobile_app/build/app/outputs/flutter-apk/app-debug.apk`。

## 控制协议

App 每 50 ms 发送一条 UDP JSON 控制消息：

```json
{"type":"control","seq":12,"clientMs":123456,"left":0.5,"right":0.5}
```

`left` 和 `right` 均为 `-1.0` 至 `1.0`。ESP32 回复：

```json
{"type":"ack","seq":12,"serverMs":123500,"leftUs":1750,"rightUs":1750}
```

WebSocket 负责连接建立和备用控制路径；UDP 无需等待前一包确认。偶发丢包只会丢失过期状态，下一包立即覆盖，固件超时保护会在链路中断时停止小车。

## 安全说明

- 新 WebSocket 客户端接入及客户端断开时，固件立即输出 1500 µs。
- 同时只允许一个手机控制。
- 500 ms 未收到有效控制包，自动停车。
- 请先架空车轮、限流供电，再上路测试。
