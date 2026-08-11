#!/usr/bin/env bash
# SC2016: Some fixtures intentionally emit literal shell variables for a mock
# executable or verify that shell-like configuration text is not evaluated.
# SC2034: Tests inject application globals that are consumed after sourcing;
# ShellCheck cannot follow those assignments across the test/app boundary.
# SC2317 (ShellCheck 0.9) and SC2329 (newer releases): Test cases use
# dynamic dispatch, and command mocks override functions called indirectly by
# the sourced application. Both diagnostics are false positives in this file.
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -uo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_DIR=$(cd -- "$TEST_DIR/.." && pwd)
APP=$PROJECT_DIR/a2dpilot
TESTS_RUN=0
TESTS_FAILED=0

fail() {
  printf '    %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected=$1 actual=$2
  [[ $actual == "$expected" ]] || fail "expected '$expected', got '$actual'"
}

assert_contains() {
  local value=$1 expected=$2
  [[ $value == *"$expected"* ]] || fail "expected output to contain: $expected"
}

assert_not_contains() {
  local value=$1 unexpected=$2
  [[ $value != *"$unexpected"* ]] || fail "expected output not to contain: $unexpected"
}

assert_file_contains() {
  local path=$1 expected=$2
  grep -Fq -- "$expected" "$path" || fail "$path does not contain: $expected"
}

assert_file_not_contains() {
  local path=$1 unexpected=$2
  ! grep -Fq -- "$unexpected" "$path" || fail "$path unexpectedly contains: $unexpected"
}

expect_failure_contains() {
  local expected=$1 output rc
  shift
  set +e
  output=$("$@" 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail "command unexpectedly succeeded: $*"
  assert_contains "$output" "$expected"
}

cleanup_scratch_dir() {
  [[ -n ${TEST_SCRATCH:-} && -d $TEST_SCRATCH ]] || return 0
  find "$TEST_SCRATCH" -depth -delete
}

setup_scratch_dir() {
  TEST_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/a2dpilot-test.XXXXXX")
  trap cleanup_scratch_dir EXIT
}

load_app() {
  set --
  # SC1090: APP is derived from this test file's directory and deliberately
  # sourced so each isolated test can exercise and override application code.
  # shellcheck disable=SC1090
  source "$APP" >/dev/null
  # Keep command mocks visible to controller batches. Production uses coreutils
  # timeout around bluetoothctl; isolated tests substitute a shell function.
  run_bounded_bluetoothctl() {
    shift
    bluetoothctl "$@"
  }
}

configure_scratch_paths() {
  CONFIG_FILE=$TEST_SCRATCH/etc/a2dpilot.conf
  STATE_DIR=$TEST_SCRATCH/state
  BACKUP_DIR=$STATE_DIR/backup
  STATE_FILE=$STATE_DIR/state
  INSTALLED_CLI=$TEST_SCRATCH/usr/local/sbin/a2dpilot
  SYSTEMD_UNIT=$TEST_SCRATCH/etc/systemd/system/a2dpilot.service
  WIREPLUMBER_CONF=$TEST_SCRATCH/etc/wireplumber/wireplumber.conf.d/51-a2dpilot.conf
  TRIGGER_CONF=$TEST_SCRATCH/etc/triggerhappy/triggers.d/a2dpilot.conf
  LOCK_FILE=$TEST_SCRATCH/run/lock/a2dpilot/lock
  MEDIA_STATE_ROOT=$TEST_SCRATCH/run/a2dpilot
  MEDIA_STATE_DIR=$MEDIA_STATE_ROOT/media
  MEDIA_LOCK_FILE=$MEDIA_STATE_DIR/media.lock
  ROUTING_STATE_FILE=$STATE_DIR/routing-overrides
  ROUTING_STATE_SPEAKERS=([AA:BB:CC:DD:EE:FF]=1)
  MEDIA_RUNTIME_USER=$(id -un)
  install -d "$(dirname "$CONFIG_FILE")" "$(dirname "$LOCK_FILE")" \
    "$STATE_DIR" "$BACKUP_DIR" "$MEDIA_STATE_ROOT"
}

write_test_config() {
  local path=$1 user=$2
  shift 2
  {
    printf 'audio-user = %s\n' "$user"
    printf 'controller = auto\n'
    printf 'reconnect-interval = 5\n'
    printf 'media-controls = auto\n'
    printf 'base-url = http://127.0.0.1:32500/\n'
    printf 'media-key = KEY_PLAYCD player/playback/playPause?type=music&commandID={command-id}\n'
    printf 'media-key = KEY_PAUSECD player/playback/playPause?type=music&commandID={command-id}\n'
    printf 'media-key = KEY_NEXTSONG player/playback/skipNext?type=music&commandID={command-id}\n'
    printf 'media-key = KEY_PREVIOUSSONG player/playback/skipPrevious?type=music&commandID={command-id}\n'
    while [[ $# -gt 0 ]]; do
      printf 'speaker = %s\n' "$1"
      shift
    done
  } > "$path"
}

write_update_payload_version() {
  local path=$1 version=$2
  shift 2
  {
    printf '#!/usr/bin/env bash\n'
    printf 'A2DPILOT_VERSION=%s\n' "$version"
    printf '%s\n' "$@"
  } > "$path"
}

write_update_payload() {
  local path=$1
  shift
  write_update_payload_version "$path" "$A2DPILOT_VERSION" "$@"
}

run_test() {
  local name=$1 test_function=$2 rc
  TESTS_RUN=$((TESTS_RUN + 1))
  set +e
  (
    set -Eeuo pipefail
    "$test_function"
  )
  rc=$?
  set -e
  if (( rc == 0 )); then
    printf 'ok %d - %s\n' "$TESTS_RUN" "$name"
  else
    printf 'not ok %d - %s\n' "$TESTS_RUN" "$name"
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

test_syntax_help_and_stream_bootstrap() {
  local local_help streamed_help output
  bash -n "$APP"
  local_help=$(bash "$APP" --help)
  streamed_help=$(bash -s -- --help < "$APP")
  assert_eq "$local_help" "$streamed_help"
  assert_contains "$local_help" 'a2dpilot install [--user USER] [--non-interactive]'
  assert_contains "$local_help" 'a2dpilot config [--check]'
  assert_contains "$local_help" 'a2dpilot audio onboard disable [analog | hdmi | all]'
  assert_contains "$local_help" 'a2dpilot update [--tag TAG | --branch BRANCH | --sha SHA]'
  assert_contains "$local_help" 'uninstall [--keep-bonds | --remove-bonds]'
  assert_not_contains "$local_help" '--with-dependencies'
  assert_not_contains "$local_help" 'update --mac'
  assert_not_contains "$local_help" '--control-helper'
  set +e
  output=$(bash "$APP" obsolete 2>&1)
  set -e
  assert_contains "$output" 'Unknown command: obsolete'
}

test_managed_package_list() {
  local package
  local -a expected=(
    bluez bluez-firmware pipewire pipewire-alsa pipewire-pulse wireplumber
    libspa-0.2-bluetooth rtkit triggerhappy curl rfkill
  )
  local -A seen=()
  load_app
  assert_eq nobody "$MEDIA_RUNTIME_USER"
  for package in "${PACKAGES[@]}"; do
    [[ ! ${seen[$package]+present} ]] || fail "duplicate package: $package"
    seen[$package]=1
  done
  for package in "${expected[@]}"; do
    [[ ${seen[$package]+present} ]] || fail "missing package: $package"
  done
  assert_eq "${#expected[@]}" "${#PACKAGES[@]}"
}

test_config_parser_and_normalization() {
  local user
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  {
    printf '# A safe config\n\n'
    printf ' audio-user = %s \n' "$user"
    printf 'controller = aa:bb:cc:dd:ee:01\n'
    printf 'reconnect-interval = 9\n'
    printf 'media-controls = required\n'
    printf 'base-url = https://player.example:32500/api///\n'
    printf 'media-key = KEY_NEXTSONG /next?request={command-id}\n'
    printf 'media-key = KEY_PLAYPAUSE https://other.example/play?literal=yes\n'
    printf 'speaker = aa:bb:cc:dd:ee:ff aptx_hd aptx sbc_xq sbc\n'
    printf 'speaker = 10:20:30:40:50:60\n'
  } > "$CONFIG_FILE"
  parse_config "$CONFIG_FILE"
  assert_eq "$user" "$CFG_AUDIO_USER"
  assert_eq AA:BB:CC:DD:EE:01 "$CFG_CONTROLLER"
  assert_eq 9 "$CFG_RECONNECT_INTERVAL"
  assert_eq required "$CFG_MEDIA_CONTROLS"
  assert_eq enabled "$CFG_ONBOARD_ANALOG"
  assert_eq enabled "$CFG_ONBOARD_HDMI"
  assert_eq https://player.example:32500/api "$CFG_BASE_URL"
  assert_eq KEY_NEXTSONG "${CFG_MEDIA_KEYS[0]}"
  assert_eq '/next?request={command-id}' "${CFG_MEDIA_URLS[0]}"
  assert_eq KEY_PLAYPAUSE "${CFG_MEDIA_KEYS[1]}"
  assert_eq 'https://other.example/play?literal=yes' "${CFG_MEDIA_URLS[1]}"
  assert_eq AA:BB:CC:DD:EE:FF "${CFG_SPEAKERS[0]}"
  assert_eq 10:20:30:40:50:60 "${CFG_SPEAKERS[1]}"
  assert_eq 'aptx_hd aptx sbc_xq sbc' "${CFG_SPEAKER_CODECS[0]}"
  assert_eq '' "${CFG_SPEAKER_CODECS[1]}"
}

test_speaker_codec_configuration() {
  local user mac=AA:BB:CC:DD:EE:FF all_codecs codec codec_id
  local -a supported=()
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  all_codecs='sbc sbc_xq aac aac_eld aptx aptx_hd ldac aptx_ll aptx_ll_duplex faststream faststream_duplex lc3plus_hr opus_05 opus_05_51 opus_05_71 opus_05_duplex opus_05_pro opus_g'
  write_test_config "$CONFIG_FILE" "$user" "$mac $all_codecs"
  parse_config "$CONFIG_FILE"
  assert_eq "$all_codecs" "${CFG_SPEAKER_CODECS[0]}"
  assert_eq "$all_codecs" "$(speaker_codec_policy "$mac")"
  assert_contains "$(speaker_codec_policy_display "$mac")" 'aptx>aptx_hd>ldac'
  read -r -a supported <<< "$all_codecs"
  for codec in "${supported[@]}"; do
    codec_id=$(a2dp_codec_id "$codec")
    assert_eq "$codec" "$(a2dp_codec_name "$codec_id")"
  done

  write_test_config "$CONFIG_FILE" "$user" "$mac sbc sbc"
  if parse_config "$CONFIG_FILE"; then fail 'duplicate speaker codec was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'duplicate codec'

  for invalid in auto SBC sbc,sbc_xq lc3 aptx_adaptive unknown_codec; do
    write_test_config "$CONFIG_FILE" "$user" "$mac $invalid"
    if parse_config "$CONFIG_FILE"; then fail "invalid speaker codec was accepted: $invalid"; fi
    assert_contains "$CONFIG_ERROR" 'unsupported A2DP codec'
  done
}

test_onboard_audio_configuration() {
  local user
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)

  write_test_config "$CONFIG_FILE" "$user" AA:BB:CC:DD:EE:FF
  parse_config "$CONFIG_FILE"
  assert_eq enabled "$CFG_ONBOARD_ANALOG"
  assert_eq enabled "$CFG_ONBOARD_HDMI"

  printf 'onboard-analog = disabled\nonboard-hdmi = disabled\n' >> "$CONFIG_FILE"
  parse_config "$CONFIG_FILE"
  assert_eq disabled "$CFG_ONBOARD_ANALOG"
  assert_eq disabled "$CFG_ONBOARD_HDMI"
  assert_eq AA:BB:CC:DD:EE:FF "${CFG_SPEAKERS[0]}"

  printf 'onboard-analog = enabled\n' >> "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'duplicate onboard-analog was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'duplicate setting: onboard-analog'

  write_test_config "$CONFIG_FILE" "$user"
  printf 'onboard-hdmi = hidden\n' >> "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'invalid onboard-hdmi policy was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'onboard-hdmi must be enabled or disabled'

  write_default_config "$CONFIG_FILE" "$user"
  assert_file_contains "$CONFIG_FILE" 'onboard-analog = enabled'
  assert_file_contains "$CONFIG_FILE" 'onboard-hdmi = enabled'
}

test_default_media_key_mappings() {
  local user index
  local -a expected_keys=(
    KEY_PLAYPAUSE KEY_PLAY KEY_PLAYCD KEY_PAUSE KEY_PAUSECD
    KEY_STOP KEY_STOPCD KEY_NEXT KEY_NEXTSONG KEY_PREVIOUS KEY_PREVIOUSSONG
    KEY_FORWARD KEY_FASTFORWARD KEY_REWIND KEY_FASTREVERSE
    KEY_VOLUMEUP KEY_VOLUMEDOWN KEY_MUTE KEY_SHUFFLE KEY_MEDIA_REPEAT
  )
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_default_config "$CONFIG_FILE" "$user"
  parse_config "$CONFIG_FILE"
  assert_eq "${#expected_keys[@]}" "${#CFG_MEDIA_KEYS[@]}"
  for index in "${!expected_keys[@]}"; do
    assert_eq "${expected_keys[$index]}" "${CFG_MEDIA_KEYS[$index]}"
  done
  assert_eq '/player/playback/play?type=music&commandID={command-id}' "${CFG_MEDIA_URLS[2]}"
  assert_eq '/player/playback/pause?type=music&commandID={command-id}' "${CFG_MEDIA_URLS[4]}"
  assert_eq '/player/playback/stepForward?type=music&commandID={command-id}' "${CFG_MEDIA_URLS[12]}"
  assert_eq '/player/playback/stepBack?type=music&commandID={command-id}' "${CFG_MEDIA_URLS[14]}"
  assert_eq '/player/playback/setParameters?type=music&volume={volume-up}&commandID={command-id}' \
    "${CFG_MEDIA_URLS[15]}"
  assert_eq '/player/playback/setParameters?type=music&volume={mute-toggle}&commandID={command-id}' \
    "${CFG_MEDIA_URLS[17]}"
  assert_eq '/player/playback/setParameters?type=music&shuffle={shuffle-toggle}&commandID={command-id}' \
    "${CFG_MEDIA_URLS[18]}"
  assert_eq '/player/playback/setParameters?type=music&repeat={repeat-cycle}&commandID={command-id}' \
    "${CFG_MEDIA_URLS[19]}"
}

test_config_parser_rejections_and_no_eval() {
  local user marker
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  marker=$TEST_SCRATCH/executed
  write_test_config "$CONFIG_FILE" "$user" AA:BB:CC:DD:EE:FF aa:bb:cc:dd:ee:ff
  if parse_config "$CONFIG_FILE"; then fail 'duplicate MAC was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'duplicate speaker'

  write_test_config "$CONFIG_FILE" "$user"
  printf 'unknown-setting = true\n' >> "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'unknown key was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'unknown setting'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's/reconnect-interval = 5/reconnect-interval = 0/' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'zero interval was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'positive integer'

  write_test_config "$CONFIG_FILE" "\$(touch $marker)"
  if parse_config "$CONFIG_FILE"; then fail 'code-like user value was accepted'; fi
  [[ ! -e $marker ]] || fail 'configuration was evaluated as shell code'

  write_test_config "$CONFIG_FILE" "$user"
  user_home() { printf '/definitely/not/a/home\n'; }
  if parse_config "$CONFIG_FILE"; then fail 'audio user without a usable home was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'no usable home directory'

  write_test_config "$TEST_SCRATCH/real-config" "$user"
  unlink "$CONFIG_FILE"
  ln -s "$TEST_SCRATCH/real-config" "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'symlinked configuration was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'missing or unsafe'
}

test_invalid_reload_retains_last_valid_configuration() {
  local user
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" 'AA:BB:CC:DD:EE:FF aptx sbc'
  parse_config "$CONFIG_FILE"
  printf 'this is not configuration\n' > "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'invalid reload unexpectedly succeeded'; fi
  assert_eq "$user" "$CFG_AUDIO_USER"
  assert_eq 5 "$CFG_RECONNECT_INTERVAL"
  assert_eq http://127.0.0.1:32500 "$CFG_BASE_URL"
  assert_eq KEY_PLAYCD "${CFG_MEDIA_KEYS[0]}"
  assert_eq '/player/playback/playPause?type=music&commandID={command-id}' "${CFG_MEDIA_URLS[0]}"
  assert_eq AA:BB:CC:DD:EE:FF "${CFG_SPEAKERS[0]}"
  assert_eq 'aptx sbc' "${CFG_SPEAKER_CODECS[0]}"
}

test_config_parser_avoids_legacy_subshell_helpers() {
  local user
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" aa:bb:cc:dd:ee:ff
  trim() { fail 'parse_config invoked the legacy trim output helper'; }
  normalize_mac() { fail 'parse_config invoked the legacy MAC output helper'; }
  normalize_base_url() { fail 'parse_config invoked the legacy base URL output helper'; }
  normalize_media_url_template() { fail 'parse_config invoked the legacy media URL output helper'; }

  parse_config "$CONFIG_FILE"
  assert_eq AA:BB:CC:DD:EE:FF "${CFG_SPEAKERS[0]}"
  assert_eq http://127.0.0.1:32500 "$CFG_BASE_URL"
  assert_eq '/player/playback/skipNext?type=music&commandID={command-id}' \
    "${CFG_MEDIA_URLS[2]}"
}

test_media_url_configuration_validation() {
  local user
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)

  write_test_config "$CONFIG_FILE" "$user"
  printf 'media-key = KEY_NEXTSONG https://override.example/next\n' >> "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'duplicate media key was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'duplicate media key'

  write_test_config "$CONFIG_FILE" "$user"
  printf 'base-url = https://duplicate.example\n' >> "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'duplicate base-url was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'duplicate setting: base-url'

  write_test_config "$CONFIG_FILE" "$user"
  printf 'media-key = next https://override.example/next\n' >> "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'invalid media key name was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'invalid media key name'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i '/^base-url =/d' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'relative mapping without base-url was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'relative media-key URL requires base-url'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i '/^base-url =/d; /^media-key =/d' "$CONFIG_FILE"
  printf 'media-key = KEY_CUSTOM https://other.example/action?literal=yes\n' >> "$CONFIG_FILE"
  parse_config "$CONFIG_FILE"
  assert_eq '' "$CFG_BASE_URL"
  assert_eq KEY_CUSTOM "${CFG_MEDIA_KEYS[0]}"

  write_test_config "$CONFIG_FILE" "$user"
  sed -i '/^media-key =/d' "$CONFIG_FILE"
  parse_config "$CONFIG_FILE"
  assert_eq 0 "${#CFG_MEDIA_KEYS[@]}"

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#media-key = KEY_PLAYCD .*#media-key = KEY_PLAYCD ftp://other.example/action#' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'non-HTTP media URL was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'invalid media-key URL or placeholder'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#media-key = KEY_PLAYCD .*#media-key = KEY_PLAYCD //other.example/action#' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'scheme-relative media URL was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'invalid media-key URL or placeholder'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#media-key = KEY_PLAYCD .*#media-key = KEY_PLAYCD ../action#' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'parent-relative media URL was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'invalid media-key URL or placeholder'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#media-key = KEY_PLAYCD .*#media-key = KEY_PLAYCD ?action=next#' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'query-only media URL was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'invalid media-key URL or placeholder'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#base-url = .*#base-url = http://127.0.0.1:32500/api?bad=yes#' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'base-url query was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'without a query or fragment'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#base-url = .*#base-url = http://-bad.example:70000#' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'malformed base-url authority was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'base-url must be an HTTP or HTTPS URL'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#base-url = .*#base-url = http://[::::]:32500#' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'malformed IPv6 authority was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'base-url must be an HTTP or HTTPS URL'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#base-url = .*#base-url = http://localhost/bad%path#' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'malformed base-url path was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'base-url must be an HTTP or HTTPS URL'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's/{command-id}/{unknown}/' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'unknown URL placeholder was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'invalid media-key URL or placeholder'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i '/^base-url =/d; /^media-key =/d' "$CONFIG_FILE"
  printf 'media-key = KEY_VOLUMEUP https://player.example/set?volume={volume-up}\n' >> "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'stateful placeholder without base-url was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'stateful media-key placeholder requires base-url'

  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#{command-id}#{volume-up}\&down={volume-down}#' "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'multiple stateful placeholders were accepted'; fi
  assert_contains "$CONFIG_ERROR" 'invalid media-key URL or placeholder'

  write_test_config "$CONFIG_FILE" "$user"
  {
    printf 'media-key = KEY_CUSTOM https://other.example/'
    printf '\a'
    printf 'action\n'
  } >> "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'control character in URL was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'invalid media-key URL or placeholder'

  write_test_config "$CONFIG_FILE" "$user"
  printf 'player-url = http://legacy.example\n' >> "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'removed player-url setting was accepted'; fi
  assert_contains "$CONFIG_ERROR" 'unknown setting: player-url'
}

test_generated_integration_files() {
  setup_scratch_dir
  load_app
  configure_scratch_paths
  install -d "$(dirname "$WIREPLUMBER_CONF")" "$(dirname "$TRIGGER_CONF")" "$(dirname "$SYSTEMD_UNIT")"
  CFG_MEDIA_KEYS=(KEY_NEXTSONG KEY_PREVIOUSSONG)
  CFG_MEDIA_URLS=(
    '/next?commandID={command-id}'
    'https://other.example/previous'
  )
  write_wireplumber_config "$WIREPLUMBER_CONF"
  write_trigger_config "$TRIGGER_CONF" auto
  write_systemd_unit "$SYSTEMD_UNIT"
  assert_file_contains "$WIREPLUMBER_CONF" 'monitor.bluez.seat-monitoring = disabled'
  assert_file_not_contains "$WIREPLUMBER_CONF" 'monitor.alsa.rules'
  assert_file_not_contains "$WIREPLUMBER_CONF" 'bluez5.codecs'
  assert_file_contains "$TRIGGER_CONF" 'a2dpilot player-control KEY_NEXTSONG'
  assert_file_contains "$TRIGGER_CONF" 'a2dpilot player-control KEY_PREVIOUSSONG'
  assert_file_not_contains "$TRIGGER_CONF" 'https://other.example'
  assert_file_contains "$SYSTEMD_UNIT" 'ExecStart='
  assert_file_contains "$SYSTEMD_UNIT" 'a2dpilot daemon'
  assert_file_contains "$SYSTEMD_UNIT" 'RuntimeDirectory=a2dpilot'
  assert_file_contains "$SYSTEMD_UNIT" 'RuntimeDirectoryMode=0755'
  assert_file_contains "$SYSTEMD_UNIT" 'RuntimeDirectoryPreserve=restart'
  assert_file_contains "$SYSTEMD_UNIT" "ExecStartPre=/usr/bin/install -d -o $MEDIA_RUNTIME_USER"
  assert_file_contains "$SYSTEMD_UNIT" "-m 0700 $MEDIA_STATE_DIR"
  assert_file_contains "$SYSTEMD_UNIT" 'Before=triggerhappy.service'

  CFG_ONBOARD_ANALOG=disabled
  CFG_ONBOARD_HDMI=enabled
  write_wireplumber_config "$WIREPLUMBER_CONF"
  assert_file_contains "$WIREPLUMBER_CONF" 'monitor.alsa.rules'
  assert_file_contains "$WIREPLUMBER_CONF" 'device.form-factor = "internal"'
  assert_file_contains "$WIREPLUMBER_CONF" 'api.alsa.card.name = "~bcm2835.*"'
  assert_file_contains "$WIREPLUMBER_CONF" 'device.disabled = true'
  assert_file_not_contains "$WIREPLUMBER_CONF" 'vc4-hdmi'
  assert_file_not_contains "$WIREPLUMBER_CONF" 'bluez5.codecs'

  CFG_ONBOARD_HDMI=disabled
  write_wireplumber_config "$WIREPLUMBER_CONF"
  assert_file_contains "$WIREPLUMBER_CONF" 'api.alsa.card.name = "~bcm2835.*"'
  assert_file_contains "$WIREPLUMBER_CONF" 'api.alsa.card.name = "~vc4-hdmi.*"'

  write_trigger_config "$TRIGGER_CONF" off
  assert_file_contains "$TRIGGER_CONF" 'media controls are disabled'
  assert_file_not_contains "$TRIGGER_CONF" 'KEY_NEXTSONG'

  CFG_MEDIA_KEYS=()
  CFG_MEDIA_URLS=()
  write_trigger_config "$TRIGGER_CONF" required
  assert_file_contains "$TRIGGER_CONF" 'no media-key mappings are configured'
}

test_wireplumber_config_path_safety() {
  local parent redirected
  setup_scratch_dir
  load_app
  configure_scratch_paths
  parent=$(dirname "$WIREPLUMBER_CONF")
  redirected=$TEST_SCRATCH/redirected-wireplumber-config
  install -d "$(dirname "$parent")" "$redirected"
  ln -s "$redirected" "$parent"
  as_user_systemctl() { fail 'unsafe WirePlumber config restarted WirePlumber'; }

  expect_failure_contains 'Refusing to traverse symlinked directory' apply_wireplumber_config
  [[ -z $(find "$redirected" -mindepth 1 -print -quit) ]] || \
    fail 'apply_wireplumber_config wrote through its symlinked parent'

  unlink "$parent"
  install -d "$parent"
  ln -s "$redirected/target" "$WIREPLUMBER_CONF"
  expect_failure_contains '' apply_wireplumber_config
  [[ ! -e $redirected/target ]] || \
    fail 'apply_wireplumber_config wrote through its symlinked target'
}

test_trigger_config_rejects_symlinked_parent() {
  local parent redirected
  setup_scratch_dir
  load_app
  configure_scratch_paths
  parent=$(dirname "$TRIGGER_CONF")
  redirected=$TEST_SCRATCH/redirected-trigger-config
  install -d "$(dirname "$parent")" "$redirected"
  ln -s "$redirected" "$parent"
  CFG_MEDIA_KEYS=(KEY_PLAYCD)
  CFG_MEDIA_URLS=('/player/playback/playPause')
  systemctl() { printf '%s\n' "$*" >> "$TEST_SCRATCH/systemctl.log"; }

  expect_failure_contains 'Refusing to traverse symlinked directory' apply_trigger_config auto
  [[ -z $(find "$redirected" -mindepth 1 -print -quit) ]] || \
    fail 'apply_trigger_config wrote through its symlinked parent'
  [[ ! -e $TEST_SCRATCH/systemctl.log ]] || \
    fail 'apply_trigger_config restarted Triggerhappy after rejecting the parent'
}

test_noninteractive_install_and_uninstall_fixture() {
  local user apt_log output
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  apt_log=$TEST_SCRATCH/apt.log

  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  has_tty() { return 1; }
  install() {
    local -a forwarded=()
    while [[ $# -gt 0 ]]; do
      case $1 in
        -o|-g) shift 2 ;;
        *) forwarded+=("$1"); shift ;;
      esac
    done
    /usr/bin/install "${forwarded[@]}"
  }
  chown() { :; }
  record_system_service_states() { : > "$STATE_DIR/system-service-states"; }
  record_user_state() { :; }
  record_rfkill_state() { : > "$STATE_DIR/rfkill-state"; }
  record_controller_state() { : > "$STATE_DIR/controller-state"; }
  apt-get() {
    printf '%s\n' "$*" >> "$apt_log"
  }
  systemctl() {
    printf '%s\n' "$*" >> "$TEST_SCRATCH/systemctl.log"
    if [[ $1 == unmask && $* == *triggerhappy.service* ]]; then
      : > "$TEST_SCRATCH/system-unmasked"
    elif [[ $* == 'disable --now triggerhappy.socket' ]]; then
      [[ -e $TEST_SCRATCH/system-unmasked ]] || return 1
      : > "$TEST_SCRATCH/triggerhappy-socket-disabled"
    elif [[ $1 == enable && ${2:-} == --now ]]; then
      [[ $* != *triggerhappy.socket* ]] || return 1
      [[ -e $TEST_SCRATCH/triggerhappy-socket-disabled ]] || return 1
    fi
  }
  ensure_audio_user() { :; }
  power_controller() { :; }

  output=$(install_action --user "$user" --non-interactive)
  assert_contains "$output" 'installed successfully'
  [[ -x $INSTALLED_CLI ]] || fail 'installer did not persist the executable'
  bash -n "$INSTALLED_CLI"
  parse_config "$CONFIG_FILE"
  assert_eq "$user" "$CFG_AUDIO_USER"
  assert_eq 0 "${#CFG_SPEAKERS[@]}"
  assert_eq http://127.0.0.1:32500 "$CFG_BASE_URL"
  assert_eq 20 "${#CFG_MEDIA_KEYS[@]}"
  assert_file_contains "$SYSTEMD_UNIT" "$INSTALLED_CLI daemon"
  assert_file_contains "$TRIGGER_CONF" 'player-control KEY_PLAYCD'
  assert_file_not_contains "$TRIGGER_CONF" 'commandID='
  assert_file_contains "$STATE_FILE" 'INSTALL_PHASE=installed'
  assert_file_contains "$apt_log" 'install -y --no-install-recommends'
  assert_file_not_contains "$apt_log" 'DPkg::Pre-Invoke'
  assert_file_not_contains "$apt_log" 'DPkg::Post-Invoke'
  assert_file_contains "$TEST_SCRATCH/systemctl.log" \
    'unmask bluetooth.service triggerhappy.socket triggerhappy.service a2dpilot.service'
  assert_file_contains "$TEST_SCRATCH/systemctl.log" \
    'unmask --runtime bluetooth.service triggerhappy.socket triggerhappy.service a2dpilot.service'
  assert_file_contains "$TEST_SCRATCH/systemctl.log" \
    'disable --now triggerhappy.socket'
  assert_file_contains "$TEST_SCRATCH/systemctl.log" \
    'enable --now bluetooth.service triggerhappy.service a2dpilot.service'
  assert_file_not_contains "$TEST_SCRATCH/systemctl.log" \
    'enable --now bluetooth.service triggerhappy.service triggerhappy.socket a2dpilot.service'

  restore_all_user_states() { :; }
  restore_controller_state() { :; }
  restore_rfkill_state() { :; }
  restore_system_service_states() { :; }
  output=$(uninstall_action --keep-bonds)
  assert_contains "$output" 'APT-managed packages were retained.'
  assert_contains "$output" 'managed system state was restored'
  [[ ! -e $INSTALLED_CLI ]] || fail 'created executable survived uninstall'
  [[ ! -e $CONFIG_FILE ]] || fail 'created configuration survived uninstall'
  [[ ! -e $STATE_DIR ]] || fail 'rollback state survived successful uninstall'
  assert_file_not_contains "$apt_log" 'remove -y'
}

test_uninstall_keeps_packages_and_reports_empty_bond_policy() {
  local output
  setup_scratch_dir
  load_app
  configure_scratch_paths
  : > "$STATE_FILE"
  : > "$STATE_DIR/created-bonds"
  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  systemctl() {
    if [[ $1 == show ]]; then
      printf 'not-found\n'
    else
      printf '%s\n' "$*" >> "$TEST_SCRATCH/systemctl.log"
    fi
  }
  apt-get() {
    printf '%s\n' "$*" >> "$TEST_SCRATCH/apt.log"
  }
  output=$(uninstall_action --remove-bonds)
  assert_contains "$output" 'No A2DPilot-created bonds were recorded.'
  assert_contains "$output" 'APT-managed packages were retained.'
  [[ ! -e $TEST_SCRATCH/apt.log ]] || fail 'uninstall invoked APT'
  [[ ! -e $STATE_DIR ]] || fail 'package-retaining uninstall retained state'
}

test_uninstall_preserves_audio_session_after_routing_cleanup_failure() {
  local user output rc cleanup_count
  setup_scratch_dir
  load_app
  configure_scratch_paths
  cleanup_count=$TEST_SCRATCH/cleanup-count
  user=$(id -un)
  render_state_file "$STATE_FILE" installed
  printf '%s\n' "$user" > "$STATE_DIR/runtime-user"
  : > "$STATE_DIR/created-bonds"
  printf '0\n' > "$cleanup_count"

  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { printf 'release\n' >> "$TEST_SCRATCH/lock.log"; }
  systemctl() {
    if [[ $1 == show ]]; then
      printf 'loaded\n'
    else
      printf '%s\n' "$*" >> "$TEST_SCRATCH/systemctl.log"
    fi
  }
  clear_owned_routing() {
    local count
    count=$(< "$cleanup_count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$cleanup_count"
    (( count > 1 ))
  }
  restore_managed_files() { printf 'files\n' >> "$TEST_SCRATCH/restore.log"; }
  restore_all_user_states() { printf 'users\n' >> "$TEST_SCRATCH/restore.log"; }
  restore_controller_state() { printf 'controller\n' >> "$TEST_SCRATCH/restore.log"; }
  restore_rfkill_state() { printf 'rfkill\n' >> "$TEST_SCRATCH/restore.log"; }
  restore_system_service_states() { printf 'services\n' >> "$TEST_SCRATCH/restore.log"; }

  set +e
  output=$(uninstall_action --keep-bonds 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'uninstall continued after routing cleanup failed'
  assert_contains "$output" 'Could not fully clear A2DPilot-owned audio routing overrides'
  assert_contains "$output" "recovery state remains at $STATE_DIR"
  assert_file_contains "$STATE_FILE" 'INSTALL_PHASE=failed'
  [[ -f $STATE_DIR/runtime-user ]] || fail 'failed cleanup discarded its audio user'
  [[ ! -e $TEST_SCRATCH/restore.log ]] || \
    fail 'failed routing cleanup restored managed state or the audio session'

  output=$(uninstall_action --keep-bonds)
  assert_contains "$output" 'managed system state was restored'
  assert_file_contains "$TEST_SCRATCH/restore.log" 'users'
  [[ ! -e $STATE_DIR ]] || fail 'successful uninstall retry retained recovery state'
}

test_failed_install_rollback_retains_packages() {
  local output rc mock
  setup_scratch_dir
  load_app
  configure_scratch_paths
  mock=$TEST_SCRATCH/uninstall-mock
  cat > "$mock" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$ROLLBACK_LOG"
EOF
  chmod +x "$mock"
  ROLLBACK_LOG=$TEST_SCRATCH/rollback.log
  export ROLLBACK_LOG
  SCRIPT_PATH=$mock
  release_lock() { :; }
  set +e
  output=$(rollback_failed_install 23 2>&1)
  rc=$?
  set -e
  assert_eq 23 "$rc"
  assert_contains "$output" 'Automatic rollback succeeded.'
  assert_eq 'uninstall --keep-bonds' "$(< "$ROLLBACK_LOG")"
}

test_install_recovery_needs_no_package_snapshot() {
  local lock_calls mock phase
  for phase in installing failed; do
    lock_calls=0
    setup_scratch_dir
    load_app
    configure_scratch_paths
    printf 'INSTALL_PHASE=%s\n' "$phase" > "$STATE_FILE"
    mock=$TEST_SCRATCH/uninstall-mock
    cat > "$mock" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$RECOVERY_LOG"
EOF
    chmod +x "$mock"
    RECOVERY_LOG=$TEST_SCRATCH/recovery.log
    export RECOVERY_LOG
    SCRIPT_PATH=$mock
    require_root() { :; }
    acquire_lock() {
      lock_calls=$((lock_calls + 1))
      (( lock_calls == 1 )) || die "recovery checkpoint"
    }
    release_lock() { :; }
    expect_failure_contains 'recovery checkpoint' install_action --non-interactive
    assert_eq 'uninstall --keep-bonds' "$(< "$RECOVERY_LOG")"
    cleanup_scratch_dir
  done
}

test_update_source_selection_and_validation() {
  local sha=0123456789abcdef0123456789abcdef01234567 ref parsed_version version_file
  local major minor patch newer_version
  local -a valid_refs=(main feat/update_command release/v1.2.3 v1.2.3+build one@two -tag)
  local -a invalid_refs=('' '@' '/main' 'main/' 'main.' 'feat//one' 'feat/../one' \
    'feat/@{one' '.hidden' 'feat/.hidden' 'release.lock' 'feat/release.lock' 'has space' \
    'question?' 'star*' 'back\slash')
  setup_scratch_dir
  load_app
  assert_eq 'https://raw.githubusercontent.com/treyturner/a2dpilot/refs/heads/main/a2dpilot' \
    "$(update_source_url branch main)"
  assert_eq 'https://raw.githubusercontent.com/treyturner/a2dpilot/refs/heads/feat/update_command/a2dpilot' \
    "$(update_source_url branch feat/update_command)"
  assert_eq 'https://raw.githubusercontent.com/treyturner/a2dpilot/refs/tags/v1.2.3/a2dpilot' \
    "$(update_source_url tag v1.2.3)"
  assert_eq "https://raw.githubusercontent.com/treyturner/a2dpilot/$sha/a2dpilot" \
    "$(update_source_url sha "$sha")"
  for ref in "${valid_refs[@]}"; do
    valid_update_ref "$ref" || fail "valid update ref was rejected: $ref"
  done
  for ref in "${invalid_refs[@]}"; do
    if valid_update_ref "$ref"; then fail "invalid update ref was accepted: $ref"; fi
  done
  valid_a2dpilot_version "$A2DPILOT_VERSION" || fail 'running version is invalid'
  a2dpilot_version_is_older 0.3.0 "$A2DPILOT_VERSION" || \
    fail 'pre-per-override routing version was not detected as older'
  a2dpilot_version_is_older 0.2.0 "$A2DPILOT_VERSION" || \
    fail 'pre-cleanup-cursor application version was not detected as older'
  a2dpilot_version_is_older 0.1.0 "$A2DPILOT_VERSION" || \
    fail 'pre-routing-state application version was not detected as older'
  a2dpilot_version_is_older 0.0.9 "$A2DPILOT_VERSION" || \
    fail 'older candidate version was not detected'
  if a2dpilot_version_is_older "$A2DPILOT_VERSION" "$A2DPILOT_VERSION"; then
    fail 'equal candidate version was treated as older'
  fi
  IFS=. read -r major minor patch <<< "$A2DPILOT_VERSION"
  newer_version=$major.$minor.$((patch + 1))
  if a2dpilot_version_is_older "$newer_version" "$A2DPILOT_VERSION"; then
    fail 'newer candidate version was treated as older'
  fi
  a2dpilot_version_is_older 99999999999999999999.0.0 100000000000000000000.0.0 || \
    fail 'large older candidate version was not detected'
  version_file=$TEST_SCRATCH/versioned-executable
  write_update_payload "$version_file" '# version fixture'
  read_a2dpilot_version "$version_file" parsed_version || fail 'valid version was not read'
  assert_eq "$A2DPILOT_VERSION" "$parsed_version"

  require_root() { :; }
  expect_failure_contains 'mutually exclusive' update_action --tag v1.0.0 --branch main
  expect_failure_contains 'mutually exclusive' update_action --branch main --branch next
  expect_failure_contains 'full 40-character' update_action --sha 0123456
  expect_failure_contains 'Invalid tag name' update_action --tag 'bad tag'
  expect_failure_contains 'Unknown update option' update_action --repository elsewhere
  expect_failure_contains 'Unexpected update argument' update_action main
}

test_update_executable_only_transaction() {
  local payload output before after service_active=1 target_owner=0 target_group=0 target_mode=755
  local upper_sha=ABCDEF0123456789ABCDEF0123456789ABCDEF01
  setup_scratch_dir
  load_app
  configure_scratch_paths
  install -d "$(dirname "$INSTALLED_CLI")" "$(dirname "$SYSTEMD_UNIT")" \
    "$(dirname "$WIREPLUMBER_CONF")" "$(dirname "$TRIGGER_CONF")"
  render_state_file "$STATE_FILE" installed
  printf 'created files sentinel\n' > "$STATE_DIR/created-files"
  printf 'replaced files sentinel\n' > "$STATE_DIR/replaced-files"
  printf 'created bonds sentinel\n' > "$STATE_DIR/created-bonds"
  printf 'runtime user sentinel\n' > "$STATE_DIR/runtime-user"
  write_update_payload "$INSTALLED_CLI" '# old executable'
  chmod 0755 "$INSTALLED_CLI"
  printf 'config sentinel\n' > "$CONFIG_FILE"
  printf 'unit sentinel\n' > "$SYSTEMD_UNIT"
  printf 'wireplumber sentinel\n' > "$WIREPLUMBER_CONF"
  printf 'trigger sentinel\n' > "$TRIGGER_CONF"
  before=$(sha256sum "$STATE_FILE" "$STATE_DIR/created-files" \
    "$STATE_DIR/replaced-files" "$STATE_DIR/created-bonds" "$STATE_DIR/runtime-user" \
    "$CONFIG_FILE" "$SYSTEMD_UNIT" \
    "$WIREPLUMBER_CONF" "$TRIGGER_CONF")
  payload=$TEST_SCRATCH/update-payload
  UPDATE_EXECUTION_LOG=$TEST_SCRATCH/candidate-execution.log
  export UPDATE_EXECUTION_LOG
  write_update_payload "$payload" \
    'printf '\''executed\n'\'' >> "$UPDATE_EXECUTION_LOG"' '# updated main'

  require_root() { :; }
  acquire_lock() { printf 'acquire\n' >> "$TEST_SCRATCH/lock.log"; }
  release_lock() { printf 'release\n' >> "$TEST_SCRATCH/lock.log"; }
  stat() {
    if [[ ${1:-} == -c && ${4:-} == "$INSTALLED_CLI" ]]; then
      case $2 in
        %u) printf '%s\n' "$target_owner" ;;
        %g) printf '%s\n' "$target_group" ;;
        %a) printf '%s\n' "$target_mode" ;;
        *) /usr/bin/stat "$@" ;;
      esac
    else
      /usr/bin/stat "$@"
    fi
  }
  install() {
    local -a forwarded=()
    printf '%s\n' "$*" >> "$TEST_SCRATCH/install.log"
    while [[ $# -gt 0 ]]; do
      case $1 in
        -o|-g) shift 2 ;;
        *) forwarded+=("$1"); shift ;;
      esac
    done
    /usr/bin/install "${forwarded[@]}"
  }
  curl() {
    local output_path=''
    printf '%s\n' "$*" >> "$TEST_SCRATCH/curl.log"
    while [[ $# -gt 0 ]]; do
      if [[ $1 == --output ]]; then output_path=$2; shift 2; else shift; fi
    done
    cp "$payload" "$output_path"
  }
  systemctl() {
    case $1 in
      is-active)
        if (( service_active )); then printf 'active\n'; else printf 'inactive\n'; fi
        ;;
      restart) printf '%s\n' "$*" >> "$TEST_SCRATCH/systemctl.log" ;;
      *) fail "unexpected systemctl call during update: $*" ;;
    esac
  }
  apt-get() { fail 'update invoked APT'; }
  reconcile_runtime_configuration() { fail 'update reconciled runtime configuration'; }
  write_systemd_unit() { fail 'update regenerated its systemd unit'; }
  write_wireplumber_config() { fail 'update regenerated WirePlumber configuration'; }
  write_trigger_config() { fail 'update regenerated Triggerhappy configuration'; }

  output=$(update_action)
  assert_contains "$output" "updated successfully from branch 'main'"
  assert_file_contains "$INSTALLED_CLI" '# updated main'
  assert_eq 755 "$(/usr/bin/stat -c %a "$INSTALLED_CLI")"
  assert_file_contains "$TEST_SCRATCH/curl.log" "--proto =https --proto-redir =https"
  assert_file_contains "$TEST_SCRATCH/curl.log" "--connect-timeout 10 --max-time 60"
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'https://raw.githubusercontent.com/treyturner/a2dpilot/refs/heads/main/a2dpilot'
  assert_file_contains "$TEST_SCRATCH/install.log" '-o root -g root -m 0755'
  assert_eq 1 "$(grep -Fc 'restart a2dpilot.service' "$TEST_SCRATCH/systemctl.log")"
  [[ ! -e $UPDATE_EXECUTION_LOG ]] || fail 'update directly executed its downloaded candidate'

  : > "$TEST_SCRATCH/systemctl.log"
  output=$(update_action)
  assert_contains "$output" "already current for branch 'main'"
  [[ ! -s $TEST_SCRATCH/systemctl.log ]] || fail 'no-op update restarted the service'

  target_group=1234
  target_mode=644
  output=$(update_action)
  assert_contains "$output" "updated successfully from branch 'main'"
  assert_eq 755 "$(/usr/bin/stat -c %a "$INSTALLED_CLI")"
  assert_eq 1 "$(grep -Fc 'restart a2dpilot.service' "$TEST_SCRATCH/systemctl.log")"
  target_group=0
  target_mode=755
  : > "$TEST_SCRATCH/systemctl.log"

  service_active=0
  write_update_payload "$payload" '# updated branch'
  update_action --branch feat/update_command >/dev/null
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'https://raw.githubusercontent.com/treyturner/a2dpilot/refs/heads/feat/update_command/a2dpilot'
  write_update_payload "$payload" '# updated tag'
  update_action --tag v1.2.3 >/dev/null
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'https://raw.githubusercontent.com/treyturner/a2dpilot/refs/tags/v1.2.3/a2dpilot'
  write_update_payload "$payload" '# updated sha'
  update_action --sha "$upper_sha" >/dev/null
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'https://raw.githubusercontent.com/treyturner/a2dpilot/abcdef0123456789abcdef0123456789abcdef01/a2dpilot'
  [[ ! -s $TEST_SCRATCH/systemctl.log ]] || fail 'inactive service was started during update'

  after=$(sha256sum "$STATE_FILE" "$STATE_DIR/created-files" \
    "$STATE_DIR/replaced-files" "$STATE_DIR/created-bonds" "$STATE_DIR/runtime-user" \
    "$CONFIG_FILE" "$SYSTEMD_UNIT" \
    "$WIREPLUMBER_CONF" "$TRIGGER_CONF")
  assert_eq "$before" "$after"
  assert_eq 6 "$(grep -Fc acquire "$TEST_SCRATCH/lock.log")"
  assert_eq 6 "$(grep -Fc release "$TEST_SCRATCH/lock.log")"
  [[ ! -e $UPDATE_EXECUTION_LOG ]] || fail 'update directly executed an installed candidate'
}

test_update_rechecks_installed_version_under_lock() {
  local payload output rc major minor patch candidate_version concurrent_version
  setup_scratch_dir
  load_app
  configure_scratch_paths
  install -d "$(dirname "$INSTALLED_CLI")"
  render_state_file "$STATE_FILE" installed
  write_update_payload "$INSTALLED_CLI" '# original executable'
  chmod 0755 "$INSTALLED_CLI"
  IFS=. read -r major minor patch <<< "$A2DPILOT_VERSION"
  candidate_version=$major.$minor.$((patch + 1))
  concurrent_version=$major.$minor.$((patch + 2))
  payload=$TEST_SCRATCH/update-payload
  write_update_payload_version "$payload" "$candidate_version" '# downloaded candidate'

  require_root() { :; }
  acquire_lock() {
    write_update_payload_version "$INSTALLED_CLI" "$concurrent_version" \
      '# concurrent update winner'
    chmod 0755 "$INSTALLED_CLI"
    printf 'acquire\n' >> "$TEST_SCRATCH/lock.log"
  }
  release_lock() { printf 'release\n' >> "$TEST_SCRATCH/lock.log"; }
  stat() {
    if [[ ${1:-} == -c && ${2:-} == %u && ${4:-} == "$INSTALLED_CLI" ]]; then
      printf '0\n'
    else
      /usr/bin/stat "$@"
    fi
  }
  curl() {
    local output_path=''
    while [[ $# -gt 0 ]]; do
      if [[ $1 == --output ]]; then output_path=$2; shift 2; else shift; fi
    done
    cp "$payload" "$output_path"
  }
  atomic_install_file() { : > "$TEST_SCRATCH/unexpected-replacement"; return 1; }
  systemctl() { fail 'concurrent downgrade queried or changed the service'; }

  set +e
  output=$(update_action 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'concurrent update installed an older candidate'
  assert_contains "$output" \
    "Refusing to downgrade A2DPilot from $concurrent_version to $candidate_version"
  assert_file_contains "$INSTALLED_CLI" "A2DPILOT_VERSION=$concurrent_version"
  assert_file_contains "$INSTALLED_CLI" '# concurrent update winner'
  [[ ! -e $TEST_SCRATCH/unexpected-replacement ]] || \
    fail 'concurrent downgrade reached executable replacement'
  assert_eq $'acquire\nrelease' "$(< "$TEST_SCRATCH/lock.log")"
}

test_update_rejects_bad_candidates_and_targets() {
  local mode output rc candidate target_owner=0 parent redirected
  setup_scratch_dir
  load_app
  configure_scratch_paths
  install -d "$(dirname "$INSTALLED_CLI")"
  render_state_file "$STATE_FILE" installed
  write_update_payload "$INSTALLED_CLI" '# old executable'
  chmod 0755 "$INSTALLED_CLI"

  require_root() { :; }
  acquire_lock() { printf 'acquire\n' >> "$TEST_SCRATCH/lock.log"; }
  release_lock() { printf 'release\n' >> "$TEST_SCRATCH/lock.log"; }
  stat() {
    if [[ ${1:-} == -c && ${2:-} == %u && ${4:-} == "$INSTALLED_CLI" ]]; then
      printf '%s\n' "$target_owner"
    else
      /usr/bin/stat "$@"
    fi
  }
  curl() {
    local output_path=''
    while [[ $# -gt 0 ]]; do
      if [[ $1 == --output ]]; then output_path=$2; shift 2; else shift; fi
    done
    printf '%s\n' "$output_path" > "$TEST_SCRATCH/candidate-path"
    case $mode in
      fail) return 22 ;;
      empty) : > "$output_path" ;;
      no-shebang) printf 'printf "valid Bash without a shebang"\n' > "$output_path" ;;
      invalid) printf '#!/usr/bin/env bash\nif broken syntax\n' > "$output_path" ;;
      missing-version) printf '#!/usr/bin/env bash\n# no version\n' > "$output_path" ;;
      malformed-version) printf '#!/usr/bin/env bash\nA2DPILOT_VERSION=latest\n' > "$output_path" ;;
      duplicate-version)
        printf '#!/usr/bin/env bash\nA2DPILOT_VERSION=%s\nA2DPILOT_VERSION=%s\n' \
          "$A2DPILOT_VERSION" "$A2DPILOT_VERSION" > "$output_path"
        ;;
      downgrade) printf '#!/usr/bin/env bash\nA2DPILOT_VERSION=0.0.9\n' > "$output_path" ;;
    esac
  }

  for mode in fail empty no-shebang invalid missing-version malformed-version duplicate-version downgrade; do
    : > "$TEST_SCRATCH/lock.log"
    set +e
    output=$(update_action 2>&1)
    rc=$?
    set -e
    (( rc != 0 )) || fail "$mode update candidate was accepted"
    case $mode in
      fail) assert_contains "$output" 'Could not download A2DPilot' ;;
      empty) assert_contains "$output" 'empty or unsafe' ;;
      no-shebang) assert_contains "$output" 'lacks the expected Bash shebang' ;;
      invalid) assert_contains "$output" 'failed Bash syntax validation' ;;
      missing-version|malformed-version|duplicate-version)
        assert_contains "$output" 'must declare exactly one valid A2DPILOT_VERSION'
        ;;
      downgrade)
        assert_contains "$output" "Refusing to downgrade A2DPilot from $A2DPILOT_VERSION to 0.0.9"
        assert_contains "$output" 'sudo a2dpilot uninstall --keep-bonds'
        ;;
    esac
    candidate=$(< "$TEST_SCRATCH/candidate-path")
    [[ ! -e $candidate ]] || fail "$mode update left its candidate behind"
    assert_file_not_contains "$TEST_SCRATCH/lock.log" acquire
    assert_file_contains "$INSTALLED_CLI" '# old executable'
  done

  rm -f -- "$TEST_SCRATCH/candidate-path"
  render_state_file "$STATE_FILE" failed
  expect_failure_contains "requires an installed state; found 'failed'" update_action
  [[ ! -e $TEST_SCRATCH/candidate-path ]] || fail 'failed installation state downloaded a candidate'
  render_state_file "$STATE_FILE" installed
  target_owner=1000
  expect_failure_contains 'must be owned by root' update_action
  [[ ! -e $TEST_SCRATCH/candidate-path ]] || fail 'owner validation downloaded a candidate'
  target_owner=0
  rm -f -- "$INSTALLED_CLI"
  ln -s /etc/passwd "$INSTALLED_CLI"
  expect_failure_contains 'missing or unsafe' update_action
  [[ ! -e $TEST_SCRATCH/candidate-path ]] || fail 'symlink validation downloaded a candidate'

  rm -f -- "$INSTALLED_CLI"
  parent=$(dirname "$INSTALLED_CLI")
  rmdir -- "$parent"
  redirected=$TEST_SCRATCH/redirected-update-target
  install -d "$redirected"
  printf '#!/usr/bin/env bash\n' > "$redirected/a2dpilot"
  ln -s "$redirected" "$parent"
  expect_failure_contains 'Refusing to traverse symlinked directory' update_action
  [[ ! -e $TEST_SCRATCH/candidate-path ]] || fail 'symlinked parent downloaded a candidate'
}

test_update_activation_rollback_and_interruption() {
  local payload output rc restart_count atomic_count test_signal=TERM second_signal=INT retained_previous
  setup_scratch_dir
  load_app
  configure_scratch_paths
  install -d "$(dirname "$INSTALLED_CLI")"
  render_state_file "$STATE_FILE" installed
  write_update_payload "$INSTALLED_CLI" '# old executable'
  chmod 0755 "$INSTALLED_CLI"
  payload=$TEST_SCRATCH/update-payload
  write_update_payload "$payload" '# new executable'
  restart_count=$TEST_SCRATCH/restart-count
  atomic_count=$TEST_SCRATCH/atomic-count
  printf '0\n' > "$restart_count"

  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { printf 'release\n' >> "$TEST_SCRATCH/release.log"; }
  stat() {
    if [[ ${1:-} == -c && ${2:-} == %u && ${4:-} == "$INSTALLED_CLI" ]]; then
      printf '0\n'
    else
      /usr/bin/stat "$@"
    fi
  }
  install() {
    local -a forwarded=()
    while [[ $# -gt 0 ]]; do
      case $1 in
        -o|-g) shift 2 ;;
        *) forwarded+=("$1"); shift ;;
      esac
    done
    /usr/bin/install "${forwarded[@]}"
  }
  mktemp() {
    case $1 in
      /tmp/a2dpilot-*) /usr/bin/mktemp "$TEST_SCRATCH/${1##*/}" ;;
      *) /usr/bin/mktemp "$@" ;;
    esac
  }
  curl() {
    local output_path=''
    while [[ $# -gt 0 ]]; do
      if [[ $1 == --output ]]; then output_path=$2; shift 2; else shift; fi
    done
    cp "$payload" "$output_path"
  }
  systemctl() {
    local count
    case $1 in
      is-active) printf 'active\n' ;;
      restart)
        count=$(< "$restart_count")
        count=$((count + 1))
        printf '%s\n' "$count" > "$restart_count"
        (( count > 1 ))
        ;;
    esac
  }
  set +e
  output=$(update_action 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'failed service activation reported update success'
  assert_contains "$output" 'updated A2DPilot service did not become active'
  assert_contains "$output" 'previous A2DPilot executable was restored'
  assert_file_contains "$INSTALLED_CLI" '# old executable'
  assert_eq 2 "$(< "$restart_count")"
  [[ -z $(find "$TEST_SCRATCH" -maxdepth 1 -name 'a2dpilot-update.*' -o \
    -name 'a2dpilot-previous.*') ]] || fail 'successful rollback retained temporary files'

  write_update_payload "$INSTALLED_CLI" '# old executable'
  printf '0\n' > "$restart_count"
  printf '0\n' > "$atomic_count"
  atomic_install_file() {
    local count
    count=$(< "$atomic_count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$atomic_count"
    (( count < 2 )) || return 1
    cp "$1" "$2"
    chmod "$3" "$2"
  }
  set +e
  output=$(update_action 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'failed executable restoration reported success'
  retained_previous=$(find "$TEST_SCRATCH" -maxdepth 1 -name 'a2dpilot-previous.*' -type f)
  [[ -n $retained_previous && $retained_previous != *$'\n'* ]] || \
    fail 'failed executable restoration did not retain exactly one rollback copy'
  assert_contains "$output" "rollback copy retained at $retained_previous"
  assert_file_contains "$retained_previous" '# old executable'
  [[ -z $(find "$TEST_SCRATCH" -maxdepth 1 -name 'a2dpilot-update.*') ]] || \
    fail 'failed executable restoration retained its downloaded candidate'
  assert_file_contains "$INSTALLED_CLI" '# new executable'
  rm -f -- "$retained_previous"

  write_update_payload "$INSTALLED_CLI" '# old executable before signal'
  printf '0\n' > "$atomic_count"
  : > "$TEST_SCRATCH/replacement-state.log"
  systemctl() {
    case $1 in
      is-active) printf 'active\n' ;;
      restart) : ;;
    esac
  }
  atomic_install_file() {
    local count
    count=$(< "$atomic_count")
    count=$((count + 1))
    printf '%s\n' "$count" > "$atomic_count"
    printf '%s\n' "$UPDATE_REPLACED" >> "$TEST_SCRATCH/replacement-state.log"
    cp "$1" "$2"
    chmod "$3" "$2"
    if (( count == 1 )); then
      kill "-$test_signal" "$BASHPID"
    elif (( count == 2 )); then
      kill "-$second_signal" "$BASHPID"
    fi
  }
  set +e
  output=$(update_action 2>&1)
  rc=$?
  set -e
  assert_eq 143 "$rc"
  assert_contains "$output" 'A2DPilot update was terminated'
  assert_contains "$output" 'previous A2DPilot executable was restored'
  assert_eq 1 "$(head -n 1 "$TEST_SCRATCH/replacement-state.log")"
  assert_file_contains "$INSTALLED_CLI" '# old executable before signal'
  [[ -z $(find "$TEST_SCRATCH" -maxdepth 1 -name 'a2dpilot-update.*' -o \
    -name 'a2dpilot-previous.*') ]] || fail 'interrupted replacement retained temporary files'

  test_signal=HUP
  write_update_payload "$INSTALLED_CLI" '# old executable before hangup'
  printf '0\n' > "$atomic_count"
  : > "$TEST_SCRATCH/replacement-state.log"
  set +e
  output=$(update_action 2>&1)
  rc=$?
  set -e
  assert_eq 129 "$rc"
  assert_contains "$output" 'interrupted by a hangup'
  assert_contains "$output" 'previous A2DPilot executable was restored'
  assert_eq 1 "$(head -n 1 "$TEST_SCRATCH/replacement-state.log")"
  assert_file_contains "$INSTALLED_CLI" '# old executable before hangup'
  [[ -z $(find "$TEST_SCRATCH" -maxdepth 1 -name 'a2dpilot-update.*' -o \
    -name 'a2dpilot-previous.*') ]] || fail 'hangup rollback retained temporary files'

  UPDATE_PREVIOUS=$TEST_SCRATCH/interrupted-previous
  UPDATE_CANDIDATE=$TEST_SCRATCH/interrupted-candidate
  printf '#!/usr/bin/env bash\n# interrupted old\n' > "$UPDATE_PREVIOUS"
  printf '#!/usr/bin/env bash\n# interrupted candidate\n' > "$UPDATE_CANDIDATE"
  write_update_payload "$INSTALLED_CLI" '# interrupted new'
  UPDATE_REPLACED=1
  UPDATE_WAS_ACTIVE=0
  atomic_install_file() { cp "$1" "$2"; chmod "$3" "$2"; }
  set +e
  output=$(rollback_failed_update 130 'A2DPilot update was interrupted.' 2>&1)
  rc=$?
  set -e
  assert_eq 130 "$rc"
  assert_contains "$output" 'previous A2DPilot executable was restored'
  assert_file_contains "$INSTALLED_CLI" '# interrupted old'
  [[ ! -e $UPDATE_PREVIOUS && ! -e $UPDATE_CANDIDATE ]] || \
    fail 'interrupted update retained temporary files'

  write_update_payload "$INSTALLED_CLI" '# old executable before query failure'
  write_update_payload "$payload" '# candidate before query failure'
  rm -f -- "$TEST_SCRATCH/unexpected-replacement"
  systemctl() {
    case $1 in
      is-active) return 1 ;;
      restart) fail 'service-state query failure attempted a restart' ;;
    esac
  }
  atomic_install_file() {
    : > "$TEST_SCRATCH/unexpected-replacement"
    return 1
  }
  set +e
  output=$(update_action 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'indeterminate service state reported update success'
  assert_contains "$output" 'Could not determine the A2DPilot service state'
  assert_file_contains "$INSTALLED_CLI" '# old executable before query failure'
  [[ ! -e $TEST_SCRATCH/unexpected-replacement ]] || \
    fail 'indeterminate service state replaced the executable'
}

test_config_editor_success_and_validation_failure() {
  local user candidate before output rc
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user"
  : > "$STATE_FILE"
  candidate=$TEST_SCRATCH/candidate
  write_test_config "$candidate" "$user" AA:BB:CC:DD:EE:FF
  before=$TEST_SCRATCH/before
  cp "$CONFIG_FILE" "$before"

  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  chown() { :; }
  run_editor() { cp "$candidate" "$1"; }
  atomic_install_file() { cp "$1" "$2"; }
  reconcile_runtime_configuration() { :; }
  systemctl() { :; }
  SUDO_USER=$user

  config_action
  parse_config "$CONFIG_FILE"
  assert_eq AA:BB:CC:DD:EE:FF "${CFG_SPEAKERS[0]}"

  cp "$before" "$CONFIG_FILE"
  printf 'not valid\n' > "$candidate"
  set +e
  output=$(config_action 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'invalid editor content was installed'
  assert_contains "$output" 'expected key = value'
  cmp -s "$before" "$CONFIG_FILE" || fail 'invalid edit changed the live configuration'

  run_editor() { rm -f -- "$1"; ln -s /etc/passwd "$1"; }
  set +e
  output=$(config_action 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'symlinked editor candidate was installed'
  assert_contains "$output" 'unsafe configuration candidate'
  cmp -s "$before" "$CONFIG_FILE" || fail 'unsafe edit changed the live configuration'
}

test_config_editor_installs_protected_snapshot() {
  local user candidate editor_path='' installed_source=''
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user"
  : > "$STATE_FILE"
  candidate=$TEST_SCRATCH/candidate
  write_test_config "$candidate" "$user" AA:BB:CC:DD:EE:FF

  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  chown() { :; }
  run_editor() {
    editor_path=$1
    cp "$candidate" "$editor_path"
  }
  atomic_install_file() {
    installed_source=$1
    [[ $installed_source != "$editor_path" ]] || {
      fail 'configuration was installed from the editor-owned inode'
      return 1
    }
    [[ ! -e $editor_path ]] || {
      fail 'editor workspace remained reachable during installation'
      return 1
    }
    cp "$installed_source" "$2"
  }
  reconcile_runtime_configuration() { :; }
  systemctl() { :; }
  SUDO_USER=$user

  config_action
  [[ $installed_source == "$STATE_DIR"/.a2dpilot-config-new.* ]] || \
    fail 'configuration was not installed from protected state'
  parse_config "$CONFIG_FILE"
  assert_eq AA:BB:CC:DD:EE:FF "${CFG_SPEAKERS[0]}"
}

test_config_application_rolls_back() {
  local user candidate before output rc restart_count=0
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user"
  : > "$STATE_FILE"
  candidate=$TEST_SCRATCH/candidate
  write_test_config "$candidate" "$user" AA:BB:CC:DD:EE:FF
  before=$TEST_SCRATCH/before
  cp "$CONFIG_FILE" "$before"

  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  chown() { :; }
  run_editor() { cp "$candidate" "$1"; }
  atomic_install_file() { cp "$1" "$2"; }
  reconcile_runtime_configuration() { :; }
  systemctl() {
    if [[ $* == 'restart a2dpilot.service' ]]; then
      restart_count=$((restart_count + 1))
      (( restart_count > 1 ))
    fi
  }
  SUDO_USER=$user
  set +e
  output=$(config_action 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'fault-injected application unexpectedly succeeded'
  assert_contains "$output" 'previous configuration was restored'
  cmp -s "$before" "$CONFIG_FILE" || fail 'application rollback did not restore exact config'
}

test_onboard_audio_cli_and_application() {
  local user output
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" AA:BB:CC:DD:EE:FF
  : > "$STATE_FILE"
  install -d "$(dirname "$WIREPLUMBER_CONF")"
  parse_config "$CONFIG_FILE"
  write_wireplumber_config "$WIREPLUMBER_CONF"

  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  atomic_install_file() { cp "$1" "$2"; chmod "$3" "$2"; }
  reconcile_runtime_configuration() { apply_wireplumber_config; }
  as_user_systemctl() { printf '%s\n' "$*" >> "$TEST_SCRATCH/user-systemctl.log"; }
  systemctl() { printf '%s\n' "$*" >> "$TEST_SCRATCH/systemctl.log"; }

  audio_onboard_action disable analog
  parse_config "$CONFIG_FILE"
  assert_eq disabled "$CFG_ONBOARD_ANALOG"
  assert_eq enabled "$CFG_ONBOARD_HDMI"
  assert_eq AA:BB:CC:DD:EE:FF "${CFG_SPEAKERS[0]}"
  assert_file_contains "$WIREPLUMBER_CONF" 'api.alsa.card.name = "~bcm2835.*"'
  assert_file_not_contains "$WIREPLUMBER_CONF" 'vc4-hdmi'

  audio_onboard_action disable
  parse_config "$CONFIG_FILE"
  assert_eq disabled "$CFG_ONBOARD_ANALOG"
  assert_eq disabled "$CFG_ONBOARD_HDMI"
  assert_file_contains "$WIREPLUMBER_CONF" 'api.alsa.card.name = "~vc4-hdmi.*"'

  audio_onboard_action enable hdmi
  parse_config "$CONFIG_FILE"
  assert_eq disabled "$CFG_ONBOARD_ANALOG"
  assert_eq enabled "$CFG_ONBOARD_HDMI"
  assert_file_not_contains "$WIREPLUMBER_CONF" 'vc4-hdmi'

  output=$(audio_onboard_action enable hdmi)
  assert_contains "$output" 'already current'
  expect_failure_contains 'Unknown onboard-audio target' audio_onboard_action disable usb
  expect_failure_contains 'Unknown onboard-audio operation' audio_onboard_action toggle analog
  assert_file_contains "$TEST_SCRATCH/user-systemctl.log" "$user restart wireplumber.service"
  assert_file_contains "$TEST_SCRATCH/systemctl.log" 'restart a2dpilot.service'
}

test_onboard_audio_application_rolls_back() {
  local user before output rc restart_count=0
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" AA:BB:CC:DD:EE:FF
  before=$TEST_SCRATCH/config-before
  cp "$CONFIG_FILE" "$before"
  : > "$STATE_FILE"
  install -d "$(dirname "$WIREPLUMBER_CONF")"
  parse_config "$CONFIG_FILE"
  write_wireplumber_config "$WIREPLUMBER_CONF"

  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  atomic_install_file() { cp "$1" "$2"; chmod "$3" "$2"; }
  reconcile_runtime_configuration() { apply_wireplumber_config; }
  as_user_systemctl() { printf '%s\n' "$*" >> "$TEST_SCRATCH/user-systemctl.log"; }
  systemctl() {
    if [[ $* == 'restart a2dpilot.service' ]]; then
      restart_count=$((restart_count + 1))
      (( restart_count > 1 ))
    fi
  }

  set +e
  output=$(audio_onboard_action disable analog 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'fault-injected onboard policy application unexpectedly succeeded'
  assert_contains "$output" 'previous configuration was restored'
  cmp -s "$before" "$CONFIG_FILE" || fail 'onboard policy rollback did not restore exact config'
  assert_file_not_contains "$WIREPLUMBER_CONF" 'monitor.alsa.rules'
  assert_eq 2 "$(wc -l < "$TEST_SCRATCH/user-systemctl.log")"
}

test_onboard_audio_path_failure_rolls_back() {
  local user before output rc parent real_parent
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" AA:BB:CC:DD:EE:FF
  before=$TEST_SCRATCH/config-before
  cp "$CONFIG_FILE" "$before"
  : > "$STATE_FILE"
  parent=$(dirname "$WIREPLUMBER_CONF")
  real_parent=$TEST_SCRATCH/wireplumber-real
  install -d "$parent"
  parse_config "$CONFIG_FILE"
  write_wireplumber_config "$WIREPLUMBER_CONF"
  mv "$parent" "$real_parent"
  ln -s "$real_parent" "$parent"

  require_root() { :; }
  acquire_lock() { printf 'acquire\n' >> "$TEST_SCRATCH/lock.log"; }
  release_lock() { printf 'release\n' >> "$TEST_SCRATCH/lock.log"; }
  atomic_install_file() { cp "$1" "$2"; chmod "$3" "$2"; }
  reconcile_runtime_configuration() { apply_wireplumber_config; }
  as_user_systemctl() { fail 'unsafe WirePlumber path restarted WirePlumber'; }
  systemctl() { :; }

  set +e
  output=$(audio_onboard_action disable analog 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'symlinked WirePlumber parent unexpectedly applied'
  assert_contains "$output" 'previous configuration was restored'
  cmp -s "$before" "$CONFIG_FILE" || \
    fail 'path-validation failure did not restore the previous configuration'
  assert_file_contains "$TEST_SCRATCH/lock.log" 'release'
  assert_file_not_contains "$real_parent/51-a2dpilot.conf" 'monitor.alsa.rules'
}

test_onboard_audio_status_and_matching() {
  local user output
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user"
  parse_config "$CONFIG_FILE"
  bounded_user_pw_cli() {
    if [[ $3 == ls ]]; then
      cat <<'EOF'
	id 48, type PipeWire:Interface:Device/3
		device.api = "alsa"
		media.class = "Audio/Device"
	id 49, type PipeWire:Interface:Device/3
		device.api = "alsa"
		media.class = "Audio/Device"
	id 50, type PipeWire:Interface:Device/3
		device.api = "alsa"
		media.class = "Audio/Device"
	id 51, type PipeWire:Interface:Device/3
		device.api = "alsa"
		media.class = "Audio/Device"
	id 52, type PipeWire:Interface:Device/3
		device.api = "v4l2"
		media.class = "Video/Device"
	id 53, type PipeWire:Interface:Device/3
		device.api = "bluez5"
		media.class = "Audio/Device"
	id 54, type PipeWire:Interface:Device/3
		device.api = "alsa"
		media.class = "Audio/Device"
EOF
      return 0
    fi
    printf '%s\n' "$4" >> "$TEST_SCRATCH/onboard-inspections"
    case $4 in
      48) cat <<'EOF'
	id: 48
	type: PipeWire:Interface:Device/3
*		api.alsa.card.name = "bcm2835 Headphones"
*		device.api = "alsa"
*		device.form-factor = "internal"
*		media.class = "Audio/Device"
EOF
        ;;
      49) cat <<'EOF'
	id: 49
	type: PipeWire:Interface:Device/3
*		api.alsa.card.name = "vc4-hdmi"
*		device.api = "alsa"
*		device.form-factor = "internal"
*		media.class = "Audio/Device"
EOF
        ;;
      50) cat <<'EOF'
	id: 50
	type: PipeWire:Interface:Device/3
*		api.alsa.card.name = "bcm2835 USB impostor"
*		device.api = "alsa"
*		device.form-factor = "external"
*		media.class = "Audio/Device"
EOF
        ;;
      51) cat <<'EOF'
	id: 51
	type: PipeWire:Interface:Device/3
*		api.alsa.card.name = "snd_rpi_hifiberry_dacplus"
*		device.api = "alsa"
*		device.form-factor = "internal"
*		media.class = "Audio/Device"
EOF
        ;;
      54) cat <<'EOF'
	id: 54
	type: PipeWire:Interface:Device/3
*		api.alsa.card.name = "bcm2835 USB device without form factor"
*		device.api = "alsa"
*		media.class = "Audio/Device"
EOF
        ;;
    esac
  }

  visible_onboard_devices
  assert_eq 1 "$ONBOARD_ANALOG_VISIBLE"
  assert_eq 1 "$ONBOARD_HDMI_VISIBLE"
  assert_file_not_contains "$TEST_SCRATCH/onboard-inspections" '53'
  assert_file_contains "$TEST_SCRATCH/onboard-inspections" '54'
  output=$(print_onboard_audio_status all)
  assert_contains "$output" 'Onboard analog: enabled (1 visible matching devices)'
  assert_contains "$output" 'Onboard HDMI: enabled (1 visible matching devices)'

  bounded_user_pw_cli() {
    if [[ $3 == ls ]]; then
      printf '\tid 48, type PipeWire:Interface:Device/3\n\t\tdevice.api = "alsa"\n\t\tmedia.class = "Audio/Device"\n'
    else
      printf '\tid: 999\n\ttype: PipeWire:Interface:Device/3\n'
    fi
  }
  if visible_onboard_devices; then fail 'malformed PipeWire device details were accepted'; fi
  output=$(print_onboard_audio_status analog)
  assert_contains "$output" 'unknown visible matching devices'

  bounded_user_pw_cli() { :; }
  output=$(print_onboard_audio_status all)
  assert_contains "$output" 'Onboard analog: enabled (0 visible matching devices)'
  assert_contains "$output" 'Onboard HDMI: enabled (0 visible matching devices)'
}

test_player_control_resolves_configured_urls() {
  local user mock_bin output rc mapped_url first_id second_id
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user"
  sed -i 's#http://127.0.0.1:32500/#http://player.example:1234/api/#' "$CONFIG_FILE"
  printf 'media-key = KEY_CUSTOM https://other.example/action?literal=yes\n' >> "$CONFIG_FILE"
  printf 'media-key = KEY_MULTI https://other.example/{command-id}?id={command-id}\n' >> "$CONFIG_FILE"
  mock_bin=$TEST_SCRATCH/bin
  install -d "$mock_bin"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "%s\n" "$@" > "$CURL_LOG"'
  } > "$mock_bin/curl"
  chmod 0755 "$mock_bin/curl"
  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" player_control_action KEY_NEXTSONG)
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'http://player.example:1234/api/player/playback/skipNext?type=music&commandID='
  assert_file_not_contains "$TEST_SCRATCH/curl.log" '{command-id}'
  assert_file_contains "$TEST_SCRATCH/curl.log" '--connect-timeout'
  assert_file_contains "$TEST_SCRATCH/curl.log" '--max-time'

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" player_control_action KEY_CUSTOM)
  assert_file_contains "$TEST_SCRATCH/curl.log" 'https://other.example/action?literal=yes'

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" player_control_action KEY_MULTI)
  mapped_url=$(tail -n1 "$TEST_SCRATCH/curl.log")
  assert_not_contains "$mapped_url" '{command-id}'
  first_id=${mapped_url#https://other.example/}
  first_id=${first_id%%\?*}
  second_id=${mapped_url##*=}
  assert_eq "$first_id" "$second_id"

  rm -f -- "$TEST_SCRATCH/curl.log"
  set +e
  output=$(PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" \
    player_control_action KEY_MISSING 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'unmapped media key unexpectedly succeeded'
  assert_contains "$output" 'No valid media URL is configured for KEY_MISSING'
  [[ ! -e $TEST_SCRATCH/curl.log ]] || fail 'curl ran for an unmapped media key'
}

test_media_control_shared_deadline() {
  local clock_call=0
  load_app
  MEDIA_DEADLINE_US=4000000
  media_now_us() {
    local target_name=$1 value
    clock_call=$((clock_call + 1))
    case $clock_call in
      1) value=2500000 ;;
      2) value=3500000 ;;
      *) value=4000000 ;;
    esac
    printf -v "$target_name" '%s' "$value"
  }
  curl() { printf '%s\n' "$*" >> "$TEST_SCRATCH/media-curl.log"; }
  setup_scratch_dir

  media_curl https://player.example/first
  media_curl https://player.example/second
  assert_contains "$(sed -n '1p' "$TEST_SCRATCH/media-curl.log")" \
    '--connect-timeout 1 --max-time 1.500000'
  assert_contains "$(sed -n '2p' "$TEST_SCRATCH/media-curl.log")" \
    '--connect-timeout 0.500000 --max-time 0.500000'
  if media_curl https://player.example/expired; then
    fail 'expired media-control deadline still invoked curl'
  fi
  assert_eq 2 "$(wc -l < "$TEST_SCRATCH/media-curl.log")"
}

test_media_control_monotonic_outer_bound() {
  local clock mock_bin now command_id output rc
  setup_scratch_dir
  load_app
  configure_scratch_paths
  clock=$TEST_SCRATCH/uptime
  printf '12.345678 99.000000\n' > "$clock"
  MEDIA_MONOTONIC_CLOCK=$clock

  media_now_us now
  assert_eq 12345678 "$now"
  start_media_deadline
  assert_eq 14345678 "$MEDIA_DEADLINE_US"
  A2DPILOT_MEDIA_DEADLINE_US=$MEDIA_DEADLINE_US import_media_deadline
  assert_eq 1 "$MEDIA_DEADLINE_INHERITED"
  MEDIA_DEADLINE_INHERITED=0
  if A2DPILOT_MEDIA_DEADLINE_US=14345679 import_media_deadline; then
    fail 'worker accepted an inherited deadline longer than the media budget'
  fi
  media_command_id command_id
  [[ $command_id =~ ^[0-9]+$ ]] || fail 'media command ID is not epoch milliseconds'

  mock_bin=$TEST_SCRATCH/bin
  install -d "$mock_bin"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'printf "%s\n" "$*" > "$TIMEOUT_LOG"'
    printf '%s\n' 'exit "${TIMEOUT_RESULT:-0}"'
  } > "$mock_bin/timeout"
  chmod 0755 "$mock_bin/timeout"
  MEDIA_RUNTIME_USER=nobody
  SCRIPT_PATH=/usr/local/sbin/a2dpilot
  media_invoking_as_root() { return 0; }
  set +e
  output=$(PATH="$mock_bin:$PATH" TIMEOUT_LOG="$TEST_SCRATCH/timeout.log" \
    TIMEOUT_RESULT=124 bounded_player_control_action KEY_PLAYCD 2>&1)
  rc=$?
  set -e
  assert_eq 124 "$rc"
  assert_contains "$output" 'media-control request timed out'
  assert_file_contains "$TEST_SCRATCH/timeout.log" '--signal=TERM --kill-after=0.1 2.000000'
  assert_file_contains "$TEST_SCRATCH/timeout.log" \
    'runuser -u nobody -- env A2DPILOT_MEDIA_DEADLINE_US=14345678'
  assert_file_contains "$TEST_SCRATCH/timeout.log" \
    '/usr/local/sbin/a2dpilot __player-control KEY_PLAYCD'

  media_invoking_as_root() { return 1; }
  PATH="$mock_bin:$PATH" TIMEOUT_LOG="$TEST_SCRATCH/timeout.log" \
    bounded_player_control_action KEY_NEXTSONG
  assert_file_not_contains "$TEST_SCRATCH/timeout.log" 'runuser'
  assert_file_contains "$TEST_SCRATCH/timeout.log" \
    '/usr/local/sbin/a2dpilot __player-control KEY_NEXTSONG'
}

test_player_control_resolves_stateful_media_keys() {
  local user mock_bin output rc mute_state
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_default_config "$CONFIG_FILE" "$user"
  mock_bin=$TEST_SCRATCH/bin
  install -d "$mock_bin"
  {
    printf '%s\n' '#!/bin/sh'
    printf '%s\n' 'for argument do url=$argument; done'
    printf '%s\n' 'case $url in'
    printf '%s\n' '  */player/timeline/poll\?*)'
    printf '%s\n' '    printf "poll %s\n" "$*" >> "$CURL_LOG"'
    printf '%s\n' '    printf "<MediaContainer><Timeline type=\"music\" volume=\"%s\" shuffle=\"%s\" repeat=\"%s\" /></MediaContainer>\n" "${TIMELINE_VOLUME:-50}" "${TIMELINE_SHUFFLE:-0}" "${TIMELINE_REPEAT:-0}"'
    printf '%s\n' '    ;;'
    printf '%s\n' '  *)'
    printf '%s\n' '    printf "request %s\n" "$url" >> "$CURL_LOG"'
    printf '%s\n' '    [ "${FINAL_REQUEST_FAIL:-0}" = 0 ]'
    printf '%s\n' '    ;;'
    printf '%s\n' 'esac'
  } > "$mock_bin/curl"
  chmod 0755 "$mock_bin/curl"
  acquire_media_lock() { printf 'acquire %s\n' "$1" >> "$TEST_SCRATCH/media-lock.log"; }
  release_media_lock() { printf 'release\n' >> "$TEST_SCRATCH/media-lock.log"; }
  # Keep this mock's argument contract visible to ShellCheck 0.9; the
  # player-control calls below verify that the real path supplies the budget.
  acquire_media_lock 0.500000
  : > "$TEST_SCRATCH/media-lock.log"

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=98 \
    player_control_action KEY_VOLUMEUP)
  assert_file_contains "$TEST_SCRATCH/curl.log" 'X-Plex-Client-Identifier: a2dpilot'
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'request http://127.0.0.1:32500/player/playback/setParameters?type=music&volume=100&commandID='

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=2 \
    player_control_action KEY_VOLUMEDOWN)
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'request http://127.0.0.1:32500/player/playback/setParameters?type=music&volume=0&commandID='

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=63 \
    player_control_action KEY_MUTE)
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'request http://127.0.0.1:32500/player/playback/setParameters?type=music&volume=0&commandID='
  parse_config "$CONFIG_FILE"
  mute_state=$(media_mute_state_path)
  assert_file_contains "$mute_state" '63'

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=0 \
    player_control_action KEY_MUTE)
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'request http://127.0.0.1:32500/player/playback/setParameters?type=music&volume=63&commandID='
  [[ ! -e $mute_state ]] || fail 'successful unmute retained the saved volume'

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=0 \
    player_control_action KEY_MUTE)
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'request http://127.0.0.1:32500/player/playback/setParameters?type=music&volume=15&commandID='

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=42 \
    player_control_action KEY_MUTE)
  [[ -f $mute_state ]] || fail 'mute did not save its pre-mute volume'
  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=0 \
    player_control_action KEY_VOLUMEUP)
  [[ ! -e $mute_state ]] || fail 'volume-up from zero retained the saved mute volume'

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=54 \
    player_control_action KEY_MUTE)
  set +e
  PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=0 \
    FINAL_REQUEST_FAIL=1 player_control_action KEY_MUTE
  rc=$?
  set -e
  (( rc != 0 )) || fail 'fault-injected unmute unexpectedly succeeded'
  assert_file_contains "$mute_state" '54'

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_SHUFFLE=0 \
    player_control_action KEY_SHUFFLE)
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'request http://127.0.0.1:32500/player/playback/setParameters?type=music&shuffle=1&commandID='

  (PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_REPEAT=2 \
    player_control_action KEY_MEDIA_REPEAT)
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'request http://127.0.0.1:32500/player/playback/setParameters?type=music&repeat=1&commandID='

  set +e
  output=$(PATH="$mock_bin:$PATH" CURL_LOG="$TEST_SCRATCH/curl.log" TIMELINE_VOLUME=101 \
    player_control_action KEY_VOLUMEUP 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'out-of-range timeline volume was accepted'
  assert_contains "$output" 'No valid media URL is configured for KEY_VOLUMEUP'
  assert_file_contains "$TEST_SCRATCH/media-lock.log" 'acquire'
  assert_file_contains "$TEST_SCRATCH/media-lock.log" 'release'
  grep -Eq '^acquire [01]\.[0-9]{6}$' "$TEST_SCRATCH/media-lock.log" || \
    fail 'stateful media lock did not receive the shared deadline remainder'
}

test_mute_state_rejects_symlinked_parent() {
  local user redirected
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_default_config "$CONFIG_FILE" "$user"
  parse_config "$CONFIG_FILE"
  acquire_media_lock "$MEDIA_ACTION_TIMEOUT"
  [[ -n $MEDIA_LOCK_FD ]] || fail 'media lock did not retain a descriptor'
  assert_eq 600 "$(stat -c %a "$MEDIA_LOCK_FILE")"
  assert_eq "$(id -u "$MEDIA_RUNTIME_USER")" "$(stat -c %u "$MEDIA_STATE_DIR")"
  release_media_lock
  [[ -z $MEDIA_LOCK_FD ]] || fail 'media lock descriptor was not released'
  rm -f -- "$MEDIA_LOCK_FILE"
  rmdir -- "$MEDIA_STATE_DIR"
  redirected=$TEST_SCRATCH/redirected-media-state
  install -d "$(dirname "$MEDIA_STATE_DIR")" "$redirected"
  ln -s "$redirected" "$MEDIA_STATE_DIR"
  expect_failure_contains 'Refusing to traverse symlinked directory' read_media_mute_volume
  expect_failure_contains 'Refusing to traverse symlinked directory' write_media_mute_volume 70
  [[ -z $(find "$redirected" -mindepth 1 -print -quit) ]] || \
    fail 'mute state was written through its symlinked parent'
}

test_media_state_rejects_unprivileged_parent_for_root() {
  local parent_uid
  setup_scratch_dir
  load_app
  configure_scratch_paths
  rm -rf -- "$MEDIA_STATE_DIR"
  parent_uid=$(id -u)
  if (( parent_uid == 0 )); then
    parent_uid=$(id -u nobody) || fail 'could not resolve an unprivileged fixture user'
    chown "$parent_uid" "$MEDIA_STATE_ROOT"
  fi
  assert_eq "$parent_uid" "$(stat -c %u "$MEDIA_STATE_ROOT")"
  media_effective_uid() { printf '0\n'; }

  if prepare_media_state_directory; then
    fail 'root accepted an unprivileged-owned media-state parent'
  fi
  [[ ! -e $MEDIA_STATE_DIR ]] || \
    fail 'root mutated an unprivileged-owned media-state parent'
}

test_media_state_rejects_wrong_identity() {
  local user foreign_user=nobody
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  [[ $(id -u "$foreign_user") != "$(id -u)" ]] || foreign_user=root
  write_default_config "$CONFIG_FILE" "$user"
  parse_config "$CONFIG_FILE"
  MEDIA_RUNTIME_USER=$foreign_user

  if acquire_media_lock 0.1; then
    fail 'non-runtime identity acquired the media-state lock'
  fi
  if write_media_mute_volume 70; then
    fail 'non-runtime identity wrote media state'
  fi
  if clear_media_mute_volume; then
    fail 'non-runtime identity cleared media state'
  fi
  [[ ! -e $MEDIA_LOCK_FILE ]] || fail 'identity rejection created a lock file'
  [[ ! -e $MEDIA_STATE_DIR ]] || fail 'identity rejection created the media directory'
}

test_status_reports_media_url_configuration() {
  local user output
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user"
  require_root() { :; }
  rfkill() { :; }
  systemctl() { :; }
  as_user_systemctl() { :; }
  bounded_user_pw_cli() { :; }
  configured_default_sink() { return 1; }
  output=$(status_action)
  assert_contains "$output" 'Base URL: http://127.0.0.1:32500'
  assert_contains "$output" 'Media key mappings: 4'
  assert_contains "$output" 'Onboard analog: enabled (0 visible matching devices)'
  assert_contains "$output" 'Onboard HDMI: enabled (0 visible matching devices)'
  assert_contains "$output" 'Configured audio default: unknown'

  configured_default_sink() { return 2; }
  output=$(print_routing_status)
  assert_contains "$output" 'Configured audio default: none'
}

test_status_stream_inspection_shared_deadline() {
  local user output clock=100
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  printf 'AA:BB:CC:DD:EE:FF\n' > "$STATE_DIR/active-speaker"
  routing_now_seconds() { printf '%s\n' "$clock"; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { return 2; }
  enumerate_playback_streams() {
    assert_eq 3 "$2" || return 1
    printf '%s\n' '95 138' '96 139' '97 140'
  }
  inspect_pipewire_node() {
    if [[ $2 == 83 ]]; then
      PIPEWIRE_NODE_SERIAL=89
      PIPEWIRE_NODE_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
      PIPEWIRE_NODE_CLASS=Audio/Sink
      PIPEWIRE_NODE_DRIVER=
      return 0
    fi
    printf '%s %s\n' "$2" "$3" >> "$TEST_SCRATCH/status-inspections"
    PIPEWIRE_NODE_SERIAL=$((43 + $2))
    PIPEWIRE_NODE_NAME='Status Player'
    PIPEWIRE_NODE_CLASS=Stream/Output/Audio
    PIPEWIRE_NODE_DRIVER=35
    if [[ $2 == 95 ]]; then clock=102; else clock=103; fi
  }

  output=$(print_routing_status)
  assert_contains "$output" 'Playback streams off active sink: unknown'
  assert_eq $'95 3\n96 1' "$(< "$TEST_SCRATCH/status-inspections")"
  assert_file_not_contains "$TEST_SCRATCH/status-inspections" '97 '
}

test_status_rejects_unverified_or_recycled_active_node() {
  local user output
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  printf 'AA:BB:CC:DD:EE:FF\n' > "$STATE_DIR/active-speaker"
  find_a2dp_node_id() { printf '83\n'; }
  inspect_pipewire_node() {
    PIPEWIRE_NODE_SERIAL=90
    PIPEWIRE_NODE_NAME=alsa_output.recycled
    PIPEWIRE_NODE_CLASS=Audio/Sink
    PIPEWIRE_NODE_DRIVER=
  }
  configured_default_sink() { return 2; }
  enumerate_playback_streams() {
    fail 'status enumerated streams against an unverified or recycled active node'
  }

  output=$(print_routing_status)
  assert_contains "$output" 'Active managed sink: none'
  assert_contains "$output" 'Playback streams off active sink: n/a'
}

test_pairing_provenance_and_existing_bond() {
  local user mac=AA:BB:CC:DD:EE:FF paired=0 paired_file trusted_file
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user"
  parse_config "$CONFIG_FILE"
  paired_file=$TEST_SCRATCH/paired
  trusted_file=$TEST_SCRATCH/trusted
  : > "$STATE_DIR/created-bonds"
  atomic_install_file() { cp "$1" "$2"; }
  has_tty() { return 1; }
  note() { printf '%s\n' "$*" >> "$TEST_SCRATCH/pairing-notes"; }
  scan_bredr() { :; }
  configured_controller_address() { printf '12:34:56:78:9A:BC\n'; }
  device_paired() { (( paired )) || [[ -f $paired_file ]]; }
  device_trusted() { [[ -f $trusted_file ]]; }
  wait_for_device_connection() { return 0; }
  systemctl() { :; }
  bluetoothctl() {
    local input=''
    if [[ ${1:-} == show ]]; then
      printf '\tPairable: no\n'
      return 0
    fi
    if [[ $* == *'--agent '* ]]; then
      while IFS= read -r input; do
        printf '%s\n' "$input" >> "$TEST_SCRATCH/bluetooth.log"
        [[ $input != quit ]] || break
        if [[ $input == "pair $mac" ]]; then
          : > "$paired_file"
          printf 'Pairing successful\n'
        fi
      done
      return 0
    fi
    while IFS= read -r input; do
      printf '%s\n' "$input" >> "$TEST_SCRATCH/bluetooth.log"
      [[ $input != "trust $mac" ]] || : > "$trusted_file"
    done
    return 0
  }

  pair_one "$mac" NoInputNoOutput
  assert_file_contains "$STATE_DIR/created-bonds" "12:34:56:78:9A:BC $mac"
  assert_file_contains "$TEST_SCRATCH/bluetooth.log" "pair $mac"
  assert_file_contains "$TEST_SCRATCH/pairing-notes" 'Pairing succeeded; finalizing trust and connection...'
  parse_config "$CONFIG_FILE"
  assert_eq "$mac" "${CFG_SPEAKERS[0]}"
  assert_eq '' "${CFG_SPEAKER_CODECS[0]}"

  : > "$TEST_SCRATCH/bluetooth.log"
  : > "$STATE_DIR/created-bonds"
  rm -f -- "$trusted_file"
  pair_one "$mac" NoInputNoOutput
  assert_file_not_contains "$TEST_SCRATCH/bluetooth.log" "pair $mac"
  assert_file_contains "$TEST_SCRATCH/bluetooth.log" "trust $mac"
  [[ ! -s $STATE_DIR/created-bonds ]] || fail 'existing bond was recorded as A2DPilot-created'
}

test_pairing_session_terminates_after_bonding() {
  local mac=AA:BB:CC:DD:EE:FF controller=12:34:56:78:9A:BC
  local pair_failure=0 pair_hang=0 session_pid rc attempt
  setup_scratch_dir
  load_app
  configure_scratch_paths
  printf 'no\n' > "$TEST_SCRATCH/pairable-state"
  has_tty() { return 1; }
  kill() {
    [[ ${1:-} =~ ^[0-9]+$ ]] && printf '%s\n' "$1" >> "$TEST_SCRATCH/terminated-pair-sessions"
    builtin kill "$@"
  }
  bluetoothctl() {
    local command
    if [[ ${1:-} == show ]]; then
      printf '\tPairable: %s\n' "$(< "$TEST_SCRATCH/pairable-state")"
      return 0
    fi
    if [[ $* == *'--agent '* ]]; then
      printf 'args: %s\n' "$*" >> "$TEST_SCRATCH/pair-sessions"
    else
      printf 'args: %s\n' "$*" >> "$TEST_SCRATCH/pairable-restores"
    fi
    while IFS= read -r command; do
      if [[ $* == *'--agent '* ]]; then
        printf '%s\n' "$command" >> "$TEST_SCRATCH/pair-sessions"
      else
        printf '%s\n' "$command" >> "$TEST_SCRATCH/pairable-restores"
      fi
      case $command in
        'pairable on') printf 'yes\n' > "$TEST_SCRATCH/pairable-state" ;;
        'pairable off') printf 'no\n' > "$TEST_SCRATCH/pairable-state" ;;
        "pair $mac")
          if (( pair_hang )); then
            : > "$TEST_SCRATCH/pair-session-started"
            while true; do sleep 1; done
          elif (( pair_failure )); then
            printf 'Failed to pair: org.bluez.Error.AuthenticationFailed\n'
          else
            printf 'Pairing successful\n'
          fi
          ;;
      esac
    done
  }

  CFG_CONTROLLER=auto
  pair_on_controller "$mac" NoInputNoOutput >/dev/null
  assert_eq no "$(< "$TEST_SCRATCH/pairable-state")"
  printf '%s\n' session-end >> "$TEST_SCRATCH/pair-sessions"
  printf 'yes\n' > "$TEST_SCRATCH/pairable-state"
  CFG_CONTROLLER=$controller
  pair_on_controller "$mac" NoInputNoOutput >/dev/null
  assert_eq yes "$(< "$TEST_SCRATCH/pairable-state")"
  printf 'no\n' > "$TEST_SCRATCH/pairable-state"
  pair_failure=1
  if pair_on_controller "$mac" NoInputNoOutput >/dev/null; then
    fail 'fault-injected pairing failure reported success'
  fi
  assert_eq no "$(< "$TEST_SCRATCH/pairable-state")"

  pair_failure=0
  pair_hang=1
  CFG_CONTROLLER=auto
  pair_on_controller "$mac" NoInputNoOutput >/dev/null &
  session_pid=$!
  for attempt in {1..50}; do
    [[ -e $TEST_SCRATCH/pair-session-started ]] && break
    sleep 0.05
  done
  [[ -e $TEST_SCRATCH/pair-session-started ]] || fail 'interrupted pairing session did not start'
  assert_eq yes "$(< "$TEST_SCRATCH/pairable-state")"
  builtin kill -TERM "$session_pid"
  set +e
  wait "$session_pid" 2>/dev/null
  rc=$?
  set -e
  assert_eq 143 "$rc"
  assert_eq no "$(< "$TEST_SCRATCH/pairable-state")"

  assert_eq 4 "$(grep -Fc 'args: --agent NoInputNoOutput' "$TEST_SCRATCH/pair-sessions")"
  assert_eq 4 "$(grep -Fc 'pairable on' "$TEST_SCRATCH/pair-sessions")"
  assert_eq 4 "$(grep -Fc "pair $mac" "$TEST_SCRATCH/pair-sessions")"
  assert_file_not_contains "$TEST_SCRATCH/pair-sessions" 'quit'
  assert_eq 4 "$(wc -l < "$TEST_SCRATCH/terminated-pair-sessions")"
  assert_eq 3 "$(grep -Fc 'pairable off' "$TEST_SCRATCH/pairable-restores")"
  assert_eq 1 "$(grep -Fc 'pairable on' "$TEST_SCRATCH/pairable-restores")"
  assert_eq 4 "$(grep -Fc 'quit' "$TEST_SCRATCH/pairable-restores")"
  assert_eq 2 "$(grep -Fc "select $controller" "$TEST_SCRATCH/pair-sessions")"
  assert_eq $'args: --agent NoInputNoOutput\npairable on\npair AA:BB:CC:DD:EE:FF' \
    "$(sed -n '1,/session-end/{ /session-end/d; p; }' "$TEST_SCRATCH/pair-sessions")"
}

test_pair_all_attempts_every_configured_speaker() {
  local user first=AA:BB:CC:DD:EE:01 second=AA:BB:CC:DD:EE:02 output rc
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_CONTROLLER=auto
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" "$first aptx sbc" "$second sbc"
  : > "$STATE_FILE"
  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  power_controller() { :; }
  pair_one() {
    printf '%s\n' "$1" >> "$TEST_SCRATCH/pair-order"
    [[ $1 != "$first" ]]
  }
  systemctl() { :; }
  set +e
  output=$(pair_action --all 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'partial --all pairing failure reported success'
  assert_contains "$output" "Could not provision $first"
  assert_eq "$first" "$(sed -n '1p' "$TEST_SCRATCH/pair-order")"
  assert_eq "$second" "$(sed -n '2p' "$TEST_SCRATCH/pair-order")"
}

test_interactive_scan_selection() {
  local configured=AA:BB:CC:DD:EE:FF existing=10:20:30:40:50:60
  local -a answers=(r 1 '')
  local answer_index=0 scan_count=0 warnings=''
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_CONTROLLER=auto
  CFG_SPEAKERS=("$configured")
  scan_bredr() { scan_count=$((scan_count + 1)); }
  tty_print() { printf '%s\n' "$*" >> "$TEST_SCRATCH/prompts"; }
  tty_read() {
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  warn() { warnings+="$*"; }
  bluetoothctl() {
    if [[ ${1:-} == devices && $scan_count -gt 1 ]]; then
      printf 'Device %s Already Configured\n' "$configured"
      printf 'Device %s Existing Bond\n' "$existing"
    fi
  }
  pair_one() {
    printf '%s %s\n' "$1" "$2" >> "$TEST_SCRATCH/selected"
    CFG_SPEAKERS+=("$1")
  }
  interactive_pair_loop KeyboardDisplay
  assert_file_contains "$TEST_SCRATCH/selected" "$existing KeyboardDisplay"
  assert_eq 1 "$(wc -l < "$TEST_SCRATCH/selected")"
  assert_eq 3 "$scan_count"
  assert_not_contains "$warnings" 'Invalid selection.'
  assert_file_contains "$TEST_SCRATCH/prompts" '[r]escan'
  assert_file_not_contains "$TEST_SCRATCH/prompts" "$configured"
  assert_eq 1 "$(grep -Fc "$existing" "$TEST_SCRATCH/prompts")"
}

test_forget_removes_config_and_provenance() {
  local user mac=AA:BB:CC:DD:EE:FF present=1 recorded_present=1
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" "$mac aptx_hd aptx sbc" 10:20:30:40:50:60
  printf '12:34:56:78:9A:BC %s\n' "$mac" > "$STATE_DIR/created-bonds"
  printf '%s\n' "$mac" > "$STATE_DIR/active-speaker"
  printf '%s\taptx_hd aptx sbc\n' "$mac" > "$STATE_DIR/active-codec-policy"
  : > "$STATE_FILE"
  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  atomic_install_file() { cp "$1" "$2"; }
  clear_owned_routing() {
    printf 'clear-routing %s %s\n' "$1" "$2" >> "$TEST_SCRATCH/forget-order"
  }
  disconnect_bluetooth_device() {
    printf 'disconnect %s\n' "$1" >> "$TEST_SCRATCH/forget-order"
  }
  device_info() { (( present )) && printf 'Paired: yes\n'; }
  remove_bluetooth_device() {
    present=0
    printf 'current %s\n' "$1" >> "$TEST_SCRATCH/bluetooth.log"
  }
  device_info_on_controller() { (( recorded_present )); }
  remove_bluetooth_device_on_controller() {
    recorded_present=0
    printf '%s %s\n' "$1" "$2" >> "$TEST_SCRATCH/bluetooth.log"
  }
  systemctl() { :; }
  forget_action "$mac" --yes
  parse_config "$CONFIG_FILE"
  assert_eq 1 "${#CFG_SPEAKERS[@]}"
  assert_eq 10:20:30:40:50:60 "${CFG_SPEAKERS[0]}"
  [[ ! -s $STATE_DIR/created-bonds ]] || fail 'forgotten bond remained in provenance ledger'
  assert_file_contains "$TEST_SCRATCH/bluetooth.log" "current $mac"
  assert_file_contains "$TEST_SCRATCH/bluetooth.log" "12:34:56:78:9A:BC $mac"
  assert_eq $'disconnect '"$mac"$'\nclear-routing '"$user $mac" \
    "$(< "$TEST_SCRATCH/forget-order")"
  [[ ! -e $STATE_DIR/active-speaker && ! -e $STATE_DIR/active-codec-policy ]] || \
    fail 'forgotten active speaker retained daemon state'
}

test_forget_clears_routing_for_prior_speaker() {
  local user mac=AA:BB:CC:DD:EE:FF active=10:20:30:40:50:60
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" "$mac" "$active"
  printf '%s\n' "$active" > "$STATE_DIR/active-speaker"
  : > "$STATE_FILE"
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  write_routing_state
  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  atomic_install_file() { cp "$1" "$2"; }
  clear_owned_routing() {
    printf '%s %s\n' "$1" "$2" > "$TEST_SCRATCH/forget-routing-user"
    rm -f -- "$ROUTING_STATE_FILE"
  }
  disconnect_bluetooth_device() { :; }
  device_info() { return 1; }
  systemctl() { :; }

  forget_action "$mac" --yes
  assert_eq "$user $mac" "$(< "$TEST_SCRATCH/forget-routing-user")"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'forget retained routing provenance for a prior speaker'
  assert_eq "$active" "$(< "$STATE_DIR/active-speaker")"
}

test_forget_preserves_unrelated_routing() {
  local user mac=AA:BB:CC:DD:EE:FF active=10:20:30:40:50:60
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" "$mac" "$active"
  printf '%s\n' "$active" > "$STATE_DIR/active-speaker"
  : > "$STATE_FILE"
  ROUTING_STATE_USER=$user
  ROUTING_STATE_SPEAKERS=()
  ROUTING_STATE_SPEAKERS["$active"]=1
  ROUTING_DEFAULT_NAME=bluez_output.10_20_30_40_50_60.1
  write_routing_state
  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  atomic_install_file() { cp "$1" "$2"; }
  clear_owned_routing() { fail 'forget cleared routing owned by another speaker'; }
  disconnect_bluetooth_device() { :; }
  device_info() { return 1; }
  systemctl() { :; }

  forget_action "$mac" --yes
  assert_file_contains "$ROUTING_STATE_FILE" \
    $'default\tbluez_output.10_20_30_40_50_60.1'
  assert_eq "$active" "$(< "$STATE_DIR/active-speaker")"
}

test_forget_active_speaker_preserves_different_routing_owner() {
  local user mac=AA:BB:CC:DD:EE:FF owner=10:20:30:40:50:60
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" "$owner" "$mac"
  printf '%s\n' "$mac" > "$STATE_DIR/active-speaker"
  : > "$STATE_FILE"
  ROUTING_STATE_USER=$user
  ROUTING_STATE_SPEAKERS=(["$owner"]=1)
  ROUTING_DEFAULT_NAME=bluez_output.10_20_30_40_50_60.1
  write_routing_state
  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  atomic_install_file() { cp "$1" "$2"; }
  clear_owned_routing() { fail 'forget cleared routing owned by another speaker'; }
  disconnect_bluetooth_device() { :; }
  device_info() { return 1; }
  systemctl() { :; }

  forget_action "$mac" --yes
  assert_file_contains "$ROUTING_STATE_FILE" \
    $'default\tbluez_output.10_20_30_40_50_60.1'
  [[ ! -e $STATE_DIR/active-speaker ]] || \
    fail 'forgotten active speaker retained daemon state'
}

test_forget_commits_before_routing_cleanup_failure() {
  local user mac=AA:BB:CC:DD:EE:FF output rc
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" "$mac"
  printf '%s\n' "$mac" > "$STATE_DIR/active-speaker"
  : > "$STATE_FILE"
  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  clear_owned_routing() { return 1; }
  disconnect_bluetooth_device() { : > "$TEST_SCRATCH/disconnected"; }
  device_info() { return 1; }
  atomic_install_file() { cp "$1" "$2"; }
  systemctl() { :; }

  set +e
  output=$(forget_action "$mac" --yes 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'forget succeeded after routing cleanup failed'
  assert_contains "$output" "Forgot $mac, but could not clear all of its audio routing"
  assert_file_not_contains "$CONFIG_FILE" "speaker = $mac"
  [[ -e $TEST_SCRATCH/disconnected ]] || fail 'forget did not disconnect before cleanup'
  [[ ! -e $STATE_DIR/active-speaker ]] || \
    fail 'forget retained active state after committing configuration removal'
}

test_forget_failure_preserves_routing_and_configuration() {
  local user mac=AA:BB:CC:DD:EE:FF output rc
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" "$mac"
  : > "$STATE_FILE"
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  write_routing_state
  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  disconnect_bluetooth_device() { :; }
  device_info() { return 0; }
  remove_bluetooth_device() { return 1; }
  clear_owned_routing() { fail 'failed bond removal cleared audio routing'; }

  set +e
  output=$(forget_action "$mac" --yes 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'forget succeeded after BlueZ removal failed'
  assert_contains "$output" "BlueZ could not remove $mac"
  assert_file_contains "$CONFIG_FILE" "speaker = $mac"
  assert_file_contains "$ROUTING_STATE_FILE" \
    $'default\tbluez_output.AA_BB_CC_DD_EE_FF.1\tAA:BB:CC:DD:EE:FF'
}

test_media_control_health_modes() {
  load_app
  device_connected() { return 0; }
  a2dp_connected() { return 0; }
  avrcp_connected() { return 1; }
  CFG_MEDIA_CONTROLS=auto
  device_healthy AA:BB:CC:DD:EE:FF || fail 'auto mode required AVRCP'
  CFG_MEDIA_CONTROLS=off
  device_healthy AA:BB:CC:DD:EE:FF || fail 'off mode required AVRCP'
  CFG_MEDIA_CONTROLS=required
  if device_healthy AA:BB:CC:DD:EE:FF; then fail 'required mode ignored AVRCP'; fi
}

test_codec_reporting_is_optimistic() {
  local user candidate_codec output
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" AA:BB:CC:DD:EE:FF
  require_root() { :; }
  device_paired() { return 0; }
  device_trusted() { return 0; }
  device_connected() { return 0; }
  a2dp_connected() { return 0; }
  avrcp_connected() { return 1; }
  device_name() { printf 'Test Speaker\n'; }
  for candidate_codec in sbc sbc_xq aptx aptx_hd ldac mystery_codec; do
    TEST_CODEC=$candidate_codec
    a2dp_codec() { printf '%s\n' "$TEST_CODEC"; }
    output=$(devices_action)
    assert_contains "$output" "$candidate_codec"
    assert_contains "$output" 'yes'
    assert_contains "$output" 'CODEC-POLICY'
    assert_contains "$output" 'auto'
  done
  write_test_config "$CONFIG_FILE" "$user" 'AA:BB:CC:DD:EE:FF aptx_hd aptx sbc'
  output=$(devices_action)
  assert_contains "$output" 'aptx_hd>aptx>sbc'
}

test_codec_property_parsing() {
  local codec calls
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_AUDIO_USER=$(id -un)
  printf '99\n' > "$TEST_SCRATCH/clock"
  now_seconds() {
    local current
    current=$(< "$TEST_SCRATCH/clock")
    current=$((current + 1))
    printf '%s\n' "$current" > "$TEST_SCRATCH/clock"
    printf '%s\n' "$current"
  }
  bounded_user_wpctl() {
    printf '%s %s\n' "$2" "${*:3}" >> "$TEST_SCRATCH/wpctl-calls"
    case $3 in
      status) printf '  42. bluez_output.AA_BB_CC_DD_EE_FF.1\n' ;;
      inspect) printf '  * api.bluez5.codec = "ldac"\n' ;;
    esac
  }
  codec=$(a2dp_codec AA:BB:CC:DD:EE:FF 5)
  assert_eq ldac "$codec"
  calls=$(< "$TEST_SCRATCH/wpctl-calls")
  assert_contains "$calls" '4 status --name'
  assert_contains "$calls" '3 inspect 42'
}

mock_pipewire_nodes_for_routing() {
  cat <<'EOF'
	id 83, type PipeWire:Interface:Node/3
		object.serial = "89"
		node.name = "bluez_output.AA_BB_CC_DD_EE_FF.1"
		media.class = "Audio/Sink"
	id 95, type PipeWire:Interface:Node/3
		object.serial = "138"
		node.name = "alsa_playback.test-player"
		media.class = "Stream/Output/Audio"
EOF
}

test_pipewire_routing_parsers() {
  local output
  setup_scratch_dir
  load_app
  KERNEL_BOOT_ID_FILE=$TEST_SCRATCH/boot-id
  PROC_ROOT=$TEST_SCRATCH/proc
  install -d "$PROC_ROOT/4321"
  printf '%s\n' '01234567-89ab-cdef-0123-456789abcdef' > "$KERNEL_BOOT_ID_FILE"
  printf '%s\n' \
    '4321 (PipeWire worker) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654' \
    > "$PROC_ROOT/4321/stat"
  bounded_user_systemctl() { printf '4321\n'; }
  assert_eq '01234567-89ab-cdef-0123-456789abcdef:4321:987654' \
    "$(pipewire_instance_id audio 3)"
  valid_pipewire_instance_id \
    '01234567-89ab-cdef-0123-456789abcdef:4321:987654' || \
    fail 'valid PipeWire instance identity was rejected'
  if valid_pipewire_instance_id '01234567-89ab-cdef-0123-456789abcdef:4321'; then
    fail 'incomplete PipeWire instance identity was accepted'
  fi
  ROUTING_MONOTONIC_CLOCK=$TEST_SCRATCH/uptime
  printf '123.45 67.89\n' > "$ROUTING_MONOTONIC_CLOCK"
  assert_eq 123.45 "$(routing_now_seconds)"
  assert_eq 123450 "$(routing_now_milliseconds)"
  assert_eq "$ROUTING_TIMEOUT" "$(routing_seconds_until_deadline 999000)"
  printf '123.95 67.89\n' > "$ROUTING_MONOTONIC_CLOCK"
  assert_eq 0.500 "$(routing_seconds_until_deadline 124450)"
  valid_timeout_duration 0.500 || fail 'fractional timeout duration was rejected'
  if valid_timeout_duration 0.000; then fail 'zero timeout duration was accepted'; fi

  bounded_user_pw_cli() { mock_pipewire_nodes_for_routing; }
  output=$(enumerate_playback_streams audio 3)
  assert_eq '95 138' "$output"

  bounded_user_wpctl() {
    cat <<'EOF'
id 95, type PipeWire:Interface:Node
  * object.serial = "138"
  * node.name = "Plexamp Playback / Main"
    node.driver-id = "83"
  * media.class = "Stream/Output/Audio"
EOF
  }
  inspect_pipewire_node audio 95 3
  assert_eq 138 "$PIPEWIRE_NODE_SERIAL"
  assert_eq 'Plexamp Playback / Main' "$PIPEWIRE_NODE_NAME"
  assert_eq Stream/Output/Audio "$PIPEWIRE_NODE_CLASS"
  assert_eq 83 "$PIPEWIRE_NODE_DRIVER"

  bounded_user_pw_metadata() {
    printf '%s\n' "update: id:0 key:'default.configured.audio.sink' value:'{\"name\":\"bluez_output.AA_BB_CC_DD_EE_FF.1\"}' type:'Spa:String:JSON'"
  }
  assert_eq bluez_output.AA_BB_CC_DD_EE_FF.1 \
    "$(configured_default_sink audio 3)"
  bounded_user_pw_metadata() {
    printf '%s\n' "update: id:95 key:'target.object' value:'89' type:'Spa:Id'"
  }
  assert_eq 89 "$(stream_target_serial audio 95 3)"
  bounded_user_pw_metadata() { printf 'malformed metadata output\n'; }
  if configured_default_sink audio 3; then
    fail 'malformed configured-default metadata was accepted as absent'
  else
    assert_eq 1 "$?"
  fi
  bounded_user_pw_metadata() { printf 'Found \"default\" metadata 42\n'; }
  if configured_default_sink audio 3; then
    fail 'configured-default discovery banner was treated as a property'
  else
    assert_eq 2 "$?"
  fi
  bounded_user_pw_metadata() { printf 'malformed target metadata\n'; }
  if stream_target_serial audio 95 3; then
    fail 'malformed stream-target metadata was accepted as absent'
  else
    assert_eq 1 "$?"
  fi
  bounded_user_pw_metadata() { printf 'Found \"default\" metadata 42\n'; }
  if stream_target_serial audio 95 3; then
    fail 'stream-target discovery banner was treated as a property'
  else
    assert_eq 2 "$?"
  fi

  bounded_user_pw_cli() {
    printf '%s\n' $'\tid 95, type PipeWire:Interface:Node/3' \
      $'\t\tmedia.class = "Stream/Output/Audio"'
  }
  if enumerate_playback_streams audio 3 >/dev/null; then
    fail 'playback stream without an object serial was accepted'
  fi
  bounded_user_wpctl() {
    printf '%s\n' '  * object.serial = "138"' '  * object.serial = "139"' \
      '  * node.name = "alsa_playback.test"' '  * media.class = "Stream/Output/Audio"'
  }
  if inspect_pipewire_node audio 95 3; then
    fail 'duplicate PipeWire object serial was accepted'
  fi
}

test_default_routing_and_owned_cleanup() {
  local user mac=AA:BB:CC:DD:EE:FF default_sink=alsa_output.builtin
  local stream_driver=35 stream_serial=138 stream_target='' cleanup_log inspect_stream_fails=0
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  now_seconds() { printf '100\n'; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  bounded_user_pw_cli() { mock_pipewire_nodes_for_routing; }
  bounded_user_wpctl() {
    case $3 in
      inspect)
        if [[ $4 == 83 ]]; then
          cat <<'EOF'
  * object.serial = "89"
  * node.name = "bluez_output.AA_BB_CC_DD_EE_FF.1"
  * media.class = "Audio/Sink"
EOF
        else
          (( inspect_stream_fails == 0 )) || return 1
          printf '%s\n' "  * object.serial = \"$stream_serial\"" \
            '  * node.name = "alsa_playback.test-player"' \
            "    node.driver-id = \"$stream_driver\"" \
            '  * media.class = "Stream/Output/Audio"'
        fi
        ;;
      set-default)
        assert_file_contains "$ROUTING_STATE_FILE" \
          $'default-pending\tbluez_output.AA_BB_CC_DD_EE_FF.1' || return 1
        default_sink=bluez_output.AA_BB_CC_DD_EE_FF.1
        printf 'set-default %s\n' "$4" >> "$TEST_SCRATCH/routing.log"
        ;;
      clear-default)
        default_sink=
        printf 'clear-default %s\n' "$4" >> "$TEST_SCRATCH/routing.log"
        ;;
    esac
  }
  bounded_user_pw_metadata() {
    if [[ $* == *'default.configured.audio.sink'* ]]; then
      [[ -z $default_sink ]] || printf '%s\n' \
        "update: id:0 key:'default.configured.audio.sink' value:'{\"name\":\"$default_sink\"}' type:'Spa:String:JSON'"
    elif [[ $* == *'-d -n default 95 target.object'* ]]; then
      stream_target=
      printf 'clear-target 95\n' >> "$TEST_SCRATCH/routing.log"
    elif [[ $* == *'95 target.object 89 Spa:Id'* ]]; then
      assert_file_contains "$ROUTING_STATE_FILE" $'stream-pending\t138\t89' || return 1
      stream_target=89
      stream_driver=83
      printf 'set-target 95 89\n' >> "$TEST_SCRATCH/routing.log"
    elif [[ $* == *'95 target.object'* ]]; then
      [[ -z $stream_target ]] || printf '%s\n' \
        "update: id:95 key:'target.object' value:'$stream_target' type:'Spa:Id'"
    fi
  }

  ROUTING_STATE_USER=$user
  ROUTING_STATE_SPEAKERS=([11:22:33:44:55:66]=1)
  ROUTING_DEFAULT_NAME=bluez_output.11_22_33_44_55_66.1
  write_routing_state
  reconcile_speaker_routing "$mac"
  assert_eq bluez_output.AA_BB_CC_DD_EE_FF.1 "$default_sink"
  assert_eq 83 "$stream_driver"
  assert_eq 89 "$stream_target"
  assert_file_contains "$ROUTING_STATE_FILE" $'speaker\tAA:BB:CC:DD:EE:FF'
  assert_file_not_contains "$ROUTING_STATE_FILE" $'speaker\t11:22:33:44:55:66'
  assert_file_contains "$ROUTING_STATE_FILE" $'default\tbluez_output.AA_BB_CC_DD_EE_FF.1'
  assert_file_contains "$ROUTING_STATE_FILE" \
    $'instance\t01234567-89ab-cdef-0123-456789abcdef:4321:987654'
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t138\t89'

  clear_owned_routing "$user"
  [[ ! -e $ROUTING_STATE_FILE ]] || fail 'cleared routing provenance remained'
  [[ -z $default_sink && -z $stream_target ]] || fail 'owned routing overrides survived cleanup'
  assert_file_contains "$TEST_SCRATCH/routing.log" 'clear-default 0'
  assert_file_contains "$TEST_SCRATCH/routing.log" 'clear-target 95'

  default_sink=alsa_output.user-choice
  stream_target=77
  cleanup_log=$(< "$TEST_SCRATCH/routing.log")
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  ROUTING_DEFAULT_SPEAKER=$mac
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  ROUTING_STREAM_SPEAKERS=([138]=$mac)
  write_routing_state
  clear_owned_routing "$user"
  assert_eq alsa_output.user-choice "$default_sink"
  assert_eq 77 "$stream_target"
  assert_eq "$cleanup_log" "$(< "$TEST_SCRATCH/routing.log")"
  [[ ! -e $ROUTING_STATE_FILE ]] || fail 'stale routing provenance was not discarded'

  stream_serial=999
  stream_target=89
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  ROUTING_STREAM_SPEAKERS=([138]=$mac)
  write_routing_state
  bounded_user_pw_cli() { mock_pipewire_nodes_for_routing; }
  clear_owned_routing "$user"
  assert_eq 89 "$stream_target"
  assert_eq "$cleanup_log" "$(< "$TEST_SCRATCH/routing.log")"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'recycled stream ID retained stale routing provenance'
  stream_serial=138

  stream_target=89
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  ROUTING_STREAM_SPEAKERS=([138]=$mac)
  write_routing_state
  inspect_stream_fails=1
  if clear_owned_routing "$user"; then
    fail 'stream inspection failure reported complete routing cleanup'
  fi
  assert_eq 89 "$stream_target"
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t138\t89'
  inspect_stream_fails=0
  clear_owned_routing "$user"
  [[ -z $stream_target && ! -e $ROUTING_STATE_FILE ]] || \
    fail 'routing cleanup retry did not clear retained stream provenance'

  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([999]=89)
  ROUTING_STREAM_SPEAKERS=([999]=$mac)
  write_routing_state
  bounded_user_pw_cli() { :; }
  clear_owned_routing "$user"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'provenance for an exited playback stream remained after cleanup'

  printf 'sentinel\n' > "$TEST_SCRATCH/redirected-routing-state"
  ln -s "$TEST_SCRATCH/redirected-routing-state" "$ROUTING_STATE_FILE"
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  ROUTING_DEFAULT_SPEAKER=$mac
  if write_routing_state; then fail 'routing state followed a symlink'; fi
  assert_eq sentinel "$(< "$TEST_SCRATCH/redirected-routing-state")"
}

test_default_failure_still_routes_streams() {
  local user mac=AA:BB:CC:DD:EE:FF stream_target=77 stream_driver=35 clock=100
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  routing_now_seconds() { printf '%s\n' "$clock"; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() {
    assert_eq 1 "$2" || return 1
    printf 'alsa_output.builtin\n'
  }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    if [[ $2 == 83 ]]; then
      PIPEWIRE_NODE_SERIAL=89
      PIPEWIRE_NODE_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
      PIPEWIRE_NODE_CLASS=Audio/Sink
      PIPEWIRE_NODE_DRIVER=
    else
      PIPEWIRE_NODE_SERIAL=138
      PIPEWIRE_NODE_NAME='Long-lived Player'
      PIPEWIRE_NODE_CLASS=Stream/Output/Audio
      PIPEWIRE_NODE_DRIVER=$stream_driver
    fi
  }
  bounded_user_wpctl() {
    [[ $3 == set-default ]] || return 1
    assert_eq 1 "$2" || return 1
    clock=101
    return 1
  }
  stream_target_serial() { printf '%s\n' "$stream_target"; }
  bounded_user_pw_metadata() {
    [[ $* == *'95 target.object 89 Spa:Id'* ]] || return 1
    stream_target=89
    stream_driver=83
  }

  if reconcile_speaker_routing "$mac"; then
    fail 'failed default selection reported complete routing success'
  fi
  assert_eq 89 "$stream_target"
  assert_eq 83 "$stream_driver"
  assert_file_contains "$ROUTING_STATE_FILE" \
    $'default-pending\tbluez_output.AA_BB_CC_DD_EE_FF.1'
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t138\t89'
}

test_routing_cleanup_is_scoped_per_speaker() {
  local user speaker_a=AA:BB:CC:DD:EE:FF speaker_b=11:22:33:44:55:66
  local default_sink=bluez_output.11_22_33_44_55_66.1 stream_target=89
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  ROUTING_STATE_USER=$user
  ROUTING_STATE_SPEAKERS=()
  ROUTING_DEFAULT_NAME=$default_sink
  ROUTING_DEFAULT_SPEAKER=$speaker_b
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  ROUTING_STREAM_SPEAKERS=([138]=$speaker_a)
  write_routing_state
  configured_default_sink() { printf '%s\n' "$default_sink"; }
  bounded_user_wpctl() { fail 'speaker A cleanup cleared speaker B default'; }
  pipewire_instance_id() {
    printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'
  }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    PIPEWIRE_NODE_SERIAL=138
    PIPEWIRE_NODE_NAME='Long-lived Player'
    PIPEWIRE_NODE_CLASS=Stream/Output/Audio
    PIPEWIRE_NODE_DRIVER=83
  }
  stream_target_serial() { printf '%s\n' "$stream_target"; }
  bounded_user_pw_metadata() {
    stream_target=
    printf 'clear-target 95\n' >> "$TEST_SCRATCH/routing.log"
  }

  clear_owned_routing "$user" "$speaker_a"
  assert_eq bluez_output.11_22_33_44_55_66.1 "$default_sink"
  assert_eq '' "$stream_target"
  assert_file_contains "$ROUTING_STATE_FILE" \
    $'default\tbluez_output.11_22_33_44_55_66.1\t11:22:33:44:55:66'
  assert_file_not_contains "$ROUTING_STATE_FILE" $'speaker\tAA:BB:CC:DD:EE:FF'
  assert_file_not_contains "$ROUTING_STATE_FILE" $'stream\t138\t89'
  assert_file_contains "$TEST_SCRATCH/routing.log" 'clear-target 95'
}

test_routing_write_failure_prevents_mutation() {
  local user mac=AA:BB:CC:DD:EE:FF output rc
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  now_seconds() { printf '100\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'alsa_output.builtin\n'; }
  bounded_user_wpctl() {
    if [[ $3 == inspect ]]; then
      printf '%s\n' '  * object.serial = "89"' \
        '  * node.name = "bluez_output.AA_BB_CC_DD_EE_FF.1"' \
        '  * media.class = "Audio/Sink"'
    else
      : > "$TEST_SCRATCH/routing-mutated"
    fi
  }
  chmod() {
    if [[ ${1:-} == 0600 && ${2:-} == "$STATE_DIR"/.routing-overrides.* ]]; then
      return 1
    fi
    /usr/bin/chmod "$@"
  }

  set +e
  output=$(reconcile_speaker_routing "$mac" 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'routing succeeded after its provenance write failed'
  assert_eq '' "$output"
  [[ ! -e $TEST_SCRATCH/routing-mutated ]] || \
    fail 'routing metadata changed after its provenance write failed'
  [[ -z $(find "$STATE_DIR" -maxdepth 1 -name '.routing-overrides.*' -print -quit) ]] || \
    fail 'failed routing-state write retained its temporary file'

  printf 'user\t%s\ndefault\tbluez_output.AA_BB_CC_DD_EE_FF.1\n' \
    "$user" > "$ROUTING_STATE_FILE"
  ROUTING_DEFAULT_NAME=
  rm() {
    if [[ ${*: -1} == "$ROUTING_STATE_FILE" ]]; then return 1; fi
    command rm "$@"
  }
  if write_routing_state; then
    fail 'routing state reported success after its removal failed'
  fi
  [[ -e $ROUTING_STATE_FILE ]] || fail 'routing removal-failure fixture disappeared'
}

test_unchanged_routing_state_is_not_replaced() {
  local user original_inode current_inode
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  write_routing_state
  original_inode=$(stat -c %i -- "$ROUTING_STATE_FILE")

  write_routing_state
  current_inode=$(stat -c %i -- "$ROUTING_STATE_FILE")
  assert_eq "$original_inode" "$current_inode"

  chmod 0644 "$ROUTING_STATE_FILE"
  write_routing_state
  assert_eq 600 "$(stat -c %a -- "$ROUTING_STATE_FILE")"
  current_inode=$(stat -c %i -- "$ROUTING_STATE_FILE")
  [[ $current_inode != "$original_inode" ]] || \
    fail 'routing-state metadata repair did not replace the file'
}

test_routing_cleanup_checkpoints_deadline_progress() {
  local user clock=100 deleted_id deleted_serial remaining_serial
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  routing_now_seconds() { printf '%s\n' "$clock"; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() { printf '%s\n' '95 138' '96 139'; }
  inspect_pipewire_node() {
    PIPEWIRE_NODE_SERIAL=$([[ $2 == 95 ]] && printf 138 || printf 139)
    PIPEWIRE_NODE_NAME='Long-lived Player'
    PIPEWIRE_NODE_CLASS=Stream/Output/Audio
    PIPEWIRE_NODE_DRIVER=83
  }
  stream_target_serial() { printf '89\n'; }
  bounded_user_pw_metadata() {
    deleted_id=$6
    printf '%s\n' "$deleted_id" > "$TEST_SCRATCH/deleted-stream-id"
    clock=$((clock + ROUTING_TIMEOUT))
  }
  ROUTING_STATE_USER=$user
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89 [139]=89)
  write_routing_state

  if clear_owned_routing "$user"; then
    fail 'deadline-exhausted routing cleanup reported success'
  fi
  deleted_id=$(< "$TEST_SCRATCH/deleted-stream-id")
  if [[ $deleted_id == 95 ]]; then
    deleted_serial=138
    remaining_serial=139
  else
    deleted_serial=139
    remaining_serial=138
  fi
  assert_file_not_contains "$ROUTING_STATE_FILE" $'stream\t'"$deleted_serial"$'\t89'
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t'"$remaining_serial"$'\t89'
}

test_routing_cleanup_rotates_after_deadline() {
  local user clock=100 first_id second_id
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  routing_now_seconds() { printf '%s\n' "$clock"; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() { printf '%s\n' '95 138' '96 139'; }
  inspect_pipewire_node() {
    printf '%s\n' "$2" >> "$TEST_SCRATCH/cleanup-streams"
    clock=$((clock + ROUTING_TIMEOUT))
    return 1
  }
  ROUTING_STATE_USER=$user
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89 [139]=89)
  write_routing_state

  if clear_owned_routing "$user"; then
    fail 'deadline-exhausted cleanup reported success'
  fi
  clock=200
  if clear_owned_routing "$user"; then
    fail 'second deadline-exhausted cleanup reported success'
  fi
  first_id=$(sed -n '1p' "$TEST_SCRATCH/cleanup-streams")
  second_id=$(sed -n '2p' "$TEST_SCRATCH/cleanup-streams")
  [[ -n $first_id && -n $second_id && $first_id != "$second_id" ]] || \
    fail 'routing cleanup retried the same blocking stream first'
}

test_pipewire_restart_during_target_cleanup() {
  local user instance_queries
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  printf '0\n' > "$TEST_SCRATCH/cleanup-instance-queries"
  routing_now_seconds() { printf '100\n'; }
  pipewire_instance_id() {
    instance_queries=$(< "$TEST_SCRATCH/cleanup-instance-queries")
    instance_queries=$((instance_queries + 1))
    printf '%s\n' "$instance_queries" > "$TEST_SCRATCH/cleanup-instance-queries"
    if (( instance_queries == 1 )); then
      printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'
    else
      printf 'fedcba98-7654-3210-fedc-ba9876543210:1234:567890\n'
    fi
  }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    PIPEWIRE_NODE_SERIAL=138
    PIPEWIRE_NODE_NAME='Long-lived Player'
    PIPEWIRE_NODE_CLASS=Stream/Output/Audio
    PIPEWIRE_NODE_DRIVER=83
  }
  stream_target_serial() { printf '89\n'; }
  bounded_user_pw_metadata() { : > "$TEST_SCRATCH/restarted-cleanup-deleted"; }
  ROUTING_STATE_USER=$user
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  write_routing_state

  clear_owned_routing "$user"
  [[ ! -e $TEST_SCRATCH/restarted-cleanup-deleted ]] || \
    fail 'cleanup deleted a target after PipeWire restarted'
  assert_eq 2 "$(< "$TEST_SCRATCH/cleanup-instance-queries")"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'cleanup retained stream provenance from the prior PipeWire instance'
}

test_reconciliation_checkpoints_retired_stream() {
  local user mac=AA:BB:CC:DD:EE:FF
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  routing_now_seconds() { printf '100\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() { printf '%s\n' '95 138' '96 139'; }
  inspect_pipewire_node() {
    if [[ $2 == 83 ]]; then
      PIPEWIRE_NODE_SERIAL=89
      PIPEWIRE_NODE_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
      PIPEWIRE_NODE_CLASS=Audio/Sink
      PIPEWIRE_NODE_DRIVER=
    else
      PIPEWIRE_NODE_SERIAL=$([[ $2 == 95 ]] && printf 138 || printf 139)
      PIPEWIRE_NODE_NAME='Long-lived Player'
      PIPEWIRE_NODE_CLASS=Stream/Output/Audio
      PIPEWIRE_NODE_DRIVER=83
      if [[ $2 == 96 ]]; then
        daemon_signal
        return 1
      fi
    fi
  }
  stream_target_serial() { return 2; }
  ROUTING_STATE_USER=$user
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  write_routing_state

  if reconcile_speaker_routing "$mac"; then
    fail 'stop-requested stream retirement reported routing success'
  fi
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'stop request after stream retirement retained stale provenance'
  assert_eq 1 "$DAEMON_STOP_REQUESTED"
  assert_eq 0 "$ROUTING_MUTATION_CRITICAL"
}

test_default_cleanup_revalidates_and_retires_missing_user() {
  local user mac=AA:BB:CC:DD:EE:FF
  local missing_user=a2dpilot-user-that-does-not-exist queries
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  ROUTING_DEFAULT_SPEAKER=$mac
  write_routing_state
  printf '0\n' > "$TEST_SCRATCH/default-queries"
  configured_default_sink() {
    queries=$(< "$TEST_SCRATCH/default-queries")
    queries=$((queries + 1))
    printf '%s\n' "$queries" > "$TEST_SCRATCH/default-queries"
    if (( queries == 1 )); then
      printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'
    else
      printf 'alsa_output.user-choice\n'
    fi
  }
  bounded_user_wpctl() { : > "$TEST_SCRATCH/new-default-cleared"; }

  clear_owned_routing "$user"
  [[ ! -e $TEST_SCRATCH/new-default-cleared ]] || \
    fail 'cleanup cleared a default that changed after ownership validation'
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'changed default retained stale routing provenance'

  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  ROUTING_DEFAULT_SPEAKER=$mac
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  ROUTING_STREAM_SPEAKERS=([138]=$mac)
  write_routing_state
  configured_default_sink() { printf 'alsa_output.user-choice\n'; }
  pipewire_instance_id() {
    assert_file_not_contains "$ROUTING_STATE_FILE" \
      $'default\tbluez_output.AA_BB_CC_DD_EE_FF.1' || return 1
    return 1
  }
  if clear_owned_routing "$user"; then
    fail 'failed stream discovery reported complete routing cleanup'
  fi
  assert_file_not_contains "$ROUTING_STATE_FILE" \
    $'default\tbluez_output.AA_BB_CC_DD_EE_FF.1'
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t138\t89'

  ROUTING_STATE_USER=$missing_user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  ROUTING_DEFAULT_SPEAKER=$mac
  ROUTING_PIPEWIRE_INSTANCE=
  ROUTING_STREAM_TARGETS=()
  ROUTING_STREAM_SPEAKERS=()
  write_routing_state
  configured_default_sink() { fail 'missing-user cleanup queried PipeWire'; }
  clear_owned_routing "$missing_user"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'missing audio user retained unusable routing provenance'

  ROUTING_STATE_USER=$missing_user
  ROUTING_STATE_SPEAKERS=([AA:BB:CC:DD:EE:FF]=1)
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  ROUTING_DEFAULT_SPEAKER=$mac
  write_routing_state
  rm() {
    if [[ ${*: -1} == "$ROUTING_STATE_FILE" ]]; then return 1; fi
    command rm "$@"
  }
  if clear_owned_routing "$missing_user"; then
    fail 'missing-user cleanup masked routing-state removal failure'
  fi
}

test_recycled_sink_is_not_defaulted() {
  local user mac=AA:BB:CC:DD:EE:FF inspections=0
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'alsa_output.builtin\n'; }
  inspect_pipewire_node() {
    inspections=$((inspections + 1))
    PIPEWIRE_NODE_CLASS=Audio/Sink
    PIPEWIRE_NODE_DRIVER=
    if (( inspections == 1 )); then
      PIPEWIRE_NODE_SERIAL=89
      PIPEWIRE_NODE_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
    else
      PIPEWIRE_NODE_SERIAL=90
      PIPEWIRE_NODE_NAME=bluez_output.11_22_33_44_55_66.1
    fi
  }
  bounded_user_wpctl() { : > "$TEST_SCRATCH/recycled-sink-defaulted"; }

  if reconcile_speaker_routing "$mac"; then
    fail 'recycled sink identity reported routing success'
  fi
  [[ ! -e $TEST_SCRATCH/recycled-sink-defaulted ]] || \
    fail 'a recycled PipeWire sink ID became the configured default'
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'recycled sink retained pending routing ownership'
}

test_recycled_sink_is_not_targeted() {
  local user mac=AA:BB:CC:DD:EE:FF sink_inspections=0
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  routing_now_seconds() { printf '100\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    if [[ $2 == 83 ]]; then
      sink_inspections=$((sink_inspections + 1))
      PIPEWIRE_NODE_CLASS=Audio/Sink
      PIPEWIRE_NODE_DRIVER=
      if (( sink_inspections == 1 )); then
        PIPEWIRE_NODE_SERIAL=89
        PIPEWIRE_NODE_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
      else
        PIPEWIRE_NODE_SERIAL=90
        PIPEWIRE_NODE_NAME=bluez_output.11_22_33_44_55_66.1
      fi
    else
      PIPEWIRE_NODE_SERIAL=138
      PIPEWIRE_NODE_NAME='Long-lived Player'
      PIPEWIRE_NODE_CLASS=Stream/Output/Audio
      PIPEWIRE_NODE_DRIVER=35
    fi
  }
  stream_target_serial() { return 2; }
  bounded_user_pw_metadata() { : > "$TEST_SCRATCH/recycled-sink-targeted"; }

  if reconcile_speaker_routing "$mac"; then
    fail 'recycled sink identity reported stream-routing success'
  fi
  [[ ! -e $TEST_SCRATCH/recycled-sink-targeted ]] || \
    fail 'a recycled PipeWire sink ID received a stream target'
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'recycled sink retained pending stream ownership'
}

test_pipewire_restart_during_target_assignment() {
  local user mac=AA:BB:CC:DD:EE:FF instance_queries
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  printf '0\n' > "$TEST_SCRATCH/instance-queries"
  routing_now_seconds() { printf '100\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'; }
  pipewire_instance_id() {
    instance_queries=$(< "$TEST_SCRATCH/instance-queries")
    instance_queries=$((instance_queries + 1))
    printf '%s\n' "$instance_queries" > "$TEST_SCRATCH/instance-queries"
    if (( instance_queries == 1 )); then
      printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'
    else
      printf 'fedcba98-7654-3210-fedc-ba9876543210:1234:567890\n'
    fi
  }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    if [[ $2 == 83 ]]; then
      PIPEWIRE_NODE_SERIAL=89
      PIPEWIRE_NODE_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
      PIPEWIRE_NODE_CLASS=Audio/Sink
      PIPEWIRE_NODE_DRIVER=
    else
      PIPEWIRE_NODE_SERIAL=138
      PIPEWIRE_NODE_NAME='Long-lived Player'
      PIPEWIRE_NODE_CLASS=Stream/Output/Audio
      PIPEWIRE_NODE_DRIVER=35
    fi
  }
  stream_target_serial() { return 2; }
  bounded_user_pw_metadata() { : > "$TEST_SCRATCH/restarted-instance-targeted"; }
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  write_routing_state

  if reconcile_speaker_routing "$mac"; then
    fail 'mid-assignment PipeWire restart reported routing success'
  fi
  [[ ! -e $TEST_SCRATCH/restarted-instance-targeted ]] || \
    fail 'a stream target was written after PipeWire restarted'
  assert_file_contains "$ROUTING_STATE_FILE" \
    $'default\tbluez_output.AA_BB_CC_DD_EE_FF.1'
  assert_file_contains "$ROUTING_STATE_FILE" $'speaker\tAA:BB:CC:DD:EE:FF'
  assert_file_not_contains "$ROUTING_STATE_FILE" $'instance\t'
  assert_file_not_contains "$ROUTING_STATE_FILE" $'stream\t'
}

test_stale_owned_target_is_rewritten_after_relink() {
  local user mac=AA:BB:CC:DD:EE:FF stream_target=77
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  routing_now_seconds() { printf '100\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    if [[ $2 == 83 ]]; then
      PIPEWIRE_NODE_SERIAL=89
      PIPEWIRE_NODE_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
      PIPEWIRE_NODE_CLASS=Audio/Sink
      PIPEWIRE_NODE_DRIVER=
    else
      PIPEWIRE_NODE_SERIAL=138
      PIPEWIRE_NODE_NAME='Long-lived Player'
      PIPEWIRE_NODE_CLASS=Stream/Output/Audio
      PIPEWIRE_NODE_DRIVER=83
    fi
  }
  stream_target_serial() { printf '%s\n' "$stream_target"; }
  bounded_user_pw_metadata() {
    [[ $* == *'95 target.object 89 Spa:Id'* ]] || return 1
    stream_target=89
  }
  ROUTING_STATE_USER=$user
  ROUTING_STATE_SPEAKERS=([11:22:33:44:55:66]=1)
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=77)
  write_routing_state

  reconcile_speaker_routing "$mac"
  assert_eq 89 "$stream_target"
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t138\t89'
  assert_file_not_contains "$ROUTING_STATE_FILE" $'stream\t138\t77'
}

test_recycled_stream_is_not_cleared() {
  local user inspections target_queries
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  printf '0\n' > "$TEST_SCRATCH/stream-inspections"
  printf '0\n' > "$TEST_SCRATCH/target-queries"
  routing_now_seconds() { printf '100\n'; }
  configured_default_sink() { return 2; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    inspections=$(< "$TEST_SCRATCH/stream-inspections")
    inspections=$((inspections + 1))
    printf '%s\n' "$inspections" > "$TEST_SCRATCH/stream-inspections"
    PIPEWIRE_NODE_CLASS=Stream/Output/Audio
    PIPEWIRE_NODE_SERIAL=$((137 + inspections))
    PIPEWIRE_NODE_NAME='Reused Player ID'
    PIPEWIRE_NODE_DRIVER=83
  }
  stream_target_serial() {
    target_queries=$(< "$TEST_SCRATCH/target-queries")
    target_queries=$((target_queries + 1))
    printf '%s\n' "$target_queries" > "$TEST_SCRATCH/target-queries"
    printf '89\n'
  }
  bounded_user_pw_metadata() { : > "$TEST_SCRATCH/recycled-stream-cleared"; }
  ROUTING_STATE_USER=$user
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  write_routing_state

  clear_owned_routing "$user"
  [[ ! -e $TEST_SCRATCH/recycled-stream-cleared ]] || \
    fail 'a recycled PipeWire stream ID had its target cleared'
  target_queries=$(< "$TEST_SCRATCH/target-queries")
  assert_eq 1 "$target_queries"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'recycled stream retained stale routing provenance'
}

test_changed_stream_target_is_not_cleared() {
  local user target_queries instance_queries
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  printf '0\n' > "$TEST_SCRATCH/target-queries"
  printf '0\n' > "$TEST_SCRATCH/instance-queries"
  printf '89\n' > "$TEST_SCRATCH/stream-target"
  routing_now_seconds() { printf '100\n'; }
  configured_default_sink() { return 2; }
  pipewire_instance_id() {
    instance_queries=$(< "$TEST_SCRATCH/instance-queries")
    instance_queries=$((instance_queries + 1))
    printf '%s\n' "$instance_queries" > "$TEST_SCRATCH/instance-queries"
    if (( instance_queries == 2 )); then printf '77\n' > "$TEST_SCRATCH/stream-target"; fi
    printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'
  }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    PIPEWIRE_NODE_CLASS=Stream/Output/Audio
    PIPEWIRE_NODE_SERIAL=138
    PIPEWIRE_NODE_NAME='Long-lived Player'
    PIPEWIRE_NODE_DRIVER=83
  }
  stream_target_serial() {
    target_queries=$(< "$TEST_SCRATCH/target-queries")
    target_queries=$((target_queries + 1))
    printf '%s\n' "$target_queries" > "$TEST_SCRATCH/target-queries"
    command cat "$TEST_SCRATCH/stream-target"
  }
  bounded_user_pw_metadata() { : > "$TEST_SCRATCH/changed-target-cleared"; }
  ROUTING_STATE_USER=$user
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  write_routing_state

  clear_owned_routing "$user"
  [[ ! -e $TEST_SCRATCH/changed-target-cleared ]] || \
    fail 'an independently changed stream target was cleared'
  target_queries=$(< "$TEST_SCRATCH/target-queries")
  assert_eq 3 "$target_queries"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'independently changed stream retained stale routing provenance'
}

test_linked_stream_target_lookup_failure_is_reported() {
  local user mac=AA:BB:CC:DD:EE:FF
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  routing_now_seconds() { printf '100\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'; }
  pipewire_instance_id() {
    printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'
  }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    if [[ $2 == 83 ]]; then
      PIPEWIRE_NODE_SERIAL=89
      PIPEWIRE_NODE_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
      PIPEWIRE_NODE_CLASS=Audio/Sink
      PIPEWIRE_NODE_DRIVER=
    else
      PIPEWIRE_NODE_SERIAL=138
      PIPEWIRE_NODE_NAME='Linked Player'
      PIPEWIRE_NODE_CLASS=Stream/Output/Audio
      PIPEWIRE_NODE_DRIVER=83
    fi
  }
  stream_target_serial() { return 1; }
  bounded_user_pw_metadata() { fail 'lookup failure rewrote stream routing'; }
  ROUTING_STATE_USER=$user
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  ROUTING_STREAM_SPEAKERS=([138]=$mac)
  write_routing_state

  if reconcile_speaker_routing "$mac"; then
    fail 'stream target lookup failure reported routing success'
  fi
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t138\t89\tAA:BB:CC:DD:EE:FF'
}

test_interrupted_routing_transition_preserves_prior_owner() {
  local user mac=AA:BB:CC:DD:EE:FF sink_name=bluez_output.AA_BB_CC_DD_EE_FF.1
  local prior_mac=11:22:33:44:55:66
  local default_sink=bluez_output.11_22_33_44_55_66.1 stream_target=77 stream_driver=35
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  now_seconds() { printf '100\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  configured_default_sink() {
    [[ -n $default_sink ]] || return 2
    printf '%s\n' "$default_sink"
  }
  inspect_pipewire_node() {
    case $2 in
      83)
        PIPEWIRE_NODE_SERIAL=89
        PIPEWIRE_NODE_NAME=$sink_name
        PIPEWIRE_NODE_CLASS=Audio/Sink
        PIPEWIRE_NODE_DRIVER=
        ;;
      95)
        PIPEWIRE_NODE_SERIAL=138
        PIPEWIRE_NODE_NAME='Long-lived Player'
        PIPEWIRE_NODE_CLASS=Stream/Output/Audio
        PIPEWIRE_NODE_DRIVER=$stream_driver
        ;;
      *) return 1 ;;
    esac
  }
  bounded_user_wpctl() {
    case $3 in
      set-default) return 1 ;;
      clear-default) default_sink= ;;
    esac
  }
  enumerate_playback_streams() { printf '95 138\n'; }
  stream_target_serial() {
    [[ -n $stream_target ]] || return 2
    printf '%s\n' "$stream_target"
  }
  bounded_user_pw_metadata() {
    if [[ $* == *'-d -n default 95 target.object'* ]]; then
      stream_target=
    else
      return 1
    fi
  }

  ROUTING_STATE_USER=$user
  ROUTING_STATE_SPEAKERS=()
  ROUTING_STATE_SPEAKERS["$prior_mac"]=1
  ROUTING_DEFAULT_NAME=$default_sink
  write_routing_state
  if reconcile_speaker_routing "$mac"; then
    fail 'failed default transition reported routing success'
  fi
  assert_file_contains "$ROUTING_STATE_FILE" $'speaker\t11:22:33:44:55:66'
  assert_file_contains "$ROUTING_STATE_FILE" $'speaker\tAA:BB:CC:DD:EE:FF'
  assert_file_contains "$ROUTING_STATE_FILE" $'default\tbluez_output.11_22_33_44_55_66.1'
  assert_file_contains "$ROUTING_STATE_FILE" \
    $'default-pending\tbluez_output.AA_BB_CC_DD_EE_FF.1'
  clear_owned_routing "$user"
  [[ -z $default_sink && ! -e $ROUTING_STATE_FILE ]] || \
    fail 'cleanup lost the prior default owner after an interrupted transition'

  default_sink=$sink_name
  stream_target=77
  ROUTING_STATE_USER=$user
  ROUTING_STATE_SPEAKERS=([AA:BB:CC:DD:EE:FF]=1)
  ROUTING_DEFAULT_NAME=$sink_name
  ROUTING_PENDING_DEFAULT_NAME=
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=77)
  ROUTING_PENDING_STREAM_TARGETS=()
  write_routing_state
  if reconcile_speaker_routing "$mac"; then
    fail 'failed stream transition reported routing success'
  fi
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t138\t77'
  assert_file_contains "$ROUTING_STATE_FILE" $'stream-pending\t138\t89'
  clear_owned_routing "$user"
  [[ -z $default_sink && -z $stream_target && ! -e $ROUTING_STATE_FILE ]] || \
    fail 'cleanup lost the prior stream owner after an interrupted transition'
}

test_routing_rotates_after_deadline() {
  local user mac=AA:BB:CC:DD:EE:FF clock=100
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  now_seconds() { printf '%s\n' "$clock"; }
  routing_now_seconds() { printf '%s\n' "$clock"; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() {
    printf '%s\n' '95 138' '96 139' '97 140' '98 141'
  }
  inspect_pipewire_node() {
    if [[ $2 == 83 ]]; then
      PIPEWIRE_NODE_SERIAL=89
      PIPEWIRE_NODE_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
      PIPEWIRE_NODE_CLASS=Audio/Sink
      PIPEWIRE_NODE_DRIVER=
      return 0
    fi
    printf '%s\n' "$2" >> "$TEST_SCRATCH/rotated-streams"
    clock=$((clock + ROUTING_TIMEOUT))
    return 1
  }

  reconcile_speaker_routing "$mac" || true
  reconcile_speaker_routing "$mac" || true
  reconcile_speaker_routing "$mac" || true
  reconcile_speaker_routing "$mac" || true
  assert_eq 1 "$(grep -Fc 95 "$TEST_SCRATCH/rotated-streams")"
  assert_eq 1 "$(grep -Fc 96 "$TEST_SCRATCH/rotated-streams")"
  assert_eq 1 "$(grep -Fc 97 "$TEST_SCRATCH/rotated-streams")"
  assert_eq 1 "$(grep -Fc 98 "$TEST_SCRATCH/rotated-streams")"
}

test_invalid_initial_config_clears_recorded_routing() {
  local user
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  write_routing_state
  clear_owned_routing() {
    printf '%s\n' "$1" > "$TEST_SCRATCH/cleared-routing-user"
    rm -f -- "$ROUTING_STATE_FILE"
  }

  clear_daemon_routing_from_state
  assert_eq "$user" "$(< "$TEST_SCRATCH/cleared-routing-user")"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'invalid initial configuration retained recorded routing ownership'
}

test_daemon_signal_defers_during_routing_mutation() {
  local user mac=AA:BB:CC:DD:EE:FF default_sink=alsa_output.builtin
  local sink_name=bluez_output.AA_BB_CC_DD_EE_FF.1
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  DAEMON_STOP_REQUESTED=0
  now_seconds() { printf '100\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  inspect_pipewire_node() {
    PIPEWIRE_NODE_SERIAL=89
    PIPEWIRE_NODE_NAME=$sink_name
    PIPEWIRE_NODE_CLASS=Audio/Sink
    PIPEWIRE_NODE_DRIVER=
  }
  configured_default_sink() { printf '%s\n' "$default_sink"; }
  bounded_user_wpctl() {
    [[ $ROUTING_MUTATION_CRITICAL == 1 ]] || \
      fail 'routing mutation command ran outside its critical section'
    default_sink=$sink_name
    daemon_signal
  }

  if reconcile_speaker_routing "$mac"; then
    fail 'stop-requested routing reconciliation reported success'
  fi
  assert_eq 1 "$DAEMON_STOP_REQUESTED"
  assert_eq 0 "$ROUTING_MUTATION_CRITICAL"
  assert_file_contains "$ROUTING_STATE_FILE" $'default\tbluez_output.AA_BB_CC_DD_EE_FF.1'
  assert_file_not_contains "$ROUTING_STATE_FILE" 'default-pending'

  DAEMON_STOP_REQUESTED=0
  bounded_user_wpctl() {
    [[ $ROUTING_MUTATION_CRITICAL == 1 ]] || \
      fail 'default cleanup ran outside its critical section'
    default_sink=
    daemon_signal
  }
  if clear_owned_routing "$user"; then
    fail 'stop-requested default cleanup reported success'
  fi
  assert_eq 1 "$DAEMON_STOP_REQUESTED"
  assert_eq 0 "$ROUTING_MUTATION_CRITICAL"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'interrupted default cleanup retained stale provenance'

  DAEMON_STOP_REQUESTED=0
  ROUTING_STATE_USER=$user
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  ROUTING_STREAM_SPEAKERS=([138]=$mac)
  write_routing_state
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    PIPEWIRE_NODE_SERIAL=138
    PIPEWIRE_NODE_NAME='Long-lived Player'
    PIPEWIRE_NODE_CLASS=Stream/Output/Audio
    PIPEWIRE_NODE_DRIVER=83
  }
  stream_target_serial() { printf '89\n'; }
  bounded_user_pw_metadata() {
    [[ $ROUTING_MUTATION_CRITICAL == 1 ]] || \
      fail 'stream cleanup ran outside its critical section'
    daemon_signal
  }
  if clear_owned_routing "$user"; then
    fail 'stop-requested stream cleanup reported success'
  fi
  assert_eq 1 "$DAEMON_STOP_REQUESTED"
  assert_eq 0 "$ROUTING_MUTATION_CRITICAL"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'interrupted stream cleanup retained stale provenance'
}

test_cli_signal_defers_during_routing_cleanup() {
  local user result mac=AA:BB:CC:DD:EE:FF default_sink=alsa_output.builtin
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=$default_sink
  ROUTING_DEFAULT_SPEAKER=$mac
  write_routing_state
  configured_default_sink() { printf '%s\n' "$default_sink"; }
  bounded_user_wpctl() {
    [[ $ROUTING_MUTATION_CRITICAL == 1 ]] || \
      fail 'CLI default cleanup ran outside its critical section'
    default_sink=
    kill -TERM "$BASHPID"
  }

  if clear_owned_routing "$user"; then
    fail 'signaled CLI default cleanup reported success'
  else
    result=$?
  fi
  assert_eq 143 "$result"
  assert_eq 0 "$ROUTING_MUTATION_CRITICAL"
  [[ -z $(trap -p HUP) && -z $(trap -p INT) && -z $(trap -p TERM) ]] || \
    fail 'CLI cleanup retained its temporary signal traps'
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'signaled CLI default cleanup retained stale provenance'

  DAEMON_STOP_REQUESTED=0
  ROUTING_STATE_USER=$user
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  ROUTING_STREAM_SPEAKERS=([138]=$mac)
  write_routing_state
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  enumerate_playback_streams() { printf '95 138\n'; }
  inspect_pipewire_node() {
    PIPEWIRE_NODE_SERIAL=138
    PIPEWIRE_NODE_NAME='Long-lived Player'
    PIPEWIRE_NODE_CLASS=Stream/Output/Audio
    PIPEWIRE_NODE_DRIVER=83
  }
  stream_target_serial() { printf '89\n'; }
  bounded_user_pw_metadata() {
    [[ $ROUTING_MUTATION_CRITICAL == 1 ]] || \
      fail 'CLI stream cleanup ran outside its critical section'
    kill -INT "$BASHPID"
  }

  if clear_owned_routing "$user"; then
    fail 'signaled CLI stream cleanup reported success'
  else
    result=$?
  fi
  assert_eq 130 "$result"
  assert_eq 0 "$ROUTING_MUTATION_CRITICAL"
  [[ -z $(trap -p HUP) && -z $(trap -p INT) && -z $(trap -p TERM) ]] || \
    fail 'CLI cleanup retained its temporary signal traps'
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'signaled CLI stream cleanup retained stale provenance'

  DAEMON_STOP_REQUESTED=0
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=alsa_output.builtin
  ROUTING_DEFAULT_SPEAKER=$mac
  ROUTING_PIPEWIRE_INSTANCE=
  ROUTING_STREAM_TARGETS=()
  write_routing_state
  default_sink=alsa_output.builtin
  configured_default_sink() { printf '%s\n' "$default_sink"; }
  bounded_user_wpctl() {
    default_sink=
    kill -HUP "$BASHPID"
  }
  if clear_owned_routing "$user"; then
    fail 'HUP-signaled CLI cleanup reported success'
  else
    result=$?
  fi
  assert_eq 129 "$result"
  [[ -z $(trap -p HUP) && -z $(trap -p INT) && -z $(trap -p TERM) ]] || \
    fail 'HUP-signaled cleanup retained its temporary signal traps'
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'HUP-signaled cleanup retained stale provenance'
}

test_runtime_reconciliation_failure_clears_routing() {
  setup_scratch_dir
  load_app
  configure_scratch_paths
  require_root() { :; }
  prepare_media_state_directory() { :; }
  acquire_lock() { :; }
  release_lock() { : > "$TEST_SCRATCH/daemon-lock-released"; }
  parse_config() {
    CFG_RECONNECT_INTERVAL=5
    return 0
  }
  load_daemon_active() { :; }
  reconcile_runtime_configuration() { return 1; }
  daemon_log() { :; }
  clear_daemon_routing() {
    : > "$TEST_SCRATCH/runtime-failure-routing-cleared"
    DAEMON_STOP_REQUESTED=1
  }

  daemon_action
  [[ -e $TEST_SCRATCH/runtime-failure-routing-cleared ]] || \
    fail 'runtime reconciliation failure did not attempt routing cleanup'
  [[ -e $TEST_SCRATCH/daemon-lock-released ]] || \
    fail 'daemon stop request did not release the global lock'
}

test_unmovable_stream_does_not_starve_routing() {
  local user mac=AA:BB:CC:DD:EE:FF clock=100
  local first_driver=35 second_driver=35 first_target='' second_target=''
  local output rc
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  now_seconds() { printf '%s\n' "$clock"; }
  routing_now_seconds() { printf '%s\n' "$clock"; }
  sleep() { clock=$((clock + 1)); }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'; }
  bounded_user_pw_cli() {
    cat <<'EOF'
	id 95, type PipeWire:Interface:Node/3
		object.serial = "138"
		media.class = "Stream/Output/Audio"
	id 96, type PipeWire:Interface:Node/3
		object.serial = "139"
		media.class = "Stream/Output/Audio"
EOF
  }
  bounded_user_wpctl() {
    case $4 in
      83)
        printf '%s\n' '  * object.serial = "89"' \
          '  * node.name = "bluez_output.AA_BB_CC_DD_EE_FF.1"' \
          '  * media.class = "Audio/Sink"'
        ;;
      95)
        printf '%s\n' '  * object.serial = "138"' \
          '  * node.name = "Pinned Player"' \
          "    node.driver-id = \"$first_driver\"" \
          '  * media.class = "Stream/Output/Audio"'
        ;;
      96)
        [[ $second_driver != 83 ]] || : > "$TEST_SCRATCH/second-stream-routed"
        printf '%s\n' '  * object.serial = "139"' \
          '  * node.name = "Movable Player"' \
          "    node.driver-id = \"$second_driver\"" \
          '  * media.class = "Stream/Output/Audio"'
        ;;
    esac
  }
  stream_target_serial() {
    case $2 in
      95) [[ -n $first_target ]] && printf '%s\n' "$first_target" || return 2 ;;
      96) [[ -n $second_target ]] && printf '%s\n' "$second_target" || return 2 ;;
    esac
  }
  bounded_user_pw_metadata() {
    case $5 in
      95) first_target=89 ;;
      96) second_target=89; second_driver=83 ;;
    esac
    printf 'target %s\n' "$5" >> "$TEST_SCRATCH/routing-targets"
  }

  ROUTING_STATE_USER=$user
  ROUTING_STATE_SPEAKERS=([11:22:33:44:55:66]=1)
  ROUTING_DEFAULT_NAME=bluez_output.11_22_33_44_55_66.1
  write_routing_state
  set +e
  output=$(reconcile_speaker_routing "$mac" 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'an unmovable stream reported routing success'
  assert_eq '' "$output"
  assert_file_contains "$TEST_SCRATCH/routing-targets" 'target 95'
  assert_file_contains "$TEST_SCRATCH/routing-targets" 'target 96'
  [[ -e $TEST_SCRATCH/second-stream-routed ]] || \
    fail 'movable stream was not verified after the pinned stream'
  assert_file_contains "$ROUTING_STATE_FILE" $'speaker\tAA:BB:CC:DD:EE:FF'
  assert_file_not_contains "$ROUTING_STATE_FILE" $'speaker\t11:22:33:44:55:66'
}

test_vanished_stream_does_not_starve_routing() {
  local user mac=AA:BB:CC:DD:EE:FF second_driver=35 second_target='' include_vanished=1
  local output rc
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  CFG_AUDIO_USER=$user
  now_seconds() { printf '100\n'; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'; }
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  write_routing_state
  bounded_user_pw_cli() {
    if (( include_vanished )); then
      printf '%s\n' $'\tid 95, type PipeWire:Interface:Node/3' \
        $'\t\tobject.serial = "138"' \
        $'\t\tmedia.class = "Stream/Output/Audio"'
    fi
    cat <<'EOF'
	id 96, type PipeWire:Interface:Node/3
		object.serial = "139"
		media.class = "Stream/Output/Audio"
EOF
  }
  bounded_user_wpctl() {
    case $4 in
      83)
        printf '%s\n' '  * object.serial = "89"' \
          '  * node.name = "bluez_output.AA_BB_CC_DD_EE_FF.1"' \
          '  * media.class = "Audio/Sink"'
        ;;
      95) return 1 ;;
      96)
        printf '%s\n' '  * object.serial = "139"' \
          '  * node.name = "Long-lived Player"' \
          "    node.driver-id = \"$second_driver\"" \
          '  * media.class = "Stream/Output/Audio"'
        ;;
    esac
  }
  stream_target_serial() {
    [[ $2 == 96 && -n $second_target ]] || return 2
    printf '%s\n' "$second_target"
  }
  bounded_user_pw_metadata() {
    second_driver=83
    second_target=89
    printf 'target %s\n' "$5" >> "$TEST_SCRATCH/routing-targets"
  }

  set +e
  output=$(reconcile_speaker_routing "$mac" 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'vanished stream inspection reported complete routing success'
  assert_eq '' "$output"
  assert_file_contains "$TEST_SCRATCH/routing-targets" 'target 96'
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t138\t89'
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t139\t89'

  include_vanished=0
  reconcile_speaker_routing "$mac"
  assert_file_not_contains "$ROUTING_STATE_FILE" $'stream\t138\t89'
  assert_file_contains "$ROUTING_STATE_FILE" $'stream\t139\t89'
}

test_recycled_stream_is_not_targeted() {
  local user mac=AA:BB:CC:DD:EE:FF stream_inspections stream_inspections_file
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  stream_inspections_file=$TEST_SCRATCH/stream-inspections
  printf '0\n' > "$stream_inspections_file"
  CFG_AUDIO_USER=$user
  now_seconds() { printf '100\n'; }
  pipewire_instance_id() { printf '01234567-89ab-cdef-0123-456789abcdef:4321:987654\n'; }
  find_a2dp_node_id() { printf '83\n'; }
  configured_default_sink() { printf 'bluez_output.AA_BB_CC_DD_EE_FF.1\n'; }
  bounded_user_pw_cli() {
    printf '%s\n' $'\tid 95, type PipeWire:Interface:Node/3' \
      $'\t\tobject.serial = "138"' \
      $'\t\tmedia.class = "Stream/Output/Audio"'
  }
  bounded_user_wpctl() {
    case $4 in
      83)
        printf '%s\n' '  * object.serial = "89"' \
          '  * node.name = "bluez_output.AA_BB_CC_DD_EE_FF.1"' \
          '  * media.class = "Audio/Sink"'
        ;;
      95)
        stream_inspections=$(< "$stream_inspections_file")
        stream_inspections=$((stream_inspections + 1))
        printf '%s\n' "$stream_inspections" > "$stream_inspections_file"
        if (( stream_inspections == 1 )); then
          printf '%s\n' '  * object.serial = "138"' \
            '  * node.name = "Short-lived Player"' \
            '    node.driver-id = "35"' \
            '  * media.class = "Stream/Output/Audio"'
        else
          printf '%s\n' '  * object.serial = "999"' \
            '  * node.name = "Replacement Player"' \
            '    node.driver-id = "35"' \
            '  * media.class = "Stream/Output/Audio"'
        fi
        ;;
    esac
  }
  stream_target_serial() { return 2; }
  bounded_user_pw_metadata() { : > "$TEST_SCRATCH/recycled-stream-targeted"; }

  reconcile_speaker_routing "$mac"
  [[ ! -e $TEST_SCRATCH/recycled-stream-targeted ]] || \
    fail 'routing targeted a recycled stream ID'
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'recycled stream retained write-ahead routing provenance'
}

test_pipewire_restart_discards_stream_provenance() {
  local user
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  now_seconds() { printf '100\n'; }
  ROUTING_STATE_USER=$user
  ROUTING_DEFAULT_NAME=
  ROUTING_PIPEWIRE_INSTANCE=01234567-89ab-cdef-0123-456789abcdef:4321:987654
  ROUTING_STREAM_TARGETS=([138]=89)
  write_routing_state
  pipewire_instance_id() { printf 'fedcba98-7654-3210-fedc-ba9876543210:9876:123456\n'; }
  enumerate_playback_streams() { : > "$TEST_SCRATCH/stale-stream-enumerated"; return 1; }
  inspect_pipewire_node() { : > "$TEST_SCRATCH/stale-stream-inspected"; return 1; }
  bounded_user_pw_metadata() { : > "$TEST_SCRATCH/stale-target-cleared"; return 1; }

  clear_owned_routing "$user"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'stream provenance from a former PipeWire instance remained'
  [[ ! -e $TEST_SCRATCH/stale-stream-enumerated &&
     ! -e $TEST_SCRATCH/stale-stream-inspected &&
     ! -e $TEST_SCRATCH/stale-target-cleared ]] || \
    fail 'stale PipeWire stream provenance touched the new server instance'

  printf 'user\t%s\ninstance\t%s\nstream\t138\t89\n' "$user" \
    '01234567-89ab-cdef-0123-456789abcdef:4321:987654' > "$ROUTING_STATE_FILE"
  if load_routing_state; then
    fail 'routing provenance without a speaker identity was accepted'
  fi
  printf 'user\t%s\nspeaker\t%s\ndefault\t%s\t%s\n' "$user" \
    'AA:BB:CC:DD:EE:FF' 'bluez_output.11_22_33_44_55_66.1' \
    '11:22:33:44:55:66' > "$ROUTING_STATE_FILE"
  if load_routing_state; then
    fail 'aggregate routing provenance disagreed with its override owner'
  fi
}

mock_a2dp_enum_profiles() {
  cat <<'EOF'
  Object: size 256, type Spa:Pod:Object:Param:Profile, id EnumProfile
  Prop: key Spa:Pod:Object:Param:Profile:index (1), flags 00000000
    Int 131079
  Prop: key Spa:Pod:Object:Param:Profile:name (2), flags 00000000
    String "a2dp-sink"
  Object: size 256, type Spa:Pod:Object:Param:Profile, id EnumProfile
  Prop: key Spa:Pod:Object:Param:Profile:index (1), flags 00000000
    Int 131078
  Prop: key Spa:Pod:Object:Param:Profile:name (2), flags 00000000
    String "a2dp-sink-aptx"
  Object: size 256, type Spa:Pod:Object:Param:Profile, id EnumProfile
  Prop: key Spa:Pod:Object:Param:Profile:index (1), flags 00000000
    Int 131073
  Prop: key Spa:Pod:Object:Param:Profile:name (2), flags 00000000
    String "a2dp-sink-sbc"
  Object: size 256, type Spa:Pod:Object:Param:Profile, id EnumProfile
  Prop: key Spa:Pod:Object:Param:Profile:index (1), flags 00000000
    Int 131078
  Prop: key Spa:Pod:Object:Param:Profile:name (2), flags 00000000
    String "a2dp-sink-ldac"
  Object: size 256, type Spa:Pod:Object:Param:Profile, id EnumProfile
  Prop: key Spa:Pod:Object:Param:Profile:index (1), flags 00000000
    Int 131584
  Prop: key Spa:Pod:Object:Param:Profile:name (2), flags 00000000
    String "bap-sink"
EOF
}

test_pipewire_codec_profile_discovery() {
  local output profiles
  load_app
  id() {
    if [[ ${1:-} == -u && ${2:-} == audio ]]; then
      printf '1234\n'
    else
      /usr/bin/id "$@"
    fi
  }
  user_home() { printf '/srv/audio\n'; }
  runuser() { printf '%s\n' "$*"; }
  output=$(bounded_user_pw_cli audio 3 enum-params 55 EnumProfile)
  assert_contains "$output" '-u audio -- env HOME=/srv/audio'
  assert_contains "$output" 'XDG_RUNTIME_DIR=/run/user/1234'
  assert_contains "$output" 'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1234/bus'
  assert_contains "$output" 'timeout --signal=TERM --kill-after=1 3 pw-cli enum-params 55 EnumProfile'
  output=$(bounded_user_wpctl audio 2 status --name)
  assert_contains "$output" 'timeout --signal=TERM --kill-after=1 2 wpctl status --name'
  output=$(bounded_user_pw_metadata audio 2 -n default 0 default.configured.audio.sink)
  assert_contains "$output" 'timeout --signal=TERM --kill-after=1 2 pw-metadata -n default 0 default.configured.audio.sink'

  CFG_AUDIO_USER=audio
  bounded_user_wpctl() {
    printf '  44. bluez_card.00_11_22_33_44_55\n'
    printf '  55. bluez_card.AA_BB_CC_DD_EE_FF\n'
  }
  assert_eq 55 "$(find_a2dp_device_id AA:BB:CC:DD:EE:FF 3)"
  bounded_user_pw_cli() { mock_a2dp_enum_profiles; }
  profiles=$(enumerate_a2dp_profiles 55 3)
  assert_eq $'aptx_hd 131079\naptx 131078\nsbc 131073' "$profiles"

  bounded_user_pw_cli() { printf 'EnumProfile output changed shape\n'; }
  if enumerate_a2dp_profiles 55 3 >/dev/null; then
    fail 'unrecognized pw-cli output was accepted'
  fi
}

test_per_speaker_codec_selection() {
  local mac=AA:BB:CC:DD:EE:FF user state_file command_log rc connected=1
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  state_file=$TEST_SCRATCH/codec-state
  command_log=$TEST_SCRATCH/pw-cli.log
  CFG_AUDIO_USER=$user
  CFG_MEDIA_CONTROLS=auto
  CFG_SPEAKERS=("$mac")
  CFG_SPEAKER_CODECS=('ldac aptx sbc')
  find_a2dp_device_id() { printf '55\n'; }
  device_connected() { (( connected == 1 )); }
  a2dp_connected() { (( connected == 1 )); }
  device_healthy() { (( connected == 1 )); }
  now_seconds() { printf '100\n'; }
  a2dp_codec() {
    local codec_state
    if [[ -f $state_file ]]; then
      IFS= read -r codec_state < "$state_file"
      printf '%s\n' "$codec_state"
    else
      printf 'sbc_xq\n'
    fi
  }
  bounded_user_pw_cli() {
    if [[ $3 == enum-params ]]; then
      mock_a2dp_enum_profiles
    else
      printf '%s\n' "$*" >> "$command_log"
      if [[ $* == *'131078'* ]]; then printf 'aptx\n' > "$state_file"; fi
      if [[ $* == *'131073'* ]]; then printf 'sbc\n' > "$state_file"; fi
    fi
  }

  apply_speaker_codec_policy "$mac" 110
  assert_eq aptx "$(< "$state_file")"
  assert_file_contains "$command_log" "set-param 55 Profile { index: 131078, save: false }"
  assert_eq aptx "${DAEMON_CODEC_TARGET[$mac]}"
  assert_eq 'ldac aptx sbc' "${DAEMON_CODEC_POLICY[$mac]}"

  : > "$command_log"
  apply_speaker_codec_policy "$mac" 110
  [[ ! -s $command_log ]] || fail 'cached compliant codec was selected again'

  CFG_SPEAKER_CODECS=('sbc')
  apply_speaker_codec_policy "$mac" 110
  assert_eq sbc "$(< "$state_file")"
  assert_file_contains "$command_log" "set-param 55 Profile { index: 131073, save: false }"

  remember_daemon_active "$mac"
  DAEMON_ACTIVE=
  DAEMON_CODEC_POLICY=()
  DAEMON_CODEC_TARGET=()
  load_daemon_active
  assert_eq sbc "${DAEMON_CODEC_POLICY[$mac]}"
  bluetooth_device_command() {
    printf '%s\n' "$*" >> "$TEST_SCRATCH/bluetooth-codec-reset.log"
    case $2 in
      disconnect) connected=0 ;;
      connect) connected=1 ;;
    esac
  }
  CFG_SPEAKER_CODECS=('')
  apply_speaker_codec_policy "$mac" 110
  assert_file_contains "$TEST_SCRATCH/bluetooth-codec-reset.log" '10 disconnect AA:BB:CC:DD:EE:FF'
  assert_file_contains "$TEST_SCRATCH/bluetooth-codec-reset.log" '10 connect AA:BB:CC:DD:EE:FF'
  [[ ! -e $STATE_DIR/active-codec-policy ]] || fail 'cleared codec policy remained recorded'
  [[ ! ${DAEMON_CODEC_POLICY[$mac]+present} ]] || fail 'cleared codec policy remained cached'

  : > "$command_log"
  CFG_SPEAKER_CODECS=('ldac')
  if apply_speaker_codec_policy "$mac" 110; then
    fail 'speaker without a configured available codec became healthy'
  else
    rc=$?
  fi
  assert_eq 2 "$rc"
  assert_contains "$CODEC_POLICY_ERROR" 'requested: ldac; available: aptx_hd aptx sbc'
  [[ ! -s $command_log ]] || fail 'unavailable codec caused a profile change'

  CFG_SPEAKER_CODECS=('aptx')
  printf 'sbc\n' > "$state_file"
  bounded_user_pw_cli() {
    if [[ $3 == enum-params ]]; then mock_a2dp_enum_profiles; else return 1; fi
  }
  if apply_speaker_codec_policy "$mac" 110; then fail 'failed profile command was accepted'; fi
  assert_contains "$CODEC_POLICY_ERROR" 'could not select aptx'

  bounded_user_pw_cli() {
    if [[ $3 == enum-params ]]; then
      mock_a2dp_enum_profiles
    else
      : > "$TEST_SCRATCH/deadline-expired"
    fi
  }
  now_seconds() {
    if [[ -e $TEST_SCRATCH/deadline-expired ]]; then printf '110\n'; else printf '100\n'; fi
  }
  set +e
  apply_speaker_codec_policy "$mac" 110 >/dev/null 2>&1
  rc=$?
  set -e
  (( rc != 0 )) || fail 'unverified profile switch was accepted'
  assert_contains "$CODEC_POLICY_ERROR" 'codec aptx did not become healthy'
}

test_daemon_nonpreemption_and_failover_order() {
  local first=AA:BB:CC:DD:EE:01 second=AA:BB:CC:DD:EE:02
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_SPEAKERS=("$first" "$second")
  CFG_RECONNECT_INTERVAL=5
  CFG_MEDIA_CONTROLS=auto
  CFG_CONTROLLER=auto
  DAEMON_ACTIVE=$second
  device_healthy() { [[ $1 == "$second" ]]; }
  device_connected() { [[ $1 == "$second" ]]; }
  a2dp_connected() { [[ $1 == "$second" ]]; }
  maintain_speaker_routing() { :; }
  disconnect_other_speakers() { printf '%s\n' "$1" > "$TEST_SCRATCH/stale-cleanup"; }
  bluetoothctl() { printf '%s\n' "$*" >> "$TEST_SCRATCH/bluetooth.log"; }
  daemon_cycle
  [[ ! -e $TEST_SCRATCH/bluetooth.log ]] || fail 'healthy fallback was preempted'
  assert_eq "$second" "$(< "$TEST_SCRATCH/stale-cleanup")"
  assert_eq "$second" "$DAEMON_ACTIVE"

  DAEMON_ACTIVE=
  DAEMON_FAILURES=()
  DAEMON_NEXT_ATTEMPT=()
  device_healthy() { return 1; }
  device_paired() { return 0; }
  device_trusted() { return 0; }
  wait_for_health() { [[ $1 == "$second" ]]; }
  disconnect_other_speakers() { :; }
  a2dp_codec() { printf 'ldac\n'; }
  now_seconds() { printf '100\n'; }
  bluetoothctl() {
    local command attempted=
    while IFS= read -r command; do
      [[ $command != connect\ * ]] || attempted=${command#connect }
    done
    [[ -n $attempted ]] || return 0
    printf '%s\n' "$attempted" >> "$TEST_SCRATCH/connect-order"
    [[ $attempted == "$second" ]]
  }
  daemon_cycle >/dev/null
  assert_eq "$first" "$(sed -n '1p' "$TEST_SCRATCH/connect-order")"
  assert_eq "$second" "$(sed -n '2p' "$TEST_SCRATCH/connect-order")"
  assert_eq "$second" "$DAEMON_ACTIVE"
}

test_daemon_disconnects_new_stale_connection() {
  local stale=AA:BB:CC:DD:EE:01 active=AA:BB:CC:DD:EE:02
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_SPEAKERS=("$stale" "$active")
  CFG_RECONNECT_INTERVAL=5
  CFG_MEDIA_CONTROLS=auto
  CFG_CONTROLLER=auto
  DAEMON_ACTIVE=$active
  device_healthy() { [[ $1 == "$active" ]]; }
  device_connected() { [[ $1 == "$stale" ]]; }
  maintain_speaker_routing() { :; }
  disconnect_bluetooth_device() { printf '%s\n' "$1" >> "$TEST_SCRATCH/disconnected"; }

  daemon_cycle
  assert_eq "$stale" "$(< "$TEST_SCRATCH/disconnected")"
  assert_eq "$active" "$DAEMON_ACTIVE"
}

test_daemon_routing_failure_keeps_transport() {
  local mac=AA:BB:CC:DD:EE:FF
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_SPEAKERS=("$mac")
  CFG_RECONNECT_INTERVAL=5
  CFG_MEDIA_CONTROLS=auto
  DAEMON_ACTIVE=$mac
  device_connected() { return 0; }
  a2dp_connected() { return 0; }
  apply_speaker_codec_policy() { return 0; }
  disconnect_other_speakers() { :; }
  reconcile_speaker_routing() { return 1; }
  disconnect_bluetooth_device() { fail 'routing failure disconnected a healthy speaker'; }
  now_seconds() { printf '100\n'; }

  daemon_cycle > "$TEST_SCRATCH/daemon-output"
  assert_eq "$mac" "$DAEMON_ACTIVE"
  assert_contains "$(< "$TEST_SCRATCH/daemon-output")" \
    'Bluetooth connection remains active'
}

test_daemon_reuses_connection_deadline() {
  local mac=AA:BB:CC:DD:EE:FF
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_SPEAKERS=("$mac")
  CFG_RECONNECT_INTERVAL=5
  CFG_MEDIA_CONTROLS=auto
  CFG_CONTROLLER=auto
  DAEMON_ACTIVE=
  DAEMON_FAILURES=()
  DAEMON_NEXT_ATTEMPT=()
  device_healthy() { return 1; }
  device_paired() { return 0; }
  device_trusted() { return 0; }
  now_seconds() { printf '100\n'; }
  bluetooth_device_command() {
    [[ $2 != connect ]] || printf '%s %s %s\n' "$1" "$2" "$3" > "$TEST_SCRATCH/connect-command"
  }
  wait_for_health() {
    printf '%s\n' "${2:-missing}" > "$TEST_SCRATCH/health-deadline"
    return 1
  }

  daemon_cycle >/dev/null
  assert_eq "${CONNECT_TIMEOUT} connect $mac" "$(< "$TEST_SCRATCH/connect-command")"
  assert_eq "$((100 + CONNECT_TIMEOUT))" "$(< "$TEST_SCRATCH/health-deadline")"
}

test_daemon_codec_policy_failover() {
  local first=AA:BB:CC:DD:EE:01 second=AA:BB:CC:DD:EE:02 output
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_SPEAKERS=("$first" "$second")
  CFG_SPEAKER_CODECS=('ldac' 'sbc')
  CFG_RECONNECT_INTERVAL=5
  CFG_MEDIA_CONTROLS=auto
  CFG_CONTROLLER=auto
  DAEMON_ACTIVE=
  DAEMON_FAILURES=()
  DAEMON_NEXT_ATTEMPT=()
  device_healthy() { return 1; }
  device_connected() { return 1; }
  device_paired() { return 0; }
  device_trusted() { return 0; }
  now_seconds() { printf '100\n'; }
  bluetooth_device_command() {
    [[ $2 != connect ]] || printf '%s\n' "$3" >> "$TEST_SCRATCH/connect-order"
  }
  apply_speaker_codec_policy() {
    if [[ $1 == "$first" ]]; then
      CODEC_POLICY_ERROR="none of the configured codecs for $first are available (requested: ldac; available: sbc)"
      return 2
    fi
    return 0
  }
  disconnect_bluetooth_device() { printf '%s\n' "$1" >> "$TEST_SCRATCH/disconnected"; }
  disconnect_other_speakers() { :; }
  a2dp_codec() { printf 'sbc\n'; }

  daemon_cycle > "$TEST_SCRATCH/daemon-output"
  output=$(< "$TEST_SCRATCH/daemon-output")
  assert_contains "$output" "requested: ldac; available: sbc"
  assert_contains "$output" 'retrying in 5s'
  assert_eq "$first" "$(sed -n '1p' "$TEST_SCRATCH/connect-order")"
  assert_eq "$second" "$(sed -n '2p' "$TEST_SCRATCH/connect-order")"
  assert_file_contains "$TEST_SCRATCH/disconnected" "$first"
  assert_eq 105 "${DAEMON_NEXT_ATTEMPT[$first]}"
  assert_eq "$second" "$DAEMON_ACTIVE"

  : > "$TEST_SCRATCH/connect-order"
  : > "$TEST_SCRATCH/first-policy-attempts"
  DAEMON_ACTIVE=$first
  DAEMON_FAILURES=()
  DAEMON_NEXT_ATTEMPT=()
  device_connected() { [[ $1 == "$first" ]]; }
  a2dp_connected() { [[ $1 == "$first" ]]; }
  device_healthy() { [[ $1 == "$first" ]]; }
  apply_speaker_codec_policy() {
    if [[ $1 == "$first" ]]; then
      printf 'attempt\n' >> "$TEST_SCRATCH/first-policy-attempts"
      CODEC_POLICY_ERROR="none of the configured codecs for $first are available (requested: ldac; available: sbc)"
      return 2
    fi
    return 0
  }
  daemon_cycle >/dev/null
  assert_eq 1 "$(wc -l < "$TEST_SCRATCH/first-policy-attempts")"
  assert_eq "$second" "$(< "$TEST_SCRATCH/connect-order")"
  assert_eq "$second" "$DAEMON_ACTIVE"
}

test_daemon_cooldown_and_backoff() {
  local mac=AA:BB:CC:DD:EE:FF
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_SPEAKERS=("$mac")
  CFG_RECONNECT_INTERVAL=5
  CFG_MEDIA_CONTROLS=auto
  CFG_CONTROLLER=auto
  DAEMON_ACTIVE=
  DAEMON_FAILURES=()
  DAEMON_NEXT_ATTEMPT=()
  device_healthy() { return 1; }
  device_paired() { return 0; }
  device_trusted() { return 0; }
  now_seconds() { printf '100\n'; }
  bluetoothctl() {
    local command
    while IFS= read -r command; do
      [[ $command != connect\ * ]] || printf 'attempt\n' >> "$TEST_SCRATCH/attempts"
    done
    return 1
  }
  daemon_cycle >/dev/null
  daemon_cycle >/dev/null
  assert_eq 1 "$(wc -l < "$TEST_SCRATCH/attempts")"

  device_healthy() { return 0; }
  apply_speaker_codec_policy() { return 0; }
  disconnect_other_speakers() { :; }
  daemon_cycle >/dev/null
  assert_eq "$mac" "$DAEMON_ACTIVE"
  assert_eq 0 "${DAEMON_NEXT_ATTEMPT[$mac]}"
  assert_eq 1 "$(wc -l < "$TEST_SCRATCH/attempts")"

  assert_eq 5 "$(connection_backoff 1 5)"
  assert_eq 10 "$(connection_backoff 2 5)"
  assert_eq 60 "$(connection_backoff 9 5)"
}

test_daemon_disconnects_removed_active_speaker() {
  local removed=AA:BB:CC:DD:EE:01 replacement=AA:BB:CC:DD:EE:02
  setup_scratch_dir
  load_app
  configure_scratch_paths
  printf '%s\n' "$removed" > "$STATE_DIR/active-speaker"
  CFG_SPEAKERS=("$replacement")
  CFG_RECONNECT_INTERVAL=5
  CFG_MEDIA_CONTROLS=auto
  CFG_CONTROLLER=auto
  DAEMON_ACTIVE=
  load_daemon_active
  device_healthy() { [[ $1 == "$replacement" ]]; }
  maintain_speaker_routing() { :; }
  disconnect_bluetooth_device() {
    printf 'disconnect %s\n' "$1" >> "$TEST_SCRATCH/bluetooth.log"
  }
  daemon_cycle
  assert_file_contains "$TEST_SCRATCH/bluetooth.log" "disconnect $removed"
  assert_eq "$replacement" "$DAEMON_ACTIVE"
  assert_eq "$replacement" "$(< "$STATE_DIR/active-speaker")"
}

test_audio_user_reconciliation() {
  local old_user=root new_user
  setup_scratch_dir
  load_app
  configure_scratch_paths
  new_user=$(id -un)
  [[ $new_user != root ]] || old_user=nobody
  printf '%s\n' "$old_user" > "$STATE_DIR/runtime-user"
  id() { return 0; }
  ensure_audio_user() { printf 'ensure %s\n' "$1" >> "$TEST_SCRATCH/users.log"; }
  restore_user_state() { printf 'restore %s\n' "$1" >> "$TEST_SCRATCH/users.log"; }
  reconcile_audio_user "$new_user"
  assert_file_contains "$TEST_SCRATCH/users.log" "ensure $new_user"
  assert_file_contains "$TEST_SCRATCH/users.log" "restore $old_user"
  assert_eq "$new_user" "$(< "$STATE_DIR/runtime-user")"
}

test_missing_previous_audio_user_retires_routing() {
  local old_user=a2dpilot-user-that-does-not-exist new_user
  setup_scratch_dir
  load_app
  configure_scratch_paths
  new_user=$(id -un)
  printf '%s\n' "$old_user" > "$STATE_DIR/runtime-user"
  ROUTING_STATE_USER=$old_user
  ROUTING_DEFAULT_NAME=bluez_output.AA_BB_CC_DD_EE_FF.1
  write_routing_state
  ensure_audio_user() { :; }
  restore_user_state() { fail 'missing previous audio user was restored'; }

  reconcile_audio_user "$new_user"
  [[ ! -e $ROUTING_STATE_FILE ]] || \
    fail 'missing previous audio user retained routing state'
  assert_eq "$new_user" "$(< "$STATE_DIR/runtime-user")"
}

test_audio_user_units_are_unmasked_before_enablement() {
  local user unmask_line enable_line expected
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  record_user_state() { :; }
  loginctl() { printf '%s\n' "$*" >> "$TEST_SCRATCH/loginctl.log"; }
  systemctl() { printf '%s\n' "$*" >> "$TEST_SCRATCH/systemctl.log"; }
  as_user_systemctl() { printf '%s\n' "$*" >> "$TEST_SCRATCH/user-systemctl.log"; }
  ensure_audio_user "$user"
  assert_file_contains "$TEST_SCRATCH/user-systemctl.log" \
    "$user unmask pipewire.socket pipewire.service pipewire-pulse.socket pipewire-pulse.service wireplumber.service"
  assert_file_contains "$TEST_SCRATCH/user-systemctl.log" \
    "$user unmask --runtime pipewire.socket pipewire.service pipewire-pulse.socket pipewire-pulse.service wireplumber.service"
  unmask_line=$(grep -n ' unmask ' "$TEST_SCRATCH/user-systemctl.log" | cut -d: -f1 | head -n 1)
  enable_line=$(grep -n ' enable --now ' "$TEST_SCRATCH/user-systemctl.log" | cut -d: -f1)
  (( unmask_line < enable_line )) || fail 'user units were enabled before being unmasked'

  restore_unit_state_and_activity user "$user" masked-user.service masked 1 start
  expected=$TEST_SCRATCH/expected-user-restore
  cat > "$expected" <<EOF
$user unmask masked-user.service
$user unmask --runtime masked-user.service
$user start masked-user.service
$user mask masked-user.service
EOF
  tail -n 4 "$TEST_SCRATCH/user-systemctl.log" | diff -u "$expected" -
}

test_user_unit_enablement_restores_sockets_last() {
  local user directory expected pipewire_socket_enabled=1 pulse_socket_enabled=1
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  directory=$(user_state_dir "$user")
  install -d "$directory"
  printf '%s\n' "$user" > "$directory/user"
  printf 'yes\n' > "$directory/linger"
  cat > "$directory/service-states" <<'EOF'
pipewire.socket disabled 0
pipewire.service enabled 0
pipewire-pulse.socket disabled 0
pipewire-pulse.service enabled 0
wireplumber.service disabled 0
EOF
  : > "$directory/recorded"
  loginctl() { :; }
  systemctl() { :; }
  as_user_systemctl() {
    local run_user=$1 action unit
    shift
    action=$1
    unit=${2:-}
    if [[ $action == show ]]; then
      printf 'loaded\n'
      return 0
    fi
    printf '%s %s\n' "$run_user" "$*" >> "$TEST_SCRATCH/user-systemctl.log"
    case "$action $unit" in
      'enable pipewire.service') pipewire_socket_enabled=1 ;;
      'disable pipewire.socket') pipewire_socket_enabled=0 ;;
      'enable pipewire-pulse.service') pulse_socket_enabled=1 ;;
      'disable pipewire-pulse.socket') pulse_socket_enabled=0 ;;
    esac
  }

  restore_user_state "$user"
  assert_eq 0 "$pipewire_socket_enabled"
  assert_eq 0 "$pulse_socket_enabled"
  expected=$TEST_SCRATCH/expected-user-restore
  cat > "$expected" <<EOF
$user unmask pipewire.socket
$user unmask --runtime pipewire.socket
$user stop pipewire.socket
$user unmask pipewire.service
$user unmask --runtime pipewire.service
$user stop pipewire.service
$user unmask pipewire-pulse.socket
$user unmask --runtime pipewire-pulse.socket
$user stop pipewire-pulse.socket
$user unmask pipewire-pulse.service
$user unmask --runtime pipewire-pulse.service
$user stop pipewire-pulse.service
$user unmask wireplumber.service
$user unmask --runtime wireplumber.service
$user stop wireplumber.service
$user unmask pipewire.service
$user unmask --runtime pipewire.service
$user enable pipewire.service
$user unmask pipewire.socket
$user unmask --runtime pipewire.socket
$user disable pipewire.socket
$user unmask pipewire-pulse.service
$user unmask --runtime pipewire-pulse.service
$user enable pipewire-pulse.service
$user unmask pipewire-pulse.socket
$user unmask --runtime pipewire-pulse.socket
$user disable pipewire-pulse.socket
$user unmask wireplumber.service
$user unmask --runtime wireplumber.service
$user disable wireplumber.service
EOF
  diff -u "$expected" "$TEST_SCRATCH/user-systemctl.log"
}

test_rfkill_snapshot_restore_and_hard_block() {
  local sysfs
  setup_scratch_dir
  load_app
  configure_scratch_paths
  sysfs=$TEST_SCRATCH/sys/class/rfkill
  RFKILL_SYSFS=$sysfs
  install -d "$sysfs/rfkill0" "$sysfs/rfkill1"
  printf 'bluetooth\n' > "$sysfs/rfkill0/type"
  printf 'adapter-one\n' > "$sysfs/rfkill0/name"
  printf '1\n' > "$sysfs/rfkill0/soft"
  printf '0\n' > "$sysfs/rfkill0/hard"
  printf 'bluetooth\n' > "$sysfs/rfkill1/type"
  printf 'adapter-two\n' > "$sysfs/rfkill1/name"
  printf '0\n' > "$sysfs/rfkill1/soft"
  printf '1\n' > "$sysfs/rfkill1/hard"
  record_rfkill_state
  rfkill() { printf '%s\n' "$*" >> "$TEST_SCRATCH/rfkill.log"; }
  restore_rfkill_state
  assert_file_contains "$TEST_SCRATCH/rfkill.log" 'block 0'
  assert_file_contains "$TEST_SCRATCH/rfkill.log" 'unblock 1'
  if hard_blocked; then fail 'one usable adapter was treated as globally hard-blocked'; fi
  printf '1\n' > "$sysfs/rfkill0/hard"
  hard_blocked || fail 'all-hard-blocked state was not detected'
}

test_controller_selection_and_power() {
  local controller=12:34:56:78:9A:BC
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_CONTROLLER=$controller
  hard_blocked() { return 1; }
  controller_exists() { [[ $1 == "$controller" ]]; }
  rfkill() { printf '%s\n' "$*" >> "$TEST_SCRATCH/rfkill.log"; }
  bluetoothctl() {
    if [[ ${1:-} == show ]]; then
      printf '\tPowered: yes\n'
    else
      cat > "$TEST_SCRATCH/controller-input"
    fi
  }
  power_controller
  assert_file_contains "$TEST_SCRATCH/rfkill.log" 'unblock bluetooth'
  assert_file_contains "$TEST_SCRATCH/controller-input" "select $controller"
  assert_file_contains "$TEST_SCRATCH/controller-input" 'power on'
}

test_automatic_controller_device_commands_exit_after_result() {
  local mac=AA:BB:CC:DD:EE:FF
  setup_scratch_dir
  load_app
  bluetoothctl() {
    printf 'args: %s\n' "$*" > "$TEST_SCRATCH/automatic-controller-session"
    cat >> "$TEST_SCRATCH/automatic-controller-session"
  }

  bluetooth_device_command_on_controller auto 5 connect "$mac"

  assert_eq $'args: --timeout 5\nconnect AA:BB:CC:DD:EE:FF\nquit' \
    "$(< "$TEST_SCRATCH/automatic-controller-session")"
}

test_explicit_controller_scopes_device_operations() {
  local controller=12:34:56:78:9A:BC mac=AA:BB:CC:DD:EE:FF devices
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_CONTROLLER=$controller
  has_tty() { return 1; }
  bluetoothctl() {
    local input line
    if [[ ${1:-} == list ]]; then
      printf 'Controller 00:11:22:33:44:55 First Adapter\n'
      printf 'Controller %s Selected Adapter [default]\n' "$controller"
      return 0
    fi
    if [[ ${1:-} == show ]]; then
      printf '\tPairable: no\n'
      return 0
    fi
    if [[ $* == *'--agent '* ]]; then
      while IFS= read -r line; do
        printf '%s\n' "$line" >> "$TEST_SCRATCH/controller-sessions"
        [[ $line != "pair $mac" ]] || printf 'Pairing successful\n'
      done
      return 0
    fi
    input=$(cat)
    printf '%s\n---\n' "$input" >> "$TEST_SCRATCH/controller-sessions"
    case $input in
      *"info $mac"*) printf 'Device %s Test Speaker\n\tPaired: yes\n' "$mac" ;;
      *devices*) printf 'Device %s Test Speaker\n' "$mac" ;;
    esac
  }
  busctl() {
    case $* in
      'tree --list org.bluez')
        printf '/org/bluez/hci0\n/org/bluez/hci7\n'
        ;;
      *'/org/bluez/hci0 org.bluez.Adapter1 Address')
        printf 's "00:11:22:33:44:55"\n'
        ;;
      *'/org/bluez/hci7 org.bluez.Adapter1 Address')
        printf 's "%s"\n' "$controller"
        ;;
      *"/org/bluez/hci7/dev_${mac//:/_} org.bluez.MediaControl1 Connected")
        printf '%s\n' "$*" > "$TEST_SCRATCH/avrcp-path"
        printf 'b true\n'
        ;;
      *) return 1 ;;
    esac
  }

  device_info "$mac" >/dev/null
  bluetooth_device_command 5 trust "$mac" >/dev/null
  devices=$(configured_bluetooth_devices)
  assert_contains "$devices" "$mac"
  pair_on_controller "$mac" NoInputNoOutput >/dev/null
  assert_eq 5 "$(grep -Fc "select $controller" "$TEST_SCRATCH/controller-sessions")"
  assert_file_contains "$TEST_SCRATCH/controller-sessions" "info $mac"
  assert_file_contains "$TEST_SCRATCH/controller-sessions" "trust $mac"
  assert_file_contains "$TEST_SCRATCH/controller-sessions" "pair $mac"
  avrcp_connected "$mac"
  assert_file_contains "$TEST_SCRATCH/avrcp-path" "/org/bluez/hci7/dev_${mac//:/_}"
  CFG_CONTROLLER=auto
  assert_eq "$controller" "$(configured_controller_address)"
}

test_bond_policy_and_removal_aggregation() {
  local output rc controller=12:34:56:78:9A:BC
  setup_scratch_dir
  load_app
  configure_scratch_paths
  printf '%s %s\n' "$controller" AA:BB:CC:DD:EE:01 > "$STATE_DIR/created-bonds"
  printf '%s %s\n' "$controller" AA:BB:CC:DD:EE:02 >> "$STATE_DIR/created-bonds"
  printf '%s %s\n' "$controller" AA:BB:CC:DD:EE:03 >> "$STATE_DIR/created-bonds"
  has_tty() { return 1; }
  assert_eq keep "$(choose_bond_policy ask)"
  assert_eq remove "$(choose_bond_policy remove)"

  device_info_on_controller() { [[ $2 != AA:BB:CC:DD:EE:03 ]]; }
  remove_bluetooth_device_on_controller() {
    printf '%s %s\n' "$1" "$2" >> "$TEST_SCRATCH/bond-removals"
    [[ $2 != AA:BB:CC:DD:EE:01 ]]
  }
  set +e
  output=$(remove_created_bonds 2>&1)
  rc=$?
  set -e
  (( rc != 0 )) || fail 'partial bond removal reported success'
  assert_contains "$output" 'Could not remove'
  assert_contains "$output" 'AA:BB:CC:DD:EE:03 is already absent'
  assert_file_contains "$TEST_SCRATCH/bond-removals" 'AA:BB:CC:DD:EE:01'
  assert_file_contains "$TEST_SCRATCH/bond-removals" 'AA:BB:CC:DD:EE:02'
  assert_file_not_contains "$TEST_SCRATCH/bond-removals" 'AA:BB:CC:DD:EE:03'

  : > "$STATE_DIR/created-bonds"
  assert_eq none "$(choose_bond_policy remove)"

  require_root() { :; }
  : > "$STATE_FILE"
  expect_failure_contains 'mutually exclusive' uninstall_action --keep-bonds --remove-bonds
  expect_failure_contains 'Unknown uninstall option: --with-dependencies' \
    uninstall_action --with-dependencies
}

test_managed_paths_and_state_serialization() {
  local existing created mode
  setup_scratch_dir
  load_app
  configure_scratch_paths
  install -d "$(dirname "$INSTALLED_CLI")" "$(dirname "$SYSTEMD_UNIT")" \
    "$(dirname "$WIREPLUMBER_CONF")" "$(dirname "$TRIGGER_CONF")"
  : > "$STATE_DIR/created-files"
  : > "$STATE_DIR/replaced-files"
  existing=$CONFIG_FILE
  created=$SYSTEMD_UNIT
  printf 'original\n' > "$existing"
  backup_file "$existing"
  backup_file "$created"
  assert_file_contains "$STATE_DIR/replaced-files" "$existing"
  assert_file_contains "$STATE_DIR/created-files" "$created"
  assert_file_contains "$BACKUP_DIR$existing" original

  render_state_file "$STATE_FILE" installed
  mode=$(stat -c %a "$STATE_FILE")
  assert_eq 600 "$mode"
  assert_file_contains "$STATE_FILE" 'INSTALL_PHASE=installed'

  install -d "$TEST_SCRATCH/real" "$TEST_SCRATCH/target"
  ln -s "$TEST_SCRATCH/target" "$TEST_SCRATCH/real/link"
  expect_failure_contains 'Refusing to traverse symlinked directory' \
    validate_directory_chain "$TEST_SCRATCH/real/link/child"
  LOCK_FILE=$TEST_SCRATCH/real/link/lock
  expect_failure_contains 'Refusing to traverse symlinked directory' prepare_lock_directory
  if allowed_managed_path /tmp/not-managed; then fail 'arbitrary path passed allowlist'; fi
}

test_system_service_state_restoration() {
  local expected service_active socket_active trigger_order
  setup_scratch_dir
  load_app
  configure_scratch_paths
  cat > "$STATE_DIR/system-service-states" <<'EOF'
enabled.service enabled 1
disabled.service disabled 0
static.service static 1
masked.service masked 0
active-masked.service masked 1
runtime-masked.service masked-runtime 1
missing.service not-found 0
EOF
  systemctl() {
    local action=$1 unit=${2:-}
    if [[ $action == show ]]; then
      if [[ $unit == missing.service ]]; then printf 'not-found\n'; else printf 'loaded\n'; fi
      return 0
    fi
    printf '%s\n' "$*" >> "$TEST_SCRATCH/systemctl.log"
  }
  restore_system_service_states
  expected=$TEST_SCRATCH/expected
  cat > "$expected" <<'EOF'
unmask enabled.service
unmask --runtime enabled.service
enable enabled.service
start enabled.service
unmask disabled.service
unmask --runtime disabled.service
disable disabled.service
stop disabled.service
unmask static.service
unmask --runtime static.service
start static.service
unmask masked.service
unmask --runtime masked.service
mask masked.service
stop masked.service
unmask active-masked.service
unmask --runtime active-masked.service
start active-masked.service
mask active-masked.service
unmask runtime-masked.service
unmask --runtime runtime-masked.service
start runtime-masked.service
mask --runtime runtime-masked.service
EOF
  diff -u "$expected" "$TEST_SCRATCH/systemctl.log"

  systemctl() {
    case $1 in
      is-enabled) printf 'enabled\n' ;;
      is-active) printf 'active\n' ;;
    esac
  }
  record_system_service_states
  trigger_order=$(awk '/^triggerhappy\./ { print $1 }' \
    "$STATE_DIR/system-service-states" | paste -sd ' ')
  assert_eq 'triggerhappy.socket triggerhappy.service' "$trigger_order"
  : > "$TEST_SCRATCH/systemctl.log"
  cat > "$STATE_DIR/system-service-states" <<'EOF'
triggerhappy.socket enabled 1
triggerhappy.service enabled 1
EOF
  service_active=1
  socket_active=0
  systemctl() {
    local action=$1 unit=${2:-}
    if [[ $action == show ]]; then
      printf 'loaded\n'
      return 0
    fi
    case "$action $unit" in
      'stop triggerhappy.service') service_active=0 ;;
      'start triggerhappy.socket')
        (( service_active == 0 )) || return 1
        socket_active=1
        ;;
      'restart triggerhappy.service')
        (( socket_active == 1 )) || return 1
        service_active=1
        ;;
    esac
    printf '%s\n' "$*" >> "$TEST_SCRATCH/systemctl.log"
  }
  restore_system_service_states
  cat > "$expected" <<'EOF'
stop triggerhappy.service
unmask triggerhappy.socket
unmask --runtime triggerhappy.socket
enable triggerhappy.socket
start triggerhappy.socket
unmask triggerhappy.service
unmask --runtime triggerhappy.service
enable triggerhappy.service
restart triggerhappy.service
EOF
  diff -u "$expected" "$TEST_SCRATCH/systemctl.log"
}

run_test 'syntax, help, and streamed bootstrap' test_syntax_help_and_stream_bootstrap
run_test 'managed dependency list' test_managed_package_list
run_test 'configuration parsing and normalization' test_config_parser_and_normalization
run_test 'onboard-audio configuration and defaults' test_onboard_audio_configuration
run_test 'per-speaker codec configuration' test_speaker_codec_configuration
run_test 'default media-key mappings' test_default_media_key_mappings
run_test 'configuration rejection and non-evaluation' test_config_parser_rejections_and_no_eval
run_test 'invalid reload retains last valid configuration' test_invalid_reload_retains_last_valid_configuration
run_test 'config parser avoids legacy subshell helpers' test_config_parser_avoids_legacy_subshell_helpers
run_test 'media URL configuration validation' test_media_url_configuration_validation
run_test 'generated system integration files' test_generated_integration_files
run_test 'WirePlumber config path safety' test_wireplumber_config_path_safety
run_test 'Triggerhappy config rejects symlinked parent' test_trigger_config_rejects_symlinked_parent
run_test 'non-interactive install and uninstall fixture' test_noninteractive_install_and_uninstall_fixture
run_test 'uninstall keeps packages and reports empty bond policy' test_uninstall_keeps_packages_and_reports_empty_bond_policy
run_test 'uninstall preserves audio session after routing cleanup failure' \
  test_uninstall_preserves_audio_session_after_routing_cleanup_failure
run_test 'failed install rollback retains packages' test_failed_install_rollback_retains_packages
run_test 'install recovery needs no package snapshot' test_install_recovery_needs_no_package_snapshot
run_test 'update source selection and validation' test_update_source_selection_and_validation
run_test 'executable-only update transaction' test_update_executable_only_transaction
run_test 'update rechecks installed version under lock' \
  test_update_rechecks_installed_version_under_lock
run_test 'update rejects bad candidates and targets' test_update_rejects_bad_candidates_and_targets
run_test 'update activation rollback and interruption' test_update_activation_rollback_and_interruption
run_test 'safe config editor success and validation failure' test_config_editor_success_and_validation_failure
run_test 'config editor installs a protected snapshot' test_config_editor_installs_protected_snapshot
run_test 'failed config application restores previous config' test_config_application_rolls_back
run_test 'onboard-audio CLI and live application' test_onboard_audio_cli_and_application
run_test 'failed onboard-audio application rolls back' test_onboard_audio_application_rolls_back
run_test 'onboard-audio path failure rolls back' test_onboard_audio_path_failure_rolls_back
run_test 'onboard-audio status and device matching' test_onboard_audio_status_and_matching
run_test 'player control resolves configured URLs' test_player_control_resolves_configured_urls
run_test 'media controls share one deadline' test_media_control_shared_deadline
run_test 'media controls use a monotonic outer bound' test_media_control_monotonic_outer_bound
run_test 'player control resolves stateful media keys' test_player_control_resolves_stateful_media_keys
run_test 'mute state rejects symlinked parent' test_mute_state_rejects_symlinked_parent
run_test 'media state rejects unprivileged parent for root' \
  test_media_state_rejects_unprivileged_parent_for_root
run_test 'media state rejects the wrong identity' test_media_state_rejects_wrong_identity
run_test 'status reports media URL configuration' test_status_reports_media_url_configuration
run_test 'status stream inspection shares one deadline' \
  test_status_stream_inspection_shared_deadline
run_test 'status rejects an unverified or recycled active node' \
  test_status_rejects_unverified_or_recycled_active_node
run_test 'pairing provenance and existing bonds' test_pairing_provenance_and_existing_bond
run_test 'pairing session terminates after bonding' test_pairing_session_terminates_after_bonding
run_test 'pair --all attempts every configured speaker' test_pair_all_attempts_every_configured_speaker
run_test 'interactive scan selection' test_interactive_scan_selection
run_test 'forget removes config and provenance' test_forget_removes_config_and_provenance
run_test 'forget clears routing for a prior speaker' \
  test_forget_clears_routing_for_prior_speaker
run_test 'forget preserves unrelated routing' test_forget_preserves_unrelated_routing
run_test 'forget active speaker preserves different routing owner' \
  test_forget_active_speaker_preserves_different_routing_owner
run_test 'forget commits before routing cleanup failure' \
  test_forget_commits_before_routing_cleanup_failure
run_test 'forget failure preserves routing and configuration' \
  test_forget_failure_preserves_routing_and_configuration
run_test 'media-control health modes' test_media_control_health_modes
run_test 'optimistic codec reporting' test_codec_reporting_is_optimistic
run_test 'PipeWire codec property parsing' test_codec_property_parsing
run_test 'PipeWire routing parsers' test_pipewire_routing_parsers
run_test 'default routing and owned cleanup' test_default_routing_and_owned_cleanup
run_test 'default failure still routes streams' test_default_failure_still_routes_streams
run_test 'routing cleanup is scoped per speaker' \
  test_routing_cleanup_is_scoped_per_speaker
run_test 'routing write failure prevents mutation' test_routing_write_failure_prevents_mutation
run_test 'unchanged routing state is not replaced' \
  test_unchanged_routing_state_is_not_replaced
run_test 'routing cleanup checkpoints deadline progress' \
  test_routing_cleanup_checkpoints_deadline_progress
run_test 'routing cleanup rotates after deadline' test_routing_cleanup_rotates_after_deadline
run_test 'PipeWire restart during target cleanup' \
  test_pipewire_restart_during_target_cleanup
run_test 'reconciliation checkpoints retired stream' \
  test_reconciliation_checkpoints_retired_stream
run_test 'default cleanup revalidates and retires missing user' \
  test_default_cleanup_revalidates_and_retires_missing_user
run_test 'recycled sink is not defaulted' test_recycled_sink_is_not_defaulted
run_test 'recycled sink is not targeted' test_recycled_sink_is_not_targeted
run_test 'PipeWire restart during target assignment' \
  test_pipewire_restart_during_target_assignment
run_test 'stale owned target is rewritten after relink' \
  test_stale_owned_target_is_rewritten_after_relink
run_test 'recycled stream is not cleared' test_recycled_stream_is_not_cleared
run_test 'changed stream target is not cleared' test_changed_stream_target_is_not_cleared
run_test 'linked stream target lookup failure is reported' \
  test_linked_stream_target_lookup_failure_is_reported
run_test 'interrupted routing transition preserves prior owner' \
  test_interrupted_routing_transition_preserves_prior_owner
run_test 'routing rotates after a shared deadline' test_routing_rotates_after_deadline
run_test 'invalid initial config clears recorded routing' \
  test_invalid_initial_config_clears_recorded_routing
run_test 'daemon signal defers during routing mutation' \
  test_daemon_signal_defers_during_routing_mutation
run_test 'CLI signal defers during routing cleanup' \
  test_cli_signal_defers_during_routing_cleanup
run_test 'runtime reconciliation failure clears routing' \
  test_runtime_reconciliation_failure_clears_routing
run_test 'unmovable stream does not starve routing' test_unmovable_stream_does_not_starve_routing
run_test 'vanished stream does not starve routing' test_vanished_stream_does_not_starve_routing
run_test 'recycled stream is not targeted' test_recycled_stream_is_not_targeted
run_test 'PipeWire restart discards stream provenance' \
  test_pipewire_restart_discards_stream_provenance
run_test 'PipeWire codec profile discovery' test_pipewire_codec_profile_discovery
run_test 'per-speaker codec selection' test_per_speaker_codec_selection
run_test 'non-preemptive failover order' test_daemon_nonpreemption_and_failover_order
run_test 'healthy active speaker disconnects new stale connections' test_daemon_disconnects_new_stale_connection
run_test 'routing failure keeps healthy Bluetooth transport' test_daemon_routing_failure_keeps_transport
run_test 'connection health reuses the original deadline' test_daemon_reuses_connection_deadline
run_test 'strict codec policy fails over to next speaker' test_daemon_codec_policy_failover
run_test 'daemon cooldown and bounded backoff' test_daemon_cooldown_and_backoff
run_test 'removed active speaker is disconnected after restart' test_daemon_disconnects_removed_active_speaker
run_test 'audio-user reconciliation' test_audio_user_reconciliation
run_test 'missing previous audio user retires routing' \
  test_missing_previous_audio_user_retires_routing
run_test 'audio-user units are unmasked before enablement' test_audio_user_units_are_unmasked_before_enablement
run_test 'user socket enablement is restored after services' test_user_unit_enablement_restores_sockets_last
run_test 'rfkill snapshot, restore, and hard blocks' test_rfkill_snapshot_restore_and_hard_block
run_test 'controller selection and power control' test_controller_selection_and_power
run_test 'automatic controller device commands exit after result' test_automatic_controller_device_commands_exit_after_result
run_test 'explicit controller scopes device operations' test_explicit_controller_scopes_device_operations
run_test 'bond policy and removal aggregation' test_bond_policy_and_removal_aggregation
run_test 'managed path and private state safety' test_managed_paths_and_state_serialization
run_test 'system service restoration' test_system_service_state_restoration

if (( TESTS_FAILED > 0 )); then
  printf '%d of %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN" >&2
  exit 1
fi
printf 'All %d tests passed\n' "$TESTS_RUN"
