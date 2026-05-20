# Desktop-Free Status

The CLI no longer has a runtime dependency on the vendor desktop app. The old
database import command and helper fallback have been removed from the wrapper
and from the tracked app bundle artifacts. Stable commands now require local
CLI state and go through `BluetoothProbe.app`.

## Current Boundary

Runtime control/status is validated for an owned amaran 60x S using
the project-owned state file:

```sh
~/Library/Application Support/amaran-cli/state.json
```

The stable commands are direct:

```sh
./bin/amaran list
./bin/amaran probe
./bin/amaran status
./bin/amaran on
./bin/amaran off
./bin/amaran intensity 20
./bin/amaran cct 5600
./bin/amaran cct 3200 --intensity 10
```

## State Sources

The state file contains mesh/app keys, optional fixture DeviceKeys, fixture
metadata, source addresses, IV index, and sequence counters. It must not be
committed or printed. Safe command output may include counts, fixture names,
node addresses, model codes, and MAC suffixes.

There are two supported ways to get state now:

- `./bin/amaran pair --verify` for a factory-reset or otherwise
  unprovisioned fixture.
- `./bin/amaran state-join <join-state.json>` for runtime control of an
  existing mesh when another provisioner can supply NetKey/AppKey metadata.
- `./bin/amaran state-install <source-state.json>` for a validated state file
  produced elsewhere.

`state-join` writes control-only fixture state when DeviceKeys are absent.
Runtime commands can use that state, but Config diagnostics and node reset are
unavailable for those fixtures.

`state-install` validates schema, key lengths, runtime counters, and target
permissions, writes with `0600`, refuses to overwrite existing state, and prints
only redacted fixture summaries.

## Pairing

The guarded first-fixture pairing flow is:

```sh
./bin/amaran pair --dry-run --state-path /tmp/amaran-state.json
./bin/amaran pair --verify --state-path /tmp/amaran-state.json
./bin/amaran doctor --state-path /tmp/amaran-state.json
```

For more fixtures in the same studio mesh, use add mode against the existing
state file:

```sh
./bin/amaran pair --add --dry-run
./bin/amaran pair --add --verify
```

The dry run checks that the target state path is ready for the selected mode,
then scans for unprovisioned PB-GATT advertisers. The real pairing command runs
no-OOB PB-GATT provisioning, waits for Mesh Proxy, runs the post-provision
Config chain with retries against the newly provisioned node address, and
optionally verifies status.

`pair` without `--add` writes a new state file and refuses to overwrite an
existing one. `pair --add` reuses the existing mesh keys and appends the new
fixture; it does not remove old fixtures. To install an externally prepared
state as the default, inspect it first, then run:

```sh
./bin/amaran state-install /tmp/amaran-state.json
```

For an owned already-provisioned fixture, the destructive reset diagnostic is:

```sh
./bin/amaran config-node-reset-test --dry-run
./bin/amaran config-node-reset-test --confirm-reset
```

The dry run validates local state and prints only a safe fixture summary. The
confirmed command sends DeviceKey Config Node Reset and makes the current state
for that fixture stale.

## Runtime

The 60x S advertises Mesh Proxy service `0x1828`. Runtime commands compute the
Proxy Network ID from local CLI state, connect to the matching proxy
advertisement, and write to Mesh Proxy Data In `0x2ADD` while reading Mesh Proxy
Data Out `0x2ADE`.

Standard SIG mesh messages can be built and transmitted, but the 60x S does not
apply them to emitter output. The working output-control path is the Telink
vendor opcode `0x26`.

Runtime source-address handling is split:

- DeviceKey Config sends use a CLI-owned source address, normally `3`.
- Telink vendor control/status uses `runtime.telink_source_address`, normally
  `1`, because the fixture sends vendor CCT status replies back there.

`cct` without `--intensity` first reads status so it can preserve the
current intensity.

## Implementation Pieces

- `BluetoothProbe.app` is the signed CoreBluetooth helper used by BLE commands.
- `native_mesh_crypto.swift` implements Bluetooth Mesh crypto, access,
  transport, Network PDU, and Proxy PDU builders.
- `native_mesh_config.swift` implements Config Client message builders and
  decoders.
- `native_mesh_provisioning.swift` implements PB-GATT provisioning helpers.
- `native_mesh_state.swift` implements local state payload validation/writing.
- `native_telink_control.swift` implements Telink `0x26` packet builders and
  status decoding.

Rebuild the helper with:

```sh
npm run build:bluetooth-helper
```

Run the local regression gate with:

```sh
npm test
```

## Remaining Limitations

- The live validation coverage is still centered on an owned amaran 60x S.
- Pairing assumes the fixture supports the no-OOB PB-GATT path tested
  here.
- macOS may hide the BLE MAC for provisioned fixtures; the runtime
  does not need it, but fixture summaries may show `unknown`.
- If commands fail immediately with `central_state unauthorized`, re-enable
  Bluetooth permission for `BluetoothProbe.app`.

## References

- RFC 4493 defines AES-CMAC and includes public vectors used by tests:
  https://www.rfc-editor.org/rfc/rfc4493
- RFC 3610 defines AES-CCM and includes public packet vectors used by tests:
  https://www.rfc-editor.org/rfc/rfc3610
- Bluetooth Mesh Protocol v1.1 defines AES-CMAC, AES-CCM, nonce formats, and
  key derivation:
  https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/MshPRT_v1.1/out/en/index-en.html
- Bluetooth assigned numbers list Mesh Provisioning Data In/Out as `0x2ADB` and
  `0x2ADC`, and Mesh Proxy Data In/Out as `0x2ADD` and `0x2ADE`:
  https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/Assigned_Numbers.pdf
