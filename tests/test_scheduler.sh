#!/usr/bin/env bash
# shellcheck shell=bash

set -Eeuo pipefail
IFS=$'\n\t'

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/autoclean-scheduler-test.XXXXXX")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

export AUTOCLEAN_LIBRARY_MODE=1
export AUTOCLEAN_TEST_MODE=1
export AUTOCLEAN_TASKS_DIR="${TEST_ROOT}/tasks"
export AUTOCLEAN_SYSTEMD_DIR="${TEST_ROOT}/systemd"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "${REPO_ROOT}/cleanup-server.sh"

# Git Bash on Windows cannot represent Linux ownership modes. These two stubs
# preserve the generated files and record the modes that production requests.
install() {
  ( IFS=' '; printf '%s\n' "$*" ) >>"${TEST_ROOT}/install.log"
  mkdir -p -- "${*: -1}"
}

chmod() {
  ( IFS=' '; printf '%s\n' "$*" ) >>"${TEST_ROOT}/chmod.log"
}

systemctl() {
  ( IFS=' '; printf '%s\n' "$*" ) >>"${TEST_ROOT}/systemctl.log"
}

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf 'Ожидалось <%s>, получено <%s>\n' "$2" "$1" >&2
    exit 1
  fi
}

assert_file_has() {
  if ! grep -F -- "$2" "$1" >/dev/null; then
    printf 'В %s не найдено: %s\n' "$1" "$2" >&2
    exit 1
  fi
}

for raw in '00:00' '0000' '00 00' '00,00' '00.00' '23:59'; do
  compact="${raw//[ :,.]/}"
  assert_eq "$(normalize_time_value "$raw")" "${compact:0:2}:${compact:2:2}"
done

for raw in '24:00' '12:60' '1:00' '120' 'abcd' ''; do
  if normalize_time_value "$raw" >/dev/null 2>&1; then
    printf 'Принято некорректное время: %s\n' "$raw" >&2
    exit 1
  fi
done

assert_eq "$(normalize_month_days '31, 1,01,15,15')" '1,15,31'
for raw in '' '0' '32' '1;2' 'a,2'; do
  if normalize_month_days "$raw" >/dev/null 2>&1; then
    printf 'Приняты некорректные числа месяца: %s\n' "$raw" >&2
    exit 1
  fi
done

validate_week_days 'Mon,Wed,Sun'
if validate_week_days ''; then
  printf 'Принят пустой список дней недели.\n' >&2
  exit 1
fi
if validate_week_days 'Mon,Mon'; then
  printf 'Приняты повторяющиеся дни недели.\n' >&2
  exit 1
fi

id_daily='20260903120000-101'
id_weekly='20260903120000-102'
id_monthly='20260903120000-103'

reset_cleanup_flags
TASK_PERIOD='daily'; TASK_TIME='04:05'; TASK_DAYS=''
AUTOCLEAN_TEST_MODE=0
if save_scheduled_task "$id_daily"; then
  printf 'Задача сохранилась без доступного systemd.\n' >&2
  exit 1
fi
[[ ! -e "$TASKS_DIR" && ! -e "$SYSTEMD_UNIT_DIR" ]]
AUTOCLEAN_TEST_MODE=1

save_scheduled_task "$id_daily"
assert_file_has "${SYSTEMD_UNIT_DIR}/autoclean-${id_daily}.timer" 'OnCalendar=*-*-* 04:05:00'
assert_file_has "${SYSTEMD_UNIT_DIR}/autoclean-${id_daily}.timer" 'Persistent=true'
assert_file_has "${SYSTEMD_UNIT_DIR}/autoclean-${id_daily}.timer" "Unit=autoclean@${id_daily}.service"
assert_file_has "$SERVICE_UNIT_PATH" 'ExecStart=/usr/local/bin/cll --scheduled-task %i'
assert_file_has "${TEST_ROOT}/install.log" "-d -m 0700 -- ${TASKS_DIR}"
assert_file_has "${TEST_ROOT}/chmod.log" "0600 ${TASKS_DIR}/${id_daily}.conf.tmp."

TASK_PERIOD='weekly'; TASK_TIME='2215'; TASK_DAYS='Mon,Thu'; WITH_DOCKER=true
save_scheduled_task "$id_weekly"
assert_file_has "${SYSTEMD_UNIT_DIR}/autoclean-${id_weekly}.timer" 'OnCalendar=Mon *-*-* 22:15:00'
assert_file_has "${SYSTEMD_UNIT_DIR}/autoclean-${id_weekly}.timer" 'OnCalendar=Thu *-*-* 22:15:00'

TASK_PERIOD='monthly'; TASK_TIME='01.20'; TASK_DAYS='31, 1,15'
save_scheduled_task "$id_monthly"
assert_file_has "${SYSTEMD_UNIT_DIR}/autoclean-${id_monthly}.timer" 'OnCalendar=*-*-01 01:20:00'
assert_file_has "${SYSTEMD_UNIT_DIR}/autoclean-${id_monthly}.timer" 'OnCalendar=*-*-15 01:20:00'
assert_file_has "${SYSTEMD_UNIT_DIR}/autoclean-${id_monthly}.timer" 'OnCalendar=*-*-31 01:20:00'

# shellcheck disable=SC2034
TASK_PERIOD='daily'; TASK_TIME='06,45'; TASK_DAYS=''; WITH_DOCKER=false
save_scheduled_task "$id_daily"
assert_file_has "${SYSTEMD_UNIT_DIR}/autoclean-${id_daily}.timer" 'OnCalendar=*-*-* 06:45:00'
load_task_config "$id_daily"
assert_eq "$TASK_TIME" '06:45'

delete_scheduled_task "$id_weekly"
[[ ! -e "${TASKS_DIR}/${id_weekly}.conf" ]]
[[ ! -e "${SYSTEMD_UNIT_DIR}/autoclean-${id_weekly}.timer" ]]
[[ -e "${TASKS_DIR}/${id_daily}.conf" && -e "${TASKS_DIR}/${id_monthly}.conf" ]]
assert_file_has "${TEST_ROOT}/systemctl.log" "enable --now autoclean-${id_daily}.timer"
assert_file_has "${TEST_ROOT}/systemctl.log" "restart autoclean-${id_daily}.timer"
assert_file_has "${TEST_ROOT}/systemctl.log" "disable --now autoclean-${id_weekly}.timer"

printf 'UNKNOWN_KEY=true\n' >>"${TASKS_DIR}/${id_monthly}.conf"
if load_task_config "$id_monthly"; then
  printf 'Принят неизвестный ключ конфигурации.\n' >&2
  exit 1
fi

printf 'scheduler tests: OK\n'
