# amaran-cli

Local CLI control for owned amaran fixtures on macOS.

The CLI keeps its own JSON studio manifest in
`~/Library/Application Support/amaran-cli/state.json` and talks to fixtures
directly through the signed `BluetoothProbe.app` CoreBluetooth helper. Runtime
commands are direct: there is no Desktop database import command and no
Desktop helper fallback.

```sh
./bin/amaran help
./bin/amaran doctor
./bin/amaran pair --dry-run --state-path /tmp/amaran-test-state.json
./bin/amaran pair --verify --state-path /tmp/amaran-test-state.json
./bin/amaran pair --add --dry-run
./bin/amaran pair --add --verify
./bin/amaran gatt-probe
./bin/amaran provision-scan
./bin/amaran provision-invite-test
./bin/amaran provision-test
./bin/amaran pair-test
./bin/amaran proxy-test
./bin/amaran sig-onoff-test on
./bin/amaran control-test intensity 20
./bin/amaran status-test
./bin/amaran configure-test
./bin/amaran config-composition-get-test
./bin/amaran config-appkey-get-test
./bin/amaran config-appkey-add-test
./bin/amaran config-model-app-bind-test
./bin/amaran config-node-reset-test --dry-run
./bin/amaran config-node-reset-test --confirm-reset
./bin/amaran join-capture --output-state /private/tmp/amaran-sidus-capture.json --timeout 120
./bin/amaran state-join /tmp/sidus-join.json
./bin/amaran state-install /tmp/amaran-test-state.json
./bin/amaran list
./bin/amaran probe
./bin/amaran status
./bin/amaran on
./bin/amaran off
./bin/amaran intensity 25
./bin/amaran cct 5600
./bin/amaran cct 3200 --intensity 10
```

Use `--node <id>` or `AMARAN_NODE_ID=<id>` if more than one fixture is present.
Use `--state-path <file>` or `AMARAN_CLI_STATE_PATH=<file>` to point commands
at a different local state file, which is useful for pairing tests without
moving the real state.

Run `./bin/amaran help` or `./bin/amaran --help` for the built-in command
reference. That output is intentionally safe to paste into an issue or terminal
log; it describes key-bearing state, but does not print key material.

## Local State

The state file is a JSON manifest for the whole studio. It contains mesh/app
keys, optional DeviceKeys per fixture, fixture metadata, IV index, source
addresses, and sequence counters. Do not commit or share it. Safe CLI output
may include fixture counts, names, node addresses, model codes, and MAC
suffixes, but must not print key material.

Commands reserve sequence numbers in that state. DeviceKey Config sends
use a CLI-owned source address, normally `3` or the next unused unicast address.
Telink vendor runtime control/status uses a separate source address, normally
`1`, because the 60x S sends vendor status replies back to that address.

Install an externally prepared or test state only after inspection:

```sh
./bin/amaran doctor --state-path /tmp/amaran-test-state.json
./bin/amaran state-install /tmp/amaran-test-state.json
```

`state-install` validates the state shape, key lengths, and runtime
counters, writes the target with `0600` permissions, refuses to overwrite an
existing target state file, and prints only redacted fixture summaries.

## Joining An Existing Mesh

If another provisioner can supply the mesh NetKey, AppKey, IV index, and fixture
node addresses, the CLI can join that mesh for runtime control without resetting
fixtures:

```sh
./bin/amaran state-join /tmp/sidus-join.json
./bin/amaran doctor
./bin/amaran status --node 2
```

`state-join` writes a control-only CLI state when DeviceKeys are missing.
Runtime commands work from NetKey/AppKey, but Config diagnostics and destructive
node reset are unavailable for control-only fixtures. This command does not
extract keys from Sidus Link Pro or amaran Desktop. See
[`docs/mesh-join.md`](docs/mesh-join.md) for the join manifest format and the
remaining no-reset options.

There is also an experimental provisioning capture:

```sh
./bin/amaran join-capture --output-state /private/tmp/amaran-sidus-capture.json --timeout 120
```

This makes the Mac advertise as an unprovisioned Bluetooth Mesh node so Sidus
Link Pro can try to provision it. If Sidus accepts the dummy node, the capture
file gets the mesh NetKey and dummy node DeviceKey. It does not yet capture the
mesh AppKey, so it is not enough by itself to control existing fixtures.

## Pairing

For the first factory-reset or otherwise unprovisioned fixture in a new studio
state, the guarded path is:

```sh
./bin/amaran pair
```

That command runs PB-GATT provisioning, waits for the Mesh Proxy advertisement,
then runs the post-provision Config sequence needed for vendor control. It
retries that Config sequence because the Mesh Proxy can take a few seconds to
settle immediately after provisioning. With `--verify`, it also reads
status after configuration so the same command proves that the fixture is
reachable by the stable runtime path. Without `--add`, it refuses to overwrite
an existing CLI state file.

For each additional fixture, keep the same state file and append into the
existing mesh:

```sh
./bin/amaran pair --add --dry-run
./bin/amaran pair --add --verify
./bin/amaran list
```

The dry run checks whether the target state path is ready for the selected mode
and scans for unprovisioned fixtures. In create mode it verifies that the state
path is available. In add mode it verifies that the existing manifest is usable
and writable. It does not send provisioning PDUs or write state.

`pair --add` reuses the existing mesh NetKey/AppKey and appends one newly
provisioned fixture. It does not remove old fixtures. Once more than one
fixture is present, runtime commands need a target unless `AMARAN_NODE_ID` is
set:

```sh
./bin/amaran intensity 18 --node 18
AMARAN_NODE_ID=18 ./bin/amaran status
```

If you need to make an already-provisioned owned fixture unprovisioned, there is
a destructive diagnostic:

```sh
./bin/amaran config-node-reset-test --dry-run
./bin/amaran config-node-reset-test --confirm-reset
```

The dry run validates the local keys, runtime counters, source address, and
selected fixture needed for reset, then prints only a safe fixture summary. The
confirmed command sends Bluetooth Mesh Config Node Reset using the fixture's
DeviceKey from local CLI state. It will make the fixture leave the current mesh,
so the current state for that fixture should be treated as stale afterward.

## Command Reference

Stable runtime commands require local CLI state and use the Mesh Proxy path.

| Command | Purpose |
| --- | --- |
| `./bin/amaran list [--json]` | Print fixture names, node addresses, and MACs or `unknown` from local state. |
| `./bin/amaran probe [--node <id>] [--json]` | Connect to the matching Mesh Proxy advertisement using the Network ID from local state. |
| `./bin/amaran status [--node <id>] [--json]` | Read and decode the vendor CCT status packet. |
| `./bin/amaran on [--node <id>]` | Send Telink vendor on. |
| `./bin/amaran off [--node <id>]` | Send Telink vendor off. |
| `./bin/amaran intensity <0-100> [--node <id>]` | Send Telink brightness in percent. |
| `./bin/amaran cct <kelvin> [--intensity <0-100>] [--node <id>]` | Send Telink CCT. Without `--intensity`, the CLI reads status first and preserves the current intensity. |

State and pairing commands manage local state and fixture setup.

| Command | Purpose |
| --- | --- |
| `./bin/amaran doctor [--json]` | Inspect local state, safe runtime counters, and control readiness. |
| `./bin/amaran pair [--add] [--attention <0-255>] [--dry-run] [--verify] [--json]` | Provision an unprovisioned fixture, configure it for vendor control, and write local state. Creates the first manifest, or appends to the existing studio manifest with `--add`. |
| `./bin/amaran join-capture --output-state <capture.json> [--timeout <sec>] [--json]` | Experimental no-reset diagnostic. Advertises this Mac as an unprovisioned Mesh node and captures provisioning credentials from Sidus Link Pro. Output is redacted; the capture file is key-bearing. |
| `./bin/amaran state-join <join-state.json> [--json]` | Join an existing mesh for runtime control from externally supplied NetKey/AppKey metadata. Writes control-only fixture state when DeviceKeys are absent. |
| `./bin/amaran state-install <source-state.json> [--json]` | Validate and install a state file with `0600` permissions. Refuses to overwrite existing target state. |

Diagnostic commands are lower-level tools for discovery, provisioning, control
packet testing, and Config Client work.

| Command | Purpose |
| --- | --- |
| `./bin/amaran gatt-probe [--json]` | Discover Mesh Proxy and Provisioning GATT services. |
| `./bin/amaran provision-scan [--json]` | Scan for unprovisioned PB-GATT advertisers without writing provisioning PDUs. |
| `./bin/amaran provision-invite-test [--attention <0-255>] [--json]` | Send only Provisioning Invite and decode Capabilities. |
| `./bin/amaran provision-test [--add] [--attention <0-255>] [--json]` | Run no-OOB PB-GATT provisioning and write or append state, without post-provision configuration. |
| `./bin/amaran pair-test [--add] [--attention <0-255>] [--dry-run] [--verify] [--json]` | Diagnostic alias for provisioning plus post-provision configuration. |
| `./bin/amaran proxy-test [--json]` | Write a public sample Mesh Proxy PDU. |
| `./bin/amaran sig-onoff-test <on\|off> [--node <id>] [--json]` | Send a standard Generic OnOff test PDU. The 60x S does not apply this to emitter output. |
| `./bin/amaran control-test <on\|off\|intensity\|cct> [value] [--intensity <0-100>] [--node <id>] [--json]` | Send reconstructed Telink `0x26` control payloads. |
| `./bin/amaran status-test [--node <id>] [--json]` | Read and decode Telink `0x26` status. |
| `./bin/amaran configure-test [--node <id>] [--json]` | Fetch composition, ensure AppKey index 0, and bind the vendor model. |
| `./bin/amaran config-composition-get-test [--node <id>] [--json]` | Fetch and store Composition Data Page 0. |
| `./bin/amaran config-appkey-get-test [--node <id>] [--json]` | Read safe AppKey index metadata. |
| `./bin/amaran config-appkey-add-test [--node <id>] [--json]` | Send segmented DeviceKey Config AppKey Add. |
| `./bin/amaran config-model-app-bind-test [--node <id>] [--json]` | Bind AppKey index 0 to the first vendor model. |
| `./bin/amaran config-node-reset-test --dry-run [--node <id>] [--json]` | Validate the selected fixture and print a redacted reset preview. |
| `./bin/amaran config-node-reset-test --confirm-reset [--node <id>] [--json]` | Send destructive DeviceKey Config Node Reset. Treat existing state for that fixture as stale afterward. |

Global options:

| Option | Meaning |
| --- | --- |
| `--node <id>` | Fixture node address. Defaults to `AMARAN_NODE_ID`, then the only fixture in local state. |
| `--timeout <sec>` | BLE helper timeout. Defaults to `AMARAN_TIMEOUT` or `20`. |
| `--attention <sec>` | Provisioning Invite attention duration from `0` to `255`. Defaults to `AMARAN_ATTENTION_DURATION` or `0`. |
| `--add` | For `pair`/`provision-test`, append an unprovisioned fixture to the existing studio manifest instead of creating a new mesh. |
| `--state-path <p>` | Local CLI state file. Defaults to `AMARAN_CLI_STATE_PATH` or `~/Library/Application Support/amaran-cli/state.json`. |
| `--output-state <p>` | Secret capture output for `join-capture`. The file is created with `0600` permissions and is never printed. |
| `--dry-run` | For `pair`, preflight and scan only. For node reset, validate and print the selected fixture without sending reset. |
| `--verify` | For `pair`, read status after provisioning/configuration. |
| `--confirm-reset` | Required for destructive Config Node Reset. |
| `--json` | Print JSON where supported. JSON output must not include mesh, app, or device keys. |
| `--help`, `-h` | Show built-in help. |

## Notes

- The 60x S advertises a Telink BLE Mesh proxy on service `0x1828`.
- `gatt-probe` scans for Mesh Proxy service `0x1828` and Mesh Provisioning
  service `0x1827`, then discovers the standard Data In/Out characteristics.
- Provisioning uses Provisioning Data In `0x2ADB` and Data Out `0x2ADC`.
- `join-capture` advertises Provisioning service `0x1827` from the Mac using
  the service UUID and local name. macOS CoreBluetooth does not expose the full
  service-data advertisement real fixtures normally use, so Sidus Link Pro may
  or may not accept it.
- Runtime control uses Mesh Proxy Data In `0x2ADD` and Data Out `0x2ADE`.
- Standard SIG mesh `Generic OnOff`, `Light Lightness`, and `Light CTL` packets
  can be transmitted, but the amaran 60x S does not apply them to emitter
  output. The working control path is the Telink vendor opcode `0x26`.
- `native_mesh_crypto.swift` contains Bluetooth Mesh crypto, access, transport,
  Network PDU, and Proxy PDU builders.
- `native_mesh_config.swift` contains post-provisioning Configuration Client
  message builders and decoders.
- `native_mesh_provisioning.swift` contains PB-GATT provisioning helpers.
- `native_mesh_state.swift` contains the local state payload builder.
- `native_telink_control.swift` contains the reconstructed Telink `0x26` packet
  builders for on/off, brightness, CCT control, and status reads.

## Development

Rebuild and sign the CoreBluetooth helper with:

```sh
npm run build:bluetooth-helper
```

The default build uses an ad-hoc signature with a stable local designated
requirement for `dev.local.bluetooth-probe`. Set `AMARAN_CODESIGN_IDENTITY` to
use a real signing identity instead.

Run the default regression gate:

```sh
npm test
```

Run only the non-BLE wrapper checks:

```sh
npm run test:cli-wrapper
```

If commands fail immediately with `central_state unauthorized`, re-enable
macOS Bluetooth permission for `BluetoothProbe.app`. Older ad-hoc builds used
changing `cdhash` requirements, so an existing denied or stale permission entry
may need to be reset once.
