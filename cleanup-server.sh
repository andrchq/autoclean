#!/usr/bin/env bash
# shellcheck shell=bash
#
# Server cleanup utility.  Review before executing remotely:
#   curl -fsSL https://raw.githubusercontent.com/<OWNER>/<REPO>/<TAG>/cleanup-server.sh \
#     | sudo bash -s -- --yes
#
# Default mode is a dry-run.  Actions that can affect deployments need an
# explicit flag; see --help.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly VERSION="1.1.3"

# An invocation without arguments opens the wizard when a controlling terminal
# is available.  It also works with `curl ... | sudo bash`, where stdin is the
# script itself, because the wizard reads keys from /dev/tty.
ORIGINAL_ARG_COUNT=$#
INTERACTIVE_MODE=false
AUDIT_ONLY=false

# ANSI is enabled only on an interactive terminal.
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  RED=$'\033[38;5;203m'; GREEN=$'\033[38;5;42m'; YELLOW=$'\033[38;5;220m'
  BLUE=$'\033[38;5;75m'; CYAN=$'\033[38;5;81m'; MAGENTA=$'\033[1;35m'; GRAY=$'\033[38;5;245m'
  HEADER=$'\033[1;97;48;5;24m'
else
  RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; GRAY=''; HEADER=''
fi

# Defaults
DRY_RUN=true
TMP_AGE_DAYS=7
JOURNAL_MAX_AGE='7d'
ROTATED_LOG_AGE_DAYS=14
MIN_LARGE_SIZE='500M'
LARGE_FILE_LIMIT=30
WITH_DOCKER=false
WITH_DOCKER_VOLUMES=false
WITH_AUTOREMOVE=false
WITH_TRUNCATE_LOGS=false
ACTIVE_LOG_MIN_SIZE='100M'

# The five conservative actions are enabled by default.  The interactive
# wizard changes these switches before a cleanup starts.
CLEAN_PACKAGE_CACHE=true
CLEAN_JOURNAL=true
CLEAN_CRASH_DUMPS=true
CLEAN_TMP=true
CLEAN_ROTATED_LOGS=true

declare -i ACTIONS_PLANNED=0
declare -i ACTIONS_DONE=0
declare -i WARNINGS=0
declare -i EXIT_STATUS=0
LAST_OPERATION=''
LAST_OPERATION_DETAILS=''
UI_CLEANUP_RUNNING=false
CLEANUP_STARTED_AT=0
CLEANUP_ERROR_LOG=''
declare -a FAILED_ACTIONS=()
declare -a CLEANUP_NOTES=()

say()       { printf '%b\n' "$*"; }
title()     { "$UI_CLEANUP_RUNNING" || say "\n${BLUE}${BOLD}==> $*${RESET}"; }
ok()        { "$UI_CLEANUP_RUNNING" || say "${GREEN}✓${RESET} $*"; }
warn()      {
  ((WARNINGS+=1))
  if "$UI_CLEANUP_RUNNING"; then
    CLEANUP_NOTES+=("$*")
  else
    say "${YELLOW}!${RESET} $*"
  fi
}
fail()      { EXIT_STATUS=1; say "${RED}✗${RESET} $*" >&2; }
note()      {
  if "$UI_CLEANUP_RUNNING"; then
    CLEANUP_NOTES+=("$*")
  else
    say "${GRAY}$*${RESET}"
  fi
}
would_do()  { ((ACTIONS_PLANNED+=1)); say "${GRAY}dry-run:${RESET} $*"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
${SCRIPT_NAME} ${VERSION} — безопасная очистка Linux-сервера

Использование:
  sudo bash ${SCRIPT_NAME} [options]

По умолчанию включён dry-run: скрипт ничего не меняет.

Основные опции:
  --yes                         выполнить выбранные операции
  --dry-run                     только показать план (по умолчанию)
  --audit                       просканировать кандидаты на очистку без изменений
  --tmp-age-days DAYS           удалить /tmp и /var/tmp старше DAYS (7)
  --journal-max-age AGE         оставить systemd journal не старше AGE (7d)
  --rotated-log-age-days DAYS   удалить ротации в /var/log старше DAYS (14)
  --min-large-size SIZE         показать файлы больше SIZE (500M)
  --large-file-limit N          максимум строк в отчёте о крупных файлах (30)

Опции, требующие явного согласия:
  --docker                      удалить stopped containers, dangling images,
                                unused networks и build cache
  --docker-volumes              вместе с --docker удалить неиспользуемые volumes
  --autoremove                  удалить неиспользуемые пакеты (apt/dnf/yum)
  --truncate-logs               обнулить активные *.log в /var/log, если они
                                больше --active-log-min-size
  --active-log-min-size SIZE    порог для --truncate-logs (100M)

Примеры:
  sudo bash ${SCRIPT_NAME}
  sudo bash ${SCRIPT_NAME} --audit
  sudo bash ${SCRIPT_NAME} --yes
  sudo bash ${SCRIPT_NAME} --yes --docker
  sudo bash ${SCRIPT_NAME} --yes --docker --docker-volumes --autoremove

Важно: отчёт о крупных файлах ничего не удаляет. Скрипт не трогает /home,
данные приложений, Docker volumes без отдельного флага и активные логи без
--truncate-logs.
EOF
}

require_value() {
  local option="$1" value="${2:-}"
  if [[ -z "$value" || "$value" == --* ]]; then
    fail "Для ${option} нужно значение. Используйте --help."
    exit 2
  fi
}

validate_positive_integer() {
  local option="$1" value="$2"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    fail "${option} должно быть положительным целым числом, получено: ${value}"
    exit 2
  fi
}

validate_size() {
  local option="$1" value="$2"
  # GNU find accepts 100M, 1G, 2048k. This deliberately rejects bare values.
  if ! [[ "$value" =~ ^[1-9][0-9]*[kKMGT]$ ]]; then
    fail "${option} ожидает размер вида 500M, 1G или 2048k, получено: ${value}"
    exit 2
  fi
}

validate_journal_age() {
  local value="$1"
  if ! [[ "$value" =~ ^[1-9][0-9]*[smhdw]$ ]]; then
    fail "--journal-max-age ожидает значение вида 12h, 7d или 2w, получено: ${value}"
    exit 2
  fi
}

while (($#)); do
  case "$1" in
    --yes) DRY_RUN=false ;;
    --dry-run) DRY_RUN=true ;;
    --audit) AUDIT_ONLY=true; DRY_RUN=true ;;
    --docker) WITH_DOCKER=true ;;
    --docker-volumes) WITH_DOCKER_VOLUMES=true ;;
    --autoremove) WITH_AUTOREMOVE=true ;;
    --truncate-logs) WITH_TRUNCATE_LOGS=true ;;
    --tmp-age-days)
      require_value "$1" "${2:-}"; TMP_AGE_DAYS="$2"; validate_positive_integer "$1" "$2"; shift ;;
    --journal-max-age)
      require_value "$1" "${2:-}"; JOURNAL_MAX_AGE="$2"; validate_journal_age "$2"; shift ;;
    --rotated-log-age-days)
      require_value "$1" "${2:-}"; ROTATED_LOG_AGE_DAYS="$2"; validate_positive_integer "$1" "$2"; shift ;;
    --min-large-size)
      require_value "$1" "${2:-}"; MIN_LARGE_SIZE="$2"; validate_size "$1" "$2"; shift ;;
    --active-log-min-size)
      require_value "$1" "${2:-}"; ACTIVE_LOG_MIN_SIZE="$2"; validate_size "$1" "$2"; shift ;;
    --large-file-limit)
      require_value "$1" "${2:-}"; LARGE_FILE_LIMIT="$2"; validate_positive_integer "$1" "$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
    *) fail "Неизвестная опция: $1"; usage; exit 2 ;;
  esac
  shift
done

if "$WITH_DOCKER_VOLUMES" && ! "$WITH_DOCKER"; then
  fail "--docker-volumes можно использовать только вместе с --docker"
  exit 2
fi

if "$AUDIT_ONLY" && ! "$DRY_RUN"; then
  fail "--audit нельзя использовать вместе с --yes"
  exit 2
fi

if (( ORIGINAL_ARG_COUNT == 0 )) && [[ -r /dev/tty && -w /dev/tty && -t 1 ]]; then
  INTERACTIVE_MODE=true
fi

if (( EUID != 0 )); then
  fail "Запустите скрипт от root: sudo bash ${SCRIPT_NAME} ..."
  exit 1
fi

on_error() {
  local exit_code=$?
  fail "Непредвиденная ошибка в строке $1 (код ${exit_code}). Дальше не продолжаю."
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

format_bytes() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("Б КБ МБ ГБ ТБ ПБ", u, " "); i=1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    printf "%.2f %s", b, u[i]
  }'
}

root_available_bytes() { df -B1 --output=avail / 2>/dev/null | awk 'NR == 2 {print $1 + 0}'; }
root_used_bytes()      { df -B1 --output=used / 2>/dev/null | awk 'NR == 2 {print $1 + 0}'; }

save_failed_action_output() {
  local description="$1" output_file="$2"
  ((WARNINGS+=1))
  FAILED_ACTIONS+=("$description")

  if [[ -z "$CLEANUP_ERROR_LOG" ]]; then
    CLEANUP_ERROR_LOG="/tmp/autoclean-errors-$(date +%Y%m%d-%H%M%S)-$$.log"
    umask 077
    : >"$CLEANUP_ERROR_LOG"
  fi
  {
    printf '===== %s =====\n' "$description"
    cat -- "$output_file" 2>/dev/null || true
    printf '\n'
  } >>"$CLEANUP_ERROR_LOG"
}

run_quiet_interactive() {
  local description="$1" output_file pid frame=0 elapsed
  local -a spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  shift
  output_file="$(mktemp)"

  "$@" >"$output_file" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - CLEANUP_STARTED_AT))
    printf '\r\033[K  %b%s%b Выполняем очистку %b[%02d:%02d]%b' \
      "$MAGENTA" "${spinner[$((frame % ${#spinner[@]}))]}" "$RESET" \
      "$DIM" "$((elapsed / 60))" "$((elapsed % 60))" "$RESET"
    frame=$((frame + 1))
    sleep 0.12
  done

  if wait "$pid"; then
    rm -f -- "$output_file"
    ((ACTIONS_DONE+=1))
    return 0
  fi

  save_failed_action_output "$description" "$output_file"
  rm -f -- "$output_file"
  return 1
}

run() {
  local description="$1" output_file
  shift
  if "$DRY_RUN"; then
    would_do "$description"
    return 0
  fi

  if "$UI_CLEANUP_RUNNING"; then
    run_quiet_interactive "$description" "$@" || true
    return 0
  fi

  output_file="$(mktemp)"
  if "$@" >"$output_file" 2>&1; then
    rm -f -- "$output_file"
    ((ACTIONS_DONE+=1))
    ok "$description"
  else
    save_failed_action_output "$description" "$output_file"
    rm -f -- "$output_file"
    say "${YELLOW}!${RESET} Не удалось: $description. Детали: $CLEANUP_ERROR_LOG"
  fi
}

remove_file() {
  local path="$1" description="$2"
  [[ -f "$path" || -L "$path" ]] || return 0
  run "$description: $path" rm -f -- "$path"
}

remove_old_tmp_file() {
  local path="$1"
  [[ "$path" != /tmp && "$path" != /var/tmp ]] || return 0
  [[ -f "$path" || -L "$path" ]] || return 0
  run "Удалить устаревший временный файл: $path" rm -f -- "$path"
}

remove_old_empty_tmp_directory() {
  local path="$1"
  [[ "$path" != /tmp && "$path" != /var/tmp ]] || return 0
  [[ -d "$path" ]] || return 0
  run "Удалить пустой устаревший временный каталог: $path" rmdir -- "$path"
}

cleanup_package_cache() {
  "$CLEAN_PACKAGE_CACHE" || return
  title 'Кеш пакетного менеджера'
  local manager_found=false

  if has_cmd apt-get; then
    manager_found=true
    run 'Очистить кеш APT' env DEBIAN_FRONTEND=noninteractive apt-get clean -y
    if "$WITH_AUTOREMOVE"; then
      run 'Удалить неиспользуемые пакеты APT' env DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
    fi
  fi
  if has_cmd dnf; then
    manager_found=true
    run 'Очистить кеш DNF' dnf clean all -y
    "$WITH_AUTOREMOVE" && run 'Удалить неиспользуемые пакеты DNF' dnf autoremove -y
  elif has_cmd yum; then
    manager_found=true
    run 'Очистить кеш YUM' yum clean all -y
    "$WITH_AUTOREMOVE" && run 'Удалить неиспользуемые пакеты YUM' yum autoremove -y
  fi
  if has_cmd pacman; then
    manager_found=true
    if has_cmd paccache; then
      run 'Очистить кеш Pacman (оставить 2 последние версии)' paccache -rk2
    else
      warn 'Pacman найден, но paccache отсутствует (пакет pacman-contrib) — пропуск.'
    fi
  fi

  "$manager_found" || note 'Пакетный менеджер не распознан — пропуск.'
}

cleanup_journal() {
  "$CLEAN_JOURNAL" || return
  title 'Systemd journal'
  if ! has_cmd journalctl; then
    note 'journalctl не найден — пропуск.'
    return
  fi
  run "Оставить journal не старше ${JOURNAL_MAX_AGE}" journalctl --vacuum-time="$JOURNAL_MAX_AGE"
}

cleanup_crash_dumps() {
  "$CLEAN_CRASH_DUMPS" || return
  title 'Crash dumps'
  local directory path
  for directory in /var/crash /var/lib/systemd/coredump /var/lib/apport/coredump; do
    [[ -d "$directory" ]] || continue
    while IFS= read -r -d '' path; do
      remove_file "$path" 'Удалить crash dump'
    done < <(find "$directory" -xdev -type f -print0 2>/dev/null)
  done
}

cleanup_tmp() {
  "$CLEAN_TMP" || return
  title "Временные файлы старше ${TMP_AGE_DAYS} дн."
  local directory path
  for directory in /tmp /var/tmp; do
    [[ -d "$directory" ]] || continue
    while IFS= read -r -d '' path; do
      remove_old_tmp_file "$path"
    done < <(find "$directory" -xdev -mindepth 1 \( -type f -o -type l \) -mtime "+$TMP_AGE_DAYS" -print0 2>/dev/null)

    # Never recursively remove an old directory: it might contain a recently
    # created file.  Only remove it after it is empty.
    while IFS= read -r -d '' path; do
      remove_old_empty_tmp_directory "$path"
    done < <(find "$directory" -xdev -depth -mindepth 1 -type d -empty -mtime "+$TMP_AGE_DAYS" -print0 2>/dev/null)
  done
}

is_rotated_log() {
  case "$1" in
    *.gz|*.xz|*.zst|*.bz2|*.zip|*.old|*.[0-9]|*.[0-9][0-9]|*.log-[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup_rotated_logs() {
  "$CLEAN_ROTATED_LOGS" || return
  title "Ротации логов /var/log старше ${ROTATED_LOG_AGE_DAYS} дн."
  local path name
  [[ -d /var/log ]] || return
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    is_rotated_log "$name" || continue
    remove_file "$path" 'Удалить старую ротацию лога'
  done < <(find /var/log -xdev -type f -mtime "+$ROTATED_LOG_AGE_DAYS" -print0 2>/dev/null)
}

truncate_large_active_logs() {
  "$WITH_TRUNCATE_LOGS" || return
  title "Активные логи /var/log больше ${ACTIVE_LOG_MIN_SIZE}"
  local path name
  [[ -d /var/log ]] || return

  while IFS= read -r -d '' path; do
    name="${path##*/}"
    is_rotated_log "$name" && continue
    case "$name" in
      *.log|messages|syslog) ;;
      *) continue ;;
    esac
    run "Обнулить активный лог: $path" truncate -s 0 -- "$path"
  done < <(find /var/log -xdev -type f -size "+$ACTIVE_LOG_MIN_SIZE" -print0 2>/dev/null)
}

cleanup_docker() {
  "$WITH_DOCKER" || return
  title 'Docker'
  if ! has_cmd docker; then
    warn 'Docker не найден — пропуск.'
    return
  fi
  if ! docker info >/dev/null 2>&1; then
    warn 'Docker установлен, но daemon недоступен — пропуск.'
    return
  fi

  run 'Удалить stopped containers, dangling images, networks и build cache Docker' docker system prune -f
  if "$WITH_DOCKER_VOLUMES"; then
    run 'Удалить неиспользуемые Docker volumes' docker volume prune -f
  fi
}

# ---------- INTERACTIVE WIZARD ----------
# The visual language intentionally mirrors the companion autosettings script:
# a compact blue header, cyan section titles and a yellow cursor.
clear_screen() {
  clear >/dev/tty 2>/dev/null || printf '\033[H\033[2J' >/dev/tty
}

render_wizard_frame() {
  local section="$1"
  clear_screen
  printf '%b╔═══════════════════════════════════════════════════════════╗%b\n' "$BLUE" "$RESET"
  printf '%b║              AUTO CLEAN · SERVER MAINTENANCE              ║%b\n' "$HEADER" "$RESET"
  printf '%b╚═══════════════════════════════════════════════════════════╝%b\n' "$BLUE" "$RESET"
  printf '  %bВерсия:%b %s    %bСервер:%b %s\n\n' "$CYAN" "$RESET" "$VERSION" "$CYAN" "$RESET" "$(hostname -s 2>/dev/null || hostname)"
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n' "$BLUE" "$RESET"
  printf '%b%s%b\n' "$BOLD$CYAN" "$section" "$RESET"
  printf '%b━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%b\n\n' "$BLUE" "$RESET"
}

read_wizard_key() {
  local key='' sequence=''
  WIZARD_KEY=''
  IFS= read -rsn1 key </dev/tty || true
  if [[ "$key" == $'\e' ]]; then
    IFS= read -rsn2 -t 0.2 sequence </dev/tty || sequence=''
    case "$sequence" in
      '[A') WIZARD_KEY='up' ;;
      '[B') WIZARD_KEY='down' ;;
      *) WIZARD_KEY='escape' ;;
    esac
    return 0
  fi

  case "$key" in
    ''|$'\r'|$'\n') WIZARD_KEY='enter' ;;
    *) WIZARD_KEY="$key" ;;
  esac
}

wait_for_enter() {
  while true; do
    read_wizard_key
    [[ "$WIZARD_KEY" == 'enter' ]] && return 0
  done
}

render_menu_item() {
  local selected="$1" label="$2" description="$3"
  if [[ "$selected" == 'true' ]]; then
    printf '%b▶%b %b%s%b\n' "$YELLOW$BOLD" "$RESET" "$GREEN$BOLD" "$label" "$RESET"
    printf '    %b%s%b\n' "$DIM" "$description" "$RESET"
  else
    printf '  %s\n' "$label"
    printf '    %b%s%b\n' "$DIM" "$description" "$RESET"
  fi
}

render_last_operation() {
  [[ -n "$LAST_OPERATION" ]] || return 0
  printf '%b◽ Последнее действие:%b %b%s%b\n' "$CYAN" "$RESET" "$BOLD" "$LAST_OPERATION" "$RESET"
  printf '  %b%s%b\n\n' "$DIM" "$LAST_OPERATION_DETAILS" "$RESET"
}

run_interactive_main_menu() {
  local cursor=0

  while true; do
    render_wizard_frame 'Выберите режим'
    render_last_operation
    printf '%bСтрелки ↑/↓%b — выбор. %bEnter%b — подтвердить.\n\n' "$DIM" "$RESET" "$DIM" "$RESET"
    render_menu_item "$([[ $cursor -eq 0 ]] && printf true || printf false)" 'Аудит сервера' 'Фоновый поиск кандидатов на очистку без изменений.'
    printf '\n'
    render_menu_item "$([[ $cursor -eq 1 ]] && printf true || printf false)" 'Очистка сервера' 'Сначала выберите, что именно нужно очистить.'
    printf '\n'

    read_wizard_key
    case "$WIZARD_KEY" in
      up)
        if (( cursor > 0 )); then cursor=$((cursor - 1)); fi
        ;;
      down)
        if (( cursor < 1 )); then cursor=$((cursor + 1)); fi
        ;;
      enter)
        if (( cursor == 0 )); then
          run_interactive_audit
        else
          configure_interactive_cleanup
          DRY_RUN=false
          clear_screen
          main
        fi
        ;;
    esac
  done
}

toggle_boolean() {
  local variable_name="$1"
  if [[ "${!variable_name}" == 'true' ]]; then
    printf -v "$variable_name" '%s' false
  else
    printf -v "$variable_name" '%s' true
  fi
}

render_cleanup_setting() {
  local cursor="$1" selected="$2" available="$3" label="$4" description="$5"
  local mark='[ ]' mark_color="$RESET"

  if [[ "$available" != 'true' ]]; then
    mark='[—]'
    mark_color="$GRAY"
  elif [[ "$selected" == 'true' ]]; then
    mark='[x]'
    mark_color="$GREEN"
  fi

  if [[ "$cursor" == 'true' ]]; then
    printf '%b▶%b ' "$YELLOW$BOLD" "$RESET"
  else
    printf '  '
  fi
  printf '%b%s%b %s\n' "$mark_color" "$mark" "$RESET" "$label"
  printf '      %b%s%b\n' "$DIM" "$description" "$RESET"
}

configure_interactive_cleanup() {
  local -a keys=(
    CLEAN_PACKAGE_CACHE CLEAN_JOURNAL CLEAN_CRASH_DUMPS CLEAN_TMP CLEAN_ROTATED_LOGS
    WITH_DOCKER WITH_DOCKER_VOLUMES WITH_AUTOREMOVE WITH_TRUNCATE_LOGS
  )
  local -a labels=(
    'Кеш пакетного менеджера' 'Systemd journal' 'Crash dumps'
    "Файлы в /tmp и /var/tmp старше ${TMP_AGE_DAYS} дн."
    "Ротации в /var/log старше ${ROTATED_LOG_AGE_DAYS} дн."
    'Docker: контейнеры, dangling images, сети и build cache'
    'Docker: неиспользуемые volumes' 'Неиспользуемые пакеты'
    "Активные логи больше ${ACTIVE_LOG_MIN_SIZE}"
  )
  local -a descriptions=(
    'Удаляет только скачанные кеши.' 'Оставляет логи не старше 7 дней.'
    'Сохраняет данные приложений.' 'Удаляются только старые файлы и пустые папки.'
    'Активные логи не затрагиваются.' 'Не затрагивает работающие контейнеры.'
    'Доступно, только если включён Docker.' 'Может удалить пакеты, нужные для отката.'
    'Обнуляет только стандартные логи в /var/log.'
  )
  local cursor=0 index key available selected
  local item_count="${#keys[@]}"

  while true; do
    render_wizard_frame 'Настройте очистку'
    printf '%bСтрелки ↑/↓%b — строка. %bEnter%b — включить/выключить.\n' "$DIM" "$RESET" "$DIM" "$RESET"
    printf '%bВыберите «Начать очистку» и нажмите Enter, когда всё готово.%b\n\n' "$DIM" "$RESET"

    for index in "${!keys[@]}"; do
      key="${keys[$index]}"
      available=true
      [[ "$key" == 'WITH_DOCKER_VOLUMES' && "$WITH_DOCKER" != 'true' ]] && available=false
      selected="${!key}"
      if (( cursor == index )); then
        render_cleanup_setting true "$selected" "$available" "${labels[$index]}" "${descriptions[$index]}"
      else
        render_cleanup_setting false "$selected" "$available" "${labels[$index]}" "${descriptions[$index]}"
      fi
    done

    if (( cursor == item_count )); then
      printf '\n%b▶%b %b[ Начать очистку ]%b\n' "$YELLOW$BOLD" "$RESET" "$GREEN$BOLD" "$RESET"
    else
      printf '\n  [ Начать очистку ]\n'
    fi

    read_wizard_key
    case "$WIZARD_KEY" in
      up)
        if (( cursor > 0 )); then cursor=$((cursor - 1)); fi
        ;;
      down)
        if (( cursor < item_count )); then cursor=$((cursor + 1)); fi
        ;;
      enter)
        if (( cursor == item_count )); then
          return 0
        fi
        key="${keys[$cursor]}"
        case "$key" in
          WITH_DOCKER)
            toggle_boolean WITH_DOCKER
            [[ "$WITH_DOCKER" == 'true' ]] || WITH_DOCKER_VOLUMES=false
            ;;
          WITH_DOCKER_VOLUMES)
            if [[ "$WITH_DOCKER" == 'true' ]]; then
              toggle_boolean WITH_DOCKER_VOLUMES
            fi
            ;;
          CLEAN_PACKAGE_CACHE)
            toggle_boolean CLEAN_PACKAGE_CACHE
            [[ "$CLEAN_PACKAGE_CACHE" == 'true' ]] || WITH_AUTOREMOVE=false
            ;;
          WITH_AUTOREMOVE)
            toggle_boolean WITH_AUTOREMOVE
            if [[ "$WITH_AUTOREMOVE" == 'true' ]]; then
              CLEAN_PACKAGE_CACHE=true
            fi
            ;;
          *) toggle_boolean "$key" ;;
        esac
        ;;
    esac
  done
}

# ---------- AUDIT ----------
# The audit reports only files that match the script's conservative cleanup
# rules.  It deliberately does not label arbitrary large application files as
# safe to delete.
AUDIT_STATE_DIR=''
AUDIT_COUNT=0
AUDIT_BYTES=0

audit_write_state() {
  local pending_file="${AUDIT_STATE_DIR}/state.pending"
  printf '%s\t%s\n' "$AUDIT_COUNT" "$AUDIT_BYTES" >"$pending_file"
  mv -f -- "$pending_file" "${AUDIT_STATE_DIR}/state"
}

audit_add_candidate() {
  local path="$1" size='0'
  [[ -f "$path" || -L "$path" ]] || return 0
  size="$(stat -c '%s' -- "$path" 2>/dev/null || printf '0')"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  AUDIT_COUNT=$((AUDIT_COUNT + 1))
  AUDIT_BYTES=$((AUDIT_BYTES + size))
  if (( AUDIT_COUNT % 25 == 0 )); then
    audit_write_state
  fi
}

audit_scan_directory() {
  local directory="$1" age_days="${2:-}" path
  [[ -d "$directory" ]] || return 0
  if [[ -n "$age_days" ]]; then
    while IFS= read -r -d '' path; do
      audit_add_candidate "$path"
    done < <(find "$directory" -xdev -mindepth 1 \( -type f -o -type l \) -mtime "+$age_days" -print0 2>/dev/null)
  else
    while IFS= read -r -d '' path; do
      audit_add_candidate "$path"
    done < <(find "$directory" -xdev -mindepth 1 \( -type f -o -type l \) -print0 2>/dev/null)
  fi
}

audit_scan_rotated_logs() {
  local path name
  [[ -d /var/log ]] || return 0
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    if is_rotated_log "$name"; then
      audit_add_candidate "$path"
    fi
  done < <(find /var/log -xdev -type f -mtime "+$ROTATED_LOG_AGE_DAYS" -print0 2>/dev/null)
}

audit_collect_candidates() {
  AUDIT_COUNT=0
  AUDIT_BYTES=0
  audit_write_state

  # The same locations are used by the selected standard cleanup actions.
  has_cmd apt-get && audit_scan_directory /var/cache/apt/archives
  has_cmd dnf && audit_scan_directory /var/cache/dnf
  has_cmd yum && audit_scan_directory /var/cache/yum
  has_cmd pacman && audit_scan_directory /var/cache/pacman/pkg

  audit_scan_directory /var/crash
  audit_scan_directory /var/lib/systemd/coredump
  audit_scan_directory /var/lib/apport/coredump
  audit_scan_directory /tmp "$TMP_AGE_DAYS"
  audit_scan_directory /var/tmp "$TMP_AGE_DAYS"
  audit_scan_rotated_logs

  if has_cmd journalctl; then
    audit_scan_directory /var/log/journal "$TMP_AGE_DAYS"
    audit_scan_directory /run/log/journal "$TMP_AGE_DAYS"
  fi
  audit_write_state
}

read_audit_state() {
  local state_file="${AUDIT_STATE_DIR}/state"
  AUDIT_DISPLAY_COUNT=0
  AUDIT_DISPLAY_BYTES=0
  if [[ -s "$state_file" ]]; then
    IFS=$'\t' read -r AUDIT_DISPLAY_COUNT AUDIT_DISPLAY_BYTES <"$state_file" || true
  fi
}

run_interactive_audit() {
  local audit_pid frame=0 started_at elapsed
  local -a spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')

  AUDIT_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autoclean-audit.XXXXXX")"
  audit_write_state
  started_at=$SECONDS
  ( audit_collect_candidates ) &
  audit_pid=$!

  render_wizard_frame 'Аудит сервера'
  printf '%bПоиск идёт в фоне. Список файлов на экран не выводится.%b\n\n' "$DIM" "$RESET"
  while kill -0 "$audit_pid" 2>/dev/null; do
    read_audit_state
    elapsed=$((SECONDS - started_at))
    printf '\r\033[K  %b%s%b Поиск кандидатов %b[%02d:%02d]%b  %b·%b %b%s%b файлов  %b·%b %b%s%b' \
      "$MAGENTA" "${spinner[$((frame % ${#spinner[@]}))]}" "$RESET" \
      "$DIM" "$((elapsed / 60))" "$((elapsed % 60))" "$RESET" \
      "$GRAY" "$RESET" "$BOLD" "$AUDIT_DISPLAY_COUNT" "$RESET" \
      "$GRAY" "$RESET" "$GREEN$BOLD" "$(format_bytes "$AUDIT_DISPLAY_BYTES")" "$RESET"
    frame=$((frame + 1))
    sleep 0.12
  done

  if ! wait "$audit_pid"; then
    rm -rf -- "$AUDIT_STATE_DIR"
    AUDIT_STATE_DIR=''
    fail 'Аудит завершился с ошибкой.'
    return 1
  fi

  read_audit_state
  printf '\r\033[K'
  elapsed=$((SECONDS - started_at))
  LAST_OPERATION='Аудит сервера завершён'
  LAST_OPERATION_DETAILS="${AUDIT_DISPLAY_COUNT} файлов · $(format_bytes "$AUDIT_DISPLAY_BYTES") · $((elapsed / 60)) мин $((elapsed % 60)) сек"
  render_wizard_frame 'Аудит завершён'
  printf '%b✓%b Просканированы безопасные зоны очистки %b[%d мин %d сек]%b\n\n' \
    "$GREEN$BOLD" "$RESET" "$DIM" "$((elapsed / 60))" "$((elapsed % 60))" "$RESET"
  printf '  %bКандидатов на очистку:%b  %b%s%b файлов\n' "$CYAN" "$RESET" "$BOLD" "$AUDIT_DISPLAY_COUNT" "$RESET"
  printf '  %bПотенциально освободится:%b %b%s%b\n\n' "$CYAN" "$RESET" "$GREEN$BOLD" "$(format_bytes "$AUDIT_DISPLAY_BYTES")" "$RESET"
  printf '%bВ расчёт входят кеши, crash dumps, устаревшие tmp-файлы, ротации\n' "$DIM"
  printf 'логов и старые journal-файлы. Данные приложений не считаются мусором.%b\n\n' "$RESET"
  printf '%bНажмите Enter, чтобы завершить.%b' "$DIM" "$RESET"
  wait_for_enter

  rm -rf -- "$AUDIT_STATE_DIR"
  AUDIT_STATE_DIR=''
}

run_noninteractive_audit() {
  AUDIT_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/autoclean-audit.XXXXXX")"
  audit_collect_candidates
  read_audit_state
  title 'Аудит сервера завершён'
  say "Кандидатов на очистку:  ${BOLD}${AUDIT_DISPLAY_COUNT}${RESET} файлов"
  say "Потенциально освободится: ${GREEN}${BOLD}$(format_bytes "$AUDIT_DISPLAY_BYTES")${RESET}"
  note 'Показаны только кандидаты, подпадающие под консервативные правила очистки.'
  rm -rf -- "$AUDIT_STATE_DIR"
  AUDIT_STATE_DIR=''
}

report_large_files() {
  title "Крупные файлы от ${MIN_LARGE_SIZE} (только отчёт)"
  local report_file
  report_file="$(mktemp)"
  trap 'rm -f -- "${report_file:-}"' RETURN

  # `-xdev` intentionally keeps the scan on the server root filesystem.
  # Pseudo-filesystems and common mount points are never traversed.
  find / -xdev \
    \( -path /proc -o -path /sys -o -path /dev -o -path /run -o -path /boot -o -path /mnt -o -path /media \) -prune -o \
    -type f -size "+$MIN_LARGE_SIZE" -printf '%s\t%p\n' 2>/dev/null \
    | sort -nr >"$report_file"

  if [[ ! -s "$report_file" ]]; then
    ok 'Крупных файлов по заданному порогу не найдено.'
    rm -f -- "$report_file"
    trap - RETURN
    return
  fi

  printf '%s\n' "${BOLD}Размер             Путь${RESET}"
  local size path count=0
  while IFS=$'\t' read -r size path; do
    printf '%-18s %s\n' "$(format_bytes "$size")" "$path"
    ((count+=1))
    (( count >= LARGE_FILE_LIMIT )) && break
  done <"$report_file"
  rm -f -- "$report_file"
  trap - RETURN
}

main() {
  local available_before used_before available_after used_after reclaimed
  ACTIONS_PLANNED=0
  ACTIONS_DONE=0
  WARNINGS=0
  EXIT_STATUS=0
  FAILED_ACTIONS=()
  CLEANUP_NOTES=()
  CLEANUP_ERROR_LOG=''
  available_before="$(root_available_bytes)"
  used_before="$(root_used_bytes)"

  if "$INTERACTIVE_MODE" && ! "$DRY_RUN"; then
    UI_CLEANUP_RUNNING=true
    CLEANUP_STARTED_AT=$SECONDS
    render_wizard_frame 'Очистка сервера'
    printf '%bВыбранные действия выполняются в фоне. Технический вывод скрыт.%b\n\n' "$DIM" "$RESET"
  else
    say "${BOLD}Server cleanup ${VERSION}${RESET}"
  fi

  if "$DRY_RUN"; then
    warn 'Режим проверки: ничего не будет удалено. Для очистки добавьте --yes.'
  elif ! "$INTERACTIVE_MODE"; then
    warn 'Режим очистки включён. Удаляются только операции, перечисленные ниже.'
  fi

  cleanup_package_cache
  cleanup_journal
  cleanup_crash_dumps
  cleanup_tmp
  cleanup_rotated_logs
  truncate_large_active_logs
  cleanup_docker
  "$INTERACTIVE_MODE" || report_large_files

  available_after="$(root_available_bytes)"
  used_after="$(root_used_bytes)"

  if "$INTERACTIVE_MODE" && ! "$DRY_RUN"; then
    printf '\r\033[K'
    UI_CLEANUP_RUNNING=false
    render_wizard_frame 'Очистка завершена'
  else
    title 'Итог'
  fi
  if "$DRY_RUN"; then
    say "Режим:              ${YELLOW}dry-run${RESET}"
    say "Операций в плане:   ${ACTIONS_PLANNED}"
  else
    say "Режим:              ${GREEN}очистка${RESET}"
    say "Успешных операций:  ${ACTIONS_DONE}"
    say "Свободно до/после:  $(format_bytes "$available_before") → $(format_bytes "$available_after")"
    say "Использовано до/после: $(format_bytes "$used_before") → $(format_bytes "$used_after")"
  fi
  (( WARNINGS == 0 )) || say "Предупреждений:      ${YELLOW}${WARNINGS}${RESET}"

  if "$INTERACTIVE_MODE"; then
    reclaimed=$((available_after - available_before))
    (( reclaimed >= 0 )) || reclaimed=0
    LAST_OPERATION='Очистка сервера завершена'
    LAST_OPERATION_DETAILS="${ACTIONS_DONE} операций · освобождено $(format_bytes "$reclaimed") · предупреждений: ${WARNINGS}"
    if (( ${#FAILED_ACTIONS[@]} > 0 )); then
      say
      say "${YELLOW}!${RESET} Не выполнено операций: ${#FAILED_ACTIONS[@]}. Детали сохранены: ${CLEANUP_ERROR_LOG}"
    fi
    say
    say "${DIM}Нажмите Enter, чтобы вернуться в главное меню.${RESET}"
    wait_for_enter
  fi

  return "$EXIT_STATUS"
}

if "$INTERACTIVE_MODE"; then
  run_interactive_main_menu
elif "$AUDIT_ONLY"; then
  run_noninteractive_audit
else
  main "$@"
fi
