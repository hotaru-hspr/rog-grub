#!/usr/bin/env bash
# shellcheck disable=SC2317 # Test cases intentionally override sourced functions.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${REPO_DIR}/install.sh"
PASS=0
FAIL=0

pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf 'FAIL: %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }

run_test() {
  local name=$1 rc
  shift
  set +e
  (set -euo pipefail; "$@")
  rc=$?
  set -e
  if ((rc == 0)); then pass "$name"; else fail "$name"; fi
}

source_installer() {
  # shellcheck disable=SC1090
  source "$INSTALLER"
}

cleanup_tmp() {
  rm -rf "${TEST_TMP:?}"
}

test_installer_is_sourceable() {
  source_installer
  declare -F set_theme_config >/dev/null
  declare -F unset_theme_config >/dev/null
  declare -F backup_grub_defaults >/dev/null
}

test_install_changes_only_grub_theme() {
  source_installer
  local tmp
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  mkdir -p "$THEME_DIR/min_rog"
  cat > "$GRUB_DEFAULT_FILE" <<'EOF'
GRUB_TIMEOUT=5
GRUB_THEME="/old/theme.txt"
GRUB_BACKGROUND="/keep/background.png"
GRUB_GFXMODE=1024x768
GRUB_TERMINAL_OUTPUT="console"
EOF
  chmod 0640 "$GRUB_DEFAULT_FILE"

  capture_previous_theme
  set_theme_config

  [[ $(stat -c %a "$GRUB_DEFAULT_FILE") == 640 ]]
  grep -Fx 'GRUB_THEME="'"$THEME_DIR"'/min_rog/theme.txt" # min-rog-managed' "$GRUB_DEFAULT_FILE" >/dev/null
  grep -Fx 'GRUB_BACKGROUND="/keep/background.png"' "$GRUB_DEFAULT_FILE" >/dev/null
  grep -Fx 'GRUB_GFXMODE=1024x768' "$GRUB_DEFAULT_FILE" >/dev/null
  grep -Fx 'GRUB_TERMINAL_OUTPUT="console"' "$GRUB_DEFAULT_FILE" >/dev/null
  ! grep -F '/old/theme.txt' "$GRUB_DEFAULT_FILE" >/dev/null
}

test_remove_restores_previous_theme() {
  source_installer
  local tmp
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  mkdir -p "$STATE_DIR"
  printf '%s\n' 'GRUB_THEME="/old/theme.txt"' > "$STATE_DIR/previous-theme-line"
  : > "$STATE_DIR/initialized"
  printf '%s\n' \
    'GRUB_TIMEOUT=5' \
    'GRUB_THEME="'"$THEME_DIR"'/min_rog/theme.txt" # min-rog-managed' \
    'GRUB_GFXMODE=1024x768' > "$GRUB_DEFAULT_FILE"

  unset_theme_config

  grep -Fx 'GRUB_THEME="/old/theme.txt"' "$GRUB_DEFAULT_FILE" >/dev/null
  grep -Fx 'GRUB_GFXMODE=1024x768' "$GRUB_DEFAULT_FILE" >/dev/null
  ! grep -F 'min_rog/theme.txt' "$GRUB_DEFAULT_FILE" >/dev/null
}

test_remove_preserves_foreign_active_theme() {
  source_installer
  local tmp before after
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  mkdir -p "$STATE_DIR"
  printf '%s\n' 'GRUB_THEME="/old/theme.txt"' > "$STATE_DIR/previous-theme-line"
  : > "$STATE_DIR/initialized"
  printf '%s\n' 'GRUB_THEME="/new/foreign-theme.txt"' > "$GRUB_DEFAULT_FILE"
  before=$(sha256sum "$GRUB_DEFAULT_FILE")

  if unset_theme_config; then
    return 1
  else
    [[ $? -eq 3 ]]
  fi

  after=$(sha256sum "$GRUB_DEFAULT_FILE")
  [[ "$before" == "$after" ]]
}

test_remove_preserves_foreign_theme_with_managed_path_in_comment() {
  source_installer
  local tmp before after
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  mkdir -p "$STATE_DIR"
  printf '%s\n' 'GRUB_THEME="/old/theme.txt"' > "$STATE_DIR/previous-theme-line"
  : > "$STATE_DIR/initialized"
  printf 'GRUB_THEME="/new/foreign-theme.txt" # old value: %s/min_rog/theme.txt\n' "$THEME_DIR" > "$GRUB_DEFAULT_FILE"
  before=$(sha256sum "$GRUB_DEFAULT_FILE")

  if unset_theme_config; then
    return 1
  else
    [[ $? -eq 3 ]]
  fi

  after=$(sha256sum "$GRUB_DEFAULT_FILE")
  [[ "$before" == "$after" ]]
}

test_remove_preserves_foreign_theme_with_managed_prefix() {
  source_installer
  local tmp before after
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  mkdir -p "$STATE_DIR"
  printf '%s\n' 'GRUB_THEME="/old/theme.txt"' > "$STATE_DIR/previous-theme-line"
  : > "$STATE_DIR/initialized"
  printf 'GRUB_THEME="%s/min_rog/theme.txt"foreign-suffix\n' "$THEME_DIR" > "$GRUB_DEFAULT_FILE"
  before=$(sha256sum "$GRUB_DEFAULT_FILE")

  if unset_theme_config; then
    return 1
  else
    [[ $? -eq 3 ]]
  fi

  after=$(sha256sum "$GRUB_DEFAULT_FILE")
  [[ "$before" == "$after" ]]
}

test_remove_preserves_adjacent_hash_in_assignment_value() {
  source_installer
  local tmp before after
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  mkdir -p "$STATE_DIR"
  printf '%s\n' 'GRUB_THEME="/old/theme.txt"' > "$STATE_DIR/previous-theme-line"
  : > "$STATE_DIR/initialized"
  printf 'GRUB_THEME="%s/min_rog/theme.txt"#foreign-suffix\n' "$THEME_DIR" > "$GRUB_DEFAULT_FILE"
  before=$(sha256sum "$GRUB_DEFAULT_FILE")

  if unset_theme_config; then
    return 1
  else
    [[ $? -eq 3 ]]
  fi

  after=$(sha256sum "$GRUB_DEFAULT_FILE")
  [[ "$before" == "$after" ]]
}

test_backups_are_unique_and_preserve_content() {
  source_installer
  local tmp first second
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  printf '%s\n' 'ORIGINAL' > "$GRUB_DEFAULT_FILE"

  first=$(backup_grub_defaults)
  second=$(backup_grub_defaults)

  [[ "$first" != "$second" ]]
  [[ $(<"$first") == ORIGINAL ]]
  [[ $(<"$second") == ORIGINAL ]]
}

test_generate_stages_and_replaces_existing_theme() {
  source_installer
  local tmp
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  THEME_DIR="$tmp/themes"
  mkdir -p "$THEME_DIR/min_rog"
  printf 'stale\n' > "$THEME_DIR/min_rog/sentinel"

  generate 4k

  [[ ! -e "$THEME_DIR/min_rog/sentinel" ]]
  [[ -f "$THEME_DIR/min_rog/theme.txt" ]]
  [[ -f "$THEME_DIR/min_rog/background.png" ]]
  [[ -d "$THEME_DIR/min_rog/icons" ]]
  ! compgen -G "$THEME_DIR/.min_rog.*" >/dev/null
}

test_generate_preserves_existing_theme_when_staging_fails() {
  source_installer
  local tmp
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  REPO_DIR="$tmp/incomplete-repo"
  THEME_DIR="$tmp/themes"
  mkdir -p \
    "$THEME_DIR/min_rog" \
    "$REPO_DIR/assets/assets-white/icons-1080p" \
    "$REPO_DIR/assets/assets-select/select-1080p"
  printf 'stale\n' > "$THEME_DIR/min_rog/sentinel"
  : > "$REPO_DIR/assets/assets-white/icons-1080p/linux.png"
  : > "$REPO_DIR/assets/assets-select/select-1080p/select_c.png"
  : > "$REPO_DIR/assets/info-1080p.png"

  if generate 1080p; then
    return 1
  fi

  [[ -f "$THEME_DIR/min_rog/sentinel" ]]
  ! compgen -G "$THEME_DIR/.min_rog.*" >/dev/null
}

test_remove_action_tolerates_foreign_active_theme() {
  source_installer
  local tmp before after
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  mkdir -p "$STATE_DIR" "$THEME_DIR/min_rog"
  printf '%s\n' 'GRUB_THEME="/new/foreign-theme.txt"' > "$GRUB_DEFAULT_FILE"
  before=$(sha256sum "$GRUB_DEFAULT_FILE")
  require_root() { :; }
  validate_grub_configuration() { return 99; }
  updating_grub() { return 99; }

  remove_theme

  after=$(sha256sum "$GRUB_DEFAULT_FILE")
  [[ "$before" == "$after" ]]
  [[ ! -e "$THEME_DIR/min_rog" ]]
}

test_failed_update_restores_grub_defaults() {
  source_installer
  local tmp before after
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  printf '%s\n' 'GRUB_THEME="/old/theme.txt"' 'GRUB_TIMEOUT=5' > "$GRUB_DEFAULT_FILE"
  before=$(sha256sum "$GRUB_DEFAULT_FILE")
  require_root() { :; }
  generate() { mkdir -p "$THEME_DIR/min_rog"; : > "$THEME_DIR/min_rog/theme.txt"; }
  validate_grub_configuration() { return 0; }
  updating_grub() { return 1; }

  if (install_theme 1080p); then
    return 1
  fi

  after=$(sha256sum "$GRUB_DEFAULT_FILE")
  [[ "$before" == "$after" ]]
  [[ ! -e "$THEME_DIR/min_rog" ]]
  [[ ! -e "$STATE_DIR/initialized" ]]
  [[ ! -e "$STATE_DIR/installed-theme-dir" ]]
}

test_missing_grub_generator_restores_defaults() {
  source_installer
  local tmp before after
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  printf '%s\n' 'GRUB_THEME="/old/theme.txt"' 'GRUB_TIMEOUT=5' > "$GRUB_DEFAULT_FILE"
  before=$(sha256sum "$GRUB_DEFAULT_FILE")
  require_root() { :; }
  generate() { mkdir -p "$THEME_DIR/min_rog"; : > "$THEME_DIR/min_rog/theme.txt"; }
  grub_mkconfig_command() { return 1; }

  if (install_theme 1080p); then
    return 1
  fi

  after=$(sha256sum "$GRUB_DEFAULT_FILE")
  [[ "$before" == "$after" ]]
  [[ ! -e "$THEME_DIR/min_rog" ]]
}

test_failed_reinstall_restores_previous_assets() {
  source_installer
  local tmp old_theme_dir
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  old_theme_dir="$tmp/old-themes"
  THEME_DIR="$tmp/new-themes"
  mkdir -p "$old_theme_dir/min_rog" "$STATE_DIR"
  printf 'old-assets\n' > "$old_theme_dir/min_rog/sentinel"
  printf '%s\n' 'GRUB_THEME="'"$old_theme_dir"'/min_rog/theme.txt" # min-rog-managed' > "$GRUB_DEFAULT_FILE"
  : > "$STATE_DIR/initialized"
  : > "$STATE_DIR/previous-theme-line"
  printf '%s\n' "$old_theme_dir" > "$STATE_DIR/installed-theme-dir"
  require_root() { :; }
  generate() { mkdir -p "$THEME_DIR/min_rog"; printf 'new-assets\n' > "$THEME_DIR/min_rog/new"; }
  validate_grub_configuration() { return 0; }
  updating_grub() { return 1; }

  if (install_theme 1080p); then
    return 1
  fi

  [[ -f "$old_theme_dir/min_rog/sentinel" ]]
  [[ ! -e "$THEME_DIR/min_rog/new" ]]
  [[ -e "$STATE_DIR/initialized" ]]
  [[ $(<"$STATE_DIR/installed-theme-dir") == "$old_theme_dir" ]]
}

test_asset_rollback_allocation_failure_cleans_new_state() {
  source_installer
  local tmp real_mktemp
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  real_mktemp=$(command -v mktemp)
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  THEME_DIR="$tmp/themes"
  mkdir -p "$THEME_DIR/min_rog"
  printf 'existing-assets\n' > "$THEME_DIR/min_rog/sentinel"
  printf '%s\n' 'GRUB_THEME="/old/theme.txt"' > "$GRUB_DEFAULT_FILE"
  require_root() { :; }
  mktemp() {
    if [[ "$*" == *'.theme-rollback.'* ]]; then
      return 1
    fi
    command "$real_mktemp" "$@"
  }

  if (install_theme 1080p); then
    return 1
  fi

  [[ -f "$THEME_DIR/min_rog/sentinel" ]]
  [[ ! -e "$STATE_DIR/initialized" ]]
  [[ ! -e "$STATE_DIR/previous-theme-line" ]]
}

test_remove_uses_recorded_install_directory() {
  source_installer
  local tmp recorded default_dir
  tmp=$(mktemp -d)
  TEST_TMP=$tmp
  trap cleanup_tmp EXIT
  GRUB_DEFAULT_FILE="$tmp/grub"
  STATE_DIR="$tmp/state"
  default_dir="$tmp/default-themes"
  recorded="$tmp/boot-themes"
  THEME_DIR="$default_dir"
  mkdir -p "$STATE_DIR" "$recorded/min_rog"
  printf '%s\n' "$recorded" > "$STATE_DIR/installed-theme-dir"
  printf '%s\n' 'GRUB_THEME="'"$recorded"'/min_rog/theme.txt" # min-rog-managed' > "$GRUB_DEFAULT_FILE"
  : > "$STATE_DIR/previous-theme-line"
  : > "$STATE_DIR/initialized"
  require_root() { :; }
  validate_grub_configuration() { return 0; }
  updating_grub() { return 0; }

  remove_theme

  [[ ! -e "$recorded/min_rog" ]]
  ! grep -F 'min_rog/theme.txt' "$GRUB_DEFAULT_FILE" >/dev/null
}

test_no_password_capture_or_package_install() {
  ! grep -Eq 'sudo[[:space:]]+-S|passwordbox|Specify the root password|apt-get install|dnf install|pacman -S|zypper in' "$INSTALLER"
}

run_test 'installer can be sourced without executing main' test_installer_is_sourceable
run_test 'install changes only GRUB_THEME' test_install_changes_only_grub_theme
run_test 'remove restores the previous theme' test_remove_restores_previous_theme
run_test 'remove preserves a foreign active theme' test_remove_preserves_foreign_active_theme
run_test 'remove ignores managed paths mentioned only in comments' test_remove_preserves_foreign_theme_with_managed_path_in_comment
run_test 'remove preserves assignments that only prefix-match the managed path' test_remove_preserves_foreign_theme_with_managed_prefix
run_test 'remove preserves adjacent hashes that are part of the assignment value' test_remove_preserves_adjacent_hash_in_assignment_value
run_test 'backups are unique and preserve content' test_backups_are_unique_and_preserve_content
run_test 'generate stages and replaces an existing theme' test_generate_stages_and_replaces_existing_theme
run_test 'generate preserves the old theme when staging fails' test_generate_preserves_existing_theme_when_staging_fails
run_test 'remove action tolerates a foreign active theme' test_remove_action_tolerates_foreign_active_theme
run_test 'failed GRUB update restores defaults' test_failed_update_restores_grub_defaults
run_test 'missing GRUB generator restores defaults' test_missing_grub_generator_restores_defaults
run_test 'failed reinstall restores previous assets' test_failed_reinstall_restores_previous_assets
run_test 'asset rollback allocation failure cleans new state' test_asset_rollback_allocation_failure_cleans_new_state
run_test 'remove uses the recorded install directory' test_remove_uses_recorded_install_directory
run_test 'installer does not capture passwords or install packages' test_no_password_capture_or_package_install

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
