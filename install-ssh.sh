#!/usr/bin/env bash
#
# install-ssh.sh
# Подготовка Ubuntu-машины стенда: сеть MGMT, SSH, утилиты, имя хоста, ufw.
#
# Поддерживает 4 готовых варианта (роли):
#   1) SRV-LIN       192.168.56.40
#   2) SRV-MAIL-LIN  192.168.56.50
#   3) SRV-GW-LIN    192.168.56.60
#   4) WS-LIN        192.168.56.30
#
# Запуск (интерактивно):
#     sudo bash install-ssh.sh
#
# Неинтерактивно:
#     sudo bash install-ssh.sh --role srv-lin --yes
#     sudo bash install-ssh.sh --role srv-gw-lin --components 1,2 --yes
#
set -euo pipefail

# =====================================================================
# Параметры
# =====================================================================
SSH_PORT=22
PASSWORD_AUTH="yes"
EXTRAS_PACKAGES=(curl git vim htop net-tools ca-certificates)

ROLE_HOST=""
ROLE_IP=""
DO_SSH=1
DO_TOOLS=1
DO_NET=1
DO_HOSTNAME=1
DO_UFW=1
COMPONENTS_SET=0
ASSUME_YES=0

# =====================================================================
# Цвета и служебные функции
# =====================================================================
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'
BLD=$'\033[1m'; RST=$'\033[0m'
log()  { printf '\n%s==> %s%s\n' "$GRN" "$*" "$RST"; }
warn() { printf '\n%s[!] %s%s\n' "$YEL" "$*" "$RST" >&2; }
fail() { printf '\n%s[x] %s%s\n' "$RED" "$*" "$RST"; exit 1; }

usage() {
  cat <<'EOF'
Использование: install-ssh.sh [параметры]

  --role NAME        роль: srv-lin | srv-mail-lin | srv-gw-lin | ws-lin
  --ip ADDR          свой IPv4 (переопределяет адрес роли)
  --hostname NAME    своё имя хоста (переопределяет имя роли)
  --components LIST  номера компонентов через запятую: 1,2,3,4,5
                     1 — OpenSSH, 2 — утилиты, 3 — сеть MGMT,
                     4 — имя хоста, 5 — ufw
  --yes              без вопросов, использовать значения по умолчанию
  -h, --help         эта справка
EOF
}

# =====================================================================
# Разбор аргументов
# =====================================================================
parse_args() {
  local role_key="" override_ip="" override_host="" comps=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)       role_key="${2:-}"; shift 2 ;;
      --ip)         override_ip="${2:-}"; shift 2 ;;
      --hostname)   override_host="${2:-}"; shift 2 ;;
      --components) comps="${2:-}"; shift 2 ;;
      --yes)        ASSUME_YES=1; shift ;;
      -h|--help)    usage; exit 0 ;;
      *)            fail "Неизвестный параметр: $1 (см. --help)" ;;
    esac
  done

  if [[ -n "$role_key" ]]; then
    set_role_by_key "$role_key"
  fi
  if [[ -n "$override_host" ]]; then
    ROLE_HOST="$override_host"
  fi
  if [[ -n "$override_ip" ]]; then
    ROLE_IP="$override_ip"
  fi

  if [[ -n "$comps" ]]; then
    COMPONENTS_SET=1
    DO_SSH=0; DO_TOOLS=0; DO_NET=0; DO_HOSTNAME=0; DO_UFW=0
    local IFS=','
    local x
    for x in $comps; do
      case "$x" in
        1) DO_SSH=1 ;; 2) DO_TOOLS=1 ;; 3) DO_NET=1 ;;
        4) DO_HOSTNAME=1 ;; 5) DO_UFW=1 ;;
        *) fail "Неизвестный компонент: $x" ;;
      esac
    done
  fi
}

# =====================================================================
# Роли
# =====================================================================
set_role_by_key() {
  case "$1" in
    srv-lin)      ROLE_HOST="SRV-LIN";      ROLE_IP="192.168.56.40" ;;
    srv-mail-lin) ROLE_HOST="SRV-MAIL-LIN"; ROLE_IP="192.168.56.50" ;;
    srv-gw-lin)   ROLE_HOST="SRV-GW-LIN";   ROLE_IP="192.168.56.60" ;;
    ws-lin)       ROLE_HOST="WS-LIN";       ROLE_IP="192.168.56.30" ;;
    *) fail "Неизвестная роль: $1" ;;
  esac
}

select_role() {
  printf '\n%sВыберите машину:%s\n' "$BLD" "$RST"
  printf '  1) SRV-LIN       192.168.56.40\n'
  printf '  2) SRV-MAIL-LIN  192.168.56.50\n'
  printf '  3) SRV-GW-LIN    192.168.56.60\n'
  printf '  4) WS-LIN        192.168.56.30\n'
  printf '  5) Другая (ввести вручную)\n'
  read -rp "Номер [1]: " n
  n=${n:-1}
  case "$n" in
    1) ROLE_HOST="SRV-LIN";      ROLE_IP="192.168.56.40" ;;
    2) ROLE_HOST="SRV-MAIL-LIN"; ROLE_IP="192.168.56.50" ;;
    3) ROLE_HOST="SRV-GW-LIN";   ROLE_IP="192.168.56.60" ;;
    4) ROLE_HOST="WS-LIN";       ROLE_IP="192.168.56.30" ;;
    5)
      read -rp "Имя хоста: " ROLE_HOST
      read -rp "IPv4 (например 192.168.56.70): " ROLE_IP
      ;;
    *) fail "Неверный выбор" ;;
  esac
  [[ -n "$ROLE_HOST" && -n "$ROLE_IP" ]] || fail "Имя хоста и IP не должны быть пустыми"
}

select_components() {
  printf '\n%sЧто настроить?%s (номера через пробел, Enter — всё)\n' "$BLD" "$RST"
  printf '  1) OpenSSH-сервер\n'
  printf '  2) Базовые утилиты (curl, git, vim, htop, net-tools)\n'
  printf '  3) Сеть MGMT — статический IP (netplan)\n'
  printf '  4) Имя хоста\n'
  printf '  5) ufw: разрешить SSH\n'
  printf '  0) Всё\n'
  read -rp "Выбор [всё]: " sel
  if [[ -z "$sel" || " $sel " == *" 0 "* ]]; then
    return 0
  fi
  DO_SSH=0; DO_TOOLS=0; DO_NET=0; DO_HOSTNAME=0; DO_UFW=0
  local x
  for x in $sel; do
    case "$x" in
      1) DO_SSH=1 ;; 2) DO_TOOLS=1 ;; 3) DO_NET=1 ;;
      4) DO_HOSTNAME=1 ;; 5) DO_UFW=1 ;;
      *) warn "Пропускаю неизвестный пункт: $x" ;;
    esac
  done
}

# =====================================================================
# Проверки окружения
# =====================================================================
require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    warn "Нужны права root. Повторяю запуск через sudo..."
    exec sudo bash "$0" "$@"
  fi
}

require_ubuntu() {
  [[ -f /etc/os-release ]] || fail "Нет /etc/os-release — не удалось определить ОС"
  # shellcheck source=/dev/null
  . /etc/os-release
  log "Система: ${PRETTY_NAME:-${NAME} ${VERSION_ID}}"
  command -v apt-get >/dev/null 2>&1 || fail "Скрипт рассчитан на Debian/Ubuntu (нет apt-get)"
}

APT_UPDATED=0
ensure_apt_update() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    log "Обновляю список пакетов (apt-get update)..."
    apt-get update
    APT_UPDATED=1
  fi
}

# =====================================================================
# Сеть MGMT (netplan)
# =====================================================================
detect_mgmt_iface() {
  local dflt i
  dflt=$(ip -o route show default 2>/dev/null \
    | awk '{for (k=1;k<=NF;k++) if ($k=="dev") print $(k+1)}' | sort -u || true)

  local cands=()
  while IFS= read -r i; do
    [[ -z "$i" ]] && continue
    [[ "$i" == "lo" ]] && continue
    echo "$dflt" | grep -qx "$i" && continue
    case "$i" in
      docker*|br-*|veth*|virbr*|tun*|tap*|happ*) continue ;;
    esac
    cands+=("$i")
  done < <(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1)

  if [[ ${#cands[@]} -eq 0 ]]; then
    warn "Не найден сетевой интерфейс без маршрута по умолчанию."
    warn "Скорее всего, Host-Only адаптер не подключён к ВМ."
    warn "На хосте в VirtualBox: Настройки → Сеть → Адаптер 2 →"
    warn "  «Виртуальный адаптер хоста» → vboxnet0 → включить адаптер."
    return 1
  elif [[ ${#cands[@]} -eq 1 ]]; then
    printf '%s\n' "${cands[0]}"
  else
    printf '%s\n' "${cands[@]}" >&2
    return 2
  fi
}

apply_netplan() {
  local iface="$1" ip="$2"
  local file="/etc/netplan/60-mgmt.yaml"

  if [[ -f "$file" ]]; then
    cp -a "$file" "${file}.bak.$(date +%s)"
    log "Резервная копия прежнего ${file} сохранена"
  fi

  log "Пишу ${file}: ${iface} → ${ip}/24 (без шлюза)"
  umask 077
  cat > "$file" <<EOF
# Сгенерировано install-ssh.sh ($(date -u +%Y-%m-%dT%H:%M:%SZ)).
network:
  version: 2
  renderer: networkd
  ethernets:
    ${iface}:
      dhcp4: false
      addresses: [${ip}/24]
      optional: true
EOF
  chmod 600 "$file"

  log "Проверяю конфигурацию netplan..."
  netplan generate

  log "Применяю netplan (интерфейс ${iface})..."
  netplan apply
}

apply_nmcli() {
  local iface="$1" ip="$2"
  local con="mgmt-${iface}"

  log "NetworkManager: ${iface} → ${ip}/24 (без шлюза)"
  nmcli connection delete "$con" >/dev/null 2>&1 || true
  nmcli connection add type ethernet ifname "$iface" con-name "$con" \
    ipv4.method manual ipv4.addresses "${ip}/24" ipv4.never-default yes
  nmcli connection up "$con"
}

setup_mgmt_network() {
  local iface ip="${ROLE_IP}"
  local rc=0
  iface=$(detect_mgmt_iface) || rc=$?

  if [[ $rc -eq 1 ]]; then
    warn "Сеть MGMT не настроена: нет подходящего интерфейса."
    return 1
  elif [[ $rc -eq 2 ]]; then
    echo "Найдено несколько кандидатов (см. выше)." >&2
    if [[ $ASSUME_YES -eq 1 ]]; then
      fail "Несколько интерфейсов-кандидатов: укажите нужный вручную"
    fi
    read -rp "Укажите интерфейс для MGMT: " iface
    [[ -n "$iface" ]] || { warn "Интерфейс не указан — пропускаю."; return 1; }
  fi

  echo "Интерфейс: ${iface}, адрес: ${ip}/24"
  if [[ $ASSUME_YES -eq 0 ]]; then
    read -rp "Применить? [Y/n]: " ok
    [[ -z "$ok" || "$ok" =~ ^[Yy]$ ]] || { warn "Пропускаю настройку сети."; return 1; }
  fi
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    apply_nmcli "$iface" "$ip"
  else
    apply_netplan "$iface" "$ip"
  fi
}

# =====================================================================
# SSH
# =====================================================================
setup_ssh() {
  ensure_apt_update

  log "Устанавливаю openssh-server..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server

  log "Включаю и запускаю службу ssh..."
  systemctl enable --now ssh
  systemctl --no-pager --full status ssh || true

  local sshd_config="/etc/ssh/sshd_config"
  local dropin_dir="/etc/ssh/sshd_config.d"
  local dropin="${dropin_dir}/99-lab.conf"

  if [[ ! -f "${sshd_config}.orig" ]]; then
    cp -a "$sshd_config" "${sshd_config}.orig"
    log "Резервная копия: ${sshd_config}.orig"
  fi

  if [[ -d "$dropin_dir" ]]; then
    log "Параметры SSH → ${dropin}"
    umask 077
    cat > "$dropin" <<EOF
# Сгенерировано install-ssh.sh ($(date -u +%Y-%m-%dT%H:%M:%SZ)).
Port ${SSH_PORT}
PermitRootLogin prohibit-password
PasswordAuthentication ${PASSWORD_AUTH}
PubkeyAuthentication yes
EOF
  else
    warn "Нет каталога ${dropin_dir} — проверьте PasswordAuthentication в ${sshd_config} вручную."
  fi

  log "Проверяю конфигурацию sshd..."
  sshd -t
  log "Перезапускаю ssh..."
  systemctl restart ssh
}

setup_tools() {
  ensure_apt_update
  log "Устанавливаю утилиты: ${EXTRAS_PACKAGES[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${EXTRAS_PACKAGES[@]}"
}

setup_hostname() {
  log "Устанавливаю имя хоста: ${ROLE_HOST}"
  hostnamectl set-hostname "$ROLE_HOST"
  if grep -q '^127\.0\.1\.1' /etc/hosts 2>/dev/null; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${ROLE_HOST}/" /etc/hosts
  fi
}

setup_ufw() {
  if command -v ufw >/dev/null 2>&1; then
    log "Разрешаю SSH/${SSH_PORT} в ufw"
    ufw allow "${SSH_PORT}/tcp" || warn "Не удалось добавить правило ufw"
  else
    warn "ufw не установлен — пропускаю"
  fi
}

# =====================================================================
# Итог
# =====================================================================
print_summary() {
  log "Готово. Машина: ${ROLE_HOST} (${ROLE_IP})"
  printf '\nIPv4-интерфейсы:\n'
  ip -4 -brief address show || true
  printf '\nПроверка службы SSH: '
  systemctl is-active ssh 2>/dev/null || true
  printf '\nПодключение с ADMIN-WS:\n'
  printf '    ssh sysadmin@%s\n\n' "$ROLE_IP"
}

# =====================================================================
# main
# =====================================================================
main() {
  parse_args "$@"
  require_root "$@"
  require_ubuntu

  if [[ -z "$ROLE_HOST" || -z "$ROLE_IP" ]]; then
    if [[ $ASSUME_YES -eq 1 ]]; then
      fail "В режиме --yes укажите --role (или --hostname и --ip)"
    fi
    select_role
  fi

  if [[ $ASSUME_YES -eq 0 && $COMPONENTS_SET -eq 0 ]]; then
    select_components
  fi

  if [[ $DO_NET -eq 1 ]]; then
    setup_mgmt_network || warn "Сеть MGMT пропущена — SSH может быть недоступен по 192.168.56.x"
  fi
  if [[ $DO_HOSTNAME -eq 1 ]]; then
    setup_hostname
  fi
  if [[ $DO_SSH -eq 1 ]]; then
    setup_ssh
  fi
  if [[ $DO_TOOLS -eq 1 ]]; then
    setup_tools
  fi
  if [[ $DO_UFW -eq 1 ]]; then
    setup_ufw
  fi

  print_summary
}

main "$@"
