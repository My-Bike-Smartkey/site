# D-SmartKey — iOS Smart Key for Dat Bike

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-lightgrey.svg)]()
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)]()

> **Tiếng Việt:** Ứng dụng khóa thông minh mã nguồn mở cho xe **Dat Bike Quantum S3** — thay thế smartkey chính thức, kết nối BLE trực tiếp với firmware xe. Giao thức được reverse-engineer từ btsnoop log (xem [`docs/PROTOCOL.md`](docs/PROTOCOL.md)). Trạng thái tính năng ghi trung thực theo bằng chứng kiểm thử — build xanh **không đồng nghĩa** đã kiểm tra trên xe thật (xem [`docs/TEST_AND_DEPLOYMENT_GUIDE.md`](docs/TEST_AND_DEPLOYMENT_GUIDE.md)).

An open-source iOS smart key for the **Dat Bike Quantum S3** electric motorcycle. It speaks the vendor's proprietary GATT protocol directly over Bluetooth LE — pairing, authentication, power control, anti-theft arm, telemetry — using Core Bluetooth and AccessorySetupKit (iOS 18+).

---

## Features

| Feature | Status | Notes |
|---|---|---|
| Pairing (random 12-char PIN + NFC/SMP bonding) | ✅ shipped | First-write triggers SMP; user taps NFC card on the bike |
| Reconnect auth (SHA-256 challenge-response) | ✅ shipped | Counter-based; see [Protocol](docs/PROTOCOL.md) |
| Power ON / OFF | ✅ shipped | Single write per confirmed command |
| Anti-theft arm | ✅ shipped | |
| Find-my-bike (horn) | ✅ shipped | |
| Telemetry: battery %, odometer, temperature | ✅ shipped | 10 s polling while connected (foreground-dependent) |
| Vehicle info: name, model, frame no., firmware | ✅ shipped | |
| RSSI proximity with EMA + sample freshness | ✅ shipped | 2-sample minimum, 3 s max age, −127…−1 valid range |
| Auto power-ON when approaching the bike | ✅ shipped, field-test pending | Gated by RSSI threshold + fresh samples; **one attempt per session**, success notified only after firmware confirms `unlocked` |
| Manual-only mode (`ConnectionIntent`) | ✅ shipped | Blocks all auto reconnect/auth/turn-on until the user opts back in |
| Background reconnection (pending connect) | ✅ shipped, field-test pending | System-managed; survives suspension. **Does not survive user force-quit** (iOS policy) |
| State restoration after system jettison | ✅ shipped, field-test pending | Restored `.connecting`/`.connected` peripherals are adopted, not cancelled |

Status legend: ✅ shipped = implemented + unit-tested where testable. "Field-test pending" = verified in simulator/unit tests only; on-bike measurement is still open — see the acceptance matrix in [`docs/TEST_AND_DEPLOYMENT_GUIDE.md`](docs/TEST_AND_DEPLOYMENT_GUIDE.md).

## Honest limitations

- **Force-quit breaks auto-reconnect.** iOS does not relaunch a force-quit app for BLE events. The AccessorySetupKit pairing stays in Settings, but no app process = no smart key logic. (This is OS policy, not a bug we can fix.)
- **MIC failure recovery requires re-pairing.** iOS cannot delete the bike's LTK from the app; when the bike drops its bond, the user must remove the accessory and pair again.
- **Pending connect is not a proximity sensor.** A pending `connect` for a known peripheral proves none of: distance, zero power draw, or reconnect within a fixed latency.
- **One auto power-ON attempt per session** — deliberate safety policy: after an ambiguous write timeout the app never blind-replays a physical actuation command.
- **10 backlog tests are skipped** (they need a real bike). Total suite: 40 tests, 10 skipped, 0 failures at time of writing.

## Architecture

```
┌────────────────────────────────────────────────────────┐
│ SwiftUI App                                            │
│  ├── Views (Dashboard, Battery, Settings, Components)  │
│  ├── ViewModels (Dashboard / Battery / Settings)       │
│  └── AppDIContainer                                    │
├────────────────────────────────────────────────────────┤
│ BLE Coordinator — DatBikeCore (IoTCoordinatorProtocol) │
│  ├── CBCentralManager + state restoration (bleQueue)   │
│  ├── BLEStateMachine (lock-protected, ordered publish) │
│  ├── BLEConnectionContext (characteristic registry)    │
│  ├── BLETaskQueue + BLECharacteristicIO (transport)    │
│  ├── BLEAuthenticator (SHA-256 challenge-response)     │
│  ├── BLECommandDispatcher (write + confirm)            │
│  ├── BLEPollingEngine (RSSI/telemetry, 10 s)           │
│  ├── BLETelemetryParser / BLECryptography              │
│  ├── ProximitySampleWindow (EMA, session-scoped)       │
│  ├── RetryScheduler / NotificationManager              │
│  └── ASKManager (AccessorySetupKit picker + events)    │
└────────────────────────────────────────────────────────┘
```

Deep dive (concurrency model, background/reconnect policy, open items): [`docs/ARCHITECTURE_BLE_AND_ASK.md`](docs/ARCHITECTURE_BLE_AND_ASK.md)

Wire protocol (services, characteristics, commands, auth flow): [`docs/PROTOCOL.md`](docs/PROTOCOL.md)

## Project structure

```
ios-app/
├── DatBikeSmartkey.xcodeproj    # Committed Xcode project
├── project.yml                  # xcodegen spec (source of truth for targets)
├── DatBikeSmartkey/
│   ├── DatBikeSmartKeyApp.swift # Entry point
│   ├── AppDIContainer.swift
│   ├── BLE/
│   │   ├── Core/                # DatBikeCore, BLEStateMachine, ASKManager,
│   │   │                        # PreferencesManager, RetryScheduler, NotificationManager
│   │   ├── Domain/              # BLEConstants, IoTProtocols, IoTTypedModels, IoTError
│   │   ├── Services/            # Authenticator, CommandDispatcher, PollingEngine,
│   │   │                        # TelemetryParser, Cryptography
│   │   └── Transport/           # BLEConnectionContext, BLECharacteristicIO, BLETaskQueue
│   ├── Models/ ViewModels/ Views/
├── DatBikeSmartkeyTests/        # 7 suites; 40 tests (10 hardware-dependent skips)
└── docs/                        # Architecture, protocol, test & deployment guides
```

## Build & run

Requirements: macOS with Xcode 16+ (iOS 18 SDK), CocoaPods/SPM not needed (zero third-party dependencies).

```bash
# Open in Xcode, select your team for signing, run on a physical device.
# BLE does not work on the simulator.
open DatBikeSmartkey.xcodeproj
```

### Command line

```bash
# Unit tests (simulator)
xcodebuild -project DatBikeSmartkey.xcodeproj -scheme DatBikeSmartkey \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro,OS=18.0' \
  -configuration Debug test

# Device build (generic iOS destination avoids DDI errors in CI contexts)
xcodebuild -project DatBikeSmartkey.xcodeproj -scheme DatBikeSmartkey \
  -configuration Debug -destination 'generic/platform=iOS' \
  -derivedDataPath build/tn CODE_SIGN_STYLE=Automatic build

# Install + launch on a connected iPhone
xcrun devicectl device install app --device <DEVICE_ID> \
  'build/tn/Build/Products/Debug-iphoneos/D-SmartKey.app'
xcrun devicectl device process launch --device <DEVICE_ID> app.mybike.smartkey
```

### Regenerating the project (only after editing `project.yml`)

```bash
xcodegen generate
```

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). Short version: keep claims evidence-based — report measured pass/skip/fail, never claim on-bike stability from simulator runs, and never auto-send actuation commands during testing.

## License

[MIT](LICENSE) — © 2026 D-SmartKey contributors.

The Dat Bike BLE protocol was reverse-engineered for interoperability; Dat Bike is a trademark of its respective owner. This project is not affiliated with or endorsed by Dat Bike.
