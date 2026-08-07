# A2DPilot

A2DPilot turns a Debian-based headless machine into a reliable Bluetooth audio player. It installs and coordinates BlueZ, PipeWire, WirePlumber, and Triggerhappy; powers and provisions the Bluetooth adapter; pairs trusted speakers; and keeps one configured A2DP speaker connected.

The project is delivered as one Bash program. The same `a2dpilot` file installs the system, becomes the installed management command, runs the connection daemon, and handles media-button requests.

## Features

- Interactive Bluetooth discovery, pairing, trust, and connection setup.
- An ordered list of fallback speakers in one central configuration file.
- Non-preemptive failover: a working fallback is not interrupted merely because a preferred speaker reappears.
- Automatic controller soft-unblock and power-on at boot and after adapter loss.
- BlueZ, PipeWire A2DP, and optional AVRCP health checks.
- Automatic codec negotiation through PipeWire, including SBC, SBC-XQ, aptX, aptX HD, and LDAC when supported by the speaker.
- Configurable media-key routing with broad Linux transport-key coverage, relative volume control, and relative or absolute HTTP(S) player URLs.
- Safe configuration editing and validation through the CLI.
- Headless PipeWire/WirePlumber operation using systemd linger.
- Transactional installation with restoration of files, packages, services, user services, linger, rfkill, and controller state.
- Optional removal of only the Bluetooth bonds that A2DPilot itself created.

LE Audio/BAP, aptX Adaptive, and codec forcing are not currently supported.

## Bundled and managed components

A2DPilot installs these Debian packages with `--no-install-recommends` when necessary:

| Component            | Packages                                      | Purpose                                                                        |
| -------------------- | --------------------------------------------- | ------------------------------------------------------------------------------ |
| BlueZ                | `bluez`, `bluez-firmware`                     | Bluetooth controllers, discovery, pairing, trust, and profile connections      |
| PipeWire             | `pipewire`, `pipewire-alsa`, `pipewire-pulse` | Audio server plus ALSA and PulseAudio compatibility                            |
| Bluetooth SPA plugin | `libspa-0.2-bluetooth`                        | A2DP and available codec integration, including aptX and LDAC on Debian Trixie |
| WirePlumber          | `wireplumber`                                 | PipeWire session and Bluetooth-device policy                                   |
| RealtimeKit          | `rtkit`                                       | Controlled real-time scheduling for user audio processes                       |
| Triggerhappy         | `triggerhappy`                                | Converts Bluetooth media-key events to player commands                         |
| curl                 | `curl`                                        | Calls the local player-control API                                             |
| rfkill               | `rfkill`                                      | Detects hard blocks and clears Bluetooth soft blocks                           |

Managed files are:

| Path                                                   | Purpose                                                                           |
| ------------------------------------------------------ | --------------------------------------------------------------------------------- |
| `/usr/local/sbin/a2dpilot`                             | Installed CLI, daemon, and player-control implementation                          |
| `/etc/a2dpilot.conf`                                   | All user-facing A2DPilot configuration                                            |
| `/etc/systemd/system/a2dpilot.service`                 | Connection-maintenance daemon                                                     |
| `/etc/wireplumber/wireplumber.conf.d/51-a2dpilot.conf` | Disables seat monitoring for a dedicated headless audio session                   |
| `/etc/triggerhappy/triggers.d/a2dpilot.conf`           | Media-key mappings, or an inert file when controls are disabled                   |
| `/var/lib/a2dpilot/`                                   | Root-only backups, rollback metadata, user snapshots, and created-bond provenance |

## Environment expectations

**Raspberry Pi OS** and **Debian on Raspberry Pi** are the primary use cases. The supported target is a dedicated Debian Trixie-style system with:

- Bash, APT, dpkg, systemd, logind, and root access through `sudo`.
- A working Bluetooth Classic adapter supported by the kernel and BlueZ.
- A Bluetooth speaker that supports A2DP.
- Network access to configured APT repositories during installation.
- An existing local audio/player user with a real home directory.
- Plexamp, Caldera Music, or another compatible player already installed for that user.
- An HTTP GET endpoint for each media key you want A2DPilot to handle; the defaults target a player API at `http://127.0.0.1:32500`.



A2DPilot **cannot**:
- clear a hardware rfkill switch
- supply missing chipset firmware
- put a remote speaker into pairing mode
- prevent a phone from taking exclusive control of a speaker

## Installation

The intended installation is deliberately a streamed single command:

```sh
curl -fsSL https://raw.githubusercontent.com/treyturner/a2dpilot/main/a2dpilot \
  | sudo bash -s -- install
```

The small bootstrap at the beginning of the script first preserves the incoming program in a secure temporary file. Installation then copies the complete executable to `/usr/local/sbin/a2dpilot`, so future management does not require a checkout or another download.

Piping network content into a privileged shell trusts the referenced repository, hosting service, TLS connection, and current branch contents. To inspect the program first, download it and use the local form:

```sh
chmod +x a2dpilot
sudo ./a2dpilot install
```

The installer chooses the audio user from `SUDO_USER`, then falls back to `pi`. Override that initial choice with:

```sh
curl -fsSL https://raw.githubusercontent.com/treyturner/a2dpilot/main/a2dpilot \
  | sudo bash -s -- install --user pi
```

After package and service setup, an interactive install scans for Bluetooth Classic devices. Put the desired speaker into pairing mode, select it by number, and repeat to add additional fallbacks. The selection order becomes speaker priority. Press Enter without a selection to finish.

For unattended installation:

```sh
curl -fsSL https://raw.githubusercontent.com/treyturner/a2dpilot/main/a2dpilot \
  | sudo bash -s -- install --user pi --non-interactive
```

An unattended installation with no speakers is valid and remains idle until `a2dpilot pair` or `a2dpilot config` is used.

## Configuration

All runtime settings live in `/etc/a2dpilot.conf`:

```ini
audio-user = pi
controller = auto
reconnect-interval = 5
media-controls = auto
base-url = http://127.0.0.1:32500

media-key = KEY_PLAYPAUSE player/playback/playPause?type=music&commandID={command-id}
media-key = KEY_PLAY player/playback/play?type=music&commandID={command-id}
media-key = KEY_PLAYCD player/playback/play?type=music&commandID={command-id}
media-key = KEY_PAUSE player/playback/pause?type=music&commandID={command-id}
media-key = KEY_PAUSECD player/playback/pause?type=music&commandID={command-id}
media-key = KEY_STOP player/playback/stop?type=music&commandID={command-id}
media-key = KEY_STOPCD player/playback/stop?type=music&commandID={command-id}
media-key = KEY_NEXT player/playback/skipNext?type=music&commandID={command-id}
media-key = KEY_NEXTSONG player/playback/skipNext?type=music&commandID={command-id}
media-key = KEY_PREVIOUS player/playback/skipPrevious?type=music&commandID={command-id}
media-key = KEY_PREVIOUSSONG player/playback/skipPrevious?type=music&commandID={command-id}
media-key = KEY_FORWARD player/playback/stepForward?type=music&commandID={command-id}
media-key = KEY_FASTFORWARD player/playback/stepForward?type=music&commandID={command-id}
media-key = KEY_REWIND player/playback/stepBack?type=music&commandID={command-id}
media-key = KEY_FASTREVERSE player/playback/stepBack?type=music&commandID={command-id}
media-key = KEY_VOLUMEUP player/playback/setParameters?type=music&volume={volume-up}&commandID={command-id}
media-key = KEY_VOLUMEDOWN player/playback/setParameters?type=music&volume={volume-down}&commandID={command-id}
media-key = KEY_MUTE player/playback/setParameters?type=music&volume={mute-toggle}&commandID={command-id}
media-key = KEY_SHUFFLE player/playback/setParameters?type=music&shuffle={shuffle-toggle}&commandID={command-id}
media-key = KEY_MEDIA_REPEAT player/playback/setParameters?type=music&repeat={repeat-cycle}&commandID={command-id}

# Attempted in this order
speaker = AA:BB:CC:DD:EE:FF
speaker = 11:22:33:44:55:66
```

Open it safely with:

```sh
sudo a2dpilot config
```

A2DPilot opens a temporary copy using `SUDO_EDITOR`, `VISUAL`, `EDITOR`, or the system `editor`. The editor runs as the invoking user rather than root. When it closes, A2DPilot validates the candidate, installs it atomically, applies audio-user and media-control changes, and restarts the affected services. An invalid edit never replaces the working file.

Validate without editing:

```sh
sudo a2dpilot config --check
```

The format supports blank lines, full-line `#` comments, whitespace around `=`, repeated `speaker` and `media-key` entries, and no shell evaluation. Unknown settings, duplicated scalar settings, duplicated speakers, and duplicated media keys are rejected.

### Speaker priority

Speakers are attempted from top to bottom whenever there is no healthy connection. Failed candidates receive an exponential retry cooldown, capped at 60 seconds, so an absent preferred device does not starve a fallback.

Priority is intentionally non-preemptive. Once any configured speaker has a healthy A2DP connection, A2DPilot leaves it alone. A preferred device is reconsidered only after the current connection is lost or removed from the configuration.

### Controller selection

`controller = auto` uses the first controller BlueZ presents. On machines with multiple adapters, use the desired controller's MAC address:

```ini
controller = 12:34:56:78:9A:BC
```

### Media controls

`media-controls` accepts:

- `auto` — map available media buttons, but do not consider missing AVRCP a broken audio connection. This is the default.
- `required` — require AVRCP as well as BlueZ and A2DP; reconnect if media control is absent.
- `off` — install no active Triggerhappy mappings and do not check AVRCP.

Mappings remain in the configuration when controls are `off` and become active again if the mode changes. An empty mapping list is valid; A2DPilot then installs an inert Triggerhappy fragment even in `auto` or `required` mode.

### Media-key URLs

Each repeated mapping contains a Linux input key name and one URL or URL path:

```ini
base-url = http://127.0.0.1:32500
media-key = KEY_NEXTSONG player/playback/skipNext?type=music&commandID={command-id}
```

`base-url` is optional. It must be an HTTP(S) origin or path prefix without a query or fragment. A relative mapping is resolved against it, so the usual single-player configuration does not repeat the host. An absolute HTTP(S) mapping overrides the base and may target another host:

Requests are HTTP GETs and fail after three seconds rather than blocking Triggerhappy indefinitely. The generated Triggerhappy command contains only the validated key name; configured URLs are looked up by A2DPilot and passed to `curl` as data, never evaluated as shell code.

```ini
media-key = KEY_CUSTOM https://automation.example/hooks/skip
```

Key names must match `KEY_[A-Z0-9_]+` and may appear only once. Relative mappings require `base-url`; absolute mappings do not. The optional `{command-id}` token is replaced everywhere it appears with one fresh millisecond value.

The defaults cover the Linux play/pause, explicit play, explicit pause, stop, next, previous, forward, rewind, volume, mute, shuffle, and repeat key aliases that have direct Plex playback semantics.

The default volume mappings use `{volume-up}`, `{volume-down}`, and `{mute-toggle}`. A2DPilot polls the player's music timeline, changes its reported volume by five percentage points, clamps the result to 0–100, and substitutes the result into the configured URL. Mute saves the current nonzero volume, sets zero, and restores the saved value when toggled again. Volume-up from zero clears the saved mute state; if no saved value is available, unmute restores to 15%. `{shuffle-toggle}` switches the reported shuffle value between off and on. `{repeat-cycle}` advances from off to repeat-all to repeat-one and back to off. These stateful placeholders require `base-url`, and only one kind may appear in a mapping. A URL without a placeholder is requested literally.

## Usage

### Inspect devices and status

```sh
sudo a2dpilot devices
sudo a2dpilot status
```

`devices` prints priority, pairing, trust, BlueZ connection, A2DP, AVRCP, negotiated codec, and device name for every configured speaker. `status` adds installation, controller, rfkill, base URL, media-key count, system-service, and audio-user service diagnostics.

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

```sh
sudo a2dpilot uninstall
```

Interactive uninstall lists bonds created by A2DPilot and asks whether to remove them. The default is to keep them. Non-interactive uninstall also keeps bonds unless told otherwise:

```sh
sudo a2dpilot uninstall --keep-bonds
sudo a2dpilot uninstall --remove-bonds
```

`--remove-bonds` affects only bonds A2DPilot created. A device that was already paired before A2DPilot touched it is never automatically removed.

Uninstall restores replaced files, original system and user unit states, linger settings for every audio user A2DPilot managed, controller power and rfkill state when the hardware is still present, and packages that were explicitly absent before installation. It does not run `apt autoremove`.

Do not manually delete `/var/lib/a2dpilot` before uninstalling; it contains the rollback snapshot.

## Audio codecs

A2DPilot does not force a codec. Debian Trixie's `libspa-0.2-bluetooth` package contains PipeWire plugins for SBC, aptX, LDAC, LC3, and other codecs, and depends on the aptX and LDAC encoder libraries. WirePlumber enables all available A2DP codecs by default. The speaker and PipeWire therefore negotiate the best mutually supported profile and can fall back to SBC normally.

A2DPilot accepts any resulting `bluez_output` node as healthy and reports PipeWire's `api.bluez5.codec` value in `devices` and `status`. LDAC remains at PipeWire's adaptive-quality default. Radio congestion, Wi-Fi coexistence, speaker capabilities, and adapter quality can all affect the selected codec and stability.

aptX Adaptive is not currently exposed by this PipeWire stack. Although the LC3 library is installed transitively, A2DPilot does not enable or manage LE Audio/BAP, experimental ISO sockets, coordinated earbud sets, or LE media controls.

## Useful implementation details

- The daemon reloads the central configuration while running. If a direct manual edit becomes invalid, it retains the last valid configuration and logs the error once per distinct failure.
- Connection health requires BlueZ `Connected: yes` and a matching PipeWire `bluez_output` node. `media-controls = required` additionally checks BlueZ's `MediaControl1` AVRCP state.
- Mutating commands and daemon connection cycles serialize through the root-owned `/run/lock/a2dpilot/lock`. Stateful media controls use a separate short-lived lock so a configuration editor cannot block button handling.
- Root-managed configuration is parsed as data and never sourced as shell code.
- Triggerhappy receives only validated key names; URL resolution and placeholder expansion happen inside `player-control` immediately before `curl` runs. Stateful volume, mute, shuffle, and repeat mappings first poll the player's music timeline. Systemd recreates `/run/a2dpilot` for Debian's unprivileged Triggerhappy handler; per-player pre-mute volumes stored there expire on reboot.
- Install records its rollback snapshot before APT and service mutations. A failed or interrupted installation invokes uninstall automatically; failed rollback retains the snapshot for recovery.
- Pairing happens after installation commits, so a speaker being unavailable does not erase a valid system setup.
- The system-wide WirePlumber fragment only disables seat monitoring. It deliberately does not override `bluez5.codecs`.

## Tests

The regression suite requires no root access, packages, Bluetooth hardware, or system-service changes. It uses temporary files and mocked system commands.

Run the same checks as CI:

```sh
bash -n a2dpilot tests/a2dpilot_test.sh
shellcheck -x a2dpilot tests/a2dpilot_test.sh
./tests/a2dpilot_test.sh
```

GitHub Actions runs these checks for pull requests and pushes to `main`.

## Troubleshooting

Start with:

```sh
sudo a2dpilot status
sudo journalctl -b -u a2dpilot.service -u bluetooth.service
```

### No Bluetooth controller is available

Inspect adapters, blocks, USB/PCI identity, and kernel messages:

```sh
sudo rfkill list bluetooth
sudo bluetoothctl list
lsusb -nn
lspci -nnk
sudo journalctl -k -b | grep -Ei 'bluetooth|firmware|btusb|hci'
```

A2DPilot clears soft blocks. A reported hard block requires a hardware/firmware/platform correction.

`bluez-firmware` is installed, but other firmware is chipset-specific. Common Debian packages to investigate include `firmware-atheros`, `firmware-iwlwifi`, `firmware-realtek`, `firmware-mediatek`, and `firmware-ti-connectivity`. Install only the package matching the hardware or missing firmware filename reported by the kernel; many require Debian's `non-free-firmware` repository component.

### A speaker will not pair

- Put the speaker into pairing mode, not merely powered-on mode.
- Disconnect phones or computers that already own the active connection.
- Confirm it appears during `sudo a2dpilot pair`.
- Try an explicit address and agent capability.
- If the speaker was reset but BlueZ retained the old bond, use `a2dpilot forget` and pair it again.

### BlueZ connects but audio is absent

Inspect PipeWire as the configured user:

```sh
audio_user=pi
audio_uid=$(id -u "$audio_user")
audio_home=$(getent passwd "$audio_user" | cut -d: -f6)

sudo -u "$audio_user" env \
  HOME="$audio_home" \
  XDG_RUNTIME_DIR="/run/user/$audio_uid" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$audio_uid/bus" \
  wpctl status --name
```

Look for `bluez_output.` followed by the speaker MAC with underscores. Check the persistent user session with:

```sh
sudo loginctl show-user pi -p Linger
sudo systemctl status "user@$(id -u pi).service"
```

### aptX or LDAC was not selected

Run `sudo a2dpilot devices`. A reported SBC or SBC-XQ codec is a valid negotiated fallback, not an A2DPilot failure. Confirm the exact speaker model supports the desired codec and inspect the associated PipeWire object:

```sh
sudo -u pi env XDG_RUNTIME_DIR="/run/user/$(id -u pi)" \
  wpctl status --name
```

LDAC can fall back under poor radio conditions. A2DPilot intentionally does not force a high-bitrate profile.

### Audio works but media buttons do not

First ensure `media-controls = auto` or `required`, then inspect:

```sh
sudo journalctl -b -u triggerhappy.service -u triggerhappy.socket
sudo /usr/local/sbin/a2dpilot player-control KEY_PLAYCD
```

If the direct command reports that no URL is configured, check the exact `KEY_*` name in the `media-key` entry. If it produces a curl error, verify the resolved `base-url` and mapping URL and confirm that the destination service is running. Volume, mute, shuffle, and repeat also require the player to answer `/player/timeline/poll` with a music timeline containing the corresponding state. A speaker may support A2DP without useful AVRCP controls; use `auto` so this does not trigger reconnects, or `off` to disable the mappings.

### A configuration edit was rejected

Run:

```sh
sudo a2dpilot config --check
```

The error includes the file and line when possible. Use one instance of every required scalar key, a valid local `audio-user`, `auto` or a controller MAC, a positive interval, `auto|required|off`, unique speaker MAC addresses, and unique `KEY_*` media mappings. A relative mapping needs `base-url`; an absolute mapping must use HTTP(S). The accepted URL placeholders are `{command-id}`, `{volume-up}`, `{volume-down}`, `{mute-toggle}`, `{shuffle-toggle}`, and `{repeat-cycle}`; stateful placeholders require `base-url` and cannot be mixed in one mapping.

### Installation or uninstall failed

A2DPilot normally rolls failed installation back automatically. If restoration cannot finish, `/var/lib/a2dpilot/state` is marked `failed` and retained. Correct the reported service, package, or filesystem problem and run:

```sh
sudo /usr/local/sbin/a2dpilot uninstall --keep-bonds
```

If the installed command was one of the files already restored, rerun the downloaded repository script's `uninstall` command while preserving `/var/lib/a2dpilot`.
