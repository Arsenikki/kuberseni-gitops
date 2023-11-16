---
title: Sonoff ZBBridge
description: ---
layout: /src/layouts/MainLayout.astro
---

# Reset wifi
In case wlan network SSID or password has been changed. Following steps can be used to reset the Tasmotized ZBBridge (source: https://tasmota.github.io/docs/Device-Recovery/#recovery-techniques)

1. Hold the button down for 40 seconds. The device should reset and reboot.
2. Connect to tasmota AP and configure wlan SSID and password

# Troubleshooting

In case zigbee2mqtt or ZHA fails to connect, find the ip address of the ZBBridge and access the UI. Navigate to console and verify following line is found on startup:
```
TCP: Starting TCP server on port 8888
```
If this is missing, following might need to be executed:
```
backlog rule1 on system#boot do TCPStart 8888 endon ; rule1 1 ; template {"NAME":"Sonoff ZHABridge","GPIO":[56,208,0,209,59,58,0,0,0,0,0,0,17],"FLAG":0,"BASE":18} ; module 0
```
Source: https://digiblur.com/2020/07/25/how-to-use-the-sonoff-zigbee-bridge-with-home-assistant-tasmota/