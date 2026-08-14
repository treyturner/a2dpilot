# Troubleshooting

Start with:

```sh
sudo a2dpilot status
sudo journalctl -b -u a2dpilot.service -u bluetooth.service
```

## No Bluetooth controller is available

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

## A speaker will not pair

- Put the speaker into pairing mode, not merely powered-on mode.
- Disconnect phones or computers that already own the active connection.
- Confirm it appears during `sudo a2dpilot pair`.
- Try an explicit address and agent capability.
- If the speaker was reset but BlueZ retained the old bond, use `a2dpilot forget` and pair it again.

## BlueZ connects but audio is absent

From a shell logged in as the configured audio user, inspect PipeWire:

```sh
wpctl status --name
```

Look for `bluez_output.` followed by the speaker MAC with underscores. Check the persistent user session with:

```sh
loginctl show-user "$USER" -p Linger
systemctl status "user@$(id -u).service"
```

`sudo a2dpilot status` reports both the active managed sink and PipeWire's effective default. The daemon retries default selection while the speaker remains healthy, but it deliberately does not seize or migrate a stream that a player opened earlier. If Caldera Music or Plexamp was already running when audio policy changed, restart its user service so it opens a fresh output:

```sh
systemctl --user restart caldera-music.service
```

Use the service name shown by `a2dpilot status`. A `direct ALSA` backend can retain a hardware PCM and bypass PipeWire; a safely detected service is why interactive installation offers the same restart after pairing. Restarting may leave playback paused, and A2DPilot does not issue a resume command. If status shows `no safe user service`, restart the player through its own documented supervisor rather than killing the reported PID.

## A preferred codec was not selected

Run `sudo a2dpilot devices` and compare `CODEC` with `CODEC-POLICY`. For an automatic entry, SBC or SBC-XQ is a valid negotiated fallback. For a strict entry, the journal reports the requested and advertised codec sets when they do not overlap. Confirm the exact speaker model supports the desired codec and inspect the associated PipeWire object:

```sh
wpctl status --name
```

Add lower-priority choices explicitly, normally ending with `sbc`. A2DPilot will not escape a strict list automatically because that could silently re-enable the unstable codec the policy was meant to avoid.

## A negotiated high-definition codec is unreliable

A2DPilot cannot infer stability from successful negotiation. Remove the problematic codec from that speaker's line and leave the reliable choices in preference order:

```ini
speaker = AA:BB:CC:DD:EE:FF aptx sbc_xq sbc
```

For the most conservative test, use `speaker = AA:BB:CC:DD:EE:FF sbc`, apply it with `sudo a2dpilot config`, and confirm `CODEC` reports `sbc`. Also investigate Wi-Fi coexistence, distance, interference, adapter firmware, and USB placement before concluding that the codec itself is unusable.

## Audio works but media buttons do not

First ensure `media-controls = auto` or `required`, then inspect:

```sh
sudo journalctl -b -u triggerhappy.service -u triggerhappy.socket
sudo /usr/local/sbin/a2dpilot player-control KEY_PLAYCD
```

If the direct command reports that no URL is configured, check the exact `KEY_*` name in the `media-key` entry. If it produces a curl error, verify the resolved `base-url` and mapping URL and confirm that the destination service is running. Volume, mute, shuffle, and repeat also require the player to answer `/player/timeline/poll` with a music timeline containing the corresponding state. A speaker may support A2DP without useful AVRCP controls; use `auto` so this does not trigger reconnects, or `off` to disable the mappings.

Every action fails within approximately two seconds when the player or its timeline API is unavailable. If healthy requests still approach that limit, compare a direct `player-control` invocation with the underlying URL; persistent delay in both points to the player API rather than Triggerhappy.

## A configuration edit was rejected

Run:

```sh
sudo a2dpilot config --check
```

The error includes the file and line when possible. Use one instance of every required scalar key, a valid local `audio-user`, `auto` or a controller MAC, a positive interval, `auto|required|off`, optional `enabled|disabled` onboard-audio policies, unique speaker MAC addresses, unique lowercase codecs per speaker, and unique `KEY_*` media mappings. A relative mapping needs `base-url`; an absolute mapping must use HTTP(S). The accepted URL placeholders are `{command-id}`, `{volume-up}`, `{volume-down}`, `{mute-toggle}`, `{shuffle-toggle}`, and `{repeat-cycle}`; stateful placeholders require `base-url` and cannot be mixed in one mapping.

## An onboard audio device did not disappear

Check the configured policy and the currently visible matches:

```sh
sudo a2dpilot audio onboard status
journalctl -b --user-unit=wireplumber.service
```

The rule intentionally ignores USB and HAT devices and only matches internal Raspberry Pi cards reported as `bcm2835 Headphones` or with `vc4-hdmi*` ALSA card names. A zero count may mean that the hardware is absent, already hidden by the configured policy, or reported under a different name. Re-enable both classes with `sudo a2dpilot audio onboard enable`.

## Installation or uninstall failed

A2DPilot normally rolls failed installation back automatically. If restoration can't finish, `/var/lib/a2dpilot/state` is marked `failed` and retained. Correct the reported service, package, or filesystem problem and run:

```sh
sudo /usr/local/sbin/a2dpilot uninstall --keep-bonds
```

If the installed command was one of the files already restored, rerun the downloaded repository script's `uninstall` command while preserving `/var/lib/a2dpilot`.
