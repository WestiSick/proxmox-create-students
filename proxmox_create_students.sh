#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Proxmox VE 8.x: создание студентов из CSV (Фамилия,Имя) UTF-8
# Выход: students_passwords.csv -> fio_ru;username;password;pool
#
# ВАРИАНТ A:
# - отдельная роль StudentVMWizard на /vms (для прохождения Create VM wizard)
# - отдельная роль StudentVM на /pool/<pool> (управление только своими VM)
# - SDN.Use на vmbr0 (иначе bridge пустой / 403 при создании NIC)
# - ISO storage только на чтение (Datastore.Audit)
# - VM storage для дисков (Datastore.AllocateSpace)
# ==========================================================

# --------------------
# Настройки
# --------------------
REALM="pve"
GROUP="students"

INPUT="students.csv"
OUT="students_passwords.csv"

# Storage с ISO (Datacenter -> Storage)
ISO_STORAGE="iso-students"

# Storage для дисков VM (например: local-lvm / local-zfs / ceph и т.п.)
VM_STORAGE="local-lvm"

# Разрешаемый bridge (обычно vmbr0)
BRIDGE="vmbr0"

# (опционально) дата окончания доступа (YYYY-MM-DD), пусто = без срока
EXPIRE_DATE=""

# 1 = показать команды без изменений, 0 = выполнить
DRY_RUN=0

# --------------------
# Роли
# --------------------
ROLE_STUDENT_VM="StudentVM"              # права на управление ВМ внутри СВОЕГО пула
ROLE_WIZARD="StudentVMWizard"            # права для прохождения Create VM wizard на /vms
ROLE_ISO="ISOReader"                     # видеть ISO storage
ROLE_VMSTORE="StudentVMStore"            # выделять место на storage для дисков
ROLE_NODE_AUDIT="StudentNodeAudit"       # (опционально) для UI
ROLE_SDN_USE_FALLBACK="StudentSDNUse"    # если PVESDNUser отсутствует

# --------------------
# Helpers
# --------------------
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

trim() { echo "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'; }

role_exists() { pveum role list | awk '{print $1}' | grep -Fxq "$1"; }
group_exists(){ pveum group list | awk '{print $1}' | grep -Fxq "$1"; }
user_exists() { pveum user list  | awk '{print $1}' | grep -Fxq "$1"; }

pool_exists() {
  local p="$1"
  pvesh get /pools --output-format json 2>/dev/null | grep -q "\"poolid\":\"$p\""
}

storage_exists() {
  local st="$1"
  pvesh get /storage --output-format json 2>/dev/null | grep -q "\"storage\":\"$st\""
}

get_nodes() {
  pvesh get /nodes --output-format json | sed -n 's/.*"node":"\([^"]*\)".*/\1/p'
}

# --- RU -> EN транслитерация через python3 (без потери кириллицы) ---
translit_ru_to_en() {
  local s="$1"
  python3 - <<'PY' "$s"
import re, sys
s = sys.argv[1].strip().casefold()
m = {
  "а":"a","б":"b","в":"v","г":"g","д":"d","е":"e","ё":"yo","ж":"zh","з":"z","и":"i","й":"y",
  "к":"k","л":"l","м":"m","н":"n","о":"o","п":"p","р":"r","с":"s","т":"t","у":"u","ф":"f",
  "х":"kh","ц":"ts","ч":"ch","ш":"sh","щ":"shch","ъ":"","ы":"y","ь":"","э":"e","ю":"yu","я":"ya",
}
out = "".join(m.get(ch, ch) for ch in s)
out = re.sub(r"[^a-z0-9._-]+", "_", out).strip("_")
print(out)
PY
}

# --------------------
# Main
# --------------------
require_root

if [[ ! -f "$INPUT" ]]; then
  echo "Не найден входной файл: $INPUT" >&2
  exit 1
fi

if ! storage_exists "$ISO_STORAGE"; then
  echo "Storage ISO '$ISO_STORAGE' не найден (Datacenter -> Storage)." >&2
  exit 1
fi

if ! storage_exists "$VM_STORAGE"; then
  echo "Storage VM '$VM_STORAGE' не найден (Datacenter -> Storage)." >&2
  exit 1
fi

if [[ "$ISO_STORAGE" == "$VM_STORAGE" ]]; then
  echo "ОШИБКА: ISO_STORAGE и VM_STORAGE не должны совпадать." >&2
  exit 1
fi

# 1) Роли
if ! role_exists "$ROLE_STUDENT_VM"; then
  echo "Создаю роль $ROLE_STUDENT_VM ..."
  # Управление VM в своём пуле (без прав видеть чужие VM на /vms).
  # Важно: Pool.Allocate чтобы VM можно было класть в свой pool.
  PRIVS="VM.Audit,VM.Console,VM.PowerMgmt,VM.Config.CDROM,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,VM.Config.Disk,VM.Config.Options,VM.Config.HWType,Pool.Allocate,Pool.Audit"
  run "pveum role add '$ROLE_STUDENT_VM' -privs '$PRIVS'"
fi

if ! role_exists "$ROLE_WIZARD"; then
  echo "Создаю роль $ROLE_WIZARD ..."
  # Права для Create VM wizard на /vms:
  # VM.Allocate + конфиг основных параметров + HWType (иначе 403 VM.Config.HWType)
  PRIVS="VM.Allocate,VM.Config.CDROM,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,VM.Config.Disk,VM.Config.Options,VM.Config.HWType"
  run "pveum role add '$ROLE_WIZARD' -privs '$PRIVS'"
fi

if ! role_exists "$ROLE_ISO"; then
  echo "Создаю роль $ROLE_ISO ..."
  run "pveum role add '$ROLE_ISO' -privs 'Datastore.Audit'"
fi

if ! role_exists "$ROLE_VMSTORE"; then
  echo "Создаю роль $ROLE_VMSTORE ..."
  run "pveum role add '$ROLE_VMSTORE' -privs 'Datastore.Audit,Datastore.AllocateSpace'"
fi

if ! role_exists "$ROLE_NODE_AUDIT"; then
  echo "Создаю роль $ROLE_NODE_AUDIT ..."
  run "pveum role add '$ROLE_NODE_AUDIT' -privs 'Sys.Audit'"
fi

# SDN.Use: используем PVESDNUser если есть, иначе создаём fallback роль
SDN_ROLE="PVESDNUser"
if ! role_exists "$SDN_ROLE"; then
  SDN_ROLE="$ROLE_SDN_USE_FALLBACK"
  if ! role_exists "$SDN_ROLE"; then
    echo "PVESDNUser не найден, создаю роль $SDN_ROLE (SDN.Use) ..."
    run "pveum role add '$SDN_ROLE' -privs 'SDN.Use'"
  fi
fi

# 2) Группа
if ! group_exists "$GROUP"; then
  echo "Создаю группу $GROUP ..."
  run "pveum group add '$GROUP'"
fi

# 3) ACL на группу (общие)
echo "ACL: /vms -> $ROLE_WIZARD (Create VM wizard)"
run "pveum acl modify '/vms' -group '$GROUP' -role '$ROLE_WIZARD'"

echo "ACL: ISO storage /storage/$ISO_STORAGE -> $ROLE_ISO (только просмотр)"
run "pveum acl modify '/storage/$ISO_STORAGE' -group '$GROUP' -role '$ROLE_ISO'"

echo "ACL: VM disk storage /storage/$VM_STORAGE -> $ROLE_VMSTORE (выделение места под диски)"
run "pveum acl modify '/storage/$VM_STORAGE' -group '$GROUP' -role '$ROLE_VMSTORE'"

echo "ACL: SDN.Use на bridge $BRIDGE (чтобы bridge был виден/доступен в NIC)"
run "pveum acl modify '/sdn/zones/localnetwork/$BRIDGE' -group '$GROUP' -role '$SDN_ROLE'"

echo "ACL: Sys.Audit на ноды (опционально, но полезно для UI)"
for n in $(get_nodes); do
  run "pveum acl modify '/nodes/$n' -group '$GROUP' -role '$ROLE_NODE_AUDIT'"
done

# 4) Выходной файл
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "fio_ru;username;password;pool" > "$OUT"
fi

# 5) Студенты
echo "Создаю студентов из $INPUT ..."

while IFS=',' read -r LAST_RU FIRST_RU; do
  LAST_RU="$(trim "${LAST_RU:-}")"
  FIRST_RU="$(trim "${FIRST_RU:-}")"
  LAST_RU="${LAST_RU%$'\r'}"
  FIRST_RU="${FIRST_RU%$'\r'}"

  [[ -z "$LAST_RU" ]] && continue
  [[ "$LAST_RU" =~ ^# ]] && continue

  fio_ru="${LAST_RU} ${FIRST_RU}"
  base="$(translit_ru_to_en "$LAST_RU")"
  [[ -z "$base" ]] && { echo "Пропускаю '$fio_ru' (пустой логин)"; continue; }

  suffix=0
  while :; do
    login="$base"
    [[ "$suffix" -gt 0 ]] && login="${base}${suffix}"
    username="${login}@${REALM}"
    user_exists "$username" && { ((suffix++)); continue; }
    break
  done

  pool="student_${login}"
  password="$(openssl rand -base64 24 | tr -d '=+/ ' | cut -c1-12)"

  echo "==> $fio_ru -> $username / $pool"

  if ! user_exists "$username"; then
    if [[ -n "$EXPIRE_DATE" ]]; then
      run "pveum user add '$username' --password '$password' --expire '$EXPIRE_DATE' --comment 'Student $fio_ru'"
    else
      run "pveum user add '$username' --password '$password' --comment 'Student $fio_ru'"
    fi
  fi

  run "pveum user modify '$username' -group '$GROUP'"

  if ! pool_exists "$pool"; then
    run "pvesh create /pools --poolid '$pool'"
  fi

  # Права только на свой pool:
  run "pveum acl modify '/pool/$pool' -user '$username' -role '$ROLE_STUDENT_VM'"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "${fio_ru};${username};${password};${pool}" >> "$OUT"
  fi

done < "$INPUT"

echo
echo "Готово."
[[ "$DRY_RUN" -eq 0 ]] && echo "Файл с паролями: $OUT"
echo "ВАЖНО: студентам нужно перелогиниться в WEB."
echo "ВАЖНО: ISO storage должен иметь Content=ISO (без Disk image), а VM_STORAGE должен иметь Content=Disk image."
