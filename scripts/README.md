# Scripts operativos

Este directorio contiene las herramientas ejecutables del stack. La documentación detallada vive junto al subsistema correspondiente para evitar instrucciones duplicadas.

## Inventario

| Ruta | Responsabilidad | Documentación |
| --- | --- | --- |
| `backup/` | Dump, backup binario, restore y rotación | [backup/README.md](backup/README.md) |
| `database/` | Inicialización de usuarios y réplica MariaDB | [database/README.md](database/README.md) |
| `deploy/` | Despliegue inmutable y rollback del frontend | [deploy/README.md](deploy/README.md) |
| `security/` | Generación y auditoría de archivos de entorno | [security/README.md](security/README.md) |
| `seed/` | Crear y aplicar releases cifrados de datos seed | [seed/README.md](seed/README.md) |
| `utils/` | Inicialización, certificados y soporte operativo | [utils/README.md](utils/README.md) |
| `validate-compose.sh` | Validación local y de CI de todos los modelos Compose | [compose/README.md](../compose/README.md) |
| `management-tunnel.sh` | Túneles SSH hacia consolas administrativas locales | Ayuda del script |
| `verify-installation.sh` | Verificación posterior a instalación | Ayuda del script |

## Reglas

- Ejecuta los scripts desde la raíz del repositorio, salvo que su ayuda indique otra cosa.
- Usa el mismo `.env`, `COMPOSE_FILE` y `COMPOSE_PROFILES` del servidor.
- No ejecutes scripts de restore sin backup previo y ventana operativa aprobada.
- `BACKUP_ENCRYPTION_PASSWORD` debe venir del ambiente o de un gestor de secretos; Docker Compose no usa Docker secrets en este repositorio.
- Los backups solo se cifran cuando `BACKUP_ENCRYPTION_PASSWORD` está definida. Producción debe definirla.
- Los seeds se cifran siempre y requieren `SIHSALUS_SEED_PASSPHRASE_FILE`.
- No guardes claves, tokens, archivos `.env` o datos clínicos en Git ni en artifacts de CI.

## Validación rápida

```bash
./scripts/validate-compose.sh
./scripts/security-audit.sh .env.production
```

Para despliegues, usa el [checklist operativo](../docs/operations/deploy-checklist.md).
