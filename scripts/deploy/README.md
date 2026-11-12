# Despliegue y versiones

Ejecutar desde el checkout instalado, con su `.env`. La selección de servicios,
imágenes inmutables e historial la mantiene la herramienta en el propio servidor.
No se crean releases de GitHub por ambiente ni se editan manifiestos a mano.

```bash
python3 scripts/deploy/deploy.py status
python3 scripts/deploy/deploy.py update --frontend latest
python3 scripts/deploy/deploy.py history
python3 scripts/deploy/deploy.py rollback
```

`latest` significa la última imagen **publicada**, no un candidato de CI. También
se acepta el SHA completo de una versión publicada. El digest se resuelve una
sola vez y se conserva internamente. `--digest` permite fijarlo adicionalmente en
automatizaciones. `--prepare` prepara y verifica sin recrear servicios.

Configurar `SIHSALUS_PUBLIC_URL=https://servidor` en `.env` una vez, o pasar `--url`.
Esto incorpora las comprobaciones HTTP externas al resultado de la operación.
Sin URL, se verifican las imágenes, identidad y salud internas; el resultado no
acredita acceso desde fuera del host.

## Qué ocurre al actualizar

1. Comprueba checkout limpio, selección real de Compose, ambiente, UUID y versión
   instalada. Un cambio de herramientas operativas es compatible si los archivos
   que definen el runtime siguen idénticos. Un cambio de Compose exige una
   intervención coordinada, no una actualización individual.
2. Verifica las imágenes de recuperación y la salud del componente actual.
3. Resuelve la versión publicada por digest. Para frontend construye únicamente
   su wrapper con la configuración y UUID del servidor, sin modificar `.env` aún.
4. Guarda automáticamente las versiones anterior y candidata y un registro
   privado del intento. Conserva las imágenes anteriores.
5. Usa Docker Compose `up --no-deps --no-build --pull never --wait` exclusivamente
   sobre el componente elegido. Actualizar frontend no reinicia OpenMRS, MariaDB,
   PostgreSQL, gateway ni servicios opcionales.
6. Comprueba imágenes reales, selección persistida, salud y, con URL configurada,
   acceso externo. Si falla el frontend después de empezar, recupera su imagen
   anterior y conserva la evidencia del fallo. El comando devuelve error incluso
   si recuperó correctamente.

Después de una recuperación por fallo, `rollback` no vuelve a instalar el
candidato fallido. Para reintentarlo se elige su versión explícitamente.

Dos actualizaciones no pueden ejecutarse simultáneamente. Interrumpir un proceso
con SIGKILL o perder energía puede dejar una operación pendiente: consultar
`status` e `history` y ejecutar `rollback` si corresponde. Nunca borrar el estado
privado para forzar una actualización.

La limpieza queda fuera del despliegue. El cron local conserva al menos dos
versiones y tres días, además de imágenes en uso, candidatas y recuperación.
No se ejecuta `docker image prune`, no se eliminan volúmenes y no se necesitan
commits ni PR por cada tarea de mantenimiento local.

## Backend y content

```bash
python3 scripts/deploy/deploy.py update --backend VERSION
```

Actualiza solo backend; content viaja dentro de esa imagen y su versión se lee
del artefacto. Antes, confirmar respaldo comprobado, compatibilidad de esquema
y aceptación del cambio. Si falla, conserva la evidencia y no revierte
automáticamente: una imagen anterior no deshace migraciones ya confirmadas.
`rollback` automático/manual está limitado al frontend. La recuperación de
backend y base de datos usa el [procedimiento de backups](../backup/README.md)
y una versión compatible elegida expresamente.

## GitHub Actions y conexión remota

**Deploy Frontend** pide una versión y resuelve su SHA/digest antes de acceder a
los hosts. Mantiene los environments `development` y `quality`, revisión humana
nativa, DEV como canario y QLTY solo después de sus comprobaciones.
La aprobación describe versión y ambiente; hashes y registros son evidencia
producida por la automatización, no archivos que el operador deba preparar.

`run-redeploy-remote.sh` conserva la ejecución desconectable, exclusión mutua,
registro de resultados y comprobación MAC en **cada** conexión SSH. Mantener las
identidades vigentes: DEV `00:0c:29:86:a3:3b` / UUID
`700e430a-1c32-5241-b7cf-78ccea17f8c1`; QLTY `00:0c:29:1c:f7:78` / UUID
`0cefb0c8-c860-48c5-856f-408594775cbb`. El antecedente de VMs clonadas es #243.
`verify-external-frontend.sh` comprueba 12 conexiones independientes, versión,
UUID, dirección remota y salud; una muestra HTTP no prueba aceptación clínica.

Los scripts `deploy-frontend.sh` y `deploy-backend.sh` permanecen como entradas
compatibles y delegan en la misma implementación. No mantienen flujos separados.

## Instalaciones existentes y cambios coordinados

La herramienta reconoce el estado local anterior directamente. Para una
instalación Compose sin historial, captura las imágenes reales, sus revisiones,
content, perfiles y nodo antes de la primera actualización. No cambia datos,
perfiles ni nombres de proyecto. La adopción se detiene ante información
incompleta o imágenes fuente que no se puedan verificar.

El [motor de recuperación](../../docs/operations/release-manifests.md) mantiene
compatibilidad con registros históricos y operaciones coordinadas de Compose.
Es una interfaz interna para recuperación avanzada, no un paso de la operación
cotidiana. Una migración de perfiles, volúmenes o configuración tiene su propia
revisión, respaldo y pruebas; `redeploy-environment.sh` no es el camino normal
para actualizar versiones.

Producción no se actualiza junto con DEV/QLTY. Su adopción y actualización requieren
la ventana y autorización correspondientes.

## Integración con la consola SIHSalus

El instalador y la interfaz de mantenimiento se desarrollan en el repositorio
independiente `sihsalus-cli`. Este repositorio conserva Compose, las imágenes,
las políticas y el motor que fija las versiones y registra la recuperación.
Actualizar el CLI no actualiza por sí mismo la aplicación clínica.

`deploy.py` expone `execute_update(...)` para que la consola pueda resolver una
sola versión, comprobarla, mostrar el cambio, obtener confirmación y mantener
un respaldo abierto durante la aplicación. Conserva el bloqueo hasta terminar.
Los callbacks de seguridad y respaldo son responsabilidad del consumidor:
el motor por sí solo no realiza un escaneo de vulnerabilidades ni crea backups.
Una interrupción del backend conserva el estado y la evidencia; nunca ejecuta
un downgrade automático después de una posible migración.
