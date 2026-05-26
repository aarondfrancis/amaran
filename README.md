# amaran-cli

Local CLI control for owned amaran fixtures on macOS.

The CLI keeps its own JSON studio manifest in
`~/Library/Application Support/amaran-cli/state.json` and talks to fixtures
directly through the signed `BluetoothProbe.app` CoreBluetooth helper. Runtime
commands are direct: there is no Desktop helper fallback. Runtime BLE commands
auto-start a local `BluetoothProbe.app` daemon so repeated commands can reuse
CoreBluetooth and the Mesh Proxy connection. The recommended studio flow is to
keep Sidus Link Pro on the iPad as the pairing source of truth, then import
that mesh metadata from an encrypted local iPad backup.

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
./bin/amaran sidus-import --backup /private/tmp/Backup
./bin/amaran state-join /tmp/sidus-join.json
./bin/amaran state-install /tmp/amaran-test-state.json
./bin/amaran discover --range 2-64 --update-state
./bin/amaran fixture rename 6 desk-key
./bin/amaran scene capture "recording scene" --node desk-key
./bin/amaran scene apply "recording scene" --node desk-key
./bin/amaran fixture clear-name desk-key
./bin/amaran scene list
./bin/amaran scene show "recording scene"
./bin/amaran daemon status
./bin/amaran ui
./bin/amaran list
./bin/amaran probe
./bin/amaran status
./bin/amaran identify desk-key
./bin/amaran on
./bin/amaran off
./bin/amaran intensity 25
./bin/amaran cct 5600
./bin/amaran cct 3200 --intensity 10
./bin/amaran gm 10 --node tube-stage-left
./bin/amaran cct 4700 --intensity 24 --gm 20 --node tube-stage-right
```

Use `--node <id-or-name>` or `AMARAN_NODE_ID=<id-or-name>` if more than one
fixture is present. Use `fixture rename` to give a fixture a local name like
`desk-key` or `tube-left`. Use `--state-path <file>` or
`AMARAN_CLI_STATE_PATH=<file>` to point commands at a different local state
file, which is useful for pairing tests without moving the real state.

Run `./bin/amaran help` or `./bin/amaran --help` for the built-in command
reference. That output is intentionally safe to paste into an issue or terminal
log; it describes key-bearing state, but does not print key material.

## Local State

The state file is a JSON manifest for the whole studio. It contains mesh/app
keys, optional DeviceKeys per fixture, fixture metadata, IV index, source
addresses, and sequence counters. Do not commit or share it. Safe CLI output
may include fixture counts, names, node addresses, model codes, and MAC
suffixes, but must not print key material.

The CLI does not load a `.env` file, and DeviceKeys should not live in one.
Environment variables are only convenience defaults such as `AMARAN_NODE_ID`,
`AMARAN_TIMEOUT`, `AMARAN_CLI_STATE_PATH`, and the optional
`AMARAN_IOS_BACKUP_PASSWORD` import helper. `AMARAN_DAEMON_DISABLE=1` forces
the older one-shot helper path, and `AMARAN_DAEMON_PORT_FILE` overrides the
non-secret daemon port metadata path. `AMARAN_TUI_VENV` can override the
private Textual venv path for `ui`; set `AMARAN_TUI_BOOTSTRAP=0` to prevent
automatic dependency installation. `AMARAN_TUI_STATUS_TIMEOUT` controls the
per-fixture status timeout inside the TUI and defaults to the lower of
`AMARAN_TIMEOUT` and `5`. `AMARAN_TUI_DEBOUNCE` controls how long the TUI waits
before sending brightness, CCT, or G/M changes from sliders or keys, and
defaults to `0.35`. `AMARAN_TUI_THEME` can be
`auto`, `dark`, or `light`.
The key-bearing file is the local state manifest, normally
`~/Library/Application Support/amaran-cli/state.json`.

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

## Sidus-First Studio Flow

Use this when the iPad should remain the source of truth for pairing, grouping,
and fixture setup:

```sh
# Pair and arrange fixtures in Sidus Link Pro first.

# Create an encrypted local iPad backup in Finder, then import it.
./bin/amaran sidus-import --backup /private/tmp/Backup

# Confirm local control.
./bin/amaran list
./bin/amaran status --node <address-from-list>

# Save and recall live looks.
./bin/amaran scene capture "recording scene"
./bin/amaran scene apply "recording scene"
```

`sidus-import` accepts either an iPad backup directory or an extracted Sidus app
container. Encrypted backups require the Python package
`iphone_backup_decrypt`; if it is missing, the importer creates a private venv
under `~/Library/Application Support/amaran-cli/python/ios-backup-import` and
installs it there. Set `AMARAN_IOS_BACKUP_IMPORT_VENV` to override that path.
The command prompts for the backup password unless `AMARAN_IOS_BACKUP_PASSWORD`
is set. It writes the normal CLI state file with `0600` permissions, refuses to
overwrite existing state unless `--replace` is passed, and prints only redacted
fixture summaries.

If you add fixtures in Sidus Link Pro and the mesh keys did not change, the CLI
can scan candidate unicast addresses and optionally keep responsive fixtures:

```sh
./bin/amaran discover --range 2-64
./bin/amaran discover --range 2-64 --update-state
```

`discover` uses the existing NetKey/AppKey and batched vendor status reads to
find addresses that answer on the current mesh. The normal path sends the whole
range over one Mesh Proxy connection, so `--timeout` is the batch window rather
than a per-address delay. It can add runtime control entries, but it cannot
recover new DeviceKeys or Sidus-only metadata. If the scan range includes the
CLI-owned Config source address, discovery moves that source address before
probing so an iPad-assigned fixture at that address is not skipped. Take a fresh
encrypted iPad backup and rerun `sidus-import --replace` when you need updated
names, MACs, DeviceKeys, app metadata, or if Sidus creates a new mesh/AppKey.
Because discovery uses the same status read as `status`, a fixture that is
powered but programmatically off/asleep may not answer until it is woken.

Local fixture names are for the CLI only:

```sh
./bin/amaran list
./bin/amaran fixture rename 6 desk-key
./bin/amaran status --node desk-key
./bin/amaran identify desk-key
./bin/amaran intensity 18 --node desk-key
./bin/amaran fixture clear-name desk-key
```

The friendly name is stored as `friendly_name` in local state. It does not
rename the light in Sidus Link Pro, and it preserves the imported Sidus/source
name underneath.

Scenes live in the same local state file:

```sh
./bin/amaran scene capture "recording scene"
./bin/amaran scene capture "recording scene" --node <address-from-list>
./bin/amaran scene capture "recording scene" --node key --node fill --off-node backlight
./bin/amaran scene list
./bin/amaran scene show "recording scene"
./bin/amaran scene apply "recording scene"
./bin/amaran scene apply "recording scene" --node <address-from-list>
```

`scene capture` reads live fixture status and stores intensity, CCT, green-
magenta correction when the fixture family supports it, and sleep state. Repeat
`--node` to capture a selected set of fixtures. Use `--off-node <id-or-name>` to
save a fixture as off without requiring a status response, which is useful when
an intentionally off fixture would otherwise time out. `scene apply` wakes each
saved-on fixture first, then sends the saved look; saved-off fixtures receive
`off`. Scene restore is capability-aware, so known `400M5-*` fixtures are
clamped to `2700-6500K` and do not receive G/M commands. Both commands use the
mesh keys in local state, but command output remains redacted.

## Terminal UI

Open the local studio control surface with:

```sh
./bin/amaran ui
```

The TUI lists known fixtures, refreshes live status, toggles power, adjusts
brightness, CCT, and green-magenta correction, identifies a selected fixture,
and applies or captures scenes. Scene capture is explicit: mark fixtures in the
`cap` column to include them. If an included fixture is currently shown as off,
the TUI saves it with `--off-node`; otherwise it reads live status. Scene rows
apply on activation. The TUI uses the safe fixture capabilities exposed by
`list --json`: for example, `400M5-*` fixtures show a `2700-6500K` CCT slider
and mark G/M as unsupported instead of sending no-op G/M packets. The TUI talks
to the existing CLI commands and only consumes redacted JSON output; it does not
read or display mesh, app, or device keys.

The first run installs Textual into a private venv under
`~/Library/Application Support/amaran-cli/python/tui` if Textual is not already
available to `python3`. It detects the terminal background color with an OSC 11
query and falls back to macOS appearance when the terminal does not answer.
Use `./bin/amaran ui --theme dark` or `--theme light` to override detection.
Use `AMARAN_TUI_VENV=/path/to/venv` to choose another venv, or
`AMARAN_TUI_BOOTSTRAP=0` if you want dependency setup to fail fast.
Refresh-all uses a short per-fixture status timeout so stale fixtures are
marked as errors quickly instead of making the interface feel stuck; override
it with `AMARAN_TUI_STATUS_TIMEOUT=<seconds>`.
Brightness, CCT, and G/M controls update the screen immediately and debounce
runtime sends so dragging sliders or repeated keypresses collapse into one
command; override the wait with `AMARAN_TUI_DEBOUNCE=<seconds>`.

Useful keys:

| Key | Action |
| --- | --- |
| `q` | Quit. |
| `r` / `R` | Refresh selected fixture / all fixtures. |
| `space` | Toggle selected fixture on or off. |
| `x` | Include or exclude the selected fixture from the next scene capture. |
| `+` / `-` | Brightness up or down by 1%. |
| `[` / `]` | CCT down or up by 100K. |
| `{` / `}` | CCT down or up by 500K. |
| `g` / `m` | Green/magenta correction down or up by 1. |
| Arrow keys | Adjust the focused brightness, CCT, or G/M slider. |
| `i` | Identify the selected fixture. |
| `a` | Apply the selected scene. |
| `c` | Capture checked fixtures into the scene name field. |

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
node reset are unavailable for control-only fixtures. This command expects you
to supply keys yourself; use `sidus-import` for the local iPad backup path. See
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

For the nRF52840 DK join probe, read a redacted capture summary with:

```sh
scripts/read-dk-capture
```

The live iPad attempt loop is:

```sh
scripts/dk-sidus-attempt prepare
# Run the Sidus Link Pro add-fixture flow.
scripts/dk-sidus-attempt read --output /private/tmp/amaran-dk-sidus-attempt.hex
```

If the DK capture contains both NetKey and AppKey, convert it into a
`state-join` source without printing keys:

```sh
scripts/dk-capture-to-state-join --capture /private/tmp/amaran-dk-capture.hex --output /private/tmp/sidus-join.json --fixture 2=Key
./bin/amaran state-join /private/tmp/sidus-join.json
```

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
set. That target can be either a node address or a friendly name:

```sh
./bin/amaran fixture rename 18 tube-left
./bin/amaran intensity 18 --node tube-left
AMARAN_NODE_ID=tube-left ./bin/amaran status
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
They prefer the auto-started local daemon for speed and fall back to the
one-shot helper path if the daemon cannot be reached.

| Command | Purpose |
| --- | --- |
| `./bin/amaran list [--json]` | Print fixture names, node addresses, and MACs or `unknown` from local state. |
| `./bin/amaran probe [--node <id-or-name>] [--json]` | Connect to the matching Mesh Proxy advertisement using the Network ID from local state. |
| `./bin/amaran status [--node <id-or-name>] [--json]` | Read and decode the vendor CCT status packet. |
| `./bin/amaran identify [<id-or-name>] [--node <id-or-name>] [--json]` | Blink the selected fixture three times, then restore its previous on/off, intensity, and CCT state. |
| `./bin/amaran on [--node <id-or-name>]` | Send Telink vendor on. |
| `./bin/amaran off [--node <id-or-name>]` | Send Telink vendor off. |
| `./bin/amaran intensity <0-100> [--node <id-or-name>]` | Send Telink brightness in percent. |
| `./bin/amaran cct <kelvin> [--intensity <0-100>] [--gm <0-20>] [--node <id-or-name>]` | Send Telink CCT. The CLI clamps known fixture-family CCT ranges and reads status only when needed to preserve omitted intensity or supported green-magenta state. |
| `./bin/amaran gm <0-20> [--node <id-or-name>]` | Send Sidus-style green-magenta correction while preserving current CCT and intensity. `10` is neutral, lower is greener, higher is more magenta. Fails for fixture families without G/M support. |
| `./bin/amaran daemon [start\|status\|stop] [--json]` | Start, inspect, or stop the local runtime daemon without sending fixture control commands. Runtime commands auto-start it when needed. |
| `./bin/amaran ui` | Open the Textual terminal control surface for fixtures and scenes. |

State and pairing commands manage local state and fixture setup.

| Command | Purpose |
| --- | --- |
| `./bin/amaran doctor [--json]` | Inspect local state, safe runtime counters, and control readiness. |
| `./bin/amaran pair [--add] [--attention <0-255>] [--dry-run] [--verify] [--json]` | Provision an unprovisioned fixture, configure it for vendor control, and write local state. Creates the first manifest, or appends to the existing studio manifest with `--add`. |
| `./bin/amaran sidus-import --backup <path> [--mesh <selector>] [--replace] [--json]` | Import mesh keys and fixture metadata from an iPad Sidus Link Pro backup or extracted app container. Writes redacted output only. |
| `./bin/amaran join-capture --output-state <capture.json> [--timeout <sec>] [--json]` | Experimental no-reset diagnostic. Advertises this Mac as an unprovisioned Mesh node and captures provisioning credentials from Sidus Link Pro. Output is redacted; the capture file is key-bearing. |
| `./bin/amaran state-join <join-state.json> [--json]` | Join an existing mesh for runtime control from externally supplied NetKey/AppKey metadata. Writes control-only fixture state when DeviceKeys are absent. |
| `./bin/amaran state-install <source-state.json> [--json]` | Validate and install a state file with `0600` permissions. Refuses to overwrite existing target state. |
| `./bin/amaran discover --range <spec> [--update-state] [--json]` | Probe candidate unicast addresses on the current mesh and optionally keep responsive control-only fixture entries. |
| `./bin/amaran fixture rename <node> <friendly-name> [--json]` | Store a CLI-only friendly name for a fixture. Names are safe to print and do not change Sidus metadata. |
| `./bin/amaran fixture clear-name <node> [--json]` | Remove a CLI-only friendly name and fall back to the imported source name. |
| `./bin/amaran scene capture <name> [--node <id-or-name>]... [--off-node <id-or-name>]... [--json]` | Read live status from fixtures and save a named scene in local state. Repeat `--node` for a selected fixture set; use `--off-node` to record a fixture as off without reading status. |
| `./bin/amaran scene apply <name> [--node <id-or-name>]... [--json]` | Apply a saved scene through direct runtime commands. With `--node`, apply only matching fixture entries. |
| `./bin/amaran scene list [--json]` | List saved scenes without launching BLE. |
| `./bin/amaran scene show <name> [--json]` | Show one saved scene without launching BLE. |

Diagnostic commands are lower-level tools for discovery, provisioning, control
packet testing, and Config Client work.

| Command | Purpose |
| --- | --- |
| `./bin/amaran gatt-probe [--all-services] [--read-values] [--json]` | Discover Mesh Proxy and Provisioning GATT services. `--all-services` dumps the selected peripheral's full service list; `--read-values` reads safe readable characteristic values. |
| `./bin/amaran provision-scan [--json]` | Scan for unprovisioned PB-GATT advertisers without writing provisioning PDUs. |
| `./bin/amaran provision-invite-test [--attention <0-255>] [--json]` | Send only Provisioning Invite and decode Capabilities. |
| `./bin/amaran provision-test [--add] [--attention <0-255>] [--json]` | Run no-OOB PB-GATT provisioning and write or append state, without post-provision configuration. |
| `./bin/amaran pair-test [--add] [--attention <0-255>] [--dry-run] [--verify] [--json]` | Diagnostic alias for provisioning plus post-provision configuration. |
| `./bin/amaran monitor [--node <id-or-name>] [--timeout <sec>] [--json]` | Subscribe to Mesh Proxy notifications for reverse-engineering runtime packets. It writes a proxy reject-list filter first so application traffic is forwarded. JSON output may include raw access parameters, but not mesh keys. |
| `./bin/amaran proxy-test [--json]` | Write a public sample Mesh Proxy PDU. |
| `./bin/amaran sig-onoff-test <on\|off> [--node <id-or-name>] [--json]` | Send a standard Generic OnOff test PDU. The 60x S does not apply this to emitter output. |
| `./bin/amaran control-test <on\|off\|intensity\|cct\|raw> [value] [--intensity <0-100>] [--gm <0-20>] [--node <id-or-name>] [--json]` | Send reconstructed Telink `0x26` control payloads. `control-test cct` accepts `--gm`; `raw` accepts a checksummed 10-byte Telink packet hex for controlled reverse-engineering only. |
| `./bin/amaran status-test [--node <id-or-name>] [--json]` | Read and decode Telink `0x26` status. |
| `./bin/amaran configure-test [--node <id-or-name>] [--json]` | Fetch composition, ensure AppKey index 0, and bind the vendor model. |
| `./bin/amaran config-composition-get-test [--node <id-or-name>] [--json]` | Fetch and store Composition Data Page 0. |
| `./bin/amaran config-appkey-get-test [--node <id-or-name>] [--json]` | Read safe AppKey index metadata. |
| `./bin/amaran config-appkey-add-test [--node <id-or-name>] [--json]` | Send segmented DeviceKey Config AppKey Add. |
| `./bin/amaran config-model-app-bind-test [--node <id-or-name>] [--json]` | Bind AppKey index 0 to the first vendor model. |
| `./bin/amaran config-node-reset-test --dry-run [--node <id-or-name>] [--json]` | Validate the selected fixture and print a redacted reset preview. |
| `./bin/amaran config-node-reset-test --confirm-reset [--node <id-or-name>] [--json]` | Send destructive DeviceKey Config Node Reset. Treat existing state for that fixture as stale afterward. |

Global options:

| Option | Meaning |
| --- | --- |
| `--node <id-or-name>` | Fixture node address or friendly name. Defaults to `AMARAN_NODE_ID`, then the only fixture in local state. |
| `--timeout <sec>` | BLE helper timeout. Defaults to `AMARAN_TIMEOUT` or `20`. |
| `--attention <sec>` | Provisioning Invite attention duration from `0` to `255`. Defaults to `AMARAN_ATTENTION_DURATION` or `0`. |
| `--add` | For `pair`/`provision-test`, append an unprovisioned fixture to the existing studio manifest instead of creating a new mesh. |
| `--state-path <p>` | Local CLI state file. Defaults to `AMARAN_CLI_STATE_PATH` or `~/Library/Application Support/amaran-cli/state.json`. |
| `--output-state <p>` | Secret capture output for `join-capture`. The file is created with `0600` permissions and is never printed. |
| `--backup <path>` | iPad backup or extracted Sidus app container for `sidus-import`. |
| `--mesh <selector>` | Pick a Sidus mesh by name, UUID, or mesh file path substring. |
| `--replace` | For `sidus-import`, overwrite the target CLI state file. |
| `--range <spec>` | Address range for `discover`, such as `2-32` or `2-8,12`. |
| `--update-state` | For `discover`, keep newly responsive fixture entries in local state. |
| `--gm <0-20>` | Green-magenta correction for CCT-capable fixtures. `10` is neutral, lower is greener, higher is more magenta. |
| `--dry-run` | For `pair`, preflight and scan only. For node reset, validate and print the selected fixture without sending reset. |
| `--verify` | For `pair`, read status after provisioning/configuration. |
| `--confirm-reset` | Required for destructive Config Node Reset. |
| `--all-services` | For `gatt-probe`, discover all advertised services after selecting a mesh peripheral. |
| `--read-values` | For `gatt-probe`, read safe readable characteristic values. |
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
  builders for on/off, brightness, CCT/green-magenta control, and status reads.
- Sidus Link Pro has been observed controlling tube green/magenta tint through
  the same Telink CCT packet used for Kelvin/intensity, with GM values in the
  `0..20` range. The CLI exposes this as `gm` and `cct --gm`. Tubes also return
  Telink command type `0x0a` packets that look like hue/saturation status; those
  fields remain diagnostic until an RGB setter is confirmed.

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
