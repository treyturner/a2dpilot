# A2DPilot

A2DPilot turns a Debian-based headless machine into a reliable Bluetooth audio player. It installs and coordinates BlueZ, PipeWire, WirePlumber, and Triggerhappy; powers and provisions the Bluetooth adapter; pairs trusted speakers; and keeps one configured A2DP speaker connected.

The project is delivered as one Bash program. The same `a2dpilot` file installs the system, becomes the installed management command, runs the connection daemon, and handles media-button requests.

## Features

- Interactive Bluetooth discovery, pairing, trust, and connection setup.
- An ordered list of fallback speakers in one central configuration file.
- Non-preemptive failover: a working fallback is not interrupted merely because a preferred speaker reappears.
- Automatic controller soft-unblock and power-on at boot and after adapter loss.
- BlueZ, PipeWire A2DP, and optional AVRCP health checks.
- Automatic PipeWire codec negotiation by default, with optional ordered codec preferences for each speaker.
- Responsive media-key routing with broad Linux transport-key coverage, relative volume control, configurable HTTP(S) URLs, and one bounded action deadline.
- Reversible live suppression of Raspberry Pi onboard analogue and HDMI audio devices without disabling HDMI video.
- Safe configuration editing and validation through the CLI.
- Atomic executable-only updates from `main`, a branch, a tag, or an exact commit.
- Headless PipeWire/WirePlumber operation using systemd linger.
- Transactional installation with restoration of files, services, user services, linger, rfkill, and controller state.
- Optional removal of only the Bluetooth bonds that A2DPilot itself created.

LE Audio/BAP and aptX Adaptive are not currently supported.

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
| `/etc/wireplumber/wireplumber.conf.d/51-a2dpilot.conf` | Headless Bluetooth policy and optional Raspberry Pi onboard-audio suppression     |
| `/etc/triggerhappy/triggers.d/a2dpilot.conf`           | Media-key mappings, or an inert file when controls are disabled                   |
| `/var/lib/a2dpilot/`                                   | Root-only backups, rollback metadata, user snapshots, and created-bond provenance |

## Environment expectations

**Raspberry Pi OS** and **Debian on Raspberry Pi** are the primary use cases. The supported target is a dedicated Debian Trixie-style system with:

- Bash, APT, dpkg, systemd, logind, and root access through `sudo`.
- A working Bluetooth Classic adapter supported by the kernel and BlueZ.
- A Bluetooth speaker that supports A2DP.
- Network access to configured APT repositories during installation and GitHub during updates.
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

After package and service setup, an interactive install scans for Bluetooth Classic devices. Put the desired speaker into pairing mode, select it by number, and repeat to add additional fallbacks. The selection order becomes speaker priority. Enter `r` to rescan or press Enter without a selection to finish.

For unattended installation:

```sh
curl -fsSL https://raw.githubusercontent.com/treyturner/a2dpilot/main/a2dpilot \
  | sudo bash -s -- install --user pi --non-interactive
```

An unattended installation with no speakers is valid and remains idle until `a2dpilot pair` or `a2dpilot config` is used.

## Updating A2DPilot

Update the installed executable from the latest commit on `main`:

```sh
sudo a2dpilot update
```

An update can instead select one branch, tag, or exact commit:

```sh
sudo a2dpilot update --branch feat/example
sudo a2dpilot update --tag v1.2.3
sudo a2dpilot update --sha 0123456789abcdef0123456789abcdef01234567
```

`--tag`, `--branch`, and `--sha` are mutually exclusive. A SHA must contain all 40 hexadecimal characters. A branch or tag may move; a commit SHA is the immutable choice when an exact revision is required. Selecting an older revision is allowed and may install a version that does not itself provide the `update` command; the streamed installation command can restore a current executable in that case.

Update downloads and syntax-checks the selected Bash program, then atomically replaces only `/usr/local/sbin/a2dpilot`. It does not invoke APT, rewrite `/etc/a2dpilot.conf`, regenerate systemd, WirePlumber, or Triggerhappy files, run `systemctl daemon-reload`, or alter the installation rollback snapshot. If `a2dpilot.service` was active, it is restarted and checked; an inactive service remains inactive. Failed activation restores the previous executable and attempts to restart the previous daemon. This confirms systemd activation, not Bluetooth, PipeWire, or speaker health, which remains the daemon and `status` command's responsibility.

Like streamed installation, updating trusts this repository, GitHub, and the TLS connection. A2DPilot does not currently verify signed releases or a separate checksum manifest.

## Configuration

All runtime settings live in `/etc/a2dpilot.conf`:

```ini
audio-user = pi
controller = auto
reconnect-interval = 5
media-controls = auto
onboard-analog = enabled
onboard-hdmi = enabled
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
speaker = 11:22:33:44:55:66 aptx_hd aptx sbc_xq sbc
speaker = 22:33:44:55:66:77 sbc
```

Open it safely with:

```sh
sudo a2dpilot config
```

A2DPilot opens a temporary copy using `SUDO_EDITOR`, `VISUAL`, `EDITOR`, or the system `editor`. The editor runs as the invoking user rather than root. When it closes, A2DPilot validates the candidate, installs it atomically, applies audio-user, media-control, and onboard-audio changes, and restarts the affected services. An invalid edit never replaces the working file.

Validate without editing:

```sh
sudo a2dpilot config --check
```

The format supports blank lines, full-line `#` comments, whitespace around `=`, repeated `speaker` and `media-key` entries, and no shell evaluation. Unknown settings, duplicated scalar settings, duplicated speakers, duplicated speaker codecs, and duplicated media keys are rejected.

### Raspberry Pi onboard audio

The optional `onboard-analog` and `onboard-hdmi` settings accept `enabled` or `disabled`. If either setting is omitted, it defaults to `enabled`, so existing configurations and non-Raspberry Pi systems retain their normal audio devices.

The same policies can be inspected or changed without opening an editor:

```sh
sudo a2dpilot audio onboard status
sudo a2dpilot audio onboard disable analog
sudo a2dpilot audio onboard disable hdmi
sudo a2dpilot audio onboard enable all
```

The optional selector is `analog`, `hdmi`, or `all`; omitting it means `all`. A change atomically updates `/etc/a2dpilot.conf`, regenerates the managed WirePlumber fragment, restarts the configured user's WirePlumber session, and lets the daemon reconnect Bluetooth normally. Failed validation or application restores the prior configuration and runtime policy.

Suppression uses [WirePlumber's ALSA device rules](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/alsa.html) and is deliberately narrow. The rules require an internal ALSA card whose reported card name begins with `bcm2835` for analogue audio or `vc4-hdmi` for HDMI audio. USB interfaces and audio HATs are not hidden merely because they are present. The command changes live audio-device visibility only: it does not edit boot firmware, unload drivers, disable HDMI video, or require a reboot. On other hardware the rules normally match nothing, and status reports zero visible matching devices.

### Speaker priority

Speakers are attempted from top to bottom whenever there is no healthy connection. Failed candidates receive an exponential retry cooldown, capped at 60 seconds, so an absent preferred device does not starve a fallback.

Priority is intentionally non-preemptive. Once any configured speaker has a healthy A2DP connection, A2DPilot leaves it alone. A preferred device is reconsidered only after the current connection is lost or removed from the configuration.

### Per-speaker codecs

A speaker line containing only a MAC address uses PipeWire's automatic codec negotiation. Optional codec names after the MAC form a strict preference list:

```ini
speaker = AA:BB:CC:DD:EE:FF aptx_hd aptx sbc_xq sbc
speaker = 11:22:33:44:55:66 sbc
```

A2DPilot selects the first listed codec that PipeWire advertises for that speaker and verifies the negotiated result. If none is available, the speaker is disconnected and put into its normal retry cooldown while A2DPilot tries the next speaker. Include `sbc` explicitly when the policy should always permit the standard A2DP baseline. Changing the list for an active speaker applies the new policy without recreating its BlueZ bond; clearing a strict list reconnects that speaker once so PipeWire resumes automatic negotiation.

Configuration validation checks codec names but does not require the speaker to be online, so actual mutual support is determined when the device connects.

Accepted Trixie A2DP identifiers are `sbc`, `sbc_xq`, `aac`, `aac_eld`, `aptx`, `aptx_hd`, `ldac`, `aptx_ll`, `aptx_ll_duplex`, `faststream`, `faststream_duplex`, `lc3plus_hr`, `opus_05`, `opus_05_51`, `opus_05_71`, `opus_05_duplex`, `opus_05_pro`, and `opus_g`. They are lowercase and whitespace-separated; `auto`, commas, LC3/BAP, aptX Adaptive, and unknown names are rejected.

### Controller selection

`controller = auto` uses the first controller BlueZ presents. On machines with multiple adapters, use the desired controller's MAC address:

```ini
controller = 12:34:56:78:9A:BC
```

### Media controls

`media-controls` accepts:

- `auto`: map available media buttons, but do not consider missing AVRCP a broken audio connection. This is the default.
- `required`: require AVRCP as well as BlueZ and A2DP; reconnect if media control is absent.
- `off`: install no active Triggerhappy mappings and do not check AVRCP.

Mappings remain in the configuration when controls are `off` and become active again if the mode changes. An empty mapping list is valid; A2DPilot then installs an inert Triggerhappy fragment even in `auto` or `required` mode.

### Media-key URLs

Each repeated mapping contains a Linux input key name and one URL or URL path:

```ini
base-url = http://127.0.0.1:32500
media-key = KEY_NEXTSONG player/playback/skipNext?type=music&commandID={command-id}
```

`base-url` is optional. It must be an HTTP(S) origin or path prefix without a query or fragment. A relative mapping is resolved against it, so the usual single-player configuration does not repeat the host. An absolute HTTP(S) mapping overrides the base and may target another host:

Requests are HTTP GETs. Each media action receives one monotonic two-second budget enforced around the complete worker process and shared by configuration parsing, state locking, timeline polling, connection establishment, and the final request, so individually bounded steps cannot accumulate into a long apparent freeze. The generated Triggerhappy command contains only the validated key name; configured URLs are looked up by A2DPilot and passed to `curl` as data, never evaluated as shell code.

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
sudo a2dpilot audio onboard status
```

`devices` prints priority, pairing, trust, BlueZ connection, A2DP, AVRCP, negotiated codec, configured codec policy, and device name for every speaker. A policy appears as `auto` or an ordered value such as `aptx_hd>aptx>sbc`. `status` adds installation, controller, rfkill, base URL, media-key count, onboard-audio policy and visibility, system-service, and audio-user service diagnostics.

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

Uninstall restores replaced files, original system and user unit states, linger settings for every audio user A2DPilot managed, and controller power and rfkill state when the hardware is still present. A2DPilot never removes APT-managed packages or runs `apt autoremove`; distribution packages may be shared with other software and remain under the administrator's control. Failed-install rollback likewise restores only A2DPilot-managed system state and retains any packages APT installed.

Do not manually delete `/var/lib/a2dpilot` before uninstalling; it contains the rollback snapshot.

## Audio codecs

Debian Trixie's `libspa-0.2-bluetooth` package contains PipeWire plugins for SBC, aptX, LDAC, and other codecs and depends on the aptX and LDAC encoder libraries. WirePlumber keeps all available A2DP codecs enabled globally. Bare speaker entries therefore negotiate automatically, while entries with codec preferences select a per-device PipeWire profile after connection.

A2DPilot reads PipeWire's `api.bluez5.codec` value and reports the negotiated result in `devices` and `status`. Automatic entries accept any codec PipeWire exposes, including identifiers newer than A2DPilot. Strict entries accept only their selected configured codec. A2DPilot reapplies strict selection after reconnects but does not save a profile into WirePlumber's user state.

LDAC remains at PipeWire's adaptive-quality default. A successful negotiation only proves that both endpoints accepted a codec; it does not prove that the adapter, radio environment, and speaker can carry it reliably. A2DPilot cannot measure audible dropouts or automatically downgrade an unstable link. Remove the unreliable codec from that speaker's list or configure `sbc` alone to choose a more conservative transport.

aptX Adaptive is not currently exposed by this PipeWire stack. Although the LC3 library is installed transitively, A2DPilot does not enable or manage LE Audio/BAP, experimental ISO sockets, coordinated earbud sets, or LE media controls.

## Useful implementation details

- The daemon reloads the central configuration while running. If a direct manual edit becomes invalid, it retains the last valid configuration and logs the error once per distinct failure.
- Connection health requires BlueZ `Connected: yes` and a matching PipeWire `bluez_output` node. `media-controls = required` additionally checks BlueZ's `MediaControl1` AVRCP state.
- PipeWire lookups run with finite deadlines. Codec-profile discovery parses Trixie's `pw-cli EnumProfile` diagnostic format because that query has no structured CLI output; unrecognized output fails closed as a discovery error rather than selecting a guessed profile.
- Mutating commands and daemon connection cycles serialize through the root-owned `/run/lock/a2dpilot/lock`. Stateful media controls use a separate short-lived lock beneath `/run/a2dpilot/media`, within the same two-second action deadline, so a configuration editor cannot block button handling.
- Root-managed configuration is parsed as data and never sourced as shell code.
- Triggerhappy receives only validated key names; URL resolution and placeholder expansion happen inside `player-control` immediately before `curl` runs. Stateful volume, mute, shuffle, and repeat mappings first poll the player's music timeline. Systemd owns `/run/a2dpilot` and creates its mode-`0700` `media` child for Debian's unprivileged Triggerhappy handler; root CLI requests drop to that handler identity before opening its lock or state files, and per-player pre-mute volumes stored there expire on reboot.
- A2DPilot runs Triggerhappy through its direct service and disables the competing socket-activation unit while installed. Uninstall restores the original state of both units.
- Install records its managed-state rollback snapshot before APT and service mutations. A failed or interrupted installation invokes uninstall automatically; APT-managed packages are retained, and a failed rollback keeps the snapshot for recovery.
- Update preserves that snapshot and replaces only the installed executable; an active daemon is restarted, while an inactive daemon remains stopped.
- Pairing happens after installation commits, so a speaker being unavailable does not erase a valid system setup.
- The system-wide WirePlumber fragment disables seat monitoring and, when requested, hides narrowly matched Raspberry Pi onboard ALSA devices. It deliberately does not override `bluez5.codecs`; per-speaker selection uses advertised PipeWire profile indices with `save: false`.

## Tests

The regression suite requires no root access, packages, Bluetooth hardware, or system-service changes. It uses temporary files and mocked system commands.

Run the same checks as CI:

```sh
bash -n a2dpilot tests/a2dpilot_test.sh tests/run_shellcheck.sh
./tests/run_shellcheck.sh
./tests/a2dpilot_test.sh
```

ShellCheck is pinned in `.shellcheck-version`. The wrapper rejects a missing or
different local version so developer checks use the same analyzer as CI. Exact
release binaries are available from the
[ShellCheck releases](https://github.com/koalaman/shellcheck/releases).

GitHub Actions downloads and checksum-verifies the pinned upstream release,
then runs these checks for pull requests and pushes to `main`.

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

### A preferred codec was not selected

Run `sudo a2dpilot devices` and compare `CODEC` with `CODEC-POLICY`. For an automatic entry, SBC or SBC-XQ is a valid negotiated fallback. For a strict entry, the journal reports the requested and advertised codec sets when they do not overlap. Confirm the exact speaker model supports the desired codec and inspect the associated PipeWire object:

```sh
sudo -u pi env XDG_RUNTIME_DIR="/run/user/$(id -u pi)" \
  wpctl status --name
```

Add lower-priority choices explicitly, normally ending with `sbc`. A2DPilot will not escape a strict list automatically because that could silently re-enable the unstable codec the policy was meant to avoid.

### A negotiated high-definition codec is unreliable

A2DPilot cannot infer stability from successful negotiation. Remove the problematic codec from that speaker's line and leave the reliable choices in preference order:

```ini
speaker = AA:BB:CC:DD:EE:FF aptx sbc_xq sbc
```

For the most conservative test, use `speaker = AA:BB:CC:DD:EE:FF sbc`, apply it with `sudo a2dpilot config`, and confirm `CODEC` reports `sbc`. Also investigate Wi-Fi coexistence, distance, interference, adapter firmware, and USB placement before concluding that the codec itself is unusable.

### Audio works but media buttons do not

First ensure `media-controls = auto` or `required`, then inspect:

```sh
sudo journalctl -b -u triggerhappy.service -u triggerhappy.socket
sudo /usr/local/sbin/a2dpilot player-control KEY_PLAYCD
```

If the direct command reports that no URL is configured, check the exact `KEY_*` name in the `media-key` entry. If it produces a curl error, verify the resolved `base-url` and mapping URL and confirm that the destination service is running. Volume, mute, shuffle, and repeat also require the player to answer `/player/timeline/poll` with a music timeline containing the corresponding state. A speaker may support A2DP without useful AVRCP controls; use `auto` so this does not trigger reconnects, or `off` to disable the mappings.

Every action fails within approximately two seconds when the player or its timeline API is unavailable. If healthy requests still approach that limit, compare a direct `player-control` invocation with the underlying URL; persistent delay in both points to the player API rather than Triggerhappy.

### A configuration edit was rejected

Run:

```sh
sudo a2dpilot config --check
```

The error includes the file and line when possible. Use one instance of every required scalar key, a valid local `audio-user`, `auto` or a controller MAC, a positive interval, `auto|required|off`, optional `enabled|disabled` onboard-audio policies, unique speaker MAC addresses, unique lowercase codecs per speaker, and unique `KEY_*` media mappings. A relative mapping needs `base-url`; an absolute mapping must use HTTP(S). The accepted URL placeholders are `{command-id}`, `{volume-up}`, `{volume-down}`, `{mute-toggle}`, `{shuffle-toggle}`, and `{repeat-cycle}`; stateful placeholders require `base-url` and cannot be mixed in one mapping.

### An onboard audio device did not disappear

Check the configured policy and the currently visible matches:

```sh
sudo a2dpilot audio onboard status
sudo journalctl -b --user-unit=wireplumber.service
```

The rule intentionally ignores USB and HAT devices and only matches internal Raspberry Pi cards reported with `bcm2835*` or `vc4-hdmi*` ALSA card names. A zero count may mean that the hardware is absent, already hidden by the configured policy, or reported under a different name. Re-enable both classes with `sudo a2dpilot audio onboard enable`.

### Installation or uninstall failed

A2DPilot normally rolls failed installation back automatically. If restoration can't finish, `/var/lib/a2dpilot/state` is marked `failed` and retained. Correct the reported service, package, or filesystem problem and run:

```sh
sudo /usr/local/sbin/a2dpilot uninstall --keep-bonds
```

If the installed command was one of the files already restored, rerun the downloaded repository script's `uninstall` command while preserving `/var/lib/a2dpilot`.
