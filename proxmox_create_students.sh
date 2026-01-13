#!/usr/bin/env bash
set -euo pipefail

# =========================
# Настройки
# =========================
ROLE="StudentVM"
GROUP="students"
REALM="pve"

# storage, где лежат ISO (как в Datacenter -> Storage)
ISO_STORAGE="iso-students"

# выходной файл с паролями
OUT="students_passwords.csv"

# (опционально) дата окончания доступа (YYYY-MM-DD), пусто = без срока
EXPIRE_DATE=""

# Входной файл
INPUT="students.csv"

# Если хочешь прогон без изменений:
DRY_RUN=0

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

# нормализация логина: латиница/цифры/._-
# (если фамилии кириллицей — лучше заранее транслитерировать в файле)
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

pool_exists() {
  local p="$1"
  pvesh get /pools --output-format json 2>/dev/null | grep -q "\"poolid\":\"$p\""
}

group_exists() {
  local g="$1"
  pveum group list | awk '{print $1}' | grep -Fxq "$g"
}

role_exists() {
  local r="$1"
  pveum role list | awk '{print $1}' | grep -Fxq "$r"
}

storage_path_exists() {
  local st="$1"
  pvesh get /storage --output-format json 2>/dev/null | grep -q "\"storage\":\"$st\""
}

# =========================
# Основная логика
# =========================
require_root

if [[ ! -f "$INPUT" ]]; then
  echo "Не найден входной файл: $INPUT" >&2
  exit 1
fi

# Проверим storage ISO
if ! storage_path_exists "$ISO_STORAGE"; then
  echo "Storage '$ISO_STORAGE' не найден в Proxmox (Datacenter -> Storage)." >&2
  echo "Либо создай его, либо поменяй ISO_STORAGE в скрипте." >&2
  exit 1
fi

# Создадим роль, если нет
if ! role_exists "$ROLE"; then
  echo "Создаю роль $ROLE ..."
  # Права: управление только своей ВМ + консоль + подключение ISO + аудит datastore
  PRIVS="VM.Audit,VM.Allocate,VM.Console,VM.PowerMgmt,VM.Config.CDROM,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,VM.Config.Disk,VM.Config.Options,Datastore.Audit"
  run "pveum role add '$ROLE' -privs '$PRIVS'"
else
  echo "Роль $ROLE уже существует."
fi

# Создадим группу, если нет
if ! group_exists "$GROUP"; then
  echo "Создаю группу $GROUP ..."
  run "pveum group add '$GROUP'"
else
  echo "Группа $GROUP уже существует."
fi

# Назначим группе доступ к ISO storage (чтобы видеть ISO в списке)
# Вариант 1: отдельная роль не нужна — можно дать StudentVM на storage,
# но это логически смешивает права. Чаще делают отдельную роль ISOReader.
ISO_ROLE="ISOReader"

if ! role_exists "$ISO_ROLE"; then
  echo "Создаю роль $ISO_ROLE (только Datastore.Audit) ..."
  run "pveum role add '$ISO_ROLE' -privs 'Datastore.Audit'"
else
  echo "Роль $ISO_ROLE уже существует."
fi

echo "Назначаю группе $GROUP доступ на /storage/$ISO_STORAGE ..."
run "pveum acl modify '/storage/$ISO_STORAGE' -group '$GROUP' -role '$ISO_ROLE'"

# Заголовок выходного файла
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "username;password;pool" > "$OUT"
fi

echo "Обрабатываю список студентов из $INPUT ..."

# Читаем CSV: lastname,firstname
# Пропускаем пустые строки и комментарии
while IFS=',' read -r LAST FIRST; do
  LAST="${LAST:-}"
  FIRST="${FIRST:-}"

  # trim
  LAST="$(echo "$LAST" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
  FIRST="$(echo "$FIRST" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"

  [[ -z "$LAST" ]] && continue
  [[ "$LAST" =~ ^# ]] && continue

  base="$(sanitize "$LAST")"
  if [[ -z "$base" ]]; then
    echo "Пропускаю некорректную фамилию: '$LAST'" >&2
    continue
  fi

  # Уникализация логина при совпадениях (ivanov, ivanov -> ivanov2, ivanov3)
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

  echo "==> $LAST $FIRST -> $username / $pool"

  # Пароль
  password="$(openssl rand -base64 12 | tr -d '=+/ ' | cut -c1-12)"

  # Создать пользователя
  if [[ -n "$EXPIRE_DATE" ]]; then
    run "pveum user add '$username' --password '$password' --expire '$EXPIRE_DATE' --comment 'Student $FIRST $LAST'"
  else
    run "pveum user add '$username' --password '$password' --comment 'Student $FIRST $LAST'"
  fi

  # Добавить в группу
  run "pveum user modify '$username' -group '$GROUP'"

  # Создать пул (если нет)
  if pool_exists "$pool"; then
    echo "Пул $pool уже существует."
  else
    run "pvesh create /pools --poolid '$pool'"
  fi

  # ACL: студент получает права только на свой пул
  run "pveum acl modify '/pool/$pool' -user '$username' -role '$ROLE'"

  # Сохранить пароль
  if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "${username};${password};${pool}" >> "$OUT"
  fi

done < "$INPUT"

echo
echo "Готово."
if [[ "$DRY_RUN" -eq 0 ]]; then
  echo "Пароли сохранены в: $OUT"
else
  echo "Это был DRY_RUN — ничего не изменялось."
fi
