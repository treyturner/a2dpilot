# Advanced usage

## Unattended installation

An unattended installation with no speakers is valid and remains idle until `a2dpilot pair` or `a2dpilot config` is used. Non-interactive installation never restarts a player; it prints an actionable warning for each recognized running instance.

```sh
curl -fsSL https://raw.githubusercontent.com/treyturner/a2dpilot/main/a2dpilot \
  | sudo bash -s -- install --user USER --non-interactive
```

## Updating to a specific revision

An update can instead select one branch, tag, or exact commit:

```sh
sudo a2dpilot update --branch feat/example
sudo a2dpilot update --tag v1.2.3
sudo a2dpilot update --sha 0123456789abcdef0123456789abcdef01234567
```

`--tag`, `--branch`, and `--sha` are mutually exclusive. A SHA must contain all 40 hexadecimal characters. A branch or tag may move; a commit SHA is the immutable choice when an exact revision is required. The downloaded executable must declare a valid A2DPilot version, and `update` rejects revisions older than the running version before changing the installation. To intentionally downgrade, first back up `/etc/a2dpilot.conf`, run `sudo a2dpilot uninstall --keep-bonds`, and then install the older revision explicitly.

Update downloads and syntax-checks the selected Bash program, then atomically replaces only `/usr/local/sbin/a2dpilot`. It does not invoke APT, rewrite `/etc/a2dpilot.conf`, regenerate systemd, WirePlumber, or Triggerhappy files, run `systemctl daemon-reload`, or alter the installation rollback snapshot. If `a2dpilot.service` was active, it is restarted and checked; an inactive service remains inactive. Failed activation restores the previous executable and attempts to restart the previous daemon. This confirms systemd activation, not Bluetooth, PipeWire, or speaker health, which remains the daemon and `status` command's responsibility.

Like streamed installation, updating trusts this repository, GitHub, and the TLS connection. A2DPilot doesn't verify signed releases or a separate checksum manifest.

## Per-speaker codecs

A speaker line containing only a MAC address uses PipeWire's automatic codec negotiation. Optional codec names after the MAC form a strict preference list:

```ini
speaker = AA:BB:CC:DD:EE:FF aptx_hd aptx sbc_xq sbc
speaker = 11:22:33:44:55:66 sbc
```

A2DPilot selects the first listed codec that PipeWire advertises for that speaker and verifies the negotiated result. If none is available, the speaker is disconnected and put into its normal retry cooldown while A2DPilot tries the next speaker. Include `sbc` explicitly when the policy should always permit the standard A2DP baseline. Changing the list for an active speaker applies the new policy without recreating its BlueZ bond; clearing a strict list reconnects that speaker once so PipeWire resumes automatic negotiation.

Configuration validation checks codec names but does not require the speaker to be online, so actual mutual support is determined when the device connects.

Accepted Trixie A2DP identifiers are `sbc`, `sbc_xq`, `aac`, `aac_eld`, `aptx`, `aptx_hd`, `ldac`, `aptx_ll`, `aptx_ll_duplex`, `faststream`, `faststream_duplex`, `lc3plus_hr`, `opus_05`, `opus_05_51`, `opus_05_71`, `opus_05_duplex`, `opus_05_pro`, and `opus_g`. They are lowercase and whitespace-separated; `auto`, commas, LC3/BAP, aptX Adaptive, and unknown names are rejected.

## Media-key URLs

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
