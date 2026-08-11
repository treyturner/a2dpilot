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
    printf 'speaker = aa:bb:cc:dd:ee:ff\n'
    printf 'speaker = 10:20:30:40:50:60\n'
  } > "$CONFIG_FILE"
  parse_config "$CONFIG_FILE"
  assert_eq "$user" "$CFG_AUDIO_USER"
  assert_eq AA:BB:CC:DD:EE:01 "$CFG_CONTROLLER"
  assert_eq 9 "$CFG_RECONNECT_INTERVAL"
  assert_eq required "$CFG_MEDIA_CONTROLS"
  assert_eq https://player.example:32500/api "$CFG_BASE_URL"
  assert_eq KEY_NEXTSONG "${CFG_MEDIA_KEYS[0]}"
  assert_eq '/next?request={command-id}' "${CFG_MEDIA_URLS[0]}"
  assert_eq KEY_PLAYPAUSE "${CFG_MEDIA_KEYS[1]}"
  assert_eq 'https://other.example/play?literal=yes' "${CFG_MEDIA_URLS[1]}"
  assert_eq AA:BB:CC:DD:EE:FF "${CFG_SPEAKERS[0]}"
  assert_eq 10:20:30:40:50:60 "${CFG_SPEAKERS[1]}"
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
  write_test_config "$CONFIG_FILE" "$user" AA:BB:CC:DD:EE:FF
  parse_config "$CONFIG_FILE"
  printf 'this is not configuration\n' > "$CONFIG_FILE"
  if parse_config "$CONFIG_FILE"; then fail 'invalid reload unexpectedly succeeded'; fi
  assert_eq "$user" "$CFG_AUDIO_USER"
  assert_eq 5 "$CFG_RECONNECT_INTERVAL"
  assert_eq http://127.0.0.1:32500 "$CFG_BASE_URL"
  assert_eq KEY_PLAYCD "${CFG_MEDIA_KEYS[0]}"
  assert_eq '/player/playback/playPause?type=music&commandID={command-id}' "${CFG_MEDIA_URLS[0]}"
  assert_eq AA:BB:CC:DD:EE:FF "${CFG_SPEAKERS[0]}"
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

  write_trigger_config "$TRIGGER_CONF" off
  assert_file_contains "$TRIGGER_CONF" 'media controls are disabled'
  assert_file_not_contains "$TRIGGER_CONF" 'KEY_NEXTSONG'

  CFG_MEDIA_KEYS=()
  CFG_MEDIA_URLS=()
  write_trigger_config "$TRIGGER_CONF" required
  assert_file_contains "$TRIGGER_CONF" 'no media-key mappings are configured'
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
  local sha=0123456789abcdef0123456789abcdef01234567 ref
  local -a valid_refs=(main feat/update_command release/v1.2.3 v1.2.3+build one@two -tag)
  local -a invalid_refs=('' '@' '/main' 'main/' 'main.' 'feat//one' 'feat/../one' \
    'feat/@{one' '.hidden' 'feat/.hidden' 'release.lock' 'feat/release.lock' 'has space' \
    'question?' 'star*' 'back\slash')
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
  printf '#!/usr/bin/env bash\n# old executable\n' > "$INSTALLED_CLI"
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
  cat > "$payload" <<'EOF'
#!/usr/bin/env bash
printf 'executed\n' >> "$UPDATE_EXECUTION_LOG"
# updated main
EOF

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
  printf '#!/usr/bin/env bash\n# updated branch\n' > "$payload"
  update_action --branch feat/update_command >/dev/null
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'https://raw.githubusercontent.com/treyturner/a2dpilot/refs/heads/feat/update_command/a2dpilot'
  printf '#!/usr/bin/env bash\n# updated tag\n' > "$payload"
  update_action --tag v1.2.3 >/dev/null
  assert_file_contains "$TEST_SCRATCH/curl.log" \
    'https://raw.githubusercontent.com/treyturner/a2dpilot/refs/tags/v1.2.3/a2dpilot'
  printf '#!/usr/bin/env bash\n# updated sha\n' > "$payload"
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

test_update_rejects_bad_candidates_and_targets() {
  local mode output rc candidate target_owner=0 parent redirected
  setup_scratch_dir
  load_app
  configure_scratch_paths
  install -d "$(dirname "$INSTALLED_CLI")"
  render_state_file "$STATE_FILE" installed
  printf '#!/usr/bin/env bash\n# old executable\n' > "$INSTALLED_CLI"
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
    esac
  }

  for mode in fail empty no-shebang invalid; do
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
  printf '#!/usr/bin/env bash\n# old executable\n' > "$INSTALLED_CLI"
  chmod 0755 "$INSTALLED_CLI"
  payload=$TEST_SCRATCH/update-payload
  printf '#!/usr/bin/env bash\n# new executable\n' > "$payload"
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

  printf '#!/usr/bin/env bash\n# old executable\n' > "$INSTALLED_CLI"
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

  printf '#!/usr/bin/env bash\n# old executable before signal\n' > "$INSTALLED_CLI"
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
  printf '#!/usr/bin/env bash\n# old executable before hangup\n' > "$INSTALLED_CLI"
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
  printf '#!/usr/bin/env bash\n# interrupted new\n' > "$INSTALLED_CLI"
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

  printf '#!/usr/bin/env bash\n# old executable before query failure\n' > "$INSTALLED_CLI"
  printf '#!/usr/bin/env bash\n# candidate before query failure\n' > "$payload"
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
  output=$(status_action)
  assert_contains "$output" 'Base URL: http://127.0.0.1:32500'
  assert_contains "$output" 'Media key mappings: 4'
}

test_pairing_provenance_and_existing_bond() {
  local user mac=AA:BB:CC:DD:EE:FF paired=0 trusted=0
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user"
  parse_config "$CONFIG_FILE"
  : > "$STATE_DIR/created-bonds"
  atomic_install_file() { cp "$1" "$2"; }
  has_tty() { return 1; }
  scan_bredr() { :; }
  configured_controller_address() { printf '12:34:56:78:9A:BC\n'; }
  device_paired() { (( paired )); }
  device_trusted() { (( trusted )); }
  wait_for_device_connection() { return 0; }
  systemctl() { :; }
  bluetoothctl() {
    printf '%s\n' "$*" >> "$TEST_SCRATCH/bluetooth.log"
    if [[ $* == *' pair '* ]]; then paired=1; trusted=1; fi
    if [[ $* == *' trust '* ]]; then trusted=1; fi
    return 0
  }

  pair_one "$mac" NoInputNoOutput
  assert_file_contains "$STATE_DIR/created-bonds" "12:34:56:78:9A:BC $mac"
  assert_file_contains "$TEST_SCRATCH/bluetooth.log" "pair $mac"
  parse_config "$CONFIG_FILE"
  assert_eq "$mac" "${CFG_SPEAKERS[0]}"

  : > "$TEST_SCRATCH/bluetooth.log"
  : > "$STATE_DIR/created-bonds"
  trusted=0
  pair_one "$mac" NoInputNoOutput
  assert_file_not_contains "$TEST_SCRATCH/bluetooth.log" "pair $mac"
  assert_file_contains "$TEST_SCRATCH/bluetooth.log" "trust $mac"
  [[ ! -s $STATE_DIR/created-bonds ]] || fail 'existing bond was recorded as A2DPilot-created'
}

test_pair_all_attempts_every_configured_speaker() {
  local user first=AA:BB:CC:DD:EE:01 second=AA:BB:CC:DD:EE:02 output rc
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_CONTROLLER=auto
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" "$first" "$second"
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
  local -a answers=(1 '')
  local answer_index=0
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_CONTROLLER=auto
  scan_bredr() { :; }
  tty_print() { :; }
  tty_read() {
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  bluetoothctl() {
    if [[ ${1:-} == devices ]]; then
      printf 'Device AA:BB:CC:DD:EE:FF Kitchen Speaker\n'
      printf 'Device 10:20:30:40:50:60 Other Device\n'
    fi
  }
  pair_one() { printf '%s %s\n' "$1" "$2" >> "$TEST_SCRATCH/selected"; }
  interactive_pair_loop KeyboardDisplay
  assert_file_contains "$TEST_SCRATCH/selected" 'AA:BB:CC:DD:EE:FF KeyboardDisplay'
  assert_eq 1 "$(wc -l < "$TEST_SCRATCH/selected")"
}

test_forget_removes_config_and_provenance() {
  local user mac=AA:BB:CC:DD:EE:FF present=1 recorded_present=1
  setup_scratch_dir
  load_app
  configure_scratch_paths
  user=$(id -un)
  write_test_config "$CONFIG_FILE" "$user" "$mac" 10:20:30:40:50:60
  printf '12:34:56:78:9A:BC %s\n' "$mac" > "$STATE_DIR/created-bonds"
  : > "$STATE_FILE"
  require_root() { :; }
  acquire_lock() { :; }
  release_lock() { :; }
  atomic_install_file() { cp "$1" "$2"; }
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
  done
}

test_codec_property_parsing() {
  local codec
  load_app
  CFG_AUDIO_USER=$(id -un)
  find_a2dp_node_id() { printf '42\n'; }
  user_wpctl() {
    printf '  * api.bluez5.codec = "ldac"\n'
  }
  codec=$(a2dp_codec AA:BB:CC:DD:EE:FF)
  assert_eq ldac "$codec"
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
    if [[ $* == *' connect '* ]]; then
      printf '%s\n' "${*: -1}" >> "$TEST_SCRATCH/connect-order"
      [[ ${*: -1} == "$second" ]]
    else
      return 0
    fi
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
  disconnect_bluetooth_device() { printf '%s\n' "$1" >> "$TEST_SCRATCH/disconnected"; }

  daemon_cycle
  assert_eq "$stale" "$(< "$TEST_SCRATCH/disconnected")"
  assert_eq "$active" "$DAEMON_ACTIVE"
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
    printf '%s %s %s\n' "$1" "$2" "$3" > "$TEST_SCRATCH/connect-command"
  }
  wait_for_health() {
    printf '%s\n' "${2:-missing}" > "$TEST_SCRATCH/health-deadline"
    return 1
  }

  daemon_cycle >/dev/null
  assert_eq "${CONNECT_TIMEOUT} connect $mac" "$(< "$TEST_SCRATCH/connect-command")"
  assert_eq "$((100 + CONNECT_TIMEOUT))" "$(< "$TEST_SCRATCH/health-deadline")"
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
    [[ $* == *' connect '* ]] && printf 'attempt\n' >> "$TEST_SCRATCH/attempts"
    return 1
  }
  daemon_cycle >/dev/null
  daemon_cycle >/dev/null
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

test_explicit_controller_scopes_device_operations() {
  local controller=12:34:56:78:9A:BC mac=AA:BB:CC:DD:EE:FF devices
  setup_scratch_dir
  load_app
  configure_scratch_paths
  CFG_CONTROLLER=$controller
  has_tty() { return 1; }
  bluetoothctl() {
    local input
    if [[ ${1:-} == list ]]; then
      printf 'Controller 00:11:22:33:44:55 First Adapter\n'
      printf 'Controller %s Selected Adapter [default]\n' "$controller"
      return 0
    fi
    input=$(cat)
    printf '%s\n---\n' "$input" >> "$TEST_SCRATCH/controller-sessions"
    case $input in
      *"info $mac"*) printf 'Device %s Test Speaker\n\tPaired: yes\n' "$mac" ;;
      *devices*) printf 'Device %s Test Speaker\n' "$mac" ;;
      *"pair $mac"*) printf 'Pairing successful\n' ;;
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
  assert_eq 4 "$(grep -Fc "select $controller" "$TEST_SCRATCH/controller-sessions")"
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
run_test 'default media-key mappings' test_default_media_key_mappings
run_test 'configuration rejection and non-evaluation' test_config_parser_rejections_and_no_eval
run_test 'invalid reload retains last valid configuration' test_invalid_reload_retains_last_valid_configuration
run_test 'config parser avoids legacy subshell helpers' test_config_parser_avoids_legacy_subshell_helpers
run_test 'media URL configuration validation' test_media_url_configuration_validation
run_test 'generated system integration files' test_generated_integration_files
run_test 'Triggerhappy config rejects symlinked parent' test_trigger_config_rejects_symlinked_parent
run_test 'non-interactive install and uninstall fixture' test_noninteractive_install_and_uninstall_fixture
run_test 'uninstall keeps packages and reports empty bond policy' test_uninstall_keeps_packages_and_reports_empty_bond_policy
run_test 'failed install rollback retains packages' test_failed_install_rollback_retains_packages
run_test 'install recovery needs no package snapshot' test_install_recovery_needs_no_package_snapshot
run_test 'update source selection and validation' test_update_source_selection_and_validation
run_test 'executable-only update transaction' test_update_executable_only_transaction
run_test 'update rejects bad candidates and targets' test_update_rejects_bad_candidates_and_targets
run_test 'update activation rollback and interruption' test_update_activation_rollback_and_interruption
run_test 'safe config editor success and validation failure' test_config_editor_success_and_validation_failure
run_test 'config editor installs a protected snapshot' test_config_editor_installs_protected_snapshot
run_test 'failed config application restores previous config' test_config_application_rolls_back
run_test 'player control resolves configured URLs' test_player_control_resolves_configured_urls
run_test 'media controls share one deadline' test_media_control_shared_deadline
run_test 'media controls use a monotonic outer bound' test_media_control_monotonic_outer_bound
run_test 'player control resolves stateful media keys' test_player_control_resolves_stateful_media_keys
run_test 'mute state rejects symlinked parent' test_mute_state_rejects_symlinked_parent
run_test 'media state rejects the wrong identity' test_media_state_rejects_wrong_identity
run_test 'status reports media URL configuration' test_status_reports_media_url_configuration
run_test 'pairing provenance and existing bonds' test_pairing_provenance_and_existing_bond
run_test 'pair --all attempts every configured speaker' test_pair_all_attempts_every_configured_speaker
run_test 'interactive scan selection' test_interactive_scan_selection
run_test 'forget removes config and provenance' test_forget_removes_config_and_provenance
run_test 'media-control health modes' test_media_control_health_modes
run_test 'optimistic codec reporting' test_codec_reporting_is_optimistic
run_test 'PipeWire codec property parsing' test_codec_property_parsing
run_test 'non-preemptive failover order' test_daemon_nonpreemption_and_failover_order
run_test 'healthy active speaker disconnects new stale connections' test_daemon_disconnects_new_stale_connection
run_test 'connection health reuses the original deadline' test_daemon_reuses_connection_deadline
run_test 'daemon cooldown and bounded backoff' test_daemon_cooldown_and_backoff
run_test 'removed active speaker is disconnected after restart' test_daemon_disconnects_removed_active_speaker
run_test 'audio-user reconciliation' test_audio_user_reconciliation
run_test 'audio-user units are unmasked before enablement' test_audio_user_units_are_unmasked_before_enablement
run_test 'user socket enablement is restored after services' test_user_unit_enablement_restores_sockets_last
run_test 'rfkill snapshot, restore, and hard blocks' test_rfkill_snapshot_restore_and_hard_block
run_test 'controller selection and power control' test_controller_selection_and_power
run_test 'explicit controller scopes device operations' test_explicit_controller_scopes_device_operations
run_test 'bond policy and removal aggregation' test_bond_policy_and_removal_aggregation
run_test 'managed path and private state safety' test_managed_paths_and_state_serialization
run_test 'system service restoration' test_system_service_state_restoration

if (( TESTS_FAILED > 0 )); then
  printf '%d of %d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN" >&2
  exit 1
fi
printf 'All %d tests passed\n' "$TESTS_RUN"
