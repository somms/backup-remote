#!/bin/bash
# Funciones compartidas por backup-remote y backup-restore.
# Debe sourcerse con bash; no ejecutar directo.

backup_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

init_log() {
    local candidate
    local candidates=()
    if [[ -n "${BACKUP_REMOTE_LOG:-}" ]]; then
        candidates+=("$BACKUP_REMOTE_LOG")
    fi
    if [[ -w /var/log/backup_remote.log ]] || { [[ -w /var/log ]] && [[ ! -e /var/log/backup_remote.log ]]; }; then
        candidates+=("/var/log/backup_remote.log")
    fi
    candidates+=("${HOME}/.backup_remote.log")

    LOG_FILE="/dev/null"
    for candidate in "${candidates[@]}"; do
        if touch "$candidate" 2>/dev/null && [[ -w "$candidate" ]]; then
            LOG_FILE="$candidate"
            return 0
        fi
    done
}

log_message() {
    echo "[$(date +%Y-%m-%d\ %H:%M:%S)] $*" | tee -a "$LOG_FILE"
}

handle_error() {
    log_message "Error: ${*:-proceso abortado}."
    exit 1
}

load_backup_config() {
    local config=""
    if [[ -f "${HOME}/.backup_remote.conf" ]]; then
        config="${HOME}/.backup_remote.conf"
    elif [[ -f /etc/backup_remote.conf ]]; then
        config="/etc/backup_remote.conf"
    elif [[ -f "${backup_lib_dir}/backup_remote.conf" ]]; then
        config="${backup_lib_dir}/backup_remote.conf"
    fi

    if [[ -z "$config" || ! -f "$config" ]]; then
        handle_error "no se encontró configuración (~/.backup_remote.conf ni /etc/backup_remote.conf)"
    fi

    # shellcheck disable=SC1090
    source "$config"
    CONFIG_FILE="$config"
    log_message "Cargando configuración desde $CONFIG_FILE"

    : "${ssh_server:=${ssh_host:-}}"
    ssh_key="${ssh_key/#\~/${HOME}}"

    : "${full_backup_max_days:=90}"
    : "${keep_full_cycles:=2}"
    : "${ssh_connect_timeout:=10}"
    : "${one_file_system:=true}"

    if ! declare -p backup_excludes >/dev/null 2>&1; then
        backup_excludes=(
            "*/node_modules"
            "*/.cache"
            "*/.npm"
            "*/.local/share/Trash"
        )
    fi

    [[ -n "${ssh_server:-}" ]] || handle_error "ssh_server no definido"
    [[ -n "${ssh_user:-}" ]] || handle_error "ssh_user no definido"
    [[ -n "${ssh_key:-}" ]] || handle_error "ssh_key no definido"
    [[ -n "${remote_backup_dir:-}" ]] || handle_error "remote_backup_dir no definido"
    [[ -f "$ssh_key" ]] || handle_error "no existe la clave SSH $ssh_key"
    if ! declare -p backup_paths >/dev/null 2>&1 || [[ ${#backup_paths[@]} -eq 0 ]]; then
        handle_error "backup_paths está vacío"
    fi
}

ssh_opts() {
    printf '%s\n' \
        -i "$ssh_key" \
        -o BatchMode=yes \
        -o ConnectTimeout="$ssh_connect_timeout" \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=4
}

ssh_cmd() {
    # shellcheck disable=SC2046
    ssh $(ssh_opts) "${ssh_user}@${ssh_server}" "$@"
}

scp_from_remote() {
    local remote_path=$1
    local local_path=$2
    # shellcheck disable=SC2046
    scp $(ssh_opts) "${ssh_user}@${ssh_server}:${remote_path}" "$local_path"
}

scp_to_remote() {
    local local_path=$1
    local remote_path=$2
    # shellcheck disable=SC2046
    scp $(ssh_opts) "$local_path" "${ssh_user}@${ssh_server}:${remote_path}"
}

# parse_backup_name FILE
# Rellena parsed_prefix, parsed_date (YYYY-MM-DD_HHMMSS), parsed_kind (full|inc|unknown).
parse_backup_name() {
    local base
    base=$(basename -- "$1")
    parsed_prefix=""
    parsed_date=""
    parsed_kind="unknown"
    if [[ $base =~ ^(.+)-([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6})(-full|-inc)?\.tar\.gz$ ]]; then
        parsed_prefix="${BASH_REMATCH[1]}"
        parsed_date="${BASH_REMATCH[2]}"
        case "${BASH_REMATCH[3]}" in
            -full) parsed_kind=full ;;
            -inc) parsed_kind=inc ;;
            *) parsed_kind=unknown ;;
        esac
    fi
}

backup_date_to_epoch() {
    local d=$1
    date -d "${d:0:10} ${d:11:2}:${d:13:2}:${d:15:2}" +%s
}

list_remote_archives() {
    local dest_dir=$1
    ssh_cmd "find $(printf '%q' "$dest_dir") -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\\n' 2>/dev/null | LC_ALL=C sort"
}

resolve_remote_subdir() {
    local wanted=$1
    local path config_source_dir subdir
    remote_backup_subdir=""
    for path in "${backup_paths[@]}"; do
        IFS=":" read -r config_source_dir subdir <<<"$path"
        subdir="${subdir%/}"
        if [[ "$config_source_dir" == "$wanted" ]]; then
            remote_backup_subdir="$subdir"
            return 0
        fi
    done
    return 1
}
