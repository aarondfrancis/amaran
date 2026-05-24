# Sidus Join Probe Firmware

This Zephyr app runs on the Nordic nRF52840 DK (`PCA10056`) as a fake
Bluetooth Mesh provisionee for Sidus Link Pro join-capture experiments.

It advertises:

- Local name: `amaran 60x S`
- Mesh Provisioning service: `0x1827`
- PB-GATT Data In/Out characteristics: `0x2ADB` / `0x2ADC`
- No-OOB provisioning capabilities
- One element with a Telink/amaran-like vendor model: company `0x0211`,
  model `0x0000`

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

## Validation

```sh
./bin/amaran provision-scan --json --timeout 10
./bin/amaran provision-invite-test --json --attention 0 --timeout 20
```

Safe expected output includes the name `amaran 60x S`, service `1827`,
service-data length `18`, OOB info `0x0000`, and capabilities with input and
output OOB sizes of `0`.
