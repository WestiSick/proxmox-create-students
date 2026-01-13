#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Proxmox VE 8.x: создание студентов из CSV с РУССКИМИ ФИО
# Вход:  students.csv  (Фамилия,Имя) UTF-8
# Выход: students_passwords.csv: "Фамилия Имя;username;password;pool"
#
# Делает:
# - роли/группа (если нет)
# - ACL:
#    /storage/<ISO_STORAGE>    -> ISOReader (Datastore.Audit)
#    /storage/<VM_STORAGE>     -> VMStore   (Datastore.Audit + Datastore.AllocateSpace)
#    /sdn/zones/localnetwork/<BRIDGE> -> SDNUse (SDN.Use)  [чтобы был виден bridge и не было 403]
#    /nodes/<node>             -> NodeAudit (Sys.Audit)    [не обязательно, но полезно для UI]
# - для каждого студента:
#    user:  <lastname_translit>@pve (уникализирует)
#    pool:  student_<login>
#    ACL на /pool/<pool> -> StudentVM
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

# Storage для ДИСКОВ VM (например: local-lvm или local-zfs и т.п.)
VM_STORAGE="local-lvm"

# Какой bridge разрешаем студентам (обычно vmbr0)
BRIDGE="vmbr0"

# (опционально) дата окончания доступа (YYYY-MM-DD), пусто = без срока
EXPIRE_DATE=""

# 1 = показать команды без изменений, 0 = выполнить
DRY_RUN=0

# --------------------
# Роли
# --------------------
ROLE_STUDENT_VM="StudentVM"
ROLE_ISO="ISOReader"
ROLE_VMSTORE="StudentVMStore"
ROLE_NODE_AUDIT="StudentNodeAudit"
ROLE_SDN_USE="StudentSDNUse"  # кастомная роль на случай, если PVESDNUser недоступна

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

# --- RU -> EN транслитерация (Unicode-нормально, через python3) ---
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

# всё, что не латиница/цифры/._- -> _
out = re.sub(r"[^a-z0-9._-]+", "_", out)
out = out.strip("_")
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

# 1) Роли
if ! role_exists "$ROLE_STUDENT_VM"; then
  echo "Создаю роль $ROLE_STUDENT_VM ..."
  # Минимально нужное студенту в своём пуле:
  # - создавать VM, открывать консоль, включать/выключать
  # - настраивать CPU/RAM/Disk/Network/CDROM/Options
  # - (Pool.Audit) чтобы UI нормально показывал пул
  PRIVS_VM="VM.Audit,VM.Allocate,VM.Console,VM.PowerMgmt,VM.Config.CDROM,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,VM.Config.Disk,VM.Config.Options,Pool.Audit"
  run "pveum role add '$ROLE_STUDENT_VM' -privs '$PRIVS_VM'"
else
  echo "Роль $ROLE_STUDENT_VM уже существует."
fi

if ! role_exists "$ROLE_ISO"; then
  echo "Создаю роль $ROLE_ISO ..."
  run "pveum role add '$ROLE_ISO' -privs 'Datastore.Audit'"
else
  echo "Роль $ROLE_ISO уже существует."
fi

if ! role_exists "$ROLE_VMSTORE"; then
  echo "Создаю роль $ROLE_VMSTORE ..."
  run "pveum role add '$ROLE_VMSTORE' -privs 'Datastore.Audit,Datastore.AllocateSpace'"
else
  echo "Роль $ROLE_VMSTORE уже существует."
fi

if ! role_exists "$ROLE_NODE_AUDIT"; then
  echo "Создаю роль $ROLE_NODE_AUDIT ..."
  run "pveum role add '$ROLE_NODE_AUDIT' -privs 'Sys.Audit'"
else
  echo "Роль $ROLE_NODE_AUDIT уже существует."
fi

# SDN.Use: в PVE 8 это обязательно, иначе bridge/vmbr0 не виден и 403 при создании NIC.
# Если есть builtin роль PVESDNUser — используем её. Если нет — создаём кастомную с SDN.Use.
SDN_ROLE_TO_USE="PVESDNUser"
if ! role_exists "$SDN_ROLE_TO_USE"; then
  SDN_ROLE_TO_USE="$ROLE_SDN_USE"
  if ! role_exists "$SDN_ROLE_TO_USE"; then
    echo "PVESDNUser не найден, создаю роль $SDN_ROLE_TO_USE (SDN.Use) ..."
    run "pveum role add '$SDN_ROLE_TO_USE' -privs 'SDN.Use'"
  fi
else
  echo "Builtin роль PVESDNUser найдена — использую её."
fi

# 2) Группа
if ! group_exists "$GROUP"; then
  echo "Создаю группу $GROUP ..."
  run "pveum group add '$GROUP'"
else
  echo "Группа $GROUP уже существует."
fi

# 3) ACL на группу (общие)
echo "ACL: ISO storage /storage/$ISO_STORAGE -> $ROLE_ISO"
run "pveum acl modify '/storage/$ISO_STORAGE' -group '$GROUP' -role '$ROLE_ISO'"

echo "ACL: VM disk storage /storage/$VM_STORAGE -> $ROLE_VMSTORE"
run "pveum acl modify '/storage/$VM_STORAGE' -group '$GROUP' -role '$ROLE_VMSTORE'"

echo "ACL: SDN.Use на bridge $BRIDGE (чтобы bridge был виден в VM Wizard)"
# точечно на один bridge:
run "pveum acl modify '/sdn/zones/localnetwork/$BRIDGE' -group '$GROUP' -role '$SDN_ROLE_TO_USE'"
# если хочешь разрешить ВСЕ bridges, замени строку выше на:
# run \"pveum acl modify '/sdn/zones/localnetwork' -group '$GROUP' -role '$SDN_ROLE_TO_USE'\"

echo "ACL: Sys.Audit на ноды (полезно для UI)"
for n in $(get_nodes); do
  echo "  - /nodes/$n -> $ROLE_NODE_AUDIT"
  run "pveum acl modify '/nodes/$n' -group '$GROUP' -role '$ROLE_NODE_AUDIT'"
done

# 4) Выходной файл
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "fio_ru;username;password;pool" > "$OUT"
fi

# 5) Студенты
echo "Создаю студентов из $INPUT ..."

# поддержка CRLF и пустых строк
while IFS=',' read -r LAST_RU FIRST_RU; do
  LAST_RU="$(trim "${LAST_RU:-}")"
  FIRST_RU="$(trim "${FIRST_RU:-}")"
  LAST_RU="${LAST_RU%$'\r'}"
  FIRST_RU="${FIRST_RU%$'\r'}"

  [[ -z "$LAST_RU" ]] && continue
  [[ "$LAST_RU" =~ ^# ]] && continue

  fio_ru="${LAST_RU} ${FIRST_RU}"
  base="$(translit_ru_to_en "$LAST_RU")"

  if [[ -z "$base" ]]; then
    echo "Пропускаю: '$fio_ru' (не получилось сделать логин)" >&2
    continue
  fi

  # Уникализация логина при совпадениях: ivanov, ivanov2 ...
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
  password="$(openssl rand -base64 24 | tr -d '=+/ ' | cut -c1-12)"

  echo "==> $fio_ru -> $username / $pool"

  if user_exists "$username"; then
    echo "    user уже существует, пропускаю создание пользователя"
  else
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

  # Права студента ТОЛЬКО на свой pool
  run "pveum acl modify '/pool/$pool' -user '$username' -role '$ROLE_STUDENT_VM'"

  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "${fio_ru};${username};${password};${pool}" >> "$OUT"
  fi

done < "$INPUT"

echo
echo "Готово."
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "Файл с паролями: $OUT"
fi
echo "ВАЖНО: студентам нужно выйти/войти в веб-интерфейс Proxmox, чтобы обновились права."
echo
echo "Подсказка студентам: при создании VM обязательно выбирайте свой pool (student_<login>)."
