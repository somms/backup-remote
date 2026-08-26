#!/bin/bash
# Prueba de ciclo de vida de backup-remote / backup-restore.
# No usa caudatus ni /etc/backup_remote.conf: HOME aislado + ssh/scp de mentira.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK=$(mktemp -d /tmp/backup-remote-test.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

HOME_DIR="$WORK/home"
SRC="$WORK/src"
REMOTE="$WORK/remote"
FAKEBIN="$WORK/fakebin"
RESTORE="$WORK/restore"
PASS=0
FAIL=0
REPORT=()

mkdir -p "$HOME_DIR/.ssh" "$SRC" "$REMOTE" "$FAKEBIN" "$RESTORE"
export HOME="$HOME_DIR"
export BACKUP_REMOTE_LOG="$WORK/test.log"
: >"$BACKUP_REMOTE_LOG"
touch "$HOME_DIR/.ssh/id_rsa"

assert_ok() {
    local name=$1
    PASS=$((PASS + 1))
    REPORT+=("PASS  $name")
    echo "PASS  $name"
}

assert_fail() {
    local name=$1
    local detail=${2:-}
    FAIL=$((FAIL + 1))
    REPORT+=("FAIL  $name${detail:+  ($detail)}")
    echo "FAIL  $name${detail:+  ($detail)}"
}

expect_eq() {
    local name=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        assert_ok "$name"
    else
        assert_fail "$name" "got='$got' want='$want'"
    fi
}

expect_file() {
    local name=$1 path=$2
    if [[ -f "$path" ]]; then
        assert_ok "$name"
    else
        assert_fail "$name" "missing $path"
    fi
}

expect_no_file() {
    local name=$1 path=$2
    if [[ -e "$path" ]]; then
        assert_fail "$name" "exists $path"
    else
        assert_ok "$name"
    fi
}

expect_rc() {
    local name=$1 got=$2 want=$3
    if [[ "$got" == "$want" ]]; then
        assert_ok "$name"
    else
        assert_fail "$name" "rc=$got want=$want"
    fi
}

cat >"$FAKEBIN/ssh" <<'EOF'
#!/bin/bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|-o) shift 2 ;;
        *@*) shift; break ;;
        *) shift ;;
    esac
done
cmd="$*"
if [[ -n "${BACKUP_TEST_FAIL_SSH:-}" ]]; then
    exit "$BACKUP_TEST_FAIL_SSH"
fi
if [[ "$cmd" == gzip\ -t* && -n "${BACKUP_TEST_FAIL_GZIP:-}" ]]; then
    exit "$BACKUP_TEST_FAIL_GZIP"
fi
if [[ "$cmd" == cat\ \>* && -n "${BACKUP_TEST_FAIL_CAT:-}" ]]; then
    cat >/dev/null || true
    exit 1
fi
bash -c "$cmd"
EOF

cat >"$FAKEBIN/scp" <<'EOF'
#!/bin/bash
set -euo pipefail
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|-o) shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
src=${args[0]:-}
dst=${args[1]:-}
if [[ -z "$src" || -z "$dst" ]]; then
    echo "scp fake: need src dst" >&2
    exit 1
fi
if [[ "$src" == *:* ]]; then
    src="${src#*:}"
    cp -a -- "$src" "$dst"
else
    dst="${dst#*:}"
    cp -a -- "$src" "$dst"
fi
EOF
chmod +x "$FAKEBIN/ssh" "$FAKEBIN/scp"

export PATH="$FAKEBIN:$PATH"

cat >"$HOME_DIR/.backup_remote.conf" <<EOF
backup_paths=(
  "$SRC:testdata"
)
remote_backup_dir="$REMOTE/backups"
ssh_server="remote.test"
ssh_key="$HOME_DIR/.ssh/id_rsa"
ssh_user="tester"
keep_full_cycles=2
full_backup_max_days=90
one_file_system=true
backup_excludes=(
  "*/node_modules"
  "*/.cache"
  "*/.npm"
  "*/.local/share/Trash"
)
EOF

echo "hello-v1" >"$SRC/hello.txt"
echo "keep-me" >"$SRC/keep.txt"
mkdir -p "$SRC/node_modules/secret-pkg" "$SRC/.cache"
echo "should-not-backup" >"$SRC/node_modules/secret-pkg/secret.js"
echo "cache-junk" >"$SRC/.cache/junk"

run_backup() {
    env HOME="$HOME_DIR" BACKUP_REMOTE_LOG="$BACKUP_REMOTE_LOG" PATH="$PATH" \
        "$SCRIPT_DIR/backup-remote" "$@"
}

run_restore() {
    env HOME="$HOME_DIR" BACKUP_REMOTE_LOG="$BACKUP_REMOTE_LOG" PATH="$PATH" \
        "$SCRIPT_DIR/backup-restore" "$@"
}

archives() {
    find "$REMOTE/backups/testdata" -maxdepth 1 -type f -name '*.tar.gz' -printf '%f\n' 2>/dev/null | LC_ALL=C sort
}

latest_archive() {
    archives | tail -n 1
}

count_kind() {
    local kind=$1
    archives | grep -c -- "-${kind}.tar.gz" || true
}

find_restored() {
    local name=$1
    local root=${2:-$RESTORE}
    find "$root" -type f -name "$name" 2>/dev/null | head -n 1
}

# --- 1. Primer backup: full ---
run_backup
sleep 1
full1=$(archives | grep -- '-full.tar.gz' || true)
expect_eq "1. primer backup es full" "$(count_kind full)" "1"
expect_eq "1. primer backup no es incremental" "$(count_kind inc)" "0"
expect_file "1. existe .snar remoto" "$REMOTE/backups/testdata/testdata.snar"
if tar -tzf "$REMOTE/backups/testdata/$full1" | grep -q 'hello.txt'; then
    assert_ok "1. el full contiene hello.txt"
else
    assert_fail "1. el full contiene hello.txt"
fi
if tar -tzf "$REMOTE/backups/testdata/$full1" | grep -q 'node_modules'; then
    assert_fail "1. node_modules excluido" "apareció en el tar"
else
    assert_ok "1. node_modules excluido"
fi
if tar -tzf "$REMOTE/backups/testdata/$full1" | grep -q '.cache'; then
    assert_fail "1. .cache excluido" "apareció en el tar"
else
    assert_ok "1. .cache excluido"
fi

# --- 2. Segundo backup: incremental ---
echo "hello-v2" >"$SRC/hello.txt"
echo "new-file" >"$SRC/added.txt"
run_backup
sleep 1
expect_eq "2. tras cambios hay 1 full" "$(count_kind full)" "1"
expect_eq "2. tras cambios hay 1 incremental" "$(count_kind inc)" "1"
inc1=$(archives | grep -- '-inc.tar.gz' | head -n 1)
if tar -tzf "$REMOTE/backups/testdata/$inc1" | grep -q 'added.txt'; then
    assert_ok "2. el incremental incluye added.txt"
else
    assert_fail "2. el incremental incluye added.txt"
fi

# --- 3. Restore del incremental (cadena full+inc) ---
rm -rf "$RESTORE"
mkdir -p "$RESTORE"
inc1_date=$(echo "$inc1" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}')
run_restore --restore "$SRC" "$inc1_date" "$RESTORE"
hello_path=$(find_restored hello.txt)
added_path=$(find_restored added.txt)
secret_path=$(find_restored secret.js)
if [[ -f "$hello_path" ]] && grep -q 'hello-v2' "$hello_path"; then
    assert_ok "3. restore latest tiene hello-v2"
else
    assert_fail "3. restore latest tiene hello-v2" "path=$hello_path"
fi
expect_file "3. restore incluye added.txt" "${added_path:-/no/added.txt}"
expect_no_file "3. restore no incluye node_modules" "${secret_path:-/__not_found__}"

# --- 4. Restore a fecha del full: sin added.txt ---
rm -rf "$RESTORE"
mkdir -p "$RESTORE"
full1_date=$(echo "$full1" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}')
run_restore --restore "$SRC" "$full1_date" "$RESTORE"
hello_path=$(find_restored hello.txt)
added_path=$(find_restored added.txt)
if [[ -f "$hello_path" ]] && grep -q 'hello-v1' "$hello_path"; then
    assert_ok "4. restore al full tiene hello-v1"
else
    assert_fail "4. restore al full tiene hello-v1" "path=$hello_path content=$(cat "$hello_path" 2>/dev/null || true)"
fi
if [[ -n "${added_path}" && -f "$added_path" ]]; then
    assert_fail "4. restore al full no tiene added.txt" "encontrado $added_path"
else
    assert_ok "4. restore al full no tiene added.txt"
fi

# --- 5. Borrado de fichero + incremental ---
rm -f "$SRC/keep.txt"
run_backup
sleep 1
rm -rf "$RESTORE"
mkdir -p "$RESTORE"
run_restore --restore-latest "$SRC" "$RESTORE"
keep_path=$(find_restored keep.txt)
if [[ -n "$keep_path" && -f "$keep_path" ]]; then
    assert_fail "5. restore tras borrar keep.txt no lo recupera" "sigue en $keep_path"
else
    assert_ok "5. restore tras borrar keep.txt no lo recupera"
fi

# --- 6. --list y fecha inexistente ---
list_out=$(run_restore --list "$SRC")
if echo "$list_out" | grep -q 'full' && echo "$list_out" | grep -q 'inc'; then
    assert_ok "6. --list muestra full e inc"
else
    assert_fail "6. --list muestra full e inc" "$list_out"
fi
set +e
run_restore --restore "$SRC" "1999-01-01_000000" "$RESTORE/none" >/dev/null 2>&1
rc=$?
set -e
expect_rc "6. restore fecha sin backups falla" "$rc" "1"
set +e
run_restore --list /no/such/source >/dev/null 2>&1
rc=$?
set -e
expect_rc "6. --list de origen desconocido falla" "$rc" "1"

# --- 7. Retención: 3 fulls, keep=2 ---
BACKUP_FORCE_FULL=1 run_backup
sleep 1
BACKUP_FORCE_FULL=1 run_backup
sleep 1
BACKUP_FORCE_FULL=1 run_backup
sleep 1
full_count=$(count_kind full)
if [[ "$full_count" == "2" ]]; then
    assert_ok "7. retención deja 2 fulls (había 3+ el inicial)"
else
    # El inicial + 3 forzados = 4 fulls teóricos; keep 2 → 2
    assert_fail "7. retención deja 2 fulls" "fulls=$full_count files=$(archives | tr '\n' ' ')"
fi
if archives | grep -q -- "$full1"; then
    assert_fail "7. el full más antiguo se podó" "sigue $full1"
else
    assert_ok "7. el full más antiguo se podó"
fi

# --- 8. Error: directorio origen inexistente ---
mkdir -p "$HOME_DIR-missing"
cat >"$HOME_DIR-missing/.backup_remote.conf" <<EOF
backup_paths=("/no/such/backup-src:testdata")
remote_backup_dir="$REMOTE/backups"
ssh_server="remote.test"
ssh_key="$HOME_DIR/.ssh/id_rsa"
ssh_user="tester"
keep_full_cycles=2
backup_excludes=()
one_file_system=true
EOF
mkdir -p "$HOME_DIR-missing/.ssh"
cp "$HOME_DIR/.ssh/id_rsa" "$HOME_DIR-missing/.ssh/id_rsa"
set +e
env HOME="$HOME_DIR-missing" BACKUP_REMOTE_LOG="$WORK/missing.log" PATH="$PATH" \
    "$SCRIPT_DIR/backup-remote" >/dev/null 2>&1
rc=$?
set -e
expect_rc "8. origen inexistente aborta" "$rc" "1"

# --- 9. Error: lock ---
LOCK="$HOME_DIR/.backup-remote.lock"
exec 8>"$LOCK"
flock 8
set +e
run_backup >/dev/null 2>&1
rc=$?
set -e
flock -u 8
exec 8>&-
expect_rc "9. segundo backup con lock aborta" "$rc" "1"

# --- 10. Error: ssh/cat (pipe) no actualiza snar ---
snar_before=$(cksum "$REMOTE/backups/testdata/testdata.snar")
archives_before=$(archives | wc -l)
set +e
BACKUP_TEST_FAIL_CAT=1 run_backup >/dev/null 2>&1
rc=$?
set -e
snar_after=$(cksum "$REMOTE/backups/testdata/testdata.snar")
archives_after=$(archives | wc -l)
expect_rc "10. fallo de ssh/cat aborta" "$rc" "1"
expect_eq "10. .snar intacto si falla el pipe" "$snar_after" "$snar_before"
expect_eq "10. no queda tar extra tras fallo de cat" "$archives_after" "$archives_before"

# --- 11. Error: gzip -t, se borra el archivo y no se toca snar ---
snar_before=$(cksum "$REMOTE/backups/testdata/testdata.snar")
set +e
BACKUP_TEST_FAIL_GZIP=1 run_backup >/dev/null 2>&1
rc=$?
set -e
snar_after=$(cksum "$REMOTE/backups/testdata/testdata.snar")
expect_rc "11. gzip -t fallido aborta" "$rc" "1"
expect_eq "11. .snar intacto si gzip -t falla" "$snar_after" "$snar_before"
# El cat sí escribió un tar; el script debe haberlo borrado.
# current_date del proceso fallido no lo conocemos: no debe haber .tar.gz corruptos
corrupt=0
while IFS= read -r f; do
    if ! gzip -t "$REMOTE/backups/testdata/$f" 2>/dev/null; then
        corrupt=1
    fi
done < <(archives)
expect_eq "11. no quedan tar.gz corruptos" "$corrupt" "0"

# --- 11b. Corte de SSH durante gzip -t: se conserva el tar ---
snar_before=$(cksum "$REMOTE/backups/testdata/testdata.snar")
archives_before=$(archives | wc -l)
set +e
BACKUP_TEST_FAIL_GZIP=255 run_backup >/dev/null 2>&1
rc=$?
set -e
snar_after=$(cksum "$REMOTE/backups/testdata/testdata.snar")
archives_after=$(archives | wc -l)
expect_rc "11b. corte de red en gzip -t aborta" "$rc" "1"
expect_eq "11b. .snar intacto si se corta la verificación" "$snar_after" "$snar_before"
if (( archives_after == archives_before + 1 )); then
    assert_ok "11b. el tar.gz se conserva si SSH cae en gzip -t"
else
    assert_fail "11b. el tar.gz se conserva si SSH cae en gzip -t" "before=$archives_before after=$archives_after"
fi

# --- 12. Error: clave SSH ausente ---
rm -f "$HOME_DIR/.ssh/id_rsa"
set +e
run_backup >/dev/null 2>&1
rc=$?
set -e
expect_rc "12. sin clave SSH aborta" "$rc" "1"
touch "$HOME_DIR/.ssh/id_rsa"

# --- 13. Recuperación: un backup bueno tras los fallos ---
echo "hello-v3" >"$SRC/hello.txt"
run_backup
rm -rf "$RESTORE"
mkdir -p "$RESTORE"
run_restore --restore-latest "$SRC" "$RESTORE"
hello_path=$(find_restored hello.txt)
if [[ -f "$hello_path" ]] && grep -q 'hello-v3' "$hello_path"; then
    assert_ok "13. backup/restore funcionan tras los fallos inyectados"
else
    assert_fail "13. backup/restore funcionan tras los fallos inyectados"
fi

echo
echo "==== resumen ===="
printf '%s\n' "${REPORT[@]}"
echo "PASS=$PASS FAIL=$FAIL work=$WORK log=$BACKUP_REMOTE_LOG"
if [[ "$FAIL" -ne 0 ]]; then
    echo "---- log ----"
    cat "$BACKUP_REMOTE_LOG"
    exit 1
fi
exit 0
