# A2DPilot

A2DPilot turns a Debian-based headless machine into a reliable Bluetooth audio player. It installs and coordinates BlueZ, PipeWire, WirePlumber, and Triggerhappy; powers and provisions the Bluetooth adapter; pairs trusted speakers; and keeps one configured A2DP speaker connected.

The project is delivered as one Bash program. The same `a2dpilot` file installs the system, becomes the installed management command, runs the connection daemon, and handles media-button requests.

## Features

- Interactive Bluetooth discovery, pairing, trust, and connection setup.
- An ordered list of fallback speakers in one central configuration file.
- Non-preemptive failover: a working fallback isn't interrupted because a preferred speaker reappears.
- Automatic controller soft-unblock and power-on management.
- BlueZ, PipeWire A2DP, and optional AVRCP health checks.
- Best-effort selection of the healthy managed Bluetooth sink as PipeWire's default.
- Automatic PipeWire codec negotiation by default, with optional ordered codec preferences for each speaker.
- Responsive media-key routing with broad Linux transport-key coverage, relative volume control, configurable URLs, and one bounded action deadline.
- Optional suppression of Raspberry Pi onboard analogue and HDMI audio devices.
- Atomic executable-only updates.
- Headless PipeWire/WirePlumber operation using systemd linger.
- Transactional installation with restoration of files, services, user services, linger, rfkill, and controller state.

## Environment expectations

**Raspberry Pi OS** and **Debian on Raspberry Pi** with **Caldera Music** or **headless Plexamp** are the primary use cases.

The supported target is a dedicated Debian Trixie-style system with:

- Bash, APT, dpkg, systemd, logind, and root access through `sudo`.
- A working Bluetooth Classic adapter supported by the kernel and BlueZ.
- A Bluetooth speaker that supports A2DP.
- Network access to configured APT repositories during installation and GitHub during updates.
- An existing local audio/player user with a real home directory.
- Plexamp, Caldera Music, or another compatible player already installed for that user.
- An HTTP GET endpoint for each media key you want A2DPilot to handle; the defaults target a player API at `http://127.0.0.1:32500`.

A2DPilot **cannot**:

- Clear a hardware rfkill switch
- Supply missing chipset firmware
- Put a remote speaker into pairing mode
- Prevent a phone from taking exclusive control of a speaker

## Installation

Installation is available via a streamed single command:

```sh
curl -fsSL https://raw.githubusercontent.com/treyturner/a2dpilot/main/a2dpilot \
  | sudo bash -s -- install
```

A bootstrap preserves the incoming program in a secure temporary file; installation then copies the complete executable to `/usr/local/sbin/a2dpilot`.

Piping network content into a privileged shell trusts the referenced repository, hosting service, TLS connection, and current branch contents. To inspect the program first, download it and use the local form:

```sh
sudo bash ./a2dpilot install
```

The installer chooses the audio user from `SUDO_USER`, then falls back to `pi`. Override that initial choice with:

```sh
curl -fsSL https://raw.githubusercontent.com/treyturner/a2dpilot/main/a2dpilot \
  | sudo bash -s -- install --user USER
```

When creating a new configuration, an interactive install makes a best-effort check for Raspberry Pi onboard analogue and HDMI audio and asks separately whether to suppress each detected class. Undetected devices remain enabled and can be changed later with `a2dpilot audio onboard`.

After package and service setup, an interactive install scans for Bluetooth Classic devices. Put the desired speaker into pairing mode, select it by number, and repeat to add additional fallbacks. The selection order becomes speaker priority. Enter `r` to rescan or press Enter without a selection to finish.

After pairing finishes, A2DPilot waits up to ten seconds for the daemon to select a configured speaker after enforcing its codec policy, verifies that it is a healthy A2DP sink, and makes it PipeWire's effective default.

It then looks for exact `caldera-music`, `Plexamp`, or `plexamp` processes owned by the configured audio user. If a running Caldera or Plexamp process can be safely mapped to an active user service, the installer offers to restart it, allowing the player to reopen audio after onboard devices and the PipeWire default have changed. A recognized process that can't be tied to the audio user's active `.service` is reported for manual restart.

See [Advanced usage](ADVANCED.md) for [unattended installation](ADVANCED.md#unattended-installation).

### Updating

To update the installed executable from the latest commit on `main`:

```sh
sudo a2dpilot update
```

You can also [update to a specific revision](ADVANCED.md#updating-to-a-specific-revision).

## Usage

### Inspect devices and status

```sh
sudo a2dpilot devices
sudo a2dpilot status
sudo a2dpilot audio onboard status
```

`devices` prints priority, pairing, trust, BlueZ connection, A2DP, AVRCP, negotiated codec, configured codec policy, and device name for every speaker. A policy appears as `auto` or an ordered value such as `aptx_hd>aptx>sbc`. `status` adds installation, controller, rfkill, base URL, media-key count, onboard-audio policy and visibility, the active managed sink, PipeWire's effective default, recognized player services, best-effort player backend classification (`PipeWire`, `direct ALSA`, or `unknown`), system-service, and audio-user service diagnostics.

### Add or repair speakers

Run an interactive scan:

```sh
sudo a2dpilot pair
```

Pair an explicit address:

```sh
sudo a2dpilot pair AA:BB:CC:DD:EE:FF
```

Provision every configured speaker in order:

```sh
sudo a2dpilot pair --all
```

Most speakers work with the automatically selected BlueZ agent. An unusual authentication flow can choose a capability explicitly:

```sh
sudo a2dpilot pair AA:BB:CC:DD:EE:FF --agent KeyboardDisplay
```

Valid capabilities are `DisplayOnly`, `DisplayYesNo`, `KeyboardDisplay`, `KeyboardOnly`, and `NoInputNoOutput`.

A2DPilot never invokes BlueZ's `pair` command for an already-paired device because BlueZ would remove and recreate that bond. It instead verifies trust and reconnects it. New successful bonds are recorded with their controller so uninstall can distinguish them from pre-existing bonds and still target the correct adapter after configuration changes.

### Forget a speaker

```sh
sudo a2dpilot forget AA:BB:CC:DD:EE:FF
```

This confirms, disconnects the device, removes its BlueZ bond, removes it from the ordered configuration, and restarts connection selection. Use `--yes` for explicit non-interactive operation.

### Uninstall and restore

Do not manually delete `/var/lib/a2dpilot` before uninstalling; it contains the rollback snapshot. To uninstall:

```sh
sudo a2dpilot uninstall
```

Interactive uninstall lists bonds created by A2DPilot and asks whether to remove them. `--keep-bonds` or `--remove-bonds` can be supplied to `uninstall` to skip the prompt.

Uninstall restores replaced files, original system and user unit states, linger settings for every audio user A2DPilot managed, and controller power and rfkill state when the hardware is still present. A2DPilot never removes APT-managed packages or runs `apt autoremove`.

## Configuration

While configuration for most users will be automated by installation prompts or the commands above, the full configuration spec and additional details can be found in [`CONFIGURATION.md`](CONFIGURATION.md).

## Implementation notes

See [`IMPLEMENTATION.md`](IMPLEMENTATION.md).

## Troubleshooting

See [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md).
