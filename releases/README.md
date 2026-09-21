# Manifiestos de despliegue

Cada release revisada se incorpora como un archivo nuevo:

```text
releases/<environment>/<nodeId>/<releaseId>.json
```

Los manifiestos publicados no se editan, renombran ni eliminan. CI compara cada
archivo con la base del PR, valida su contrato y renderiza los servicios de su
commit de distro con valores sintéticos. Todos los servicios activos deben tener
una imagen por digest o un ID local exacto; no se admite `latest`, ni siquiera
acompañado de un digest. Al integrar en `main`, el workflow `Release manifests`
publica los archivos y un índice SHA-256. Git conserva el historial después de
los 90 días de retención del artefacto de Actions.

No guardar `.env`, contraseñas, configuraciones Compose renderizadas, datos
clínicos ni archivos de estado en este catálogo. El contrato rechaza campos
desconocidos para impedir que se adjunte configuración adicional por accidente.

Este directorio inicialmente contiene solo el procedimiento. No hay un
manifiesto de producción publicado o validado implícitamente. El primer
manifiesto real requiere captura, revisión y prueba de despliegue/reversión en
QLTY, siguiendo el [procedimiento de releases](../docs/operations/release-manifests.md).
