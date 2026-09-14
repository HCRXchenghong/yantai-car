#pragma once

// Copy this file to config.h before building. config.h is deliberately kept
// out of Git because it can contain the Wi-Fi password for your car.

static constexpr int LEFT_PWM_PIN = 4;
static constexpr int RIGHT_PWM_PIN = 5;

static constexpr int PWM_FREQUENCY_HZ = 50;
static constexpr int PWM_MIN_US = 1000;
static constexpr int PWM_NEUTRAL_US = 1500;
static constexpr int PWM_MAX_US = 2000;

static constexpr bool INVERT_LEFT = false;
static constexpr bool INVERT_RIGHT = false;
static constexpr uint32_t CONTROL_TIMEOUT_MS = 500;

static constexpr char WIFI_AP_SSID[] = "Yantai-Car";
static constexpr char WIFI_AP_PASSWORD[] = "change-this-password";
static constexpr uint8_t WIFI_AP_CHANNEL = 6;

static constexpr uint8_t WIFI_IP_OCTET_1 = 192;
static constexpr uint8_t WIFI_IP_OCTET_2 = 168;
static constexpr uint8_t WIFI_IP_OCTET_3 = 4;
static constexpr uint8_t WIFI_IP_OCTET_4 = 1;

static constexpr uint16_t WEBSOCKET_PORT = 81;
static constexpr uint16_t CONTROL_UDP_PORT = 4210;
