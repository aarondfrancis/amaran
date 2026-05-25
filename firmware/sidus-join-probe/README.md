# Sidus Join Probe Firmware

This Zephyr app runs on the Nordic nRF52840 DK (`PCA10056`) as a fake
Bluetooth Mesh provisionee for Sidus Link Pro join-capture experiments.

It advertises:

- Local name: `SLCK Light`
- Mesh Provisioning service: `0x1827`
- PB-GATT Data In/Out characteristics: `0x2ADB` / `0x2ADC`
- No-OOB provisioning capabilities
- One element with a Telink/amaran-like vendor model: company `0x0211`,
  model `0x0000`
- Optional private fixture-like manufacturer data from the ignored local
  identity header

It does not print or export mesh keys. The next milestone is a deliberate,
redacted capture path for NetKey/AppKey material if Sidus Link Pro provisions
the probe.

## Local Build

The local Zephyr workspace is intentionally ignored by git:

```sh
python3 -m venv .zephyrproject/.venv
.zephyrproject/.venv/bin/pip install west
.zephyrproject/.venv/bin/west init .zephyrproject
cd .zephyrproject
.venv/bin/west update
.venv/bin/pip install -r zephyr/scripts/requirements.txt
cd zephyr
../.venv/bin/west sdk install --gnu-toolchains arm-zephyr-eabi
```

Build and flash:

```sh
cd .zephyrproject
.venv/bin/west build -p always -b nrf52840dk/nrf52840 ../firmware/sidus-join-probe -d ../.zephyr-build/sidus-join-probe
.venv/bin/west flash --recover -d ../.zephyr-build/sidus-join-probe
```

`--recover` erases the DK flash. That is expected for this dev board and is
useful when clearing old provisioning/settings state.

When using a private fixture-like identity, pass the ignored local identity
directory:

```sh
cd .zephyrproject
.venv/bin/west build -p always -b nrf52840dk/nrf52840 ../firmware/sidus-join-probe -d ../.zephyr-build/sidus-join-probe -- -DAMARAN_PROBE_LOCAL_IDENTITY_DIR=/private/tmp/amaran-probe-identity
```

## Capture Decode

The capture block is key-bearing if provisioning reaches the NetKey/AppKey
steps. Keep raw dumps in `/private/tmp` or another private location, and do not
commit or share them.

Find the current capture address if `scripts/read-dk-capture` is not enough:

```sh
arm-zephyr-eabi-nm -S ../.zephyr-build/sidus-join-probe/zephyr/zephyr.elf | rg 'amaran_capture_state'
```

Read and decode a capture without printing key material:

```sh
nrfutil device read --serial-number "$AMARAN_DK_SERIAL" --address "$CAPTURE_ADDRESS" --bytes "$CAPTURE_BYTES" --direct --to-file /private/tmp/amaran-dk-capture.hex
scripts/decode-dk-capture /private/tmp/amaran-dk-capture.hex
```

The helper does both steps and discovers the address from the current ELF:

```sh
export AMARAN_DK_SERIAL=<your-dk-serial>
scripts/read-dk-capture
scripts/read-dk-capture --json
```

For the full Sidus attempt loop:

```sh
scripts/dk-sidus-attempt prepare
# Run the Sidus Link Pro add-fixture flow on the iPad.
scripts/dk-sidus-attempt read --output /private/tmp/amaran-dk-sidus-attempt.hex
```

Before a fresh Sidus attempt, clear the in-RAM capture block and confirm it
reinitialized cleanly:

```sh
scripts/read-dk-capture --clear
```

Do not run `--clear` after a Sidus attempt until the capture has been read. It
will intentionally discard any captured key material.

The decoder reports only redacted state: key presence, mesh indexes, node
address, provisioning phase bits, and capability/start negotiation metadata.
Use `--json` when a structured summary is easier to compare between attempts.

Sidus has been observed reaching Invite, Start, and provisioner Public Key, then
disconnecting after the first segmented DK Public Key notification. The current
probe raises ATT/L2CAP MTU support so the 65-byte Public Key response is sent as
one PB-GATT notification (`len=66 mtu=247`) when the central negotiates the
larger MTU.

If a raw capture contains both NetKey and AppKey, convert it into a
`state-join` source without printing keys:

```sh
scripts/dk-capture-to-state-join --capture /private/tmp/amaran-dk-capture.hex --output /private/tmp/sidus-join.json --fixture 2=Key
```

The converter writes `0600` and still needs the real fixture unicast addresses;
the DK only captures the dummy node address assigned to the probe.

## Validation

```sh
./bin/amaran provision-scan --json --timeout 10
./bin/amaran provision-invite-test --json --attention 0 --timeout 20
```

Safe expected output includes the name `SLCK Light`, service `1827`,
service-data length `18`, OOB info `0x0000`, and capabilities with input and
output OOB sizes of `0`.
