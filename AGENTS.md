# AGENTS

## Project Notes

This repo is a local CLI for controlling owned amaran fixtures from macOS
without relying on the vendor desktop app at runtime. The CLI wraps a small
signed app bundle so CoreBluetooth permissions work, keeps project-owned mesh
state, and uses Mesh Proxy for runtime control/status. Pairing
has been validated on the owned amaran 60x S. The old desktop database import
and helper fallback paths have been removed.

Useful commands:

- `./bin/amaran doctor`
- `./bin/amaran doctor --json`
- `./bin/amaran pair [--add] [--attention <0-255>] [--dry-run] [--verify]`
- `./bin/amaran pair [--add] [--attention <0-255>] [--dry-run] [--verify] --json`
- `./bin/amaran gatt-probe`
- `./bin/amaran gatt-probe --json`
- `./bin/amaran provision-scan`
- `./bin/amaran provision-scan --json`
- `./bin/amaran provision-invite-test [--attention <0-255>]`
- `./bin/amaran provision-invite-test [--attention <0-255>] --json`
- `./bin/amaran provision-test [--add] [--attention <0-255>]`
- `./bin/amaran provision-test [--add] [--attention <0-255>] --json`
- `./bin/amaran pair-test [--add] [--attention <0-255>] [--dry-run] [--verify]`
- `./bin/amaran pair-test [--add] [--attention <0-255>] [--dry-run] [--verify] --json`
- `./bin/amaran monitor [--node <id|name>] [--timeout <sec>]`
- `./bin/amaran monitor [--node <id|name>] [--timeout <sec>] --json`
- `./bin/amaran proxy-test`
- `./bin/amaran proxy-test --json`
- `./bin/amaran sig-onoff-test <on|off>`
- `./bin/amaran sig-onoff-test <on|off> --json`
- `./bin/amaran control-test <on|off|intensity|cct|raw> [value] [--intensity <0-100>] [--gm <0-20>]`
- `./bin/amaran control-test <on|off|intensity|cct|raw> [value] --json`
- `./bin/amaran status-test`
- `./bin/amaran status-test --json`
- `./bin/amaran configure-test`
- `./bin/amaran configure-test --json`
- `./bin/amaran config-composition-get-test`
- `./bin/amaran config-composition-get-test --json`
- `./bin/amaran config-appkey-get-test`
- `./bin/amaran config-appkey-get-test --json`
- `./bin/amaran config-appkey-add-test`
- `./bin/amaran config-appkey-add-test --json`
- `./bin/amaran config-model-app-bind-test`
- `./bin/amaran config-model-app-bind-test --json`
- `./bin/amaran config-node-reset-test --dry-run`
- `./bin/amaran config-node-reset-test --dry-run --json`
- `./bin/amaran config-node-reset-test --confirm-reset`
- `./bin/amaran config-node-reset-test --confirm-reset --json`
- `./bin/amaran join-capture --output-state <capture.json> [--timeout <sec>]`
- `./bin/amaran join-capture --output-state <capture.json> [--timeout <sec>] --json`
- `./bin/amaran sidus-import --backup <path> [--mesh <selector>] [--replace]`
- `./bin/amaran sidus-import --backup <path> [--mesh <selector>] [--replace] --json`
- `./bin/amaran state-join <join-state.json>`
- `./bin/amaran state-join <join-state.json> --json`
- `./bin/amaran state-install <source-state.json>`
- `./bin/amaran state-install <source-state.json> --json`
- `./bin/amaran discover --range <start-end[,addr]> [--update-state]`
- `./bin/amaran discover --range <start-end[,addr]> [--update-state] --json`
- `./bin/amaran fixture rename <node> <friendly-name>`
- `./bin/amaran fixture rename <node> <friendly-name> --json`
- `./bin/amaran fixture clear-name <node>`
- `./bin/amaran fixture clear-name <node> --json`
- `./bin/amaran scene capture <name> [--node <id-or-name>]... [--off-node <id-or-name>]...`
- `./bin/amaran scene capture <name> --json`
- `./bin/amaran scene apply <name> [--node <id-or-name>]...`
- `./bin/amaran scene apply <name> --json`
- `./bin/amaran scene list`
- `./bin/amaran scene list --json`
- `./bin/amaran scene show <name>`
- `./bin/amaran scene show <name> --json`
- `./bin/amaran daemon [start|status|stop]`
- `./bin/amaran daemon [start|status|stop] --json`
- `./bin/amaran ui`
- `./bin/amaran list`
- `./bin/amaran probe`
- `./bin/amaran status`
- `./bin/amaran identify [<id-or-name>]`
- `./bin/amaran identify [<id-or-name>] --json`
- `./bin/amaran on`
- `./bin/amaran off`
- `./bin/amaran intensity <0-100>`
- `./bin/amaran cct <kelvin> [--intensity <0-100>] [--gm <0-20>]`
- `./bin/amaran gm <0-20>`

Implementation notes:

- CLI state is a JSON studio manifest that lives in
  `~/Library/Application Support/amaran-cli/state.json`.
- The preferred Sidus-owned studio workflow is: pair/organize fixtures in Sidus
  Link Pro on the iPad, create an encrypted local iPad backup, run
  `./bin/amaran sidus-import --backup <path>`, then use direct CLI runtime
  commands and `scene` commands. This keeps the iPad as pairing source of truth.
- `list`, `probe`, `status`, `identify`, `on`, `off`, `intensity`, `cct`, and `gm` are direct
  runtime commands. They require local CLI state and must not silently fall back
  to third-party app databases or helper bundles.
- `status`, `identify`, `on`, `off`, `intensity`, `cct`, and `gm` should prefer the
  auto-started local runtime daemon in `BluetoothProbe.app` when available.
  The daemon listens only on localhost, writes non-secret port metadata under
  `~/Library/Application Support/amaran-cli/daemon.json`, keeps CoreBluetooth
  alive, and may reuse a Mesh Proxy connection for repeated commands. Set
  `AMARAN_DAEMON_DISABLE=1` to force the older one-shot helper path.
- `./bin/amaran ui` launches `scripts/amaran-tui`, a Textual terminal control
  surface backed by safe CLI JSON output. It should not read or print
  mesh/app/device keys directly. It may auto-install Textual into a private
  venv under `~/Library/Application Support/amaran-cli/python/tui`; set
  `AMARAN_TUI_VENV` to override that path or `AMARAN_TUI_BOOTSTRAP=0` to
  disable automatic dependency setup. Refresh-all uses
  `AMARAN_TUI_STATUS_TIMEOUT`, defaulting to the lower of `AMARAN_TIMEOUT` and
  5 seconds, so stale fixtures do not make the interface feel stuck. Theme
  defaults to auto detection: OSC 11 terminal background query first, then
  macOS appearance fallback. `AMARAN_TUI_THEME` or `--theme <auto|dark|light>`
  can override it. TUI brightness, CCT, and G/M controls update locally first
  and debounce runtime sends from sliders and rapid keypresses;
  `AMARAN_TUI_DEBOUNCE` defaults to 0.35 seconds.
  TUI scene capture uses a single fixture-table checkbox: `cap` includes a
  fixture in the next capture, and included fixtures currently shown as off are
  recorded with `--off-node` instead of reading live status. Scene rows apply
  on activation, so no separate apply button is required.
- `./bin/amaran fixture rename <node> <friendly-name>` stores a CLI-only
  `friendly_name` on the selected fixture. Runtime commands, diagnostics, and
  scene commands should accept that friendly name anywhere `--node` is accepted.
  It must preserve the imported/source `name`, refuse duplicate or numeric
  friendly names, write state with `0600`, and avoid printing key material.
  `fixture clear-name <node>` removes only the local `friendly_name`.
- `./bin/amaran identify [<id-or-name>]` reads vendor status, blinks the
  selected fixture three times, then restores the previous on/off, intensity,
  CCT, and green-magenta state. It should use direct runtime commands, accept
  friendly names, and avoid printing key material. After the initial status
  read, it should send the blink/restore commands as one batched helper control
  sequence so it does not repeatedly scan/connect for each flash step.
- `doctor` runs directly in the wrapper. It reports local state, safe runtime
  counters, and control readiness without launching BLE. It does not print key
  material.
- `./bin/amaran pair` is the stable guarded pairing command. Without `--add`,
  it creates the first studio manifest and must refuse to overwrite an existing
  state file. With `--add`, it reuses the existing mesh keys and appends one
  newly provisioned fixture without dropping old fixtures. It must avoid
  printing generated or existing keys.
  `pair --dry-run` checks the create guard plus state-path writability. `pair
  --add --dry-run` validates that the existing manifest is usable and writable.
  Both dry-run modes then run only the safe unprovisioned-device
  scan; they must not send provisioning PDUs or write CLI state. `pair
  --verify` performs a status read after provisioning/configuration and
  should remain incompatible with `--dry-run`. Pairing retries the
  post-provision Config sequence because Mesh Proxy advertising may lag
  immediately after Provisioning Complete.
- In add mode, the wrapper must configure and optionally verify the newly
  provisioned node address returned by provisioning. This avoids accidental
  configuration of an older fixture when the manifest contains multiple
  fixtures.
- `--state-path <file>` is the CLI equivalent of `AMARAN_CLI_STATE_PATH`. Use it
  when testing pairing against an alternate state file instead of
  moving or overwriting the real one.
- `./bin/amaran state-install <source-state.json>` validates and installs a
  local state file into the configured target state path. It must keep refusing
  to overwrite an existing target state file, validate key hex lengths and
  runtime counters, write `0600`, and print only redacted fixture
  summaries.
- `./bin/amaran sidus-import --backup <path>` imports Sidus Link Pro mesh JSON
  from an encrypted local iPad backup, an unencrypted backup, or an extracted
  Sidus app container into normal CLI state. It must refuse to overwrite target
  state unless `--replace` is passed, write `0600`, and print only redacted
  fixture summaries. Encrypted backup import uses `iphone_backup_decrypt` and
  prompts for the backup password unless `AMARAN_IOS_BACKUP_PASSWORD` is set.
  If that package is missing, the importer may create a private venv under
  `~/Library/Application Support/amaran-cli/python/ios-backup-import`; set
  `AMARAN_IOS_BACKUP_IMPORT_VENV` to override that path for tests. It must not
  print NetKey, AppKey, DeviceKeys, or backup passwords.
- `./bin/amaran state-join <join-state.json>` converts externally supplied
  NetKey/AppKey/fixture-address metadata into CLI state for runtime control of
  an existing mesh. It must refuse to overwrite target state, write `0600`, and
  print only redacted fixture summaries. It does not extract keys from Sidus
  Link Pro or amaran Desktop. Fixtures imported without DeviceKeys are
  control-only: `list`, `probe`, `status`, `on`, `off`, `intensity`, and `cct`
  can work, but Config diagnostics and node reset must fail before sending
  DeviceKey traffic for those fixtures.
- `./bin/amaran discover --range <spec>` probes candidate fixture unicast
  addresses on the current imported mesh using batched vendor status reads. The
  normal repo path should launch `BluetoothProbe.app` once, reserve a sequence
  block, send the whole range over one Mesh Proxy connection, and update state
  once. It may advance sequence counters. Without `--update-state`, discovered
  candidate fixtures must not remain in state; with `--update-state`,
  responsive new addresses may remain as control-only fixtures. It cannot
  recover new DeviceKeys, names, MACs, groups, or Sidus scenes; use a fresh
  Sidus backup import for that metadata. If the scan range includes the
  CLI-owned Config source address, discovery should relocate that source address
  before probing so a later iPad-assigned fixture at that address is not
  skipped. Because discovery uses the same status read as `status`,
  programmatically off/asleep fixtures may not answer until woken. The script
  may keep its old sequential path only as a fallback for tests or environments
  without the app bundle.
- `./bin/amaran scene capture <name>` reads live vendor status from fixtures and
  stores a local named scene in the top-level `scenes` object. Repeated
  `--node <id-or-name>` captures a selected fixture set. Repeated
  `--off-node <id-or-name>` records selected fixtures as off without sending a
  status read, which avoids failures from intentionally off/asleep fixtures. If
  `--off-node` is passed without any `--node`, capture only those forced-off
  fixtures rather than every other fixture in state.
  `scene apply` restores saved intensity/CCT/green-magenta/sleep state through
  direct runtime commands. For saved-on entries, it should send `on` before the
  saved intensity/CCT/green-magenta command so programmatically off fixtures
  wake before restore. For saved-off entries, it sends only `off`. With
  `--node`, it applies only matching fixture entries. `scene list` and
  `scene show` are offline reads. Scene commands must not print
  mesh/app/device keys.
- Fixture capabilities are safe metadata and may be inferred from source model
  names when local state does not contain explicit capabilities. Known
  `400M5-*` fixtures are CCT-only, clamp to `2700-6500K`, and do not support
  green-magenta correction. `list --json` may expose these non-secret
  capabilities so the TUI can clamp sliders and hide unsupported controls.
- `./bin/amaran join-capture --output-state <capture.json>` is experimental.
  It launches `BluetoothProbe.app` as a CoreBluetooth peripheral that advertises
  Mesh Provisioning service `0x1827` and behaves as a dummy no-OOB provisionee.
  If Sidus Link Pro provisions it, the requested capture file receives the mesh
  NetKey plus the dummy node DeviceKey with `0600` permissions. The wrapper and
  helper output must remain redacted and must not print NetKey, DeviceKey, or
  session keys. This is not enough for runtime control until the mesh AppKey is
  also captured or supplied by another path.
- `./bin/amaran config-node-reset-test --confirm-reset` is destructive.
  It sends DeviceKey Config Node Reset to an owned fixture using local CLI
  state. Do not run it without explicit user approval. The wrapper and Bluetooth
  helper both require `--confirm-reset`. After it succeeds, treat the existing
  state for that fixture as stale and test pairing with an alternate
  `--state-path` before installing any new state.
- `./bin/amaran config-node-reset-test --dry-run` is safe and does not
  launch BLE. It validates local keys, runtime counters, source address, and the
  selected fixture, then prints only a redacted summary of the fixture that would
  be reset.
- Commands reserve sequence numbers in CLI state. DeviceKey Config sends
  use a CLI-owned source address, preferring address `3` or the next unused
  unicast address.
  Telink vendor runtime control/status uses a separate source
  address, normally `1`, because the 60x S sends vendor CCT status replies back
  to that address.
- CLI-provisioned state may not contain a real BLE MAC address because macOS
  CoreBluetooth does not expose it. The runtime does not need that MAC.
- `probe` matches the advertised Mesh Proxy Network ID computed from local CLI
  state. `cct` reads status to preserve any omitted intensity or GM value.
  `gm` reads status first so it can preserve current CCT and intensity.
- The state file contains mesh/app/device keys. Do not print, log in
  final answers, commit, or share that state file or any keys from it.
- Safe output may include fixture counts, names, node addresses, model codes,
  and MAC suffixes only.
- The working control path is the Telink vendor opcode `0x26`, reproduced by
  the Mesh Proxy backend.
- Standard Bluetooth Mesh `Generic OnOff`, `Light Lightness`, and `Light CTL`
  packets can be transmitted, but the amaran 60x S does not apply them to the
  emitter output.
- Telink brightness uses `0..1000` intensity units. Telink CCT uses Kelvin
  divided by 10. Color-capable tubes have been observed using the same Telink
  CCT packet for Sidus-style green-magenta correction in the `0..20` range;
  `10` is neutral, lower is greener, and higher is more magenta.
- Telink command type `0x0a` has been observed on color-capable tubes as a
  color-status-looking packet. The CLI decodes likely hue/saturation fields as
  diagnostic candidates only; a stable RGB color setter is not confirmed yet.
- `./bin/amaran status` reads the vendor `CCTPacket`, preferring the
  Mesh Proxy status query. After `off`, status may time out because the fixture
  can stop answering menu queries while asleep.

Development notes:

- Rebuild and sign the CoreBluetooth helper with
  `npm run build:bluetooth-helper`. The default ad-hoc signature embeds a stable
  local designated requirement for `dev.local.bluetooth-probe`; set
  `AMARAN_CODESIGN_IDENTITY` to use a real signing identity instead.
- `./bin/amaran gatt-probe` launches `BluetoothProbe.app` and uses
  CoreBluetooth directly to discover Mesh Proxy/Provisioning GATT services.
- `./bin/amaran provision-scan` launches `BluetoothProbe.app`, scans only
  Mesh Provisioning service `0x1827`, decodes safe unprovisioned service data
  such as device UUID, OOB info, and URI hash, and discovers Provisioning Data
  In/Out `0x2ADB`/`0x2ADC` when a device is connectable. It must not write
  provisioning PDUs or create keys.
- `./bin/amaran provision-invite-test` launches `BluetoothProbe.app`,
  scans Mesh Provisioning service `0x1827`, subscribes to Provisioning Data Out
  `0x2ADC`, writes only the initial Invite PDU to Provisioning Data In `0x2ADB`,
  and decodes the returned Capabilities PDU. It must not create keys, send
  Provisioning Data, or write CLI state.
- `./bin/amaran provision-test` launches `BluetoothProbe.app`, scans Mesh
  Provisioning service `0x1827`, runs the no-OOB PB-GATT provisioning exchange,
  and writes CLI state only after Provisioning Complete. In create mode it
  generates fresh local NetKey/AppKey/provisioner material and refuses to start
  if the target state file already exists or the target state path is not
  writable. With `--add`, it loads the existing manifest, reuses its NetKey,
  AppKey, and IV index, chooses an unused fixture node address, and appends the
  new fixture. It must not print generated or existing keys. Run
  `configure-test` afterward to perform the post-provisioning Config
  AppKey Add / Model App Bind phase needed for vendor control.
- `./bin/amaran pair-test` wraps `provision-test`, waits briefly for the Mesh
  Proxy advertisement, then runs `configure-test` with retries against the
  newly written or appended fixture. It must not print generated or existing
  keys. This flow has been validated on the owned amaran 60x S after a Config
  Node Reset; broader fixture coverage is still unknown.
- `./bin/amaran proxy-test` launches `BluetoothProbe.app`, subscribes to
  Mesh Proxy Data Out `0x2ADE`, and writes a public sample Proxy PDU to Mesh
  Proxy Data In `0x2ADD`. It does not use local mesh keys or control the light.
- `./bin/amaran monitor` launches `BluetoothProbe.app`, subscribes to Mesh
  Proxy Data Out `0x2ADE`, writes a Proxy Configuration Set Filter Type
  message for an empty reject-list filter, and captures/decrypts forwarded
  runtime traffic for packet reverse engineering. It may include raw access
  parameters in JSON output, but must not print mesh/app/device keys.
- `./bin/amaran sig-onoff-test <on|off>` launches `BluetoothProbe.app`,
  reads CLI state, reserves and persists the next sequence number,
  matches the advertised Mesh Proxy Network ID, and writes a locally-keyed
  standard Generic OnOff Set Unacknowledged Proxy PDU. It should not change the
  60x S emitter output because standard SIG control is not the working vendor
  path. JSON output may include decoded source/destination/opcode metadata, but
  must not include keys or raw access parameters.
- `./bin/amaran control-test <on|off|intensity|cct|raw>` launches
  `BluetoothProbe.app`, reads CLI state, reserves and persists the next
  sequence number, and writes a locally-keyed Telink `0x26` control Proxy
  PDU. The test command still requires `--intensity` for `cct`; it accepts
  optional `--gm <0-20>`. The stable `cct` command can preserve current
  intensity and GM by reading status first. `raw` accepts exactly one
  checksummed 10-byte Telink packet hex and is for controlled fixture reverse
  engineering only. JSON output must not include keys or raw access parameters
  except for `monitor`, where raw access parameters are the requested
  diagnostic output.
- `./bin/amaran status-test` launches `BluetoothProbe.app`, reads CLI
  state, reserves and persists the next sequence number, sends the
  Telink `0x26` read-data request from the Telink runtime source address, and
  decodes the returned CCT packet. JSON output may include safe
  transport/status metadata, but must not include keys.
- `./bin/amaran config-composition-get-test` launches
  `BluetoothProbe.app`, reads CLI state, reserves and persists one
  sequence number, sends Config Composition Data Get with the fixture DeviceKey,
  reassembles the segmented DeviceKey response, and stores Composition Data Page
  0 back into CLI state. After a complete segmented response, it reserves one
  more sequence number and sends a lower-transport Segment
  Acknowledgment back to the fixture. It must not print keys.
- `./bin/amaran config-appkey-get-test` launches `BluetoothProbe.app`,
  reads CLI state, reserves and persists one sequence number,
  sends Config AppKey Get with the fixture DeviceKey, and decodes Config AppKey
  List as safe key-index metadata only. It must not print keys.
- `./bin/amaran config-appkey-add-test` launches `BluetoothProbe.app`,
  reads CLI state, reserves and persists the segmented sequence range,
  sends Config AppKey Add with the stored AppKey using the fixture
  DeviceKey from the CLI-owned source address, retries the already-reserved
  segmented Proxy PDUs while waiting for the lower transport Segment
  Acknowledgment, and reports safe aggregate ack metadata. It must not print
  keys.
- `./bin/amaran config-model-app-bind-test` launches `BluetoothProbe.app`,
  parses stored Composition Data Page 0, selects the first vendor model, reserves
  and persists one sequence number, and sends Config Model App Bind for AppKey
  index 0 with the fixture DeviceKey. Config diagnostics may summarize DeviceKey
  access responses, including Config Composition Data Status, Config AppKey
  List/Status, and Config Model App Status, but must not print the DeviceKey.
- `./bin/amaran configure-test` chains the current Config steps
  from local state: Composition Data Get, AppKey Get, optional AppKey Add when
  AppKey index 0 is absent, and Model App Bind. `pair-test` wraps
  provisioning and configuration into one guarded command for unprovisioned
  fixtures, but it is still a diagnostic flow rather than polished pairing UI.
- `./bin/amaran join-capture` uses the helper's peripheral-manager path, not the
  central Mesh Proxy path. It advertises only the Mesh Provisioning service UUID
  and local name because macOS CoreBluetooth does not expose the full service
  data advertisement real fixtures normally use. Sidus Link Pro may require
  service data or fixture-specific identity filtering, so failure to appear in
  the iPad app is a known possible outcome.
- `BluetoothProbe.app` has a top-level timeout guard so commands should
  return a safe CoreBluetooth state error instead of hanging if Bluetooth never
  becomes available.
- `BluetoothProbe.app` can write a sequence of Proxy PDUs. The
  provisioning test uses this for segmented Public Key and Provisioning Data
  writes. It can also reassemble segmented PB-GATT provisioning notifications
  into safe summaries and decode Mesh Proxy Segment Acknowledgment control
  metadata.
  Internal helper flag `--expect-segment-ack <SeqZero> <SegN>` waits for the
  matching acknowledgment and reports safe aggregate ack metadata.
- For the nRF52840 DK Sidus join probe, use `scripts/read-dk-capture` to read
  and decode the current `amaran_capture_state` block. It finds the symbol
  address from the current Zephyr ELF and prints only redacted metadata. Raw
  capture files may contain mesh keys if capture succeeds; keep them in
  `/private/tmp` or another private location and never commit them.
  `scripts/read-dk-capture --clear` writes the capture clear marker, resets the
  DK, and verifies a clean capture header. Use it before a fresh Sidus attempt,
  not after an attempt that may have captured keys. If a capture has both NetKey
  and AppKey, `scripts/dk-capture-to-state-join --capture <capture.hex>
  --output <join.json> --fixture <addr[=name]>` converts it into the
  key-bearing `state-join` source format with `0600` permissions and redacted
  output. The converter cannot infer real fixture unicast addresses from the DK
  capture; pass each real fixture address explicitly.
  `scripts/dk-sidus-attempt prepare|read|convert` wraps the same steps for the
  human-in-the-loop Sidus trial. The current DK firmware raises ATT/L2CAP MTU
  support so the 65-byte Provisioning Public Key response can be sent as one
  `len=66 mtu=247` PB-GATT notification. This was added after Sidus reached
  Invite, Start, and provisioner Public Key, then disconnected immediately after
  the first 30-byte segmented DK Public Key notification.
- If commands fail immediately with `central_state unauthorized`, macOS
  Bluetooth permission for `BluetoothProbe.app` likely needs to be re-enabled.
  Older ad-hoc builds used changing `cdhash` requirements, so an existing denied
  or stale permission entry may need to be reset once.
- Mesh crypto, provisioning parser, access, transport, Network PDU, and Proxy
  PDU vector tests now cover offline no-OOB provisioning transcript assembly,
  no-OOB session sequencing, PB-GATT SAR segmentation/reassembly, incoming
  provisioning notification reassembly, Confirmation/Random PDU handling,
  encrypted Provisioning Data framing, post-provision Config access-message
  builders, DevKey proxy wrapping for Config messages, segmented lower transport
  access PDU assembly/reassembly, Composition Data Status decoding, Config
  AppKey List decoding, Segment Acknowledgment building/decoding, and fake-key
  `state.json` payload construction:
  `swiftc native_mesh_crypto.swift native_mesh_config.swift native_mesh_provisioning.swift native_mesh_state.swift native_telink_control.swift tests/native_mesh_crypto_tests.swift -o /tmp/amaran-mesh-tests`
  then `/tmp/amaran-mesh-tests`.
- Run `npm test` for the default local regression gate. It combines
  `test:cli-wrapper` with `test:mesh`.
- Test non-BLE CLI wrapper guards with `npm run test:cli-wrapper`. This covers
  `pair --dry-run`, `--state-path`, help text, and invalid `--dry-run`
  routing without launching `BluetoothProbe.app`, and checks that fake
  mesh/app/device keys are not printed by safe wrapper commands.
- For TUI-only syntax checks, run
  `python3 -m py_compile scripts/amaran-tui scripts/scene-store`; this does
  not install Textual or launch BLE.
- Config AppKey Add is longer than one unsegmented access message after TransMIC;
  send it only through the Config AppKey Add diagnostic, which uses the
  segmented send path and waits for the expected Segment Acknowledgment.
- In Codex, `./bin/amaran` may need elevated execution because it launches a
  macOS app bundle. In a normal terminal it should run directly.
- One-shot helper commands launch `BluetoothProbe.app` with `open -n -W` so
  they do not attach to the long-lived daemon instance and silently ignore the
  one-shot arguments.

## Solo Integration

This project uses [Solo](https://soloterm.com) to manage development processes.

### Available MCP Tools

When Solo is running with MCP enabled, use these tools:

| Tool | Description |
|------|-------------|
| `list_projects` | List Solo projects |
| `get_project` | Read metadata for the effective project scope |
| `create_project` | Register or import an existing local directory without opening app onboarding UI |
| `delete_project` | Delete the effective Solo project after explicit confirmation, optionally converting project prompt templates to global |
| `select_project` | Set the default project scope for later MCP tools |
| `rename_project` | Set or clear the display name for the effective project scope |
| `get_project_status` | Read project metadata and current processes for the effective project scope |
| `list_processes` | List process entries in the effective project scope |
| `get_process_status` | Read detailed status for one process |
| `rename_process` | Rename a process in the Solo UI |
| `select_process` | Select a process in the Solo UI so its terminal surface is attached and rendered |
| `start_process` | Start one existing Solo process entry by name or Solo process ID; this can start a stored command, terminal, or agent |
| `stop_process` | Gracefully stop one running process by name or ID |
| `restart_process` | Restart one existing Solo process entry by name or Solo process ID; this can restart a stored command, terminal, or agent |
| `close_process` | Remove one stored Solo terminal or Solo agent by name or Solo process ID |
| `get_process_output` | Read recent rendered terminal output from one process |
| `search_output` | Search rendered terminal output from one process |
| `get_process_raw_output` | Read recent raw terminal output from one process |
| `search_raw_output` | Search raw terminal output from one process |
| `clear_output` | Clear Solo's saved output for one process |
| `send_input` | Send text or raw bytes to one running process |
| `get_process_ports` | List detected ports and URLs for one process |
| `get_project_stats` | Read CPU and memory usage for project processes |
| `services_list` | List detected project-local services, including readiness, URLs, and ports |
| `start_all_commands` | Start all trusted command processes in the effective project scope |
| `stop_all_commands` | Stop all running command processes in the effective project scope |
| `restart_all_commands` | Restart all trusted command processes in the effective project scope |
| `list_agent_tools` | List configured agent runtimes; use each returned `id` as `agent_tool_id` for `spawn_agent` or `spawn_process(kind="agent")` |
| `spawn_agent` | Create and start a new Solo agent; returns `process_id`, `name`, and optional bootstrap instructions; send the first prompt with `send_input` |
| `spawn_process` | Generic create/start tool for terminals or agents; use `kind="terminal"` for shells or `kind="agent"` with an `agent_tool_id` |
| `identify_session` | Identify this MCP session by auto-detection, by its own `SOLO_PROCESS_ID`, or as an external actor |
| `whoami` | Show the Solo-managed process tied to this MCP session |
| `submit_solo_feedback` | Open Solo's feedback form with a prefilled draft for human review and manual submission |
| `kv_set` / `kv_get` / `kv_list` / `kv_delete` | Shared project-scoped JSON state |
| `scratchpad_list` / `scratchpad_tags_list` / `scratchpad_read` / `scratchpad_find` / `scratchpad_tail` / `scratchpad_write` / `scratchpad_rename` / `scratchpad_add_tags` / `scratchpad_remove_tags` / `scratchpad_append` / `scratchpad_append_section` / `scratchpad_edit` / `scratchpad_clear` / `scratchpad_delete` / `scratchpad_archive` / `scratchpad_transfer` / `scratchpad_save_to_file` / `scratchpad_load_from_file` | Shared project-scoped scratchpads with revision checks, bounded literal search, tail reads, targeted section edits/appends, rename/tag operations, deletion, project moves, and file import/export |
| `todo_create` / `todo_list` / `todo_tags_list` / `todo_get` / `todo_update` / `todo_add_tag` / `todo_remove_tag` / `todo_transfer` / `todo_set_blockers` / `todo_add_blocker` / `todo_remove_blocker` / `todo_complete` / `todo_lock` / `todo_unlock` / `todo_delete` / `todo_comment_create` / `todo_comment_update` / `todo_comment_delete` / `todo_comment_list` | Shared project-scoped todos with tags, comments, blockers, locks, and cross-project moves |
| `lock_acquire` / `lock_status` / `lock_release` | Advisory lease-based coordination locks |
| `wait_for_bound_port` | Wait for a project-local process to expose a bound port in the effective project scope; useful for readiness and dev server URL discovery |
| `timer_set` / `timer_fire_when_idle_any` / `timer_fire_when_idle_all` / `timer_cancel` / `timer_pause` / `timer_resume` / `timer_list` | Durable timers with explicit Solo agent delivery targets; timer bodies are delivered by PTY injection as fresh user turns |
| `setup_agent_integration` | Write Solo MCP docs into `CLAUDE.md` or `AGENTS.md` |

**Note:** Solo uses `process` as the umbrella term for `command`, `terminal`, and `agent`. Bulk start/stop/restart tools only affect Solo command processes. `close_process` only applies to Solo terminals and Solo agents. Solo process IDs come from Solo tools such as `list_processes`, `get_process_status`, `spawn_agent`, and `spawn_process`; they are not non-Solo developer/runtime agent IDs. Solo command processes must be trusted in the Solo UI before MCP can start or restart them.

Project-scoped tools accept an optional `project_id` for one-off access. When `project_id` is omitted, Solo uses the selected project for the session if one is set; otherwise it falls back to the identified Solo process's project.

Solo-managed agents are normally auto-identified. `identify_session` accepts `solo_process_id` only to assert this MCP client's own `SOLO_PROCESS_ID` when auto-identification fails; it no-ops after identity exists and must not be used to target another process. External callers can pass `external` actor details for coordination identity. To wake a different agent, pass `delivery_process_id` to a timer tool. `SOLO_PROCESS_ID` is a Solo process ID, not a host OS PID.

### Recommended Solo MCP Workflow

1. Call `list_projects`, then either `select_project` to set a session default or pass `project_id` on individual project-scoped calls. Use `create_project(path, name?)` only to register or import an existing local directory. Use `delete_project` only with `confirm_delete=true`; add `confirm_stop_running=true` when running processes should be stopped and removed, and `prompt_template_policy=\"convert_to_global\"` when project prompt templates should be kept as global templates.
2. Call `whoami` to confirm `process_id`, `process_name`, `project_id`, `effective_project_id`, and `actor_id`.
3. If `whoami` cannot identify a Solo-managed child process, call `identify_session` with your own `solo_process_id` from `SOLO_PROCESS_ID` only to assert identity. If running outside Solo, call `identify_session` with `external` actor details. Never identify as a target process; use `delivery_process_id` for timer delivery.
4. To create a worker agent, call `list_agent_tools`, then `spawn_agent(agent_tool_id=N)`, then `send_input(process_id=<returned process_id>, input=<prompt>)`. Use `spawn_process(kind="terminal")` for a new shell.
5. Use `lock_acquire` / `lock_release` before editing shared files or logical work areas, and use KV, scratchpads, and todos for durable coordination state.
6. Use `services_list` to inspect detected local services, and prefer `wait_for_bound_port` and `timer_*` tools over tight polling loops when waiting on readiness or follow-up work.
7. Timers are the only Solo wake-up mechanism for Solo agent processes; pass `delivery_process_id` when scheduling a wake-up for a different agent process.
8. Use `list_prompts` / `get_prompt` for built-in playbooks such as `worker_bootstrap`, `wait_for_bound_port`, and `timer_followup`.
9. Use `submit_solo_feedback` when you uncover a Solo bug, UX issue, or feature request worth reporting upstream; Solo opens a prefilled feedback form for the human to review and submit.
