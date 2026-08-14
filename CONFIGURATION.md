# Configuration

All runtime settings live in `/etc/a2dpilot.conf`. Replace `USER` with the local account that runs the player:

```ini
audio-user = USER
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

To validate it without editing:

```sh
sudo a2dpilot config --check
```

## Controller selection

`controller = auto` uses the first controller BlueZ presents. On machines with multiple adapters, use the desired controller's MAC address:

```ini
controller = 12:34:56:78:9A:BC
```

## Speaker priority

Speakers are attempted from top to bottom whenever there is no healthy connection. Failed candidates receive an exponential retry cooldown, capped at 60 seconds, so an absent preferred device does not starve a fallback.

Priority is intentionally non-preemptive. Once any configured speaker has a healthy A2DP connection, A2DPilot leaves it alone. A preferred device is reconsidered only after the current connection is lost or removed from the configuration.

## Media controls

`media-controls` accepts:

- `auto`: map available media buttons, but do not consider missing AVRCP a broken audio connection. This is the default.
- `required`: require AVRCP as well as BlueZ and A2DP; reconnect if media control is absent.
- `off`: install no active Triggerhappy mappings and do not check AVRCP.

Mappings remain in the configuration when controls are `off` and become active again if the mode changes. An empty mapping list is valid; A2DPilot then installs an inert Triggerhappy fragment even in `auto` or `required` mode.

## Raspberry Pi onboard audio

The optional `onboard-analog` and `onboard-hdmi` settings accept `enabled` or `disabled`. If either setting is omitted, it defaults to `enabled`, so existing configurations and non-Raspberry Pi systems retain their normal audio devices.

The same policies can be inspected or changed without opening an editor:

```sh
sudo a2dpilot audio onboard status
sudo a2dpilot audio onboard disable analog
sudo a2dpilot audio onboard disable hdmi
sudo a2dpilot audio onboard enable all
```

The optional selector is `analog`, `hdmi`, or `all`; omitting it means `all`. A change atomically updates `/etc/a2dpilot.conf`, regenerates the managed WirePlumber fragment, restarts the configured user's WirePlumber session, and lets the daemon reconnect Bluetooth normally. Failed validation or application restores the prior configuration and runtime policy.

Suppression uses [WirePlumber's ALSA device rules](https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/alsa.html) and is deliberately narrow. The rules require an internal ALSA card reported as `bcm2835 Headphones` for analogue audio or with a `vc4-hdmi` name for HDMI audio. USB interfaces, audio HATs, and legacy `bcm2835 HDMI` cards are not hidden by the analogue policy. The command changes live audio-device visibility only: it does not edit boot firmware, unload drivers, disable HDMI video, or require a reboot. On other hardware the rules normally match nothing, and status reports zero visible matching devices.

## Advanced configuration

See [`ADVANCED.md`](ADVANCED.md) for configuration of [per-speaker codecs](ADVANCED.md#per-speaker-codecs) or custom [media-key URLs](ADVANCED.md#media-key-urls).
