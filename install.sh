#!/usr/bin/env bash
# Minimal ROG theme installer for GRUB/GRUB2.
# Based on GRUB2 themes by vinceliuice.

set -Eeuo pipefail

ROOT_UID=0
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THEME_DIR="${THEME_DIR:-/usr/share/grub/themes}"
STATE_DIR="${STATE_DIR:-/var/lib/min-rog-grub}"
GRUB_DEFAULT_FILE="${GRUB_DEFAULT_FILE:-/etc/default/grub}"
MANAGED_MARKER="# min-rog-managed"
SCREEN_VARIANTS=(1080p 2k 4k ultrawide ultrawide2k)

info() { printf 'INFO: %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

has_command() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
Usage:
  sudo ./install.sh --screen <1080p|2k|4k|ultrawide|ultrawide2k> [--boot]
  sudo ./install.sh --remove
  ./install.sh --generate <directory> --screen <variant>

Options:
  -s, --screen VARIANT   Screen-resolution variant (default: 1080p)
  -r, --remove           Remove this theme and restore the previous theme line
  -g, --generate DIR     Generate runtime assets under DIR without changing GRUB
  -b, --boot             Install assets below /boot/grub[/2]/themes
  -h, --help             Show this help

The privileged install changes only GRUB_THEME. It does not alter the background,
graphics mode, terminal mode, EFI boot entries, or partition layout.
EOF
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq $ROOT_UID ]] ||
    die "Run the install/remove action with sudo; this script will not request a password itself."
}

validate_screen() {
  local requested=$1 variant
  for variant in "${SCREEN_VARIANTS[@]}"; do
    [[ "$requested" == "$variant" ]] && return 0
  done
  die "Unsupported screen variant: $requested"
}

backup_grub_defaults() {
  [[ -f "$GRUB_DEFAULT_FILE" ]] || die "Cannot find GRUB defaults: $GRUB_DEFAULT_FILE"
  install -d -m 0700 "$STATE_DIR/backups"
  local backup
  backup=$(mktemp "$STATE_DIR/backups/grub.XXXXXX")
  cp -a --no-target-directory "$GRUB_DEFAULT_FILE" "$backup"
  printf '%s\n' "$backup"
}

write_recorded_theme_dir() {
  local value=$1 tmp
  install -d -m 0700 "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/.installed-theme-dir.XXXXXX")
  printf '%s\n' "$value" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$STATE_DIR/installed-theme-dir"
}

record_theme_dir() {
  write_recorded_theme_dir "$THEME_DIR"
}

load_recorded_theme_dir() {
  [[ -f "$STATE_DIR/installed-theme-dir" ]] || return 0
  local recorded
  recorded=$(<"$STATE_DIR/installed-theme-dir")
  [[ "$recorded" == /* ]] || die "Recorded theme directory is not an absolute path: $recorded"
  THEME_DIR=$recorded
}

capture_previous_theme() {
  [[ -f "$GRUB_DEFAULT_FILE" ]] || die "Cannot find GRUB defaults: $GRUB_DEFAULT_FILE"
  install -d -m 0700 "$STATE_DIR"
  [[ -e "$STATE_DIR/initialized" ]] && return 0

  local previous tmp
  previous=$(awk '/^[[:space:]]*GRUB_THEME[[:space:]]*=/{line=$0} END{if (line) print line}' "$GRUB_DEFAULT_FILE")
  tmp=$(mktemp "$STATE_DIR/.previous-theme-line.XXXXXX")
  printf '%s\n' "$previous" > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$STATE_DIR/previous-theme-line"
  : > "$STATE_DIR/initialized"
  chmod 0600 "$STATE_DIR/initialized"
}

replace_from_awk() {
  local destination=$1
  shift
  local tmp
  tmp=$(mktemp "$(dirname "$destination")/.grub.XXXXXX")
  if ! cp --attributes-only --preserve=all --no-target-directory "$destination" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! awk "$@" "$destination" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$destination"
}

set_theme_config() {
  local theme_path="${THEME_DIR}/min_rog/theme.txt"
  local managed_line="GRUB_THEME=\"${theme_path}\" ${MANAGED_MARKER}"
  replace_from_awk "$GRUB_DEFAULT_FILE" -v managed="$managed_line" '
    BEGIN { written=0 }
    /^[[:space:]]*GRUB_THEME[[:space:]]*=/ {
      if (!written) { print managed; written=1 }
      next
    }
    { print }
    END { if (!written) print managed }
  '
}

unset_theme_config() {
  local theme_path="${THEME_DIR}/min_rog/theme.txt"
  local previous=""
  [[ -f "$STATE_DIR/previous-theme-line" ]] && previous=$(<"$STATE_DIR/previous-theme-line")

  if ! awk -v path="$theme_path" '
      function theme_value(line, value, body, end, rest, result) {
        value=line
        sub(/^[[:space:]]*GRUB_THEME[[:space:]]*=[[:space:]]*/, "", value)
        if (substr(value, 1, 1) == "\"") {
          body=substr(value, 2)
          end=index(body, "\"")
          if (!end) return "__MIN_ROG_INVALID__"
          result=substr(body, 1, end - 1)
          rest=substr(body, end + 1)
        } else if (substr(value, 1, 1) == "\047") {
          body=substr(value, 2)
          end=index(body, "\047")
          if (!end) return "__MIN_ROG_INVALID__"
          result=substr(body, 1, end - 1)
          rest=substr(body, end + 1)
        } else {
          result=value
          sub(/[[:space:]].*/, "", result)
          rest=substr(value, length(result) + 1)
        }
        if (rest != "" && rest !~ /^[[:space:]]*$/ && rest !~ /^[[:space:]]+#/) return "__MIN_ROG_INVALID__"
        return result
      }
      /^[[:space:]]*GRUB_THEME[[:space:]]*=/ && theme_value($0) == path { found=1 }
      END { exit(found ? 0 : 1) }
    ' "$GRUB_DEFAULT_FILE"; then
    warn "The active GRUB theme is not managed by min-rog; leaving GRUB defaults unchanged."
    return 3
  fi

  local foreign_present=false
  if awk -v path="$theme_path" '
      function theme_value(line, value, body, end, rest, result) {
        value=line
        sub(/^[[:space:]]*GRUB_THEME[[:space:]]*=[[:space:]]*/, "", value)
        if (substr(value, 1, 1) == "\"") {
          body=substr(value, 2)
          end=index(body, "\"")
          if (!end) return "__MIN_ROG_INVALID__"
          result=substr(body, 1, end - 1)
          rest=substr(body, end + 1)
        } else if (substr(value, 1, 1) == "\047") {
          body=substr(value, 2)
          end=index(body, "\047")
          if (!end) return "__MIN_ROG_INVALID__"
          result=substr(body, 1, end - 1)
          rest=substr(body, end + 1)
        } else {
          result=value
          sub(/[[:space:]].*/, "", result)
          rest=substr(value, length(result) + 1)
        }
        if (rest != "" && rest !~ /^[[:space:]]*$/ && rest !~ /^[[:space:]]+#/) return "__MIN_ROG_INVALID__"
        return result
      }
      /^[[:space:]]*GRUB_THEME[[:space:]]*=/ && theme_value($0) != path { found=1 }
      END { exit(found ? 0 : 1) }
    ' "$GRUB_DEFAULT_FILE"; then
    foreign_present=true
  fi

  replace_from_awk "$GRUB_DEFAULT_FILE" \
    -v path="$theme_path" \
    -v previous="$previous" \
    -v foreign="$foreign_present" '
      function theme_value(line, value, body, end, rest, result) {
        value=line
        sub(/^[[:space:]]*GRUB_THEME[[:space:]]*=[[:space:]]*/, "", value)
        if (substr(value, 1, 1) == "\"") {
          body=substr(value, 2)
          end=index(body, "\"")
          if (!end) return "__MIN_ROG_INVALID__"
          result=substr(body, 1, end - 1)
          rest=substr(body, end + 1)
        } else if (substr(value, 1, 1) == "\047") {
          body=substr(value, 2)
          end=index(body, "\047")
          if (!end) return "__MIN_ROG_INVALID__"
          result=substr(body, 1, end - 1)
          rest=substr(body, end + 1)
        } else {
          result=value
          sub(/[[:space:]].*/, "", result)
          rest=substr(value, length(result) + 1)
        }
        if (rest != "" && rest !~ /^[[:space:]]*$/ && rest !~ /^[[:space:]]+#/) return "__MIN_ROG_INVALID__"
        return result
      }
      BEGIN { restored=0 }
      /^[[:space:]]*GRUB_THEME[[:space:]]*=/ && theme_value($0) == path {
        if (!restored && foreign != "true" && previous != "") {
          print previous
          restored=1
        }
        next
      }
      { print }
    '
}

populate_theme_directory() {
  local destination=$1 screen=$2
  cp -a --no-preserve=ownership "$REPO_DIR/common/"{*.png,*.pf2} "$destination" || return 1
  cp -a --no-preserve=ownership "$REPO_DIR/config/theme-${screen}.txt" "$destination/theme.txt" || return 1
  cp -a --no-preserve=ownership "$REPO_DIR/backgrounds/${screen}.png" "$destination/background.png" || return 1

  local asset_size=$screen
  if [[ "$screen" == ultrawide ]]; then
    asset_size=1080p
  elif [[ "$screen" == ultrawide2k ]]; then
    asset_size=2k
  fi

  cp -a --no-preserve=ownership "$REPO_DIR/assets/assets-white/icons-${asset_size}" "$destination/icons" || return 1
  cp -a --no-preserve=ownership "$REPO_DIR/assets/assets-select/select-${asset_size}/"*.png "$destination" || return 1
  cp -a --no-preserve=ownership "$REPO_DIR/assets/info-${asset_size}.png" "$destination/info.png" || return 1
}

generate() {
  local screen=$1
  validate_screen "$screen"
  install -d "$THEME_DIR" || return 1

  local target="$THEME_DIR/min_rog" staging old=""
  if ! staging=$(mktemp -d "$THEME_DIR/.min_rog.new.XXXXXX"); then
    return 1
  fi
  if ! populate_theme_directory "$staging" "$screen"; then
    rm -rf "$staging"
    return 1
  fi

  if [[ -e "$target" || -L "$target" ]]; then
    if ! old=$(mktemp -d "$THEME_DIR/.min_rog.old.XXXXXX"); then
      rm -rf "$staging"
      return 1
    fi
    if ! rmdir "$old" || ! mv "$target" "$old"; then
      rm -rf "$staging" "$old"
      return 1
    fi
  fi

  if ! mv "$staging" "$target"; then
    [[ -n "$old" ]] && mv "$old" "$target"
    rm -rf "$staging"
    return 1
  fi
  [[ -n "$old" ]] && rm -rf "$old"
  info "Generated $screen theme at $target"
}

grub_mkconfig_command() {
  if has_command grub-mkconfig; then
    printf '%s\n' grub-mkconfig
  elif has_command grub2-mkconfig; then
    printf '%s\n' grub2-mkconfig
  else
    return 1
  fi
}

validate_grub_configuration() {
  local generator candidate checker=""
  if ! generator=$(grub_mkconfig_command); then
    warn "Neither grub-mkconfig nor grub2-mkconfig is available."
    return 1
  fi
  if ! candidate=$(mktemp); then
    return 1
  fi
  if ! "$generator" -o "$candidate"; then
    rm -f "$candidate"
    return 1
  fi
  if has_command grub-script-check; then
    checker=grub-script-check
  elif has_command grub2-script-check; then
    checker=grub2-script-check
  fi
  if [[ -n "$checker" ]] && ! "$checker" "$candidate"; then
    rm -f "$candidate"
    return 1
  fi
  [[ -s "$candidate" ]] || { rm -f "$candidate"; return 1; }
  rm -f "$candidate"
}

updating_grub() {
  if has_command update-grub; then
    update-grub
  elif has_command grub-mkconfig && [[ -d /boot/grub ]]; then
    grub-mkconfig -o /boot/grub/grub.cfg
  elif has_command grub2-mkconfig && [[ -d /boot/grub2 ]]; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
  else
    warn "No supported GRUB update command and output directory found."
    return 1
  fi
}

restore_grub_defaults() {
  local backup=$1
  cp -a --no-target-directory "$backup" "$GRUB_DEFAULT_FILE"
}

rollback_install_transaction() {
  local target=$1 asset_backup=$2 had_state=$3 had_recorded_dir=$4 previous_recorded_dir=$5
  rm -rf "$target"
  if [[ -n "$asset_backup" && -e "$asset_backup" ]]; then
    mv "$asset_backup" "$target"
  fi
  if [[ "$had_state" == false ]]; then
    rm -f "$STATE_DIR/initialized" "$STATE_DIR/previous-theme-line" "$STATE_DIR/installed-theme-dir"
  elif [[ "$had_recorded_dir" == true ]]; then
    write_recorded_theme_dir "$previous_recorded_dir"
  else
    rm -f "$STATE_DIR/installed-theme-dir"
  fi
}

install_theme() {
  local screen=$1 backup target asset_backup="" had_state=false
  local had_recorded_dir=false previous_recorded_dir=""
  require_root
  backup=$(backup_grub_defaults)
  [[ -e "$STATE_DIR/initialized" ]] && had_state=true
  if [[ -f "$STATE_DIR/installed-theme-dir" ]]; then
    had_recorded_dir=true
    previous_recorded_dir=$(<"$STATE_DIR/installed-theme-dir")
  fi
  capture_previous_theme

  target="$THEME_DIR/min_rog"
  if [[ -e "$target" || -L "$target" ]]; then
    install -d -m 0700 "$STATE_DIR" || die "Cannot create state directory: $STATE_DIR"
    if ! asset_backup=$(mktemp -d "$STATE_DIR/.theme-rollback.XXXXXX"); then
      if [[ "$had_state" == false ]]; then
        rm -f "$STATE_DIR/initialized" "$STATE_DIR/previous-theme-line" "$STATE_DIR/installed-theme-dir"
      fi
      die "Cannot allocate an asset rollback directory."
    fi
    if ! rmdir "$asset_backup" || ! mv "$target" "$asset_backup"; then
      rm -rf "$asset_backup"
      if [[ "$had_state" == false ]]; then
        rm -f "$STATE_DIR/initialized" "$STATE_DIR/previous-theme-line" "$STATE_DIR/installed-theme-dir"
      fi
      die "Cannot move the existing theme into the rollback directory."
    fi
  fi

  if ! generate "$screen"; then
    rollback_install_transaction "$target" "$asset_backup" "$had_state" "$had_recorded_dir" "$previous_recorded_dir"
    die "Theme asset staging failed; restored the previous installation."
  fi
  if ! record_theme_dir || ! set_theme_config; then
    restore_grub_defaults "$backup"
    rollback_install_transaction "$target" "$asset_backup" "$had_state" "$had_recorded_dir" "$previous_recorded_dir"
    die "Failed to record the installation; restored previous configuration and assets."
  fi

  if ! validate_grub_configuration; then
    restore_grub_defaults "$backup"
    rollback_install_transaction "$target" "$asset_backup" "$had_state" "$had_recorded_dir" "$previous_recorded_dir"
    die "Candidate GRUB configuration failed validation; restored previous configuration and assets."
  fi
  if ! updating_grub; then
    restore_grub_defaults "$backup"
    rollback_install_transaction "$target" "$asset_backup" "$had_state" "$had_recorded_dir" "$previous_recorded_dir"
    updating_grub || true
    die "GRUB update failed; restored defaults and assets from the rollback snapshots."
  fi
  [[ -n "$asset_backup" ]] && rm -rf "$asset_backup"
  info "Installed Minimal ROG theme. Rollback snapshot: $backup"
}

remove_theme() {
  require_root
  load_recorded_theme_dir
  local backup changed=true
  backup=$(backup_grub_defaults)

  if unset_theme_config; then
    changed=true
  else
    local rc=$?
    if [[ $rc -eq 3 ]]; then
      changed=false
    else
      die "Failed to update $GRUB_DEFAULT_FILE"
    fi
  fi

  if [[ "$changed" == true ]]; then
    if ! validate_grub_configuration; then
      restore_grub_defaults "$backup"
      die "Candidate GRUB configuration failed validation; restored $GRUB_DEFAULT_FILE."
    fi
    if ! updating_grub; then
      restore_grub_defaults "$backup"
      updating_grub || true
      die "GRUB update failed; restored defaults from $backup and attempted regeneration."
    fi
  fi

  rm -rf "$THEME_DIR/min_rog"
  rm -f "$STATE_DIR/initialized" "$STATE_DIR/previous-theme-line" "$STATE_DIR/installed-theme-dir"
  info "Removed Minimal ROG theme. Rollback snapshot: $backup"
}

main() {
  local action=install screen=1080p generate_dir="" install_boot=false

  while (($#)); do
    case "$1" in
      -s|--screen)
        (($# >= 2)) || die "$1 requires a screen variant"
        screen=$2
        shift 2
        ;;
      -r|--remove)
        action=remove
        shift
        ;;
      -g|--generate)
        (($# >= 2)) || die "$1 requires a destination directory"
        action=generate
        generate_dir=$2
        shift 2
        ;;
      -b|--boot)
        install_boot=true
        shift
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        die "Unrecognized option: $1"
        ;;
    esac
  done

  validate_screen "$screen"

  if [[ "$install_boot" == true ]]; then
    if [[ -d /boot/grub2 ]]; then
      THEME_DIR=/boot/grub2/themes
    elif [[ -d /boot/grub ]]; then
      THEME_DIR=/boot/grub/themes
    else
      die "Cannot find /boot/grub or /boot/grub2"
    fi
  fi

  case "$action" in
    install) install_theme "$screen" ;;
    remove) remove_theme ;;
    generate)
      [[ -n "$generate_dir" ]] || die "Generate destination is empty"
      THEME_DIR=$generate_dir
      generate "$screen"
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
