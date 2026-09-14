#include <Arduino.h>
#include <ArduinoJson.h>
#include <ESP32Servo.h>
#include <WebSocketsServer.h>
#include <WiFi.h>
#include <WiFiUdp.h>

#include "config.h"

Servo leftPwm;
Servo rightPwm;
WebSocketsServer webSocket(WEBSOCKET_PORT);
WiFiUDP controlUdp;

uint8_t activeClient = 255;
uint32_t lastCommandAt = 0;
int currentLeftUs = PWM_NEUTRAL_US;
int currentRightUs = PWM_NEUTRAL_US;

IPAddress apIp(WIFI_IP_OCTET_1, WIFI_IP_OCTET_2, WIFI_IP_OCTET_3, WIFI_IP_OCTET_4);
IPAddress apGateway(WIFI_IP_OCTET_1, WIFI_IP_OCTET_2, WIFI_IP_OCTET_3, WIFI_IP_OCTET_4);
IPAddress apSubnet(255, 255, 255, 0);

int clampPulse(int pulse) {
  return constrain(pulse, PWM_MIN_US, PWM_MAX_US);
}

int valueToPulse(float value, bool inverted) {
  value = constrain(value, -1.0f, 1.0f);
  if (inverted) {
    value = -value;
  }

  const float pulse = static_cast<float>(PWM_NEUTRAL_US) +
                      value * static_cast<float>(PWM_MAX_US - PWM_NEUTRAL_US);
  return clampPulse(static_cast<int>(lroundf(pulse)));
}

void writeOutputs(int leftUs, int rightUs) {
  currentLeftUs = clampPulse(leftUs);
  currentRightUs = clampPulse(rightUs);
  leftPwm.writeMicroseconds(currentLeftUs);
  rightPwm.writeMicroseconds(currentRightUs);
}

void stopCar() {
  writeOutputs(PWM_NEUTRAL_US, PWM_NEUTRAL_US);
}

void sendHello(uint8_t clientId) {
  JsonDocument message;
  message["type"] = "hello";
  message["protocol"] = 1;
  message["pwmHz"] = PWM_FREQUENCY_HZ;
  message["neutralUs"] = PWM_NEUTRAL_US;
  message["udpPort"] = CONTROL_UDP_PORT;
  message["ip"] = WiFi.softAPIP().toString();

  String payload;
  serializeJson(message, payload);
  webSocket.sendTXT(clientId, payload);
}

void sendAck(uint8_t clientId, int32_t sequence) {
  JsonDocument message;
  message["type"] = "ack";
  message["seq"] = sequence;
  message["serverMs"] = millis();
  message["leftUs"] = currentLeftUs;
  message["rightUs"] = currentRightUs;

  String payload;
  serializeJson(message, payload);
  webSocket.sendTXT(clientId, payload);
}

bool applyControl(uint8_t *payload, size_t length, int32_t &sequence) {
  JsonDocument message;
  const DeserializationError error = deserializeJson(message, payload, length);
  if (error) {
    return false;
  }

  const char *type = message["type"] | "";
  if (strcmp(type, "control") != 0) {
    return false;
  }

  const float left = message["left"] | 0.0f;
  const float right = message["right"] | 0.0f;
  sequence = message["seq"] | -1;

  writeOutputs(valueToPulse(left, INVERT_LEFT), valueToPulse(right, INVERT_RIGHT));
  lastCommandAt = millis();
  return true;
}

void handleControl(uint8_t clientId, uint8_t *payload, size_t length) {
  int32_t sequence = -1;
  if (!applyControl(payload, length, sequence)) {
    return;
  }

  activeClient = clientId;
  sendAck(clientId, sequence);
}

void sendUdpAck(IPAddress remoteIp, uint16_t remotePort, int32_t sequence) {
  JsonDocument message;
  message["type"] = "ack";
  message["seq"] = sequence;
  message["serverMs"] = millis();
  message["leftUs"] = currentLeftUs;
  message["rightUs"] = currentRightUs;

  controlUdp.beginPacket(remoteIp, remotePort);
  serializeJson(message, controlUdp);
  controlUdp.endPacket();
}

void processUdpControl() {
  int packetSize = controlUdp.parsePacket();
  while (packetSize > 0) {
    uint8_t payload[256];
    const int length = controlUdp.read(payload, sizeof(payload));
    const IPAddress remoteIp = controlUdp.remoteIP();
    const uint16_t remotePort = controlUdp.remotePort();

    int32_t sequence = -1;
    if (length > 0 && applyControl(payload, static_cast<size_t>(length), sequence)) {
      sendUdpAck(remoteIp, remotePort, sequence);
    }
    packetSize = controlUdp.parsePacket();
  }
}

void onWebSocketEvent(uint8_t clientId, WStype_t event, uint8_t *payload,
                     size_t length) {
  switch (event) {
    case WStype_CONNECTED:
      // Only one phone is allowed to control the car at a time.
      if (activeClient != 255 && activeClient != clientId) {
        webSocket.disconnect(activeClient);
      }
      activeClient = clientId;
      stopCar();
      lastCommandAt = millis();
      sendHello(clientId);
      Serial.printf("WebSocket client %u connected\n", clientId);
      break;

    case WStype_TEXT:
      if (clientId == activeClient) {
        handleControl(clientId, payload, length);
      }
      break;

    case WStype_DISCONNECTED:
      if (clientId == activeClient) {
        activeClient = 255;
        stopCar();
      }
      Serial.printf("WebSocket client %u disconnected\n", clientId);
      break;

    default:
      break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);

  leftPwm.setPeriodHertz(PWM_FREQUENCY_HZ);
  rightPwm.setPeriodHertz(PWM_FREQUENCY_HZ);

  leftPwm.attach(LEFT_PWM_PIN, PWM_MIN_US, PWM_MAX_US);
  if (!leftPwm.attached()) {
    Serial.printf("Failed to attach left PWM on GPIO %d\n", LEFT_PWM_PIN);
  }
  rightPwm.attach(RIGHT_PWM_PIN, PWM_MIN_US, PWM_MAX_US);
  if (!rightPwm.attached()) {
    Serial.printf("Failed to attach right PWM on GPIO %d\n", RIGHT_PWM_PIN);
  }
  stopCar();

  WiFi.mode(WIFI_AP);
  WiFi.setSleep(false);
  WiFi.softAPConfig(apIp, apGateway, apSubnet);
  const bool apStarted = WiFi.softAP(WIFI_AP_SSID, WIFI_AP_PASSWORD,
                                     WIFI_AP_CHANNEL, false, 1);

  Serial.printf("Wi-Fi AP %s: %s\n", apStarted ? "started" : "failed",
                WIFI_AP_SSID);
  Serial.printf("Password: %s\n", WIFI_AP_PASSWORD);
  Serial.printf("Control URL: ws://%s:%u\n", WiFi.softAPIP().toString().c_str(),
                WEBSOCKET_PORT);

  webSocket.begin();
  webSocket.onEvent(onWebSocketEvent);
  controlUdp.begin(CONTROL_UDP_PORT);
  Serial.printf("UDP control port: %u\n", CONTROL_UDP_PORT);
}

void loop() {
  webSocket.loop();
  processUdpControl();

  if (activeClient != 255 && millis() - lastCommandAt > CONTROL_TIMEOUT_MS) {
    stopCar();
  }
}
