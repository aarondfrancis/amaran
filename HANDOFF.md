# Handoff: nRF52840 DK Sidus Mesh Join Capture

You are working on the amaran CLI, a local macOS CLI for controlling owned
amaran fixtures through Bluetooth Mesh / Telink vendor packets.

Read `AGENTS.md` first. The important constraints are:

- Do not print, log, commit, or share mesh NetKeys, AppKeys, DeviceKeys, session
  keys, or any real `state.json` contents.
- Runtime control currently uses local CLI state and `BluetoothProbe.app`.
- The old amaran Desktop / PyMeshSDK fallback path has been removed.
- Keep commits local unless explicitly asked to push.

## Current Goal

Use a Nordic **nRF52840 DK** (`PCA10056`) as a fake Bluetooth Mesh provisionee so
Sidus Link Pro can provision it into the existing Sidus-controlled mesh. If
that works, capture the mesh credentials needed for the amaran CLI to join and
control the existing studio mesh without resetting real lights.

The target result is a safe import path into the existing CLI state model,
probably through `./bin/amaran state-join <join-state.json>` or a new converter
that writes the same schema.

## What We Already Proved

The repo has an experimental macOS diagnostic:

```sh
./bin/amaran join-capture --output-state /private/tmp/amaran-sidus-capture.json --timeout 120
```

It launches `BluetoothProbe.app` as a CoreBluetooth peripheral and advertises:

- Local name: `amaran 60x S`
- Mesh Provisioning service UUID: `0x1827`

Manual test result:

- nRF Connect on iPad saw the Mac advertiser as `amaran 60x S` with service
  UUID `1827`.
- Sidus Link Pro did not show it in the add-fixture flow.

Conclusion: the Mac-side advertiser is real, but Sidus Link Pro is filtering on
something beyond local name + provisioning service UUID. The missing piece is
likely raw provisioning service data, manufacturer data, or a fixture-specific
advertising identity that macOS CoreBluetooth cannot fully spoof.

## Why The nRF52840 DK

The nRF52840 DK gives us raw BLE advertising and Bluetooth Mesh control that
macOS CoreBluetooth does not expose. It also has onboard SEGGER J-Link, serial
logs, buttons/LEDs, and straightforward firmware flashing/debugging.

Do not use the nRF52840 Dongle (`PCA10059`) for this unless there is no choice;
it is much more annoying to debug.

## Device Plan

1. Set up Nordic/Zephyr tooling on the Mac.
2. Flash custom firmware to the nRF52840 DK.
3. Make the DK advertise as an unprovisioned Bluetooth Mesh device with proper
   provisioning service data:
   - Device UUID
   - OOB info
   - Mesh Provisioning service data, not just service UUID
4. Open Sidus Link Pro on the iPad and try to add the DK as a Bluetooth/Sidus
   fixture.
5. If Sidus shows the DK and provisions it, log the provisioning/config data
   safely.
6. Convert captured data into CLI local state without printing secrets.

## Data We Need

For runtime control of existing fixtures, the CLI needs:

- Mesh NetKey
- Mesh AppKey
- IV index
- Fixture unicast addresses

DeviceKeys are not required for Telink vendor runtime control, but they are
useful for Config Client diagnostics and node reset.

During fake-node provisioning, the DK should be able to learn/calculate:

- NetKey from Provisioning Data
- Key index, flags, IV index
- Assigned unicast address for the fake node
- Fake node DeviceKey

That is still not enough for runtime control. We also need the mesh AppKey.
The likely AppKey capture path is post-provision Config Client traffic:

- Sidus may send Config AppKey Add to the newly provisioned DK.
- The DK must behave like enough of a Bluetooth Mesh Config Server to receive
  and decode that message.
- Capturing the AppKey is the critical next milestone after basic provisioning.

## Suggested Firmware Approach

Start with Zephyr or nRF Connect SDK Bluetooth Mesh samples rather than writing
the stack from scratch.

Minimum firmware capabilities:

- PB-GATT / PB-ADV unprovisioned node advertising.
- No-OOB provisioning path if Sidus accepts it.
- Serial logging over USB CDC/UART or RTT.
- Config Server support sufficient to receive AppKey Add and Model App Bind.
- A small vendor/model surface if Sidus requires model identity during config.

Initial milestone:

- DK appears in nRF Connect with real provisioning service data.
- DK appears in Sidus Link Pro add-fixture flow.

Second milestone:

- Sidus provisions the DK successfully.
- Firmware logs safe status summaries and writes key-bearing capture data only
  to a local file or serial output that is handled carefully.

Third milestone:

- Firmware captures AppKey or proves Sidus does not send it to this fake node.
- CLI imports the captured material into a state file and can `probe/status`
  an existing real fixture by node address.

## If Sidus Still Does Not Show The DK

If the DK advertises a valid unprovisioned Bluetooth Mesh device but Sidus Link
Pro still ignores it, Sidus is probably filtering for amaran/Aputure-specific
advertisement payloads or known product identities.

Next things to investigate:

- Capture advertisement data from a real factory-reset amaran fixture using nRF
  Connect or another BLE scanner.
- Compare service data/manufacturer data against the DK advertisement.
- Add matching manufacturer/service payloads to the DK firmware if legal and
  technically feasible.

Do not reset real studio lights casually. If a real fixture must be reset for
advertisement capture, use an alternate local state path and make the user
explicitly confirm the impact first.

## Repo State To Know

Useful commands:

```sh
./bin/amaran help
./bin/amaran doctor
./bin/amaran list
./bin/amaran probe
./bin/amaran status
./bin/amaran intensity 18 --node <address>
./bin/amaran state-join <join-state.json>
./bin/amaran join-capture --output-state /private/tmp/amaran-sidus-capture.json --timeout 120
```

Validation commands:

```sh
zsh -n bin/amaran
npm run test:mesh
npm test
npm run build:bluetooth-helper
git diff --check
```
