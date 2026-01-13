#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# Proxmox VE: создание студентов из CSV с РУССКИМИ ФИО
# Вход:  students.csv  (Фамилия,Имя) на русском
# Выход: students_passwords.csv: "Фамилия Имя;username;password;pool"
#
# Делает:
# - создает роли (если нет)
# - создает группу students
# - ACL:
#    /storage/<ISO_STORAGE>  -> Datastore.Audit (видеть ISO)
#    /vms                    -> VM.Config.Network (видеть Bridge/vmbr0 в UI)
#    /nodes/<node>           -> Sys.Audit (чтобы UI видел bridges)
# - для каждого студента:
#    user:  lastname_translit@pve (уникализирует при совпадениях)
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

# (опционально) дата окончания доступа (YYYY-MM-DD), пусто = без срока
EXPIRE_DATE=""

# 1 = показать команды без изменений, 0 = выполнить
DRY_RUN=0

# --------------------
# Роли
# --------------------
ROLE_VM="StudentVM"
ROLE_ISO="ISOReader"
ROLE_NODE_AUDIT="StudentNodeAudit"
ROLE_VMS_NETCFG="StudentVmsNetCfg"

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

# --- Транслитерация RU -> EN (простая, практичная) ---
# Пример: "Иванов" -> "ivanov", "Щербаков" -> "shcherbakov"
translit_ru_to_en() {
  local s="$1"
  # в нижний регистр (рус/лат)
  s="$(echo "$s" | tr '[:upper:]' '[:lower:]')"

  # буквы, которые лучше обработать сначала как двубуквенные
  s="$(echo "$s" | sed \
    -e 's/щ/shch/g' \
    -e 's/ш/sh/g' \
    -e 's/ч/ch/g' \
    -e 's/ц/ts/g' \
    -e 's/ю/yu/g' \
    -e 's/я/ya/g' \
    -e 's/ё/yo/g' \
    -e 's/ж/zh/g' \
    -e 's/х/kh/g' \
    -e 's/э/e/g' \
    -e 's/й/y/g' \
    -e 's/а/a/g' \
    -e 's/б/b/g' \
    -e 's/в/v/g' \
    -e 's/г/g/g' \
    -e 's/д/d/g' \
    -e 's/е/e/g' \
    -e 's/з/z/g' \
    -e 's/и/i/g' \
    -e 's/к/k/g' \
    -e 's/л/l/g' \
    -e 's/м/m/g' \
    -e 's/н/n/g' \
    -e 's/о/o/g' \
    -e 's/п/p/g' \
    -e 's/р/r/g' \
    -e 's/с/s/g' \
    -e 's/т/t/g' \
    -e 's/у/u/g' \
    -e 's/ф/f/g' \
    -e 's/ъ//g' \
    -e 's/ы/y/g' \
    -e 's/ь//g' \
  )"

  # нормализуем: всё, что не латиница/цифры/._- -> _
  s="$(echo "$s" | sed -E 's/[^a-z0-9._-]+/_/g; s/^_+|_+$//g')"
  echo "$s"
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
  echo "Storage '$ISO_STORAGE' не найден (Datacenter -> Storage)." >&2
  echo "Исправь ISO_STORAGE в скрипте или создай storage с таким именем." >&2
  exit 1
fi

# 1) Роли
if ! role_exists "$ROLE_VM"; then
  echo "Создаю роль $ROLE_VM ..."
  PRIVS_VM="VM.Audit,VM.Allocate,VM.Console,VM.PowerMgmt,VM.Config.CDROM,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,VM.Config.Disk,VM.Config.Options,Datastore.Audit"
  run "pveum role add '$ROLE_VM' -privs '$PRIVS_VM'"
else
  echo "Роль $ROLE_VM уже существует."
fi

if ! role_exists "$ROLE_ISO"; then
  echo "Создаю роль $ROLE_ISO ..."
  run "pveum role add '$ROLE_ISO' -privs 'Datastore.Audit'"
else
  echo "Роль $ROLE_ISO уже существует."
fi

if ! role_exists "$ROLE_NODE_AUDIT"; then
  echo "Создаю роль $ROLE_NODE_AUDIT ..."
  run "pveum role add '$ROLE_NODE_AUDIT' -privs 'Sys.Audit'"
else
  echo "Роль $ROLE_NODE_AUDIT уже существует."
fi

if ! role_exists "$ROLE_VMS_NETCFG"; then
  echo "Создаю роль $ROLE_VMS_NETCFG ..."
  run "pveum role add '$ROLE_VMS_NETCFG' -privs 'VM.Config.Network'"
else
  echo "Роль $ROLE_VMS_NETCFG уже существует."
fi

# 2) Группа
if ! group_exists "$GROUP"; then
  echo "Создаю группу $GROUP ..."
  run "pveum group add '$GROUP'"
else
  echo "Группа $GROUP уже существует."
fi

# 3) ACL на группу
echo "ACL: ISO storage /storage/$ISO_STORAGE -> $ROLE_ISO"
run "pveum acl modify '/storage/$ISO_STORAGE' -group '$GROUP' -role '$ROLE_ISO'"

echo "ACL: /vms -> $ROLE_VMS_NETCFG (видимость Bridge/vmbr0 в UI)"
run "pveum acl modify '/vms' -group '$GROUP' -role '$ROLE_VMS_NETCFG'"

echo "ACL: Sys.Audit на ноды (для видимости bridges)"
for n in $(get_nodes); do
  echo "  - /nodes/$n -> $ROLE_NODE_AUDIT"
  run "pveum acl modify '/nodes/$n' -group '$GROUP' -role '$ROLE_NODE_AUDIT'"
done

# 4) Выходной файл
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "fio_ru;username;password;pool" > "$OUT"
fi

# 5) Студенты
echo "Создаю студентов из $INPUT (русские ФИО -> логин транслитом) ..."

while IFS=',' read -r LAST_RU FIRST_RU; do
  LAST_RU="$(trim "${LAST_RU:-}")"
  FIRST_RU="$(trim "${FIRST_RU:-}")"

  [[ -z "$LAST_RU" ]] && continue
  [[ "$LAST_RU" =~ ^# ]] && continue

  fio_ru="${LAST_RU} ${FIRST_RU}"
  base="$(translit_ru_to_en "$LAST_RU")"

  if [[ -z "$base" ]]; then
    echo "Пропускаю: '$fio_ru' (не получилось сделать логин)" >&2
    continue
  fi

  # Уникализация логина при совпадениях: ivanov, ivanov -> ivanov2 ...
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
  password="$(openssl rand -base64 16 | tr -d '=+/ ' | cut -c1-12)"

  echo "==> $fio_ru -> $username / $pool"

  if [[ -n "$EXPIRE_DATE" ]]; then
    run "pveum user add '$username' --password '$password' --expire '$EXPIRE_DATE' --comment 'Student $fio_ru'"
  else
    run "pveum user add '$username' --password '$password' --comment 'Student $fio_ru'"
  fi

  run "pveum user modify '$username' -group '$GROUP'"

  if ! pool_exists "$pool"; then
    run "pvesh create /pools --poolid '$pool'"
  fi

  run "pveum acl modify '/pool/$pool' -user '$username' -role '$ROLE_VM'"

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
