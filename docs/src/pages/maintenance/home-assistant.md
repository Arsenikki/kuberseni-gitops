---
title: Home Assistant
description: ---
layout: /src/layouts/MainLayout.astro
---

# Configure Zigbee Bridge integration

1. Add integration 'Zigbee Home Automation'
2. Select `EZSP` as radio type
3. Input following settings:

```
serial device path: socket://<ip-address>:8888

port speed: 115200

Data flow control: Software
```