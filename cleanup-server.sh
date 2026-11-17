#!/usr/bin/env bash
# shellcheck shell=bash
#
# Server cleanup utility.  First run installs `cll`; afterwards use `cll`.
#   curl -fsSL "https://raw.githubusercontent.com/andrchq/autoclean/main/cleanup-server.sh?ts=$(date +%s)" | sudo bash
#
# Default mode is a dry-run.  Actions that can affect deployments need an
# explicit flag; see --help.

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly VERSION="1.2.2"
readonly INSTALL_PATH='/usr/local/bin/cll'
readonly REMOTE_SCRIPT_URL='https://raw.githubusercontent.com/andrchq/autoclean/main/cleanup-server.sh'
readonly TASKS_DIR="${AUTOCLEAN_TASKS_DIR:-/etc/autoclean/tasks}"
readonly SYSTEMD_UNIT_DIR="${AUTOCLEAN_SYSTEMD_DIR:-/etc/systemd/system}"
readonly SERVICE_UNIT_PATH="${SYSTEMD_UNIT_DIR}/autoclean@.service"

# An invocation without arguments opens the wizard when a controlling terminal
# is available.  It also works with `curl ... | sudo bash`, where stdin is the
# script itself, because the wizard reads keys from /dev/tty.
ORIGINAL_ARG_COUNT=$#
ORIGINAL_ARGS=("$@")
INTERACTIVE_MODE=false
AUDIT_ONLY=false
SCHEDULED_MODE=false
SCHEDULED_TASK_ID=''
SKIP_SELF_UPDATE=false
STARTUP_NOTICE=''
AUTOCLEAN_LIBRARY_MODE="${AUTOCLEAN_LIBRARY_MODE:-0}"

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
TASK_PERIOD='daily'
TASK_TIME='03:00'
TASK_DAYS=''

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
  cll [options]                   # после первой установки
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
  cll
  cll --audit
  cll --yes
  cll --yes --docker
  cll --yes --docker --docker-volumes --autoremove

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
    --scheduled-task)
      require_value "$1" "${2:-}"
      SCHEDULED_MODE=true
      SCHEDULED_TASK_ID="$2"
      shift
      ;;
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
    --internal-restart)
      SKIP_SELF_UPDATE=true
      ORIGINAL_ARG_COUNT=$((ORIGINAL_ARG_COUNT - 1))
      STARTUP_NOTICE="Команда cll установлена и обновлена до версии ${VERSION}."
      ;;
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

if (( EUID != 0 )) && [[ "$AUTOCLEAN_LIBRARY_MODE" != 1 ]]; then
  if [[ -x "$INSTALL_PATH" && ( "$0" == 'cll' || "$0" == "$INSTALL_PATH" ) ]] && has_cmd sudo; then
    exec sudo "$INSTALL_PATH" "${ORIGINAL_ARGS[@]}"
  fi
  fail "Для первой установки используйте: curl -fsSL <URL> | sudo bash"
  exit 1
fi

# ---------- INSTALLATION AND SELF-UPDATE ----------
download_latest_script() {
  local destination="$1" url=''
  url="${REMOTE_SCRIPT_URL}?ts=$(date +%s)"

  if has_cmd curl; then
    curl -fsSL --connect-timeout 10 --max-time 120 "$url" -o "$destination"
  elif has_cmd wget; then
    wget -q --timeout=30 --tries=2 "$url" -O "$destination"
  else
    return 1
  fi
}

script_version_from_file() {
  awk -F'"' '/^readonly VERSION="[0-9]+\.[0-9]+\.[0-9]+"$/ { print $2; exit }' "$1"
}

is_valid_downloaded_script() {
  local file="$1" version=''
  [[ "$(head -n 1 -- "$file" 2>/dev/null)" == '#!/usr/bin/env bash' ]] || return 1
  version="$(script_version_from_file "$file")"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

version_is_newer() {
  local candidate="$1" current="$2" index
  local -a candidate_parts current_parts
  IFS='.' read -r -a candidate_parts <<<"$candidate"
  IFS='.' read -r -a current_parts <<<"$current"

  for index in 0 1 2; do
    if (( 10#${candidate_parts[$index]} > 10#${current_parts[$index]} )); then
      return 0
    fi
    if (( 10#${candidate_parts[$index]} < 10#${current_parts[$index]} )); then
      return 1
    fi
  done
  return 1
}

install_script_file() {
  local source_file="$1" staged_file="${INSTALL_PATH}.new.$$"
  if install -m 0755 -- "$source_file" "$staged_file" >/dev/null 2>&1 \
    && mv -f -- "$staged_file" "$INSTALL_PATH" >/dev/null 2>&1; then
    return 0
  fi
  rm -f -- "$staged_file"
  return 1
}

current_script_path() {
  local invoked_as="$0"
  if [[ "$invoked_as" != */* ]]; then
    invoked_as="$(command -v -- "$invoked_as" 2>/dev/null || printf '%s' "$invoked_as")"
  fi
  readlink -f -- "$invoked_as" 2>/dev/null || printf '%s\n' "$invoked_as"
}

ensure_cll_is_current() {
  local downloaded_file remote_version current_path

  "$SKIP_SELF_UPDATE" && return 0
  downloaded_file="$(mktemp "${TMPDIR:-/tmp}/autoclean-update.XXXXXX")"
  if ! download_latest_script "$downloaded_file" || ! is_valid_downloaded_script "$downloaded_file"; then
    rm -f -- "$downloaded_file"
    STARTUP_NOTICE='Не удалось проверить обновление. Запущена текущая версия.'
    return 0
  fi

  remote_version="$(script_version_from_file "$downloaded_file")"
  current_path="$(current_script_path)"

  # The initial curl | bash run has no local script to copy. Install the
  # canonical GitHub version first, then restart from its permanent location.
  if [[ "$current_path" != "$INSTALL_PATH" ]]; then
    if ! install_script_file "$downloaded_file"; then
      rm -f -- "$downloaded_file"
      STARTUP_NOTICE="Не удалось установить ${INSTALL_PATH}. Скрипт продолжит работу без команды cll."
      return 0
    fi
    rm -f -- "$downloaded_file"
    exec "$INSTALL_PATH" --internal-restart "${ORIGINAL_ARGS[@]}"
  fi

  if version_is_newer "$remote_version" "$VERSION"; then
    if ! install_script_file "$downloaded_file"; then
      rm -f -- "$downloaded_file"
      STARTUP_NOTICE='Не удалось установить обновление. Запущена текущая версия.'
      return 0
    fi
    rm -f -- "$downloaded_file"
    exec "$INSTALL_PATH" --internal-restart "${ORIGINAL_ARGS[@]}"
  fi

  rm -f -- "$downloaded_file"
}

if [[ "$AUTOCLEAN_LIBRARY_MODE" != 1 ]]; then
  ensure_cll_is_current
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
  "$CLEAN_PACKAGE_CACHE" || return 0
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
  "$CLEAN_JOURNAL" || return 0
  title 'Systemd journal'
  if ! has_cmd journalctl; then
    note 'journalctl не найден — пропуск.'
    return
  fi
  run "Оставить journal не старше ${JOURNAL_MAX_AGE}" journalctl --vacuum-time="$JOURNAL_MAX_AGE"
}

cleanup_crash_dumps() {
  "$CLEAN_CRASH_DUMPS" || return 0
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
  "$CLEAN_TMP" || return 0
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
  "$CLEAN_ROTATED_LOGS" || return 0
  title "Ротации логов /var/log старше ${ROTATED_LOG_AGE_DAYS} дн."
  local path name
  [[ -d /var/log ]] || return 0
  while IFS= read -r -d '' path; do
    name="${path##*/}"
    is_rotated_log "$name" || continue
    remove_file "$path" 'Удалить старую ротацию лога'
  done < <(find /var/log -xdev -type f -mtime "+$ROTATED_LOG_AGE_DAYS" -print0 2>/dev/null)
}

truncate_large_active_logs() {
  "$WITH_TRUNCATE_LOGS" || return 0
  title "Активные логи /var/log больше ${ACTIVE_LOG_MIN_SIZE}"
  local log_dir="${1:-/var/log}" path name
  [[ -d "$log_dir" ]] || return 0

  while IFS= read -r -d '' path; do
    case "$path" in
      "$log_dir/syslog.1"|"$log_dir/kern.log.1")
        remove_file "$path" 'Удалить крупную ротацию лога'
        ;;
      *)
        name="${path##*/}"
        is_rotated_log "$name" && continue
        case "$name" in
          *.log|messages|syslog)
            run "Обнулить активный лог: $path" truncate --no-create -s 0 -- "$path"
            ;;
        esac
        ;;
    esac
  done < <(find "$log_dir" -xdev -type f -size "+$ACTIVE_LOG_MIN_SIZE" -print0 2>/dev/null)
}

cleanup_docker() {
  "$WITH_DOCKER" || return 0
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

# ---------- SCHEDULED CLEANUP ----------
validate_task_id() {
  [[ "$1" =~ ^[0-9]{14}-[0-9]+$ ]]
}

normalize_time_value() {
  local input="$1" hour minute
  local separated_regex='^([0-9]{2})[: ,.]{1}([0-9]{2})$'

  if [[ "$input" =~ ^[0-9]{4}$ ]]; then
    hour="${input:0:2}"
    minute="${input:2:2}"
  elif [[ "$input" =~ $separated_regex ]]; then
    hour="${BASH_REMATCH[1]}"
    minute="${BASH_REMATCH[2]}"
  else
    return 1
  fi

  (( 10#$hour <= 23 && 10#$minute <= 59 )) || return 1
  printf '%s:%s\n' "$hour" "$minute"
}

normalize_month_days() {
  local input="$1" value day result=''
  local -a values
  local -A seen=()
  IFS=',' read -r -a values <<<"$input"
  (( ${#values[@]} > 0 )) || return 1

  for value in "${values[@]}"; do
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    [[ "$value" =~ ^[0-9]{1,2}$ ]] || return 1
    day=$((10#$value))
    (( day >= 1 && day <= 31 )) || return 1
    seen["$day"]=1
  done

  for day in {1..31}; do
    [[ "${seen[$day]:-}" == 1 ]] || continue
    [[ -z "$result" ]] || result+=','
    result+="$day"
  done
  [[ -n "$result" ]] || return 1
  printf '%s\n' "$result"
}

validate_week_days() {
  local input="$1" day
  local -a days
  local -A seen=()
  [[ -n "$input" ]] || return 1
  IFS=',' read -r -a days <<<"$input"
  for day in "${days[@]}"; do
    case "$day" in Mon|Tue|Wed|Thu|Fri|Sat|Sun) ;; *) return 1 ;; esac
    [[ -z "${seen[$day]:-}" ]] || return 1
    seen["$day"]=1
  done
}

validate_boolean() {
  [[ "$1" == true || "$1" == false ]]
}

validate_task_settings() {
  local normalized_time normalized_days='' value
  normalized_time="$(normalize_time_value "$TASK_TIME")" || return 1

  case "$TASK_PERIOD" in
    daily)
      [[ -z "$TASK_DAYS" ]] || return 1
      ;;
    weekly)
      validate_week_days "$TASK_DAYS" || return 1
      normalized_days="$TASK_DAYS"
      ;;
    monthly)
      normalized_days="$(normalize_month_days "$TASK_DAYS")" || return 1
      ;;
    *) return 1 ;;
  esac

  for value in "$CLEAN_PACKAGE_CACHE" "$CLEAN_JOURNAL" "$CLEAN_CRASH_DUMPS" "$CLEAN_TMP" \
    "$CLEAN_ROTATED_LOGS" "$WITH_DOCKER" "$WITH_DOCKER_VOLUMES" "$WITH_AUTOREMOVE" "$WITH_TRUNCATE_LOGS"; do
    validate_boolean "$value" || return 1
  done
  [[ "$WITH_DOCKER_VOLUMES" != true || "$WITH_DOCKER" == true ]] || return 1
  [[ "$WITH_AUTOREMOVE" != true || "$CLEAN_PACKAGE_CACHE" == true ]] || return 1

  TASK_TIME="$normalized_time"
  TASK_DAYS="$normalized_days"
}

cleanup_flags_snapshot() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$CLEAN_PACKAGE_CACHE" "$CLEAN_JOURNAL" "$CLEAN_CRASH_DUMPS" "$CLEAN_TMP" "$CLEAN_ROTATED_LOGS" \
    "$WITH_DOCKER" "$WITH_DOCKER_VOLUMES" "$WITH_AUTOREMOVE" "$WITH_TRUNCATE_LOGS"
}

restore_cleanup_flags() {
  IFS=$'\t' read -r CLEAN_PACKAGE_CACHE CLEAN_JOURNAL CLEAN_CRASH_DUMPS CLEAN_TMP CLEAN_ROTATED_LOGS \
    WITH_DOCKER WITH_DOCKER_VOLUMES WITH_AUTOREMOVE WITH_TRUNCATE_LOGS <<<"$1"
}

reset_cleanup_flags() {
  CLEAN_PACKAGE_CACHE=true
  CLEAN_JOURNAL=true
  CLEAN_CRASH_DUMPS=true
  CLEAN_TMP=true
  CLEAN_ROTATED_LOGS=true
  WITH_DOCKER=false
  WITH_DOCKER_VOLUMES=false
  WITH_AUTOREMOVE=false
  WITH_TRUNCATE_LOGS=false
}

task_config_path() {
  validate_task_id "$1" || return 1
  printf '%s/%s.conf\n' "$TASKS_DIR" "$1"
}

task_timer_path() {
  validate_task_id "$1" || return 1
  printf '%s/autoclean-%s.timer\n' "$SYSTEMD_UNIT_DIR" "$1"
}

scheduler_available() {
  has_cmd systemctl && { [[ -d /run/systemd/system ]] || [[ "${AUTOCLEAN_TEST_MODE:-}" == 1 ]]; }
}

write_atomic_file() {
  local target="$1" mode="$2" temporary
  temporary="$(mktemp "${target}.tmp.XXXXXX")" || return 1
  cat >"$temporary"
  chmod "$mode" "$temporary"
  mv -f -- "$temporary" "$target"
}

write_service_unit() {
  install -d -m 0755 -- "$SYSTEMD_UNIT_DIR" || return 1
  write_atomic_file "$SERVICE_UNIT_PATH" 0644 <<EOF
[Unit]
Description=Auto Clean scheduled task %i
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${INSTALL_PATH} --scheduled-task %i
Nice=10
IOSchedulingClass=idle
EOF
}

write_task_config() {
  local task_id="$1" target
  target="$(task_config_path "$task_id")" || return 1
  install -d -m 0700 -- "$TASKS_DIR" || return 1
  write_atomic_file "$target" 0600 <<EOF
CONFIG_VERSION=1
TASK_PERIOD=${TASK_PERIOD}
TASK_TIME=${TASK_TIME}
TASK_DAYS=${TASK_DAYS}
CLEAN_PACKAGE_CACHE=${CLEAN_PACKAGE_CACHE}
CLEAN_JOURNAL=${CLEAN_JOURNAL}
CLEAN_CRASH_DUMPS=${CLEAN_CRASH_DUMPS}
CLEAN_TMP=${CLEAN_TMP}
CLEAN_ROTATED_LOGS=${CLEAN_ROTATED_LOGS}
WITH_DOCKER=${WITH_DOCKER}
WITH_DOCKER_VOLUMES=${WITH_DOCKER_VOLUMES}
WITH_AUTOREMOVE=${WITH_AUTOREMOVE}
WITH_TRUNCATE_LOGS=${WITH_TRUNCATE_LOGS}
EOF
}

write_task_timer() {
  local task_id="$1" target day padded_day
  local -a days
  target="$(task_timer_path "$task_id")" || return 1
  install -d -m 0755 -- "$SYSTEMD_UNIT_DIR" || return 1

  {
    printf '%s\n' '[Unit]'
    printf 'Description=Auto Clean timer %s\n\n' "$task_id"
    printf '%s\n' '[Timer]'
    case "$TASK_PERIOD" in
      daily)
        printf 'OnCalendar=*-*-* %s:00\n' "$TASK_TIME"
        ;;
      weekly)
        IFS=',' read -r -a days <<<"$TASK_DAYS"
        for day in "${days[@]}"; do
          printf 'OnCalendar=%s *-*-* %s:00\n' "$day" "$TASK_TIME"
        done
        ;;
      monthly)
        IFS=',' read -r -a days <<<"$TASK_DAYS"
        for day in "${days[@]}"; do
          printf -v padded_day '%02d' "$day"
          printf 'OnCalendar=*-*-%s %s:00\n' "$padded_day" "$TASK_TIME"
        done
        ;;
      *) return 1 ;;
    esac
    printf 'Unit=autoclean@%s.service\n' "$task_id"
    printf '%s\n\n' 'Persistent=true' 'AccuracySec=1min'
    printf '%s\n' '[Install]' 'WantedBy=timers.target'
  } | write_atomic_file "$target" 0644
}

load_task_config() {
  local task_id="$1" file key value
  local config_version='' period='' time='' task_days=''
  local package='' journal='' crash='' tmp='' rotated='' docker='' volumes='' autoremove='' truncate=''
  file="$(task_config_path "$task_id")" || return 1
  [[ -f "$file" ]] || return 1

  while IFS='=' read -r key value; do
    case "$key" in
      CONFIG_VERSION) config_version="$value" ;;
      TASK_PERIOD) period="$value" ;;
      TASK_TIME) time="$value" ;;
      TASK_DAYS) task_days="$value" ;;
      CLEAN_PACKAGE_CACHE) package="$value" ;;
      CLEAN_JOURNAL) journal="$value" ;;
      CLEAN_CRASH_DUMPS) crash="$value" ;;
      CLEAN_TMP) tmp="$value" ;;
      CLEAN_ROTATED_LOGS) rotated="$value" ;;
      WITH_DOCKER) docker="$value" ;;
      WITH_DOCKER_VOLUMES) volumes="$value" ;;
      WITH_AUTOREMOVE) autoremove="$value" ;;
      WITH_TRUNCATE_LOGS) truncate="$value" ;;
      ''|'#'*) ;;
      *) return 1 ;;
    esac
  done <"$file"

  [[ "$config_version" == 1 ]] || return 1
  [[ "$period" == daily || "$period" == weekly || "$period" == monthly ]] || return 1
  time="$(normalize_time_value "$time")" || return 1
  if [[ "$period" == weekly ]]; then
    validate_week_days "$task_days" || return 1
  elif [[ "$period" == monthly ]]; then
    task_days="$(normalize_month_days "$task_days")" || return 1
  else
    [[ -z "$task_days" ]] || return 1
  fi
  for value in "$package" "$journal" "$crash" "$tmp" "$rotated" "$docker" "$volumes" "$autoremove" "$truncate"; do
    validate_boolean "$value" || return 1
  done
  [[ "$volumes" != true || "$docker" == true ]] || return 1
  [[ "$autoremove" != true || "$package" == true ]] || return 1

  TASK_PERIOD="$period"; TASK_TIME="$time"; TASK_DAYS="$task_days"
  CLEAN_PACKAGE_CACHE="$package"; CLEAN_JOURNAL="$journal"; CLEAN_CRASH_DUMPS="$crash"
  CLEAN_TMP="$tmp"; CLEAN_ROTATED_LOGS="$rotated"; WITH_DOCKER="$docker"
  WITH_DOCKER_VOLUMES="$volumes"; WITH_AUTOREMOVE="$autoremove"; WITH_TRUNCATE_LOGS="$truncate"
}

save_scheduled_task() {
  local task_id="$1"
  scheduler_available || return 1
  validate_task_id "$task_id" || return 1
  validate_task_settings || return 1
  write_service_unit || return 1
  write_task_config "$task_id" || return 1
  write_task_timer "$task_id" || return 1
  systemctl daemon-reload >/dev/null 2>&1 || return 1
  systemctl enable --now "autoclean-${task_id}.timer" >/dev/null 2>&1 || return 1
  systemctl restart "autoclean-${task_id}.timer" >/dev/null 2>&1 || return 1
}

delete_scheduled_task() {
  local task_id="$1" config timer
  config="$(task_config_path "$task_id")" || return 1
  timer="$(task_timer_path "$task_id")" || return 1
  scheduler_available || return 1
  systemctl disable --now "autoclean-${task_id}.timer" >/dev/null 2>&1 || true
  rm -f -- "$config" "$timer"
  systemctl daemon-reload >/dev/null 2>&1
}

run_scheduled_task() {
  validate_task_id "$SCHEDULED_TASK_ID" || { fail 'Некорректный ID автоматической задачи.'; return 2; }
  load_task_config "$SCHEDULED_TASK_ID" || { fail 'Конфигурация автоматической задачи отсутствует или повреждена.'; return 2; }
  INTERACTIVE_MODE=false
  DRY_RUN=false
  main
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
  printf '%b║                  AUTO CLEAN | andrchq                     ║%b\n' "$HEADER" "$RESET"
  printf '%b╚═══════════════════════════════════════════════════════════╝%b\n' "$BLUE" "$RESET"
  printf '  %bВерсия:%b %s    %bСервер:%b %s\n\n' "$CYAN" "$RESET" "$VERSION" "$CYAN" "$RESET" "$(hostname -s 2>/dev/null || hostname)"
  if [[ -n "$STARTUP_NOTICE" ]]; then
    printf '  %b✓%b %b%s%b\n\n' "$GREEN$BOLD" "$RESET" "$DIM" "$STARTUP_NOTICE" "$RESET"
  fi
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

render_back_item() {
  local selected="$1"
  if [[ "$selected" == true ]]; then
    printf '%b▶%b %b[ Назад ]%b\n' "$YELLOW$BOLD" "$RESET" "$GRAY$BOLD" "$RESET"
  else
    printf '  %b[ Назад ]%b\n' "$DIM$GRAY" "$RESET"
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
    render_menu_item "$([[ $cursor -eq 2 ]] && printf true || printf false)" 'Автоочистка' 'Создать или изменить задачи очистки по расписанию.'
    printf '\n'
    render_menu_item "$([[ $cursor -eq 3 ]] && printf true || printf false)" 'Выход' 'Завершить работу скрипта.'
    printf '\n'

    read_wizard_key
    case "$WIZARD_KEY" in
      up)
        if (( cursor > 0 )); then cursor=$((cursor - 1)); fi
        ;;
      down)
        if (( cursor < 3 )); then cursor=$((cursor + 1)); fi
        ;;
      enter)
        if (( cursor == 0 )); then
          run_interactive_audit
        elif (( cursor == 1 )); then
          if configure_interactive_cleanup 'Начать очистку'; then
            DRY_RUN=false
            clear_screen
            main
          fi
        elif (( cursor == 2 )); then
          run_auto_cleanup_menu
        else
          render_wizard_frame 'До новых встреч'
          printf '\n  %bХорошего дня!%b\n\n' "$GREEN$BOLD" "$RESET"
          exit 0
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
  local confirm_label="${1:-Начать очистку}"
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
    'Также удаляет syslog.1 и kern.log.1, если они больше порога.'
  )
  local cursor=0 index key available selected
  local item_count="${#keys[@]}" back_index
  back_index=$((item_count + 1))

  while true; do
    render_wizard_frame 'Настройте очистку'
    printf '%bСтрелки ↑/↓%b — строка. %bEnter%b — включить/выключить.\n' "$DIM" "$RESET" "$DIM" "$RESET"
    printf '%bВыберите «%s» и нажмите Enter, когда всё готово.%b\n\n' "$DIM" "$confirm_label" "$RESET"

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
      printf '\n%b▶%b %b[ %s ]%b\n' "$YELLOW$BOLD" "$RESET" "$GREEN$BOLD" "$confirm_label" "$RESET"
    else
      printf '\n  [ %s ]\n' "$confirm_label"
    fi
    render_back_item "$([[ $cursor -eq $back_index ]] && printf true || printf false)"

    read_wizard_key
    case "$WIZARD_KEY" in
      up)
        if (( cursor > 0 )); then cursor=$((cursor - 1)); fi
        ;;
      down)
        if (( cursor < back_index )); then cursor=$((cursor + 1)); fi
        ;;
      enter)
        if (( cursor == item_count )); then
          return 0
        fi
        if (( cursor == back_index )); then
          return 10
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

server_timezone() {
  local timezone=''
  if has_cmd timedatectl; then
    timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
  fi
  [[ -n "$timezone" ]] || timezone="$(date +%Z)"
  printf '%s\n' "$timezone"
}

period_label() {
  case "$1" in
    daily) printf 'Каждый день' ;;
    weekly) printf 'По дням недели' ;;
    monthly) printf 'По числам месяца' ;;
    *) printf 'Неизвестный период' ;;
  esac
}

week_days_label() {
  local input="$1" day result=''
  local -a days
  IFS=',' read -r -a days <<<"$input"
  for day in "${days[@]}"; do
    [[ -z "$result" ]] || result+=', '
    case "$day" in
      Mon) result+='Пн' ;; Tue) result+='Вт' ;; Wed) result+='Ср' ;; Thu) result+='Чт' ;;
      Fri) result+='Пт' ;; Sat) result+='Сб' ;; Sun) result+='Вс' ;;
    esac
  done
  printf '%s\n' "$result"
}

schedule_summary() {
  case "$TASK_PERIOD" in
    daily) printf 'Каждый день · %s' "$TASK_TIME" ;;
    weekly) printf '%s · %s' "$(week_days_label "$TASK_DAYS")" "$TASK_TIME" ;;
    monthly) printf '%s числа · %s' "${TASK_DAYS//,/, }" "$TASK_TIME" ;;
  esac
}

cleanup_options_summary() {
  local item result=''
  local -a items=()
  "$CLEAN_PACKAGE_CACHE" && items+=('кеши')
  "$CLEAN_JOURNAL" && items+=('journal')
  "$CLEAN_CRASH_DUMPS" && items+=('crash dumps')
  "$CLEAN_TMP" && items+=('tmp')
  "$CLEAN_ROTATED_LOGS" && items+=('ротации логов')
  "$WITH_DOCKER" && items+=('Docker')
  "$WITH_DOCKER_VOLUMES" && items+=('Docker volumes')
  "$WITH_AUTOREMOVE" && items+=('autoremove')
  "$WITH_TRUNCATE_LOGS" && items+=('активные логи')
  if (( ${#items[@]} == 0 )); then
    printf 'ничего не выбрано'
  else
    for item in "${items[@]}"; do
      [[ -z "$result" ]] || result+=', '
      result+="$item"
    done
    printf '%s' "$result"
  fi
}

show_scheduler_message() {
  local title_text="$1" message="$2" color="${3:-$CYAN}"
  render_wizard_frame "$title_text"
  printf '  %b%s%b\n\n' "$color$BOLD" "$message" "$RESET"
  printf '%bНажмите Enter, чтобы вернуться.%b' "$DIM" "$RESET"
  wait_for_enter
}

choose_schedule_period() {
  local cursor=0
  case "$TASK_PERIOD" in daily) cursor=0 ;; weekly) cursor=1 ;; monthly) cursor=2 ;; esac
  while true; do
    render_wizard_frame 'Периодичность автоочистки'
    printf '%bСтрелки ↑/↓%b — выбор. %bEnter%b — подтвердить.\n\n' "$DIM" "$RESET" "$DIM" "$RESET"
    render_menu_item "$([[ $cursor -eq 0 ]] && printf true || printf false)" 'Каждый день' 'Запуск ежедневно в указанное время.'
    printf '\n'
    render_menu_item "$([[ $cursor -eq 1 ]] && printf true || printf false)" 'По дням недели' 'Можно отметить один или несколько дней.'
    printf '\n'
    render_menu_item "$([[ $cursor -eq 2 ]] && printf true || printf false)" 'По числам месяца' 'Можно указать несколько чисел от 1 до 31.'
    printf '\n'
    render_back_item "$([[ $cursor -eq 3 ]] && printf true || printf false)"
    read_wizard_key
    case "$WIZARD_KEY" in
      up) if (( cursor > 0 )); then cursor=$((cursor - 1)); fi ;;
      down) if (( cursor < 3 )); then cursor=$((cursor + 1)); fi ;;
      enter)
        case "$cursor" in
          0) TASK_PERIOD='daily'; TASK_DAYS=''; return 0 ;;
          1) TASK_PERIOD='weekly'; return 0 ;;
          2) TASK_PERIOD='monthly'; return 0 ;;
          3) return 10 ;;
        esac
        ;;
    esac
  done
}

choose_input_or_back() {
  local section="$1" prompt="$2" example="$3" current="$4" cursor=0 input=''
  while true; do
    render_wizard_frame "$section"
    printf '  %b%s%b\n' "$CYAN" "$prompt" "$RESET"
    printf '  %bФормат:%b %s\n' "$DIM" "$RESET" "$example"
    [[ -z "$current" ]] || printf '  %bТекущее значение:%b %s\n' "$DIM" "$RESET" "$current"
    printf '\n'
    if (( cursor == 0 )); then
      printf '%b▶%b %b[ Ввести значение ]%b\n' "$YELLOW$BOLD" "$RESET" "$GREEN$BOLD" "$RESET"
    else
      printf '  [ Ввести значение ]\n'
    fi
    render_back_item "$([[ $cursor -eq 1 ]] && printf true || printf false)"
    read_wizard_key
    case "$WIZARD_KEY" in
      up) cursor=0 ;;
      down) cursor=1 ;;
      enter)
        (( cursor == 1 )) && return 10
        render_wizard_frame "$section"
        printf '%b%s%b\n' "$CYAN" "$prompt" "$RESET"
        printf '%bПример: %s%b\n' "$DIM" "$example" "$RESET"
        [[ -z "$current" ]] || printf '%bEnter без значения оставит: %s%b\n' "$DIM" "$current" "$RESET"
        printf '\n> '
        IFS= read -r input </dev/tty || input=''
        [[ -n "$input" ]] || input="$current"
        INPUT_VALUE="$input"
        return 0
        ;;
    esac
  done
}

prompt_schedule_time() {
  local normalized=''
  while true; do
    if ! choose_input_or_back 'Время запуска' 'Введите время запуска' '03:30, 0330, 03 30, 03,30 или 03.30' "$TASK_TIME"; then
      return 10
    fi
    if normalized="$(normalize_time_value "$INPUT_VALUE")"; then
      TASK_TIME="$normalized"
      return 0
    fi
    show_scheduler_message 'Некорректное время' 'Введите часы от 00 до 23 и минуты от 00 до 59.' "$YELLOW"
  done
}

prompt_month_days() {
  local normalized=''
  while true; do
    if ! choose_input_or_back 'Числа месяца' 'Введите числа через запятую' '1, 10, 25, 31' "$TASK_DAYS"; then
      return 10
    fi
    if normalized="$(normalize_month_days "$INPUT_VALUE")"; then
      TASK_DAYS="$normalized"
      return 0
    fi
    show_scheduler_message 'Некорректные числа' 'Допустимы уникальные числа от 1 до 31 через запятую.' "$YELLOW"
  done
}

choose_week_days() {
  local -a codes=(Mon Tue Wed Thu Fri Sat Sun)
  local -a labels=('Понедельник' 'Вторник' 'Среда' 'Четверг' 'Пятница' 'Суббота' 'Воскресенье')
  local -A selected=()
  local day cursor=0 index result=''
  local -a existing
  IFS=',' read -r -a existing <<<"$TASK_DAYS"
  for day in "${existing[@]}"; do [[ -z "$day" ]] || selected["$day"]=1; done

  while true; do
    render_wizard_frame 'Дни недели'
    printf '%bСтрелки ↑/↓%b — строка. %bEnter%b — отметить.\n\n' "$DIM" "$RESET" "$DIM" "$RESET"
    for index in "${!codes[@]}"; do
      day="${codes[$index]}"
      if (( cursor == index )); then printf '%b▶%b ' "$YELLOW$BOLD" "$RESET"; else printf '  '; fi
      if [[ "${selected[$day]:-}" == 1 ]]; then
        printf '%b[x]%b %s\n' "$GREEN" "$RESET" "${labels[$index]}"
      else
        printf '[ ] %s\n' "${labels[$index]}"
      fi
    done
    if (( cursor == 7 )); then
      printf '\n%b▶%b %b[ Продолжить ]%b\n' "$YELLOW$BOLD" "$RESET" "$GREEN$BOLD" "$RESET"
    else
      printf '\n  [ Продолжить ]\n'
    fi
    render_back_item "$([[ $cursor -eq 8 ]] && printf true || printf false)"
    read_wizard_key
    case "$WIZARD_KEY" in
      up) if (( cursor > 0 )); then cursor=$((cursor - 1)); fi ;;
      down) if (( cursor < 8 )); then cursor=$((cursor + 1)); fi ;;
      enter)
        if (( cursor < 7 )); then
          day="${codes[$cursor]}"
          if [[ "${selected[$day]:-}" == 1 ]]; then unset 'selected[$day]'; else selected["$day"]=1; fi
        elif (( cursor == 7 )); then
          result=''
          for day in "${codes[@]}"; do
            [[ "${selected[$day]:-}" == 1 ]] || continue
            [[ -z "$result" ]] || result+=','
            result+="$day"
          done
          if [[ -z "$result" ]]; then
            show_scheduler_message 'Дни не выбраны' 'Отметьте хотя бы один день недели.' "$YELLOW"
          else
            TASK_DAYS="$result"
            return 0
          fi
        else
          return 10
        fi
        ;;
    esac
  done
}

configure_schedule_details() {
  case "$TASK_PERIOD" in
    daily)
      TASK_DAYS=''
      prompt_schedule_time
      ;;
    weekly)
      while true; do
        choose_week_days || return 10
        prompt_schedule_time && return 0
      done
      ;;
    monthly)
      while true; do
        prompt_month_days || return 10
        prompt_schedule_time && return 0
      done
      ;;
  esac
}

review_scheduled_task() {
  local cursor=0
  while true; do
    render_wizard_frame 'Проверка автоматической задачи'
    printf '  %bПериод:%b %s\n' "$CYAN" "$RESET" "$(period_label "$TASK_PERIOD")"
    case "$TASK_PERIOD" in
      weekly) printf '  %bДни:%b %s\n' "$CYAN" "$RESET" "$(week_days_label "$TASK_DAYS")" ;;
      monthly) printf '  %bЧисла:%b %s\n' "$CYAN" "$RESET" "${TASK_DAYS//,/, }" ;;
    esac
    printf '  %bВремя:%b %s\n' "$CYAN" "$RESET" "$TASK_TIME"
    printf '  %bЧасовой пояс:%b %s\n' "$CYAN" "$RESET" "$(server_timezone)"
    printf '  %bОчистка:%b %s\n\n' "$CYAN" "$RESET" "$(cleanup_options_summary)"
    if (( cursor == 0 )); then
      printf '%b▶%b %b[ Сохранить задачу ]%b\n' "$YELLOW$BOLD" "$RESET" "$GREEN$BOLD" "$RESET"
    else
      printf '  [ Сохранить задачу ]\n'
    fi
    render_back_item "$([[ $cursor -eq 1 ]] && printf true || printf false)"
    read_wizard_key
    case "$WIZARD_KEY" in
      up) cursor=0 ;; down) cursor=1 ;;
      enter) (( cursor == 0 )) && return 0 || return 10 ;;
    esac
  done
}

configure_auto_task() {
  local task_id="${1:-}" snapshot is_edit=false
  snapshot="$(cleanup_flags_snapshot)"
  if [[ -n "$task_id" ]]; then
    is_edit=true
    if ! load_task_config "$task_id"; then
      restore_cleanup_flags "$snapshot"
      show_scheduler_message 'Ошибка задачи' 'Конфигурация задачи повреждена или недоступна.' "$RED"
      return 1
    fi
  else
    reset_cleanup_flags
    TASK_PERIOD='daily'; TASK_TIME='03:00'; TASK_DAYS=''
  fi

  while true; do
    if ! choose_schedule_period; then
      restore_cleanup_flags "$snapshot"
      return 10
    fi
    if ! configure_schedule_details; then
      continue
    fi

    while true; do
      if ! configure_interactive_cleanup 'Продолжить'; then
        break
      fi
      if ! review_scheduled_task; then
        continue
      fi
      if ! "$is_edit"; then
        task_id="$(date +%Y%m%d%H%M%S)-$$${RANDOM}"
      fi
      if save_scheduled_task "$task_id"; then
        restore_cleanup_flags "$snapshot"
        show_scheduler_message 'Задача сохранена' "$(schedule_summary)" "$GREEN"
        return 0
      fi
      restore_cleanup_flags "$snapshot"
      show_scheduler_message 'Не удалось сохранить' 'Проверьте systemd и права доступа. Изменения не активированы.' "$RED"
      return 1
    done
  done
}

read_task_metadata() {
  local task_id="$1" snapshot saved_period="$TASK_PERIOD" saved_time="$TASK_TIME" saved_days="$TASK_DAYS"
  snapshot="$(cleanup_flags_snapshot)"
  if ! load_task_config "$task_id"; then
    restore_cleanup_flags "$snapshot"
    TASK_PERIOD="$saved_period"; TASK_TIME="$saved_time"; TASK_DAYS="$saved_days"
    return 1
  fi
  META_PERIOD="$TASK_PERIOD"; META_TIME="$TASK_TIME"; META_DAYS="$TASK_DAYS"
  restore_cleanup_flags "$snapshot"
  TASK_PERIOD="$saved_period"; TASK_TIME="$saved_time"; TASK_DAYS="$saved_days"
}

metadata_summary() {
  local saved_period="$TASK_PERIOD" saved_time="$TASK_TIME" saved_days="$TASK_DAYS"
  TASK_PERIOD="$META_PERIOD"; TASK_TIME="$META_TIME"; TASK_DAYS="$META_DAYS"
  schedule_summary
  TASK_PERIOD="$saved_period"; TASK_TIME="$saved_time"; TASK_DAYS="$saved_days"
}

load_task_list() {
  local file task_id
  TASK_IDS=(); TASK_LABELS=()
  [[ -d "$TASKS_DIR" ]] || return 0
  for file in "$TASKS_DIR"/*.conf; do
    [[ -f "$file" ]] || continue
    task_id="${file##*/}"; task_id="${task_id%.conf}"
    validate_task_id "$task_id" || continue
    TASK_IDS+=("$task_id")
    if read_task_metadata "$task_id"; then
      TASK_LABELS+=("$(metadata_summary)")
    else
      TASK_LABELS+=('Повреждённая конфигурация')
    fi
  done
}

confirm_task_deletion() {
  local task_id="$1" cursor=1
  while true; do
    render_wizard_frame 'Удаление автоматической задачи'
    printf '  %bЗадача:%b %s\n' "$CYAN" "$RESET" "$task_id"
    printf '  %bЭто действие нельзя отменить.%b\n\n' "$YELLOW" "$RESET"
    if (( cursor == 0 )); then
      printf '%b▶%b %b[ Удалить задачу ]%b\n' "$YELLOW$BOLD" "$RESET" "$RED$BOLD" "$RESET"
    else
      printf '  [ Удалить задачу ]\n'
    fi
    render_back_item "$([[ $cursor -eq 1 ]] && printf true || printf false)"
    read_wizard_key
    case "$WIZARD_KEY" in
      up) cursor=0 ;; down) cursor=1 ;;
      enter) (( cursor == 0 )) && return 0 || return 10 ;;
    esac
  done
}

run_task_actions_menu() {
  local task_id="$1" label="$2" cursor=0
  while true; do
    render_wizard_frame 'Автоматическая задача'
    printf '  %b%s%b\n  %bID: %s%b\n\n' "$BOLD" "$label" "$RESET" "$DIM" "$task_id" "$RESET"
    render_menu_item "$([[ $cursor -eq 0 ]] && printf true || printf false)" 'Изменить' 'Повторно открыть настройку расписания и очистки.'
    printf '\n'
    render_menu_item "$([[ $cursor -eq 1 ]] && printf true || printf false)" 'Удалить' 'Остановить таймер и удалить эту задачу.'
    printf '\n'
    render_back_item "$([[ $cursor -eq 2 ]] && printf true || printf false)"
    read_wizard_key
    case "$WIZARD_KEY" in
      up) if (( cursor > 0 )); then cursor=$((cursor - 1)); fi ;;
      down) if (( cursor < 2 )); then cursor=$((cursor + 1)); fi ;;
      enter)
        if (( cursor == 0 )); then
          configure_auto_task "$task_id" || true
          return 0
        elif (( cursor == 1 )); then
          if confirm_task_deletion "$task_id"; then
            if delete_scheduled_task "$task_id"; then
              show_scheduler_message 'Задача удалена' "$label" "$GREEN"
            else
              show_scheduler_message 'Ошибка удаления' 'Не удалось остановить или удалить задачу.' "$RED"
            fi
            return 0
          fi
        else
          return 0
        fi
        ;;
    esac
  done
}

run_auto_cleanup_menu() {
  local cursor=0 index count add_index back_index
  if ! scheduler_available; then
    show_scheduler_message 'Автоочистка недоступна' 'На сервере не запущен systemd.' "$YELLOW"
    return 0
  fi

  while true; do
    load_task_list
    count="${#TASK_IDS[@]}"
    if (( count == 0 )); then
      configure_auto_task '' || true
      load_task_list
      (( ${#TASK_IDS[@]} > 0 )) || return 0
    fi

    count="${#TASK_IDS[@]}"; add_index="$count"; back_index=$((count + 1))
    (( cursor <= back_index )) || cursor="$back_index"
    render_wizard_frame 'Автоочистка'
    printf '%bВыберите задачу, добавьте новую или вернитесь назад.%b\n\n' "$DIM" "$RESET"
    for index in "${!TASK_IDS[@]}"; do
      render_menu_item "$([[ $cursor -eq $index ]] && printf true || printf false)" "${TASK_LABELS[$index]}" "ID: ${TASK_IDS[$index]}"
      printf '\n'
    done
    render_menu_item "$([[ $cursor -eq $add_index ]] && printf true || printf false)" 'Добавить задачу' 'Настроить новое расписание автоочистки.'
    printf '\n'
    render_back_item "$([[ $cursor -eq $back_index ]] && printf true || printf false)"
    read_wizard_key
    case "$WIZARD_KEY" in
      up) if (( cursor > 0 )); then cursor=$((cursor - 1)); fi ;;
      down) if (( cursor < back_index )); then cursor=$((cursor + 1)); fi ;;
      enter)
        if (( cursor < count )); then
          run_task_actions_menu "${TASK_IDS[$cursor]}" "${TASK_LABELS[$cursor]}"
        elif (( cursor == add_index )); then
          configure_auto_task '' || true
        else
          return 0
        fi
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
AUDIT_LARGE_LOG_BYTES=0

audit_write_state() {
  local pending_file="${AUDIT_STATE_DIR}/state.pending"
  printf '%s\t%s\t%s\n' "$AUDIT_COUNT" "$AUDIT_BYTES" "$AUDIT_LARGE_LOG_BYTES" >"$pending_file"
  mv -f -- "$pending_file" "${AUDIT_STATE_DIR}/state"
}

audit_add_candidate() {
  local path="$1" size='0'
  [[ -f "$path" || -L "$path" ]] || return 0
  size="$(stat -c '%s' -- "$path" 2>/dev/null || printf '0')"
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  AUDIT_COUNT=$((AUDIT_COUNT + 1))
  AUDIT_BYTES=$((AUDIT_BYTES + size))
  if [[ "${2:-}" == large-log ]]; then
    AUDIT_LARGE_LOG_BYTES=$((AUDIT_LARGE_LOG_BYTES + size))
  fi
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
  local log_dir="${1:-/var/log}" path name kind
  [[ -d "$log_dir" ]] || return 0
  while IFS= read -r -d '' kind && IFS= read -r -d '' path; do
    name="${path##*/}"
    if [[ "$kind" == large-log ]] || is_rotated_log "$name"; then
      audit_add_candidate "$path" "$kind"
    fi
  done < <(find "$log_dir" -xdev -type f \( \
    \( -path "$log_dir/syslog" -o -path "$log_dir/kern.log" \
       -o -path "$log_dir/syslog.1" -o -path "$log_dir/kern.log.1" \) \
    -size "+$ACTIVE_LOG_MIN_SIZE" -printf 'large-log\0%p\0' \
    -o -mtime "+$ROTATED_LOG_AGE_DAYS" -printf 'rotated\0%p\0' \) 2>/dev/null)
}

audit_collect_candidates() {
  AUDIT_COUNT=0
  AUDIT_BYTES=0
  AUDIT_LARGE_LOG_BYTES=0
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
  AUDIT_DISPLAY_LARGE_LOG_BYTES=0
  if [[ -s "$state_file" ]]; then
    IFS=$'\t' read -r AUDIT_DISPLAY_COUNT AUDIT_DISPLAY_BYTES AUDIT_DISPLAY_LARGE_LOG_BYTES <"$state_file" || true
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
  printf '  %bПотенциально освободится:%b %b%s%b\n' "$CYAN" "$RESET" "$GREEN$BOLD" "$(format_bytes "$AUDIT_DISPLAY_BYTES")" "$RESET"
  printf '  %bИз них крупные syslog и kern.log с ротациями:%b %s\n\n' "$CYAN" "$RESET" "$(format_bytes "$AUDIT_DISPLAY_LARGE_LOG_BYTES")"
  printf '%bДля очистки крупных syslog и kern.log с ротациями включите «Активные логи».%b\n\n' "$DIM" "$RESET"
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
  say "Из них крупные syslog и kern.log с ротациями: $(format_bytes "$AUDIT_DISPLAY_LARGE_LOG_BYTES")"
  note 'Для очистки крупных syslog и kern.log с ротациями используйте --truncate-logs.'
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
  if ! "$INTERACTIVE_MODE" && ! "$SCHEDULED_MODE"; then
    report_large_files
  fi

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

if [[ "$AUTOCLEAN_LIBRARY_MODE" == 1 ]]; then
  :
elif "$SCHEDULED_MODE"; then
  run_scheduled_task
elif "$INTERACTIVE_MODE"; then
  run_interactive_main_menu
elif "$AUDIT_ONLY"; then
  run_noninteractive_audit
else
  main "$@"
fi
