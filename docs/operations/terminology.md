# Terminología en un host dedicado

El código de API y navegador vive en `sihsalus-terminology`. Este repositorio
mantiene su operación mediante `docker-compose.terminology.yml`, independiente
del stack clínico y de sus bases de datos. Todas las imágenes se descargan por
digest; no se compila en `gidis-terminology`.

## Preparación

1. Construir y verificar las imágenes API, web, PostgreSQL, Redis y Elasticsearch
   en el workflow `Terminology runtime`. Exigir pruebas, análisis de dependencias y escaneo de las imágenes
   satisfactorios en el mismo commit que se despliega.
   El workflow `Terminology service images` comprueba además el almacenamiento
   consumido directamente por digest. Las imágenes derivadas conservan las
   versiones de servicio y actualizan sus dependencias; su arranque se comprueba
   en CI antes de llegar al host.
2. Conservar backups cifrados de los volúmenes anteriores fuera de la VM.
   Inspeccionar copias de sus bases antes de seleccionar qué datos migrar.
   No renombrar ni reutilizar automáticamente los volúmenes `ocl_*` o `oclweb2_*`.
3. Preparar un checkout limpio de esta revisión en el servidor y generar
   `.env.terminology` con el modo `terminology` de `secrets_generate.sh`.
   Completar las variables documentadas en `.env.template`, incluidos el
   `/etc/machine-id` esperado, SHA fuente y referencias por digest.
4. Instalar `terminology/sihsalus-terminology.slice` en `/etc/systemd/system/`;
   ejecutar `systemctl daemon-reload` y habilitar la unidad. Docker debe usar
   el controlador systemd. El conjunto tiene un máximo de 5 GiB, 1.5 CPU y
   1 GiB de swap; cada servicio tiene además su límite individual.
5. Mantener `vm.max_map_count` al menos en 262144. Reservar 10 GiB de disco
   después del pull y espacio adicional para backups y la versión anterior.
6. Instalar la plantilla Nginx con el hostname real y los certificados
   existentes; validar con `nginx -t` antes de recargar. Solo sustituir
   `${TERMINOLOGY_HOST}` y `${TERMINOLOGY_API_HOST}`: las variables de Nginx deben permanecer literales.
   Conservar `certbot.timer` y verificar que renueva el certificado.

## Primera instalación

```sh
bash scripts/deploy/deploy-terminology.sh /ruta/privada/.env.terminology bootstrap
```

El script comprueba identidad, recursos, configuración y revisión OCI, inicia
las dependencias, ejecuta la inicialización y arranca la aplicación por etapas.
No elimina contenedores ni volúmenes anteriores. Un bootstrap fallido conserva
su estado; se inspecciona antes de reintentar. Los journals privados quedan en
`.env.terminology-state/` y nunca se publican.

El navegador y la API usan nombres DNS distintos con HTTPS en 443, y el
certificado debe cubrir ambos nombres. Las exportaciones firmadas usan
`/terminology-exports/`. Nginx consume servicios ligados a localhost. PostgreSQL,
Redis y Elasticsearch no publican puertos. Las credenciales iniciales del usuario
`ocladmin` están en el archivo privado; no se incluyen en logs ni en informes.
El navegador ofrece acceso con cuentas locales cuando no hay un proveedor OIDC
configurado. El registro público está deshabilitado; el administrador crea las
cuentas. El envío de correo está desactivado hasta configurar y autorizar un
servicio SMTP; el acceso local usa el soporte del administrador. La API no instala el middleware que registra cuerpos de peticiones y
respuestas, pues pueden contener credenciales.

## Aceptación

- Verificar el digest y revisión de las imágenes ejecutadas, salud de todos los
  servicios, límites efectivos del cgroup y ausencia de reinicios por memoria.
- Comprobar autenticación y rechazo de operaciones no autorizadas.
- Crear, editar, consultar y publicar un concepto sintético desde el navegador.
- Descargar la exportación por HTTPS y comprobar su contenido y enlaces.
- Importar una copia de los catálogos SIHSALUS y comparar códigos, UUID, mappings
  y conteos con la fuente. Medir consultas mientras se ejecuta una importación.
- Probar la restauración del backup en volúmenes distintos antes de declarar
  recuperable la instalación. Los originales se conservan hasta la aceptación.
- Integrar únicamente versiones publicadas en SIHSALUS; mantener la terminología
  empaquetada para que las pantallas clínicas no dependan de este host.

## Preparar la migración de catálogos

```sh
python3 scripts/terminology/prepare-import.py \
  --repo /ruta/sihsalus-content --ref COMMIT_REVISADO \
  --output /ruta/privada/catalogos
```

El directorio de salida debe ser nuevo. El manifiesto identifica el commit, los
hashes de los ZIP originales y los lotes, y conserva los registros esperados
para comparar códigos, `external_id`, nombres y relaciones después de cargar.
Los lotes tienen hasta 500 registros para limitar el trabajo por tarea. Esta
cifra es un límite operativo de importación, no una restricción del catálogo.

Cargar los lotes en el orden del manifiesto mediante `/importers/bulk-import/`, con
`parallel=2`: primero todos los conceptos y después todos los mappings. Los dos
procesos comparten el límite de CPU y memoria del worker; el coordinador usa un
proceso separado. Celery recibe directamente las señales de parada de Docker. Los ZIP
de trabajo se marcan `HEAD` para que el importador oficial de OCL no publique una
versión antes de terminar sus mappings. No cambian los códigos ni los UUID de
los registros. Comprobar cada resultado, reconciliar los registros persistidos
y solo entonces crear las versiones indicadas en el manifiesto y exportarlas.
El procedimiento inicial requiere fuentes vacías; una actualización de catálogos
existentes necesita revisar el diff y conservar la versión anterior.

Redis conserva los resultados completados durante una hora; los informes de
tareas persistentes permanecen en PostgreSQL y los lotes aceptados tienen
además su resultado en el directorio privado de migración. Esta ventana evita
acumular copias completas de toda la migración en la memoria del broker.
Mantener los lotes y sus tareas coordinadoras por debajo de una hora y revisar
este límite antes de ejecutar importaciones mayores. No se aplica una política
de expulsión a las colas de Redis.

`import-catalogs.py` conserva el identificador de cada tarea antes de consultar
su resultado y bloquea una segunda ejecución sobre el mismo directorio.
Crear un archivo `PAUSE` en el directorio privado de catálogos permite terminar
el lote actual sin enviar el siguiente. Para continuar, retirar ese archivo y
ejecutar de nuevo el mismo comando; no se repiten los lotes aceptados.

### Comparar y publicar

Al terminar la carga, recuperar las opciones de edición de las fuentes y
comparar una exportación nueva de cada catálogo:

```sh
python3 scripts/terminology/reconcile-catalogs.py \
  --env /ruta/privada/.env.terminology --catalogs /ruta/privada/catalogos \
  --restore-source-settings
```

El importador ZIP de OCL no traslada todas las opciones de generación de códigos
y UUID. El comando las recupera mediante la API de fuentes, junto con sus
metadatos originales. Esta operación se hace después de cargar los registros,
para conservar también los identificadores originalmente nulos. Guarda la
configuración anterior en el directorio privado. Sin `--restore-source-settings`
solo compara y detiene el proceso si encuentra diferencias.

La comparación exige todos los lotes de la fuente aceptados y excluye una
importación simultánea. Comprueba códigos, UUID externos, nombres, descripciones,
idiomas, retiros, relaciones jerárquicas, mappings y metadatos de la fuente.
Conserva los ZIP verificados y sus hashes en `reconciled-head/`; `--source NOMBRE`
permite trabajar con un catálogo sin borrar los informes de los demás.
Una importación con estado `SUCCESS` no sustituye esta comparación.

Solo después de reconciliar todos los catálogos, crear secuencialmente las
versiones originales con `POST /orgs/SIHSALUS/sources/FUENTE/versions/`, usando
`version`, `version_description` y `released` del manifiesto como los campos
`id`, `description` y `released`. La respuesta inicial puede representar trabajo
asíncrono: consultar cada versión hasta que exista y termine su procesamiento.
No enviar de nuevo una publicación cuyo resultado sea desconocido.

```sh
python3 scripts/terminology/reconcile-catalogs.py \
  --env /ruta/privada/.env.terminology --catalogs /ruta/privada/catalogos \
  --published
```

Esta segunda comparación usa las versiones publicadas y conserva su evidencia
en `reconciled-published/`. Resolver cualquier diferencia antes de configurar
consumidores clínicos. Los catálogos provienen de una revisión inmutable de
`sihsalus-content`; la migración conserva sus versiones y no constituye una
nueva aceptación clínica ni incorpora códigos SNOMED CT adicionales.

## Actualización y recuperación

```sh
bash scripts/deploy/deploy-terminology.sh /ruta/privada/.env.terminology update /ruta/privada/backups
```

La actualización conserva la configuración anterior registrada en `active.env`,
ejecuta un respaldo cifrado, guarda el plan de migraciones y aplica únicamente
las migraciones. No vuelve a cargar fixtures ni restablece la cuenta inicial.
Revisar las migraciones del cambio antes de ejecutar el comando. Una migración
fallida deja los servicios de aplicación detenidos para conservar el estado de
recuperación; inspeccionar el journal antes de reintentar. Volver a una imagen no
revierte el esquema de PostgreSQL. Si una migración
no permite retroceso, restaurar la copia en volúmenes nuevos y verificarla antes
de cambiar el servicio activo. Nunca usar `down -v` ni podas globales de Docker.

El respaldo requiere `recovery.key` con permisos 600 en el directorio privado.
Comprueba que no haya tareas en curso en PostgreSQL, en ambos workers y en el
broker; detiene brevemente las escrituras y guarda
PostgreSQL, objetos, uploads, configuración y referencias de imágenes en un
archivo cifrado. Restaura el servicio al terminar, incluso si falla la copia.
Durante una actualización, el despliegue usa `leave-stopped`: una copia correcta
deja aplicación y almacenamiento detenidos hasta iniciar la nueva revisión,
evitando arrancar y volver a parar inmediatamente los workers. Si el respaldo
falla, se intenta reanudar la revisión anterior. El timer usa la reanudación
normal.
Instalar el servicio y timer de `terminology/` solo después de probar una copia
y su restauración: programa las 03:15 de Lima. Conservar una copia cifrada y la
clave fuera de la VM. Revisar el resultado en `journalctl` y el espacio disponible.
La retención predeterminada es de 14 copias `runtime-*` y solo se aplica después
de verificar una copia nueva; `TERMINOLOGY_BACKUP_KEEP` permite ajustarla (mínimo
dos). Los backups del despliegue anterior `legacy-*` se conservan. El respaldo
no comienza si quedan menos de 10 GiB libres para proteger la capacidad del host.
`active-distro-commit` identifica la revisión realmente desplegada, aunque el
checkout ya tenga una actualización pendiente. Las instalaciones anteriores a
este registro deben establecerlo a partir de su despliegue verificado antes
del siguiente respaldo.
