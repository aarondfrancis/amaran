# Joining An Existing Mesh

The CLI can join an existing Bluetooth Mesh for runtime control if it has the
same mesh credentials as the current provisioner. It does not need to reset or
re-provision fixtures for this mode.

## What Runtime Control Needs

For `list`, `probe`, `status`, `on`, `off`, `intensity`, and `cct`, the CLI
needs:

- Mesh NetKey
- Mesh AppKey
- IV Index
- Fixture unicast addresses

DeviceKeys are not required for Telink vendor runtime control. Without
DeviceKeys, the CLI cannot run Config Client diagnostics, fetch composition
data, bind models, or send Config Node Reset for those imported fixtures.

This matches the Bluetooth Mesh model:

- NetKey possession defines membership in a mesh subnet.
- AppKey possession allows application/vendor access messages.
- DeviceKey is unique per node and is used for secure configuration between
  the node and a provisioner.

## Sidus Backup Import

The preferred no-reset path for this project is now:

1. Pair and organize fixtures in Sidus Link Pro on the iPad.
2. Create an encrypted local iPad backup in Finder.
3. Import Sidus mesh JSON into the CLI state file.
4. Use CLI runtime commands and scenes against that same mesh.

```sh
./bin/amaran sidus-import --backup /private/tmp/Backup
./bin/amaran doctor
./bin/amaran list
./bin/amaran status --node 7
```

`sidus-import` can read an iPad backup directory or an extracted Sidus app
container. It looks for Sidus mesh JSON under the Sidus app domain, imports the
NetKey, AppKey, fixture unicast addresses, and any available DeviceKeys, then
writes the normal CLI state file with `0600` permissions. Terminal output is
redacted: counts, names, addresses, and MAC suffixes only.

Encrypted backups require the Python package `iphone_backup_decrypt`. If it is
missing, the importer creates a private venv under
`~/Library/Application Support/amaran-cli/python/ios-backup-import` and installs
the dependency there. Set `AMARAN_IOS_BACKUP_IMPORT_VENV` to override that path.
The command prompts for the backup password unless `AMARAN_IOS_BACKUP_PASSWORD`
is set in the environment. Do not paste backup passwords or generated state
files into issues, logs, or commits.

Use `--mesh <selector>` when a backup contains multiple mesh files. The selector
matches mesh name, mesh UUID, or mesh file path substring. Use `--replace` only
when intentionally replacing the target CLI state with a fresh import.

## Manual Import Path

Use `state-join` when you have NetKey/AppKey metadata from another provisioner:

```sh
./bin/amaran state-join /tmp/sidus-join.json
./bin/amaran doctor
./bin/amaran probe --node 2
./bin/amaran status --node 2
```

The source file is key-bearing and should be handled like `state.json`.

```json
{
  "mesh": {
    "uuid": "studio-mesh",
    "net_key": "<32 hex chars>",
    "app_key": "<32 hex chars>",
    "iv_index": 0
  },
  "fixtures": [
    {
      "name": "key",
      "node_address": 2,
      "element_count": 1
    }
  ],
  "runtime": {
    "sequence_next": 1
  }
}
```

`state-join` writes the normal CLI state format with `0600` permissions, refuses
to overwrite an existing target state, and prints only redacted fixture
summaries. Fixtures without DeviceKeys are marked control-only.

## Discovering Fixture Addresses

Once the CLI has the Sidus mesh NetKey/AppKey, it can inspect the mesh at the
runtime-control layer by trying candidate unicast addresses:

```sh
./bin/amaran discover --range 2-64
./bin/amaran discover --range 2-64 --update-state
```

`discover` temporarily adds each candidate address to local state, sends a
status query, and records addresses that answer. Without `--update-state`, it
removes temporary fixture rows after probing; sequence counters may still
advance. With `--update-state`, responsive addresses remain as control-only
fixtures if they were not already in state.

This does not recover DeviceKeys, fixture MACs, Sidus names, groups, or Sidus
scene metadata. For that, take a fresh encrypted iPad backup and run
`sidus-import --replace`.

## Scenes

Scenes are local CLI snapshots stored under the top-level `scenes` object in
`state.json`:

```sh
./bin/amaran scene capture "recording scene"
./bin/amaran scene capture "recording scene" --node 7
./bin/amaran scene list
./bin/amaran scene show "recording scene"
./bin/amaran scene apply "recording scene"
./bin/amaran scene apply "recording scene" --node 7
```

`scene capture` reads each fixture's current vendor CCT status and stores
intensity, CCT, and sleep state. Pass `--node <id>` to capture or apply one
fixture from a larger state file. `scene apply` sends direct runtime commands
to restore those values. The iPad remains the source of truth for pairing; the
CLI scene store is just a fast local control layer.

## Sidus Link Pro Reality

Sidus Link Pro does not expose a supported mesh export flow in the app UI.
Bluetooth Reset clears or unlinks previous pairings, which is why normal CLI
pairing moves a fixture into a CLI-owned mesh instead of sharing the old one.
The local encrypted iPad backup is currently the practical non-reset path for
importing the Sidus-owned mesh into CLI state.

Known practical paths:

- If the iPad owns the studio mesh, import an encrypted local iPad backup with
  `sidus-import`.
- If another provisioner can export NetKey/AppKey and fixture addresses, import
  them with `state-join`.
- If a freshly imported Sidus state has the same mesh keys but missing fixture
  rows, use `discover --range ... --update-state` to add runtime-only entries.
- If the fixture is reset and paired by this CLI, use `pair` / `pair --add`
  instead. That makes the CLI state the source of truth.

## Experimental No-Reset Path

A more invasive path is being tested: make the CLI behave like an
unprovisioned Bluetooth Mesh node/provisionee, let Sidus Link Pro provision that
dummy node, then capture the provisioning credentials Sidus sends to it.

The first diagnostic is:

```sh
./bin/amaran join-capture --output-state /private/tmp/amaran-sidus-capture.json --timeout 120
```

This launches `BluetoothProbe.app` as a CoreBluetooth peripheral, advertises
Mesh Provisioning service `0x1827`, and waits for Sidus Link Pro to provision
the Mac as a dummy no-OOB mesh node. If Sidus accepts it, the capture file gets:

- Mesh NetKey
- Key index, flags, IV index
- The dummy node unicast address
- The dummy node DeviceKey

The normal command output is redacted. The `--output-state` file is
key-bearing, is written with `0600` permissions, and must not be committed or
shared.

This is not a complete usable join yet. Runtime fixture control still needs the
mesh AppKey. The current capture stops at PB-GATT Provisioning Complete; the
next step is to also emulate enough Mesh Proxy service `0x1828` and Config
Server behavior to receive/decode Config AppKey Add from Sidus Link Pro.

The nRF52840 DK probe can capture the same join material from a hardware
Bluetooth Mesh provisionee. Read the DK capture with redacted output:

```sh
scripts/read-dk-capture
```

For the live Sidus trial, use the operator helper:

```sh
scripts/dk-sidus-attempt prepare
# Run the Sidus Link Pro add-fixture flow on the iPad.
scripts/dk-sidus-attempt read --output /private/tmp/amaran-dk-sidus-attempt.hex
```

If the DK has captured both NetKey and AppKey, convert the raw capture into a
`state-join` source file. You still need to supply the real fixture unicast
addresses because the DK capture only knows the dummy node address Sidus gave
the probe:

```sh
scripts/dk-capture-to-state-join --capture /private/tmp/amaran-dk-capture.hex --output /private/tmp/sidus-join.json --fixture 2=Key --fixture 5=Fill
./bin/amaran state-join /private/tmp/sidus-join.json
```

The converter writes `0600`, refuses captures missing NetKey/AppKey, and prints
only redacted metadata. The generated `sidus-join.json` is key-bearing.

One observed Sidus failure reached Invite, Start, and provisioner Public Key,
then disconnected after the first segmented DK Public Key notification. The DK
firmware now raises ATT/L2CAP MTU support so the 65-byte Public Key response can
be returned as a single PB-GATT notification.

It may also fail if Sidus Link Pro filters pairable devices to known
Aputure/amaran fixture identities, or if it requires Bluetooth Mesh
provisioning service data. macOS CoreBluetooth's peripheral API supports the
service UUID and local name here, but not the full service-data advertisement
real fixtures normally use.

## References

- Bluetooth Mesh glossary, security keys:
  https://www.bluetooth.com/learn-about-bluetooth/feature-enhancements/mesh/mesh-glossary/
- Bluetooth Mesh primer, keys and provisioning:
  https://www.bluetooth.com/bluetooth-mesh-primer/
- Aputure Sidus Link Control & Updating:
  https://help.aputure.com/en/general-help/sidus-link-control
- Sidus Link Pro Auto-Patching:
  https://help.aputure.com/en/sidus-link-pro/what-is-auto-patching
