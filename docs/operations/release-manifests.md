# Estado interno de despliegue y recuperación

La operación habitual está en [Despliegue y versiones](../../scripts/deploy/README.md):
`deploy.py status`, `update`, `history` y `rollback`. El operador elige versión y
ambiente. La herramienta prepara y conserva los registros automáticamente.

## Formato y compatibilidad

`release-manifest.py` es el motor interno existente. Conserva su formato para
leer instalaciones anteriores, recuperar versiones y permitir al cron local
identificar imágenes protegidas. No se necesita publicar un manifiesto en
GitHub ni ejecutar un workflow de validación por cada servidor.

Los registros fijan las fuentes por digest, sus revisiones, content, UUID,
plataforma, selección Compose e imágenes reales de cada servicio habilitado.
Se guardan con su checksum en `.env.release-state/`, ignorado por Git y privado.
Un override de Compose fija esas imágenes; `.env` apunta a la selección actual.
No quitar ese marcador ni editar el override a mano: `security-audit.sh` compara
la selección efectiva con el estado registrado.

Cada intento conserva las versiones anterior y candidata, `before.env` privado
y el resultado. `before.env` contiene secretos y nunca debe subirse a GitHub.
Los tags `sihsalus-release-retained:*` protegen las imágenes para recuperación.
Los backups y las imágenes exportadas siguen siendo necesarios ante pérdida
del disco. Los registros históricos publicados permanecen como archivo; los
nuevos despliegues no generan releases por nodo.

## Recuperación avanzada

`deploy.py rollback` recupera el frontend anterior. Ante cambios coordinados o
de backend, revisar primero migraciones y respaldo; volver a imágenes anteriores
no revierte SQL ya aplicado. El motor conserva su interfaz de recuperación para
operadores que deban recuperar una instalación antigua o parcialmente actualizada:

```bash
python3 scripts/deploy/release-manifest.py rollback /ruta/anterior.json \
  --previous /ruta/intento.json --root /srv/sihsalus
```

Esta interfaz requiere el checkout de la versión destino, imágenes completas,
identidad y perfiles compatibles. Reutiliza el redeploy integral y puede reiniciar
todos los servicios, por lo que requiere una ventana coordinada. No equivale al
rollback cotidiano del frontend. Un estado `applying` o `failed-or-interrupted`
exige inspeccionar el intento; no restaurar solo `.env` dejando contenedores de
otra versión.

La adopción de este flujo simplificado en producción queda como operación
separada. Los lectores y registros antiguos se conservan para esa transición.

## Reconciliar el estado instalado de QLTY

Desde la instalación de QLTY, ejecuta primero el ensayo con la herramienta de la revisión aprobada. El checksum del manifiesto lleva 64 dígitos hexadecimales sin prefijo. El checkout corresponde al commit instalado en QLTY y el digest identifica la imagen oficial de PostgreSQL que ya usa FUA.

```bash
python3 /ruta/a/reconcile-qlty.py \
  --expected-release "$MANIFEST_SHA256" --checkout "$CHECKOUT_SHA" \
  --fua-postgres-digest "$POSTGRES_DIGEST"
```

El ensayo verifica la selección, la configuración efectiva de Compose, los archivos montados y el estado de los contenedores. Si falta `backend-oauth2-config`, comprueba en privado que el archivo efectivo `/openmrs/data/oauth2.properties` coincide byte a byte con el que generaría el auxiliar y conserva el propietario `root:root` y modo `0644`. Ese archivo contiene el secreto OAuth2 del cliente. Con autorización para recuperar el auxiliar, ejecuta únicamente el servicio y comprueba que el código impreso por `docker wait` sea `0`.

```bash
docker compose up -d --no-deps --no-build --pull never backend-oauth2-config
docker wait "$(docker compose ps --all --quiet backend-oauth2-config)"
```

Verifica de nuevo el contenido y los permisos del archivo y repite el ensayo. Tras revisar el resultado y autorizar la reconciliación de esa selección exacta, repite el primer comando con `--apply`. El historial registra la selección anterior y la nueva. Comprueba el resultado del intento y la continuidad del contenedor y del volumen PostgreSQL antes de reintentar el trabajo de despliegue del backend. Si algún control falla, investiga la discrepancia antes de reintentar.

## Backend de QLTY saludable después del timeout

Si el backend recreado por un despliegue de QLTY termina de iniciar después de que Compose agote su plazo, usa `scripts/deploy/finalize-qlty-backend.py --help` para preparar el ensayo. La herramienta reconoce el plazo actual de tres horas (`3h0m0s`) y el de 30 minutos (`30m0s`) de los despliegues anteriores. Desde el checkout instalado, ejecuta la herramienta de la revisión aprobada con el UUID del intento, los checksums de ambas selecciones, el SHA y digest publicados del backend, el identificador de la ejecución remota y el del respaldo verificado.

El ensayo comprueba que sigue activo el contenedor iniciado durante el intento, contrasta la evidencia del respaldo y verifica la disponibilidad pública y la identidad de QLTY. Si devuelve `ready to record`, la ejecución autorizada con `--apply` añade un registro de recuperación. El intento original conserva su fallo. Un backend que continúa inicializándose requiere diagnóstico antes de cerrar la recuperación.
