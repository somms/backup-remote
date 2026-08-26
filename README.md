# Backup Remote Script

Scripts `backup-remote` y `backup-restore` para copiar directorios locales a un servidor por SSH con GNU `tar --listed-incremental`. El archivo se genera en un pipe hacia el remoto: no hace falta espacio local del tamaño del backup.

Cada ciclo empieza con un **full** (`*-full.tar.gz`) y sigue con **incrementales** (`*-inc.tar.gz`). Un full nuevo se hace si no hay `.snar` remoto, si no hay ningún `-full.tar.gz`, o si el último full tiene más de `full_backup_max_days` días (90 por defecto). Forzar: `BACKUP_FORCE_FULL=1`.

Tras un full verificado se conservan `keep_full_cycles` ciclos (2 por defecto): el full nuevo, el anterior y los incrementales desde ese full anterior. No se borra el ciclo previo hasta que el full nuevo pasa `gzip -t` en el servidor.

El log va a `/var/log/backup_remote.log` si es escribible; si no, a `~/.backup_remote.log`.

## Configuración

El script busca, en este orden:

1. `~/.backup_remote.conf`
2. `/etc/backup_remote.conf`

```bash
backup_paths=(
    "/ruta/local1:nombre_remoto1"
    "/ruta/local2:nombre_remoto2"
)

remote_backup_dir="/var/backups/sourcename"
ssh_server="servidor.remoto.com"
ssh_user="usuario"
ssh_key="$HOME/.ssh/id_rsa"

# Opcional
# full_backup_max_days=90
# keep_full_cycles=2
# one_file_system=true
# backup_excludes=("*/node_modules" "*/.cache" "*/.npm" "*/.local/share/Trash")
# backup_excludes=()   # desactiva las exclusiones por defecto
```

Si `backup_excludes` no está definido, se aplican las exclusiones por defecto de arriba. `~/.ssh` **no** se excluye: sigue yendo al USB en claro.

## Uso

### backup-remote

```bash
./backup-remote
BACKUP_FORCE_FULL=1 ./backup-remote
```

SSH usa `BatchMode`, keepalives (`ServerAliveInterval=30`), `ConnectTimeout` y un lock en `~/.backup-remote.lock`. En WSL intenta inhibir la suspensión de Windows vía `powershell.exe` mientras corre.

El pipe `tar | ssh` comprueba tar y ssh por separado. tar 1 (ficheros que cambian durante la lectura) se registra como aviso; tar ≥ 2 o fallo de ssh abortan, borran el `.tar.gz` incompleto y **no** actualizan el `.snar`.

`gzip -t` corre en el servidor. Si el archivo está corrupto (rc 1) se borra. Si cae SSH (suspensión, reset), el tar.gz **se deja** y no se toca el `.snar`; hay que verificar a mano en caudatus.

### backup-restore

GNU tar incremental exige el full que abre la cadena y los incrementales siguientes, en orden. El restore elige el `-full.tar.gz` más reciente anterior o igual a la fecha pedida.

```bash
./backup-restore --list /ruta/local
./backup-restore --restore /ruta/local YYYY-MM-DD_HHMMSS [/ruta/destino]
./backup-restore --restore-latest /ruta/local [/ruta/destino]
./backup-restore YYYY-MM-DD_HHMMSS /ruta/local [/ruta/destino]
```

Sin destino, escribe en `/tmp/restore_<nombre>_<pid>`.

## Requisitos

- `ssh` sin contraseña interactiva (clave)
- GNU `tar` y `gzip` en local; `gzip` en el remoto para `gzip -t`
- `flock` (util-linux)

## Errores comunes

- **Permisos del log**: si no puedes escribir `/var/log`, el log cae en el home; no hace falta sudo solo por el log.
- **SSH**: `BatchMode=yes` falla al instante si pide contraseña o hay host key desconocida (salvo `accept-new` en el primer contacto).
- **Exclusiones**: un `node_modules` que quieras conservar hay que quitarlo de `backup_excludes`.

## Licencia

GNU Affero General Public License v3.0. Ver `LICENSE`.
