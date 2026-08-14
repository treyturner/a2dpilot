# Implementation

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
| `/var/lib/a2dpilot/`                                   | Root-only backups, rollback metadata, user snapshots, created-bond provenance, and current default-sink ownership |

## Notes

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
- Default selection uses bounded `wpctl` and `pw-metadata` calls and records only the last selection A2DPilot successfully verified. Forgetting that speaker, changing the audio user, or uninstalling clears the configured default only if it still matches the recorded sink; a later user change is preserved.
- A2DPilot does not enumerate or retarget existing playback streams. During interactive installation it can instead restart an exact Caldera Music or Plexamp user service after validating its process owner, cgroup, active service, and process identity. The restart is bounded to ten seconds and never invokes a player API or sends a process signal directly.
- The system-wide WirePlumber fragment disables seat monitoring and, when requested, hides narrowly matched Raspberry Pi onboard ALSA devices. It deliberately does not override `bluez5.codecs`; per-speaker selection uses advertised PipeWire profile indices with `save: false`.

## Audio codecs

Debian Trixie's `libspa-0.2-bluetooth` package contains PipeWire plugins for SBC, aptX, LDAC, and other codecs and depends on the aptX and LDAC encoder libraries. WirePlumber keeps all available A2DP codecs enabled globally. Bare speaker entries therefore negotiate automatically, while entries with codec preferences select a per-device PipeWire profile after connection.

A2DPilot reads PipeWire's `api.bluez5.codec` value and reports the negotiated result in `devices` and `status`. Automatic entries accept any codec PipeWire exposes, including identifiers newer than A2DPilot. Strict entries accept only their selected configured codec. A2DPilot reapplies strict selection after reconnects but does not save a profile into WirePlumber's user state.

LDAC remains at PipeWire's adaptive-quality default. A successful negotiation only proves that both endpoints accepted a codec; it does not prove that the adapter, radio environment, and speaker can carry it reliably. A2DPilot cannot measure audible dropouts or automatically downgrade an unstable link. Remove the unreliable codec from that speaker's list or configure `sbc` alone to choose a more conservative transport.

## Tests

The regression suite requires no root access, packages, Bluetooth hardware, or system-service changes. It uses temporary files and mocked system commands.

To run the same checks as CI:

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
