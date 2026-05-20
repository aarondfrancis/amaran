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

## Import Path

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

## Sidus Link Pro Reality

The hard part is getting the keys. Sidus Link Pro and amaran Desktop do not
appear to expose a supported mesh export flow. Vendor docs also say Bluetooth
Reset clears or unlinks previous pairings, which is why normal pairing moves the
fixture into a new owner mesh instead of sharing the old one.

Known practical paths:

- If another provisioner can export NetKey/AppKey and fixture addresses, import
  them with `state-join`.
- If an app-owned database contains the keys and the user explicitly wants to
  parse it, a one-shot converter could generate the `state-join` source format.
  This is not a runtime fallback and should not print keys.
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
