# Simulacros de backup y restauración

El workflow independiente `Backup and restore drills` se ejecuta cada lunes a
las 09:41 UTC (04:41 Perú) y manualmente desde Actions. Mantiene el archivo
`physical-backup-drill.yml`; no se activa en PR ni forma parte de `PR Gate`.

## Cobertura

Ejecuta tres jobs independientes en runners efímeros, usando los scripts
operativos del repositorio y datos sintéticos:

| Job | Comprobación |
| --- | --- |
| Dump cifrado | Crear una fila, hacer backup lógico, modificarla, restaurar y verificar su valor original |
| Semillas | Restaurar archivos cifrados, validar checksum y contraseña, rechazar destinos no vacíos y rutas inseguras |
| Restore físico | Comparar checksum y filas después del restore y verificar la recuperación del snapshot ante fallo |

El restore físico usa MariaDB 10.11.7, igual que `restore_full.sh`. Crea un
proyecto Compose y volúmenes propios, sin puertos publicados. El servicio
`backend` del fixture es inerte: no inicia OpenMRS.

El caso negativo reserva temporalmente el nombre de contenedor de `copy-back`,
para que su inicio falle después de preparar el snapshot y limpiar el destino.
Comprueba que el script recupere las filas previas desde ese snapshot. Se rechaza
un nombre ya ocupado antes de comenzar; solo se eliminan los recursos de prueba.
Esto no simula una copia parcialmente completada ni pérdida de disco.

## Ejecución manual

Seleccionar `Backup and restore drills` en Actions y la rama a comprobar, o:

```bash
gh workflow run physical-backup-drill.yml --repo sihsalus/sihsalus --ref main
```

El restore físico solo admite runners Linux efímeros de GitHub con Docker local.
Tiene un máximo de 20 minutos; los jobs de dump y semillas, 10 minutos cada uno.
La prueba de semillas también puede ejecutarse localmente sobre archivos temporales:

```bash
bash tests/seed/roundtrip.sh
```

## Evidencia y límites

El resumen del restore físico registra SHA del checkout, imagen, checksum del
backup, duración, etapa final y resultado de restauración y recuperación.
Se eliminan los backups y logs privados; los diagnósticos del restore físico
ocultan las contraseñas generadas. No se usan datos ni volúmenes de los servidores.

Antes de desplegar, revisar la última ejecución exitosa de `main` y registrar
su enlace, SHA y fecha en el [checklist](deploy-checklist.md), o dejar explícito
el pendiente. El verde del dump o las semillas no sustituye al del restore físico.
El simulacro tampoco acredita recuperación de los demás volúmenes ni aceptación
clínica; véase el [procedimiento operativo](../../scripts/backup/README.md).
