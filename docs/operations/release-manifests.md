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
