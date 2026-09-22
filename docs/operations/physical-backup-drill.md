# Simulacro de restauración física

El workflow `Physical backup restore drill` ejecuta semanalmente, cada lunes a
las 09:41 UTC, los scripts canónicos `backup_full.sh` y `restore_full.sh` sobre
una MariaDB efímera. También admite ejecución manual y se ejecuta en PR que
modifican esos scripts o la prueba. Seguimiento: [#174](https://github.com/sihsalus/sihsalus/issues/174).

## Comprobación real

1. Crea un proyecto Compose y un volumen exclusivos en un runner Linux efímero
   de GitHub. No publica puertos ni admite un Docker remoto. Las dos claves son
   aleatorias; solo se crea una tabla `probe` en la base sintética `backup_drill`.
2. Ejecuta `backup_full.sh`, que usa `mariadb-backup`, comprime y cifra el backup.
   Registra el SHA-256 del archivo cifrado.
3. Cambia una fila y elimina otra. Ejecuta `restore_full.sh`, incluido descifrado,
   preparación, snapshot previo y `copy-back`. Espera que MariaDB acepte consultas
   y compara `CHECKSUM TABLE ... EXTENDED`, las tres filas exactas y su cantidad.
4. Cambia los datos nuevamente e incorpora una cuarta fila que solo puede
   proceder del snapshot previo al siguiente intento.
5. Provoca un fallo al iniciar el contenedor de `copy-back`. Comprueba el código
   de error, la ejecución de la recuperación del snapshot, el arranque de MariaDB
   y la igualdad del checksum y de las cuatro filas anteriores al intento.
6. Verifica que el archivo cifrado siga intacto, elimina los recursos del
   proyecto y su snapshot, y registra resultados y tiempos en el resumen del job.

El flujo de preparación y copia es el que documenta
[MariaDB Backup](https://mariadb.com/docs/server/server-usage/backup-and-restore/mariadb-backup/full-backup-and-restore-with-mariadb-backup).
Se usa MariaDB 10.11.7, la versión que declara actualmente `restore_full.sh`.
El resumen identifica la imagen real del contenedor.

## Alcance del fallo controlado

El script operativo todavía asigna el nombre fijo `sihsalus-db-restore` al
contenedor de copia. El test exige que ese nombre esté libre y crea un contenedor
propio con ese nombre únicamente para el caso negativo. Docker rechaza el inicio
del `copy-back`, después de que el script haya tomado el snapshot y limpiado el
destino. Se ejecuta la recuperación existente, sin sustituir Docker, editar el
script ni añadir un modo de fallo al producto.

Esto comprueba la recuperación ante fallo de inicio de la copia; no reproduce
una copia parcialmente completada, un disco perdido ni un archivo cifrado
corrupto. El cambio de nombres se sigue en [#172](https://github.com/sihsalus/sihsalus/issues/172);
al retirar ese nombre se debe actualizar el punto de inyección manteniendo una
prueba real de la rama de recuperación. La prueba y los scripts corresponden
a los mantenedores del distro.

El servicio `backend` del fixture es un proceso inerte que permite ejecutar el
contrato Compose del restore. Este simulacro no arranca OpenMRS ni acredita
consistencia clínica, recuperación de otros volúmenes o tiempos de producción.
No usa backups, credenciales ni volúmenes de DEV, QLTY o producción.

## Evidencia operativa

Antes de desplegar, consultar el
[último simulacro exitoso de main](https://github.com/sihsalus/sihsalus/actions/workflows/physical-backup-drill.yml?query=branch%3Amain+is%3Asuccess)
y registrar su URL, SHA y fecha en el checklist. Un resultado de PR acredita
solo ese candidato; si no hay ejecución exitosa en main, registrar el pendiente.
El verde del dump lógico no sustituye esta evidencia.

El resumen incluye éxito/fallo de ambas comprobaciones, etapa final, código de
salida, tiempos, imagen y checksum del archivo cifrado. Los logs privados y el
backup se eliminan al terminar. En caso de fallo, la consola conserva únicamente
las últimas líneas de los logs sintéticos, depuradas de ambas claves generadas.
No se publican backups, datos de tablas, configuración Docker ni claves.

La ejecución completa se realiza desde Actions; el script rechaza contextos
locales y nunca inicia un daemon. Los plazos de cada operación y del job evitan
que un fallo de restauración quede esperando indefinidamente.
