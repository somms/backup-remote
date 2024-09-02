
# Backup Remote Script

Este conjunto de scripts, `backup-remote` y `backup-restore`, proporciona una solución completa para realizar y restaurar copias de seguridad de directorios locales a un servidor remoto utilizando `ssh` y `tar`. Dependiendo de la fecha, el script decide si realiza una copia de seguridad completa o incremental, realizando una nueva copia completa como máximo cada tres meses. Además, registra todas las actividades y errores en un archivo de log ubicado en `/var/log/backup_remote.log`.

## Funcionalidades

### `backup-remote`
1. **Configuración Automática**: 
   - El script primero busca la configuración en `~/.backup_remote.conf`.
   - Si no encuentra este archivo, intenta cargar la configuración desde `/etc/backup_remote.conf`.

2. **Copia de Seguridad**:
   - **Copia Completa**: Realiza una copia completa si es el primer día de un trimestre (enero, abril, julio, octubre). No utiliza el archivo `.snar` existente, y después de un backup exitoso, elimina todas las copias anteriores y sube un nuevo archivo `.snar`.
   - **Copia Incremental**: En cualquier otra fecha, realiza una copia incremental usando el archivo `.snar` existente para registrar solo los cambios desde la última copia.

3. **Registro en Log**:
   - Todas las actividades, errores y éxitos se registran en `/var/log/backup_remote.log`.

### `backup-restore`
1. **Restauración de Backups**:
   - **Listar Fechas Disponibles**: El script `backup-restore` puede listar las fechas de las copias de seguridad disponibles para restaurar.
   - **Restaurar un Backup**: Permite restaurar una copia de seguridad específica desde el servidor remoto al directorio local. Puedes especificar la fecha del backup que deseas restaurar.

2. **Modo de Uso**:
   - **Listar fechas de backups disponibles**:
     ```bash
     ./backup-restore --list <directorio_local>
     ```
   - **Restaurar un backup específico**:
     ```bash
     ./backup-restore --restore <directorio_local> <fecha>
     ```
   - **Restaurar el último backup disponible**:
     ```bash
     ./backup-restore --restore-latest <directorio_local>
     ```

## Archivos de Configuración

El script utiliza un archivo de configuración para definir las rutas de backup y las credenciales del servidor remoto. El archivo debe estar en el formato:

```bash
# ~/.backup_remote.conf o /etc/backup_remote.conf

# Usuario y host remoto
ssh_user="usuario"
ssh_host="servidor.remoto.com"
ssh_key="~/.ssh/id_rsa" 

# Carpeta raíz de destino en el servidor de backups
remote_backup_dir="/var/backups/sourcename"


# Lista de rutas de backup en formato "directorio_local:directorio_remoto"
backup_paths=(
    "/ruta/local1:/ruta_remota1"
    "/ruta/local2:/ruta_remota2"
)
```

## Uso

### `backup-remote`
1. **Ejecutar el Script**:
   - El script puede ser ejecutado directamente desde la terminal:
     ```bash
     ./backup-remote
     ```
   - Asegúrate de tener permisos de ejecución:
     ```bash
     chmod +x backup-remote
     ```

2. **Configurar el Cron Job**:
   - Puedes programar este script para que se ejecute automáticamente usando cron. Por ejemplo, para ejecutarlo todos los días a la medianoche:
     ```bash
     0 0 * * * /ruta/al/script/backup-remote
     ```

### `backup-restore`
1. **Listar las Fechas Disponibles**:
   - Ejecuta el siguiente comando para listar todas las fechas de backup disponibles para un directorio específico:
     ```bash
     ./backup-restore --list-dates /ruta/local
     ```

2. **Restaurar un Backup Específico**:
   - Para restaurar un backup específico, usa el siguiente comando:
     ```bash
     ./backup-restore YYYY-MM-DD_HHMMSS /ruta/local_original /ruta/local_destino 
     ```


## Requisitos

- `ssh` debe estar configurado entre el servidor local y remoto para que funcione sin necesidad de ingresar una contraseña cada vez.
- `tar` debe estar instalado en ambos sistemas.

## Logs

Los logs se generan en `/var/log/backup_remote.log`. Puedes revisar este archivo para ver el estado de las copias de seguridad y cualquier error que haya ocurrido.

## Errores Comunes

- **Permisos**: Asegúrate de que el usuario que ejecuta el script tenga permisos para escribir en `/var/log` y acceder a las rutas de backup tanto local como remotamente.
- **Conexión SSH**: Verifica que la conexión SSH esté configurada correctamente y que no requiera contraseñas interactivas.

## Contribuciones

Si tienes sugerencias o mejoras para este script, siéntete libre de hacer un fork del proyecto y enviar un pull request.

## Licencia

Este proyecto está bajo la licencia GNU Affero General Public License v3.0. Para más detalles, revisa el archivo LICENSE.
