#!/usr/bin/env bash
set -euo pipefail

# =========================
# Настройки
# =========================
REALM="pve"
GROUP="students"

# Storage, где лежат ISO (Datacenter -> Storage)
ISO_STORAGE="iso-students"

# Входной файл (lastname,firstname)
INPUT="students.csv"

# Выходной файл (логины/пароли)
OUT="students_passwords.csv"

# (опционально) дата окончания доступа (YYYY-MM-DD), пусто = без срока
EXPIRE_DATE=""

# 1 = только показать команды, 0 = выполнить
DRY_RUN=0

# =========================
# Роли
# =========================
ROLE_VM="StudentVM"
ROLE_ISO="ISOReader"
ROLE_NET="StudentNetUse"
ROLE_NODE="StudentNodeAudit"

# =========================
# Вспомогательные функции
# =========================
run() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "[DRY] $*"
  else
    eval "$@"
  fi
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "Запусти от root (или через sudo)." >&2
    exit 1
  fi
}

sanitize() {
  local s="$1"
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"
  s="$(echo "$s" | sed -E 's/[^a-z0-9._-]+/_/g; s/^_+|_+$//g')"
  echo "$s"
}

user_exists() {
  local u="$1"
  pveum user list | awk '{print $1}' | grep -Fxq "$u"
}

group_exists() {
  local g="$1"
  pveum group list | awk '{print $1}' | grep -Fxq "$g"
}

role_exists() {
  local r="$1"
  pveum role list | awk '{print $1}' | grep -Fxq "$r"
}

pool_exists() {
  local p="$1"
  pvesh get /pools --output-format json 2>/dev/null | grep -q "\"poolid\":\"$p\""
}

storage_exists() {
  local st="$1"
  pvesh get /storage --output-format json 2>/dev/null | grep -q "\"storage\":\"$st\""
}

get_nodes() {
  # печатает имена нод по одному в строку
  pvesh get /nodes --output-format json | sed -n 's/.*"node":"\([^"]*\)".*/\1/p'
}

# =========================
# Проверки
# =========================
require_root

if [[ ! -f "$INPUT" ]]; then
  echo "Не найден входной файл: $INPUT" >&2
  exit 1
fi

if ! storage_exists "$ISO_STORAGE"; then
  echo "Storage '$ISO_STORAGE' не найден в Proxmox (Datacenter -> Storage)." >&2
  echo "Поменяй ISO_STORAGE в скрипте или создай такой storage." >&2
  exit 1
fi

# =========================
# 1) Роли
# =========================

# Роль для управления ТОЛЬКО своей ВМ (назначается на /pool/student_xxx)
if ! role_exists "$ROLE_VM"; then
  echo "Создаю роль $ROLE_VM ..."
  PRIVS_VM="VM.Audit,VM.Allocate,VM.Console,VM.PowerMgmt,VM.Config.CDROM,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,VM.Config.Disk,VM.Config.Options,Datastore.Audit"
  run "pveum role add '$ROLE_VM' -privs '$PRIVS_VM'"
else
  echo "Роль $ROLE_VM уже существует."
fi

# Роль только чтобы видеть ISO storage
if ! role_exists "$ROLE_ISO"; then
  echo "Создаю роль $ROLE_ISO ..."
  run "pveum role add '$ROLE_ISO' -privs 'Datastore.Audit'"
else
  echo "Роль $ROLE_ISO уже существует."
fi

# Роль чтобы в UI появились bridges/vnets в Network (назначается на /vms)
# SDN.Allocate часто нужен, чтобы UI не прятал выбор сети.
if ! role_exists "$ROLE_NET"; then
  echo "Создаю роль $ROLE_NET ..."
  run "pveum role add '$ROLE_NET' -privs 'SDN.Audit,SDN.Use,SDN.Allocate'"
else
  echo "Роль $ROLE_NET уже существует."
fi

# Роль чтобы читать конфиг ноды (часто требуется, чтобы vmbr0 показался)
if ! role_exists "$ROLE_NODE"; then
  echo "Создаю роль $ROLE_NODE ..."
  run "pveum role add '$ROLE_NODE' -privs 'Sys.Audit'"
else
  echo "Роль $ROLE_NODE уже существует."
fi

# =========================
# 2) Группа + ACL (один раз)
# =========================
if ! group_exists "$GROUP"; then
  echo "Создаю группу $GROUP ..."
  run "pveum group add '$GROUP'"
else
  echo "Группа $GROUP уже существует."
fi

echo "Назначаю группе $GROUP доступ к ISO на /storage/$ISO_STORAGE ..."
run "pveum acl modify '/storage/$ISO_STORAGE' -group '$GROUP' -role '$ROLE_ISO'"

echo "Назначаю группе $GROUP сетевые права на /vms (чтобы появился Bridge/vmbr0) ..."
run "pveum acl modify '/vms' -group '$GROUP' -role '$ROLE_NET'"

echo "Назначаю группе $GROUP Sys.Audit на все ноды (чтобы UI видел vmbr0) ..."
for n in $(get_nodes); do
  run "pveum acl modify '/nodes/$n' -group '$GROUP' -role '$ROLE_NODE'"
done

# =========================
# 3) Создание студентов
# =========================
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "username;password;pool" > "$OUT"
fi

echo "Создаю студентов из $INPUT ..."

while IFS=',' read -r LAST FIRST; do
  LAST="${LAST:-}"
  FIRST="${FIRST:-}"

  LAST="$(echo "$LAST" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  FIRST="$(echo "$FIRST" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

  [[ -z "$LAST" ]] && continue
  [[ "$LAST" =~ ^# ]] && continue

  base="$(sanitize "$LAST")"
  if [[ -z "$base" ]]; then
    echo "Пропускаю некорректную фамилию: '$LAST'" >&2
    continue
  fi

  # Уникализация (ivanov, ivanov -> ivanov2, ivanov3)
  suffix=0
  while :; do
    if [[ "$suffix" -eq 0 ]]; then
      login="$base"
    else
      login="${base}${suffix}"
    fi
    username="${login}@${REALM}"
    if user_exists "$username"; then
      ((suffix++))
      continue
    fi
    break
  done

  pool="student_${login}"
  password="$(openssl rand -base64 12 | tr -d '=+/ ' | cut -c1-12)"

  echo "==> $LAST $FIRST -> $username / $pool"

  if [[ -n "$EXPIRE_DATE" ]]; then
    run "pveum user add '$username' --password '$password' --expire '$EXPIRE_DATE' --comment 'Student $FIRST $LAST'"
  else
    run "pveum user add '$username' --password '$password' --comment 'Student $FIRST $LAST'"
  fi

  run "pveum user modify '$username' -group '$GROUP'"

  if ! pool_exists "$pool"; then
    run "pvesh create /pools --poolid '$pool'"
  fi

  # Права на ВМ — только внутри своего пула
  run "pveum acl modify '/pool/$pool' -user '$username' -role '$ROLE_VM'"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "${username};${password};${pool}" >> "$OUT"
  fi

done < "$INPUT"

echo
echo "Готово."
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "Пароли: $OUT"
fi
echo "Важно: студентам нужно выйти/войти в веб-интерфейс Proxmox, чтобы обновились права."
