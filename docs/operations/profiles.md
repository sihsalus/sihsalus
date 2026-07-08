# Perfiles operativos SIH Salus

Este documento define los perfiles operativos para despliegues de SIH Salus en establecimientos con conectividad limitada. Los perfiles operativos describen realidades de uso; no son solo perfiles técnicos de Docker Compose.

## Principios

- El perfil por defecto debe permitir atención clínica local sin internet.
- Todo servicio habilitado debe tener un responsable operativo claro.
- Los puestos remotos deben usar la menor cantidad posible de servicios.
- Las herramientas técnicas no deben exponerse al personal clínico o administrativo.
- Los paneles de estado no deben mostrar datos personales, datos de salud, tokens ni secretos.
- El semáforo local debe considerarse un control parcial de disponibilidad, no una certificación de cumplimiento normativo.
- Las acciones administrativas deben quedar registradas cuando afecten continuidad, seguridad, backup o restauración.

## Puesto remoto

Perfil para establecimientos pequeños o aislados donde la prioridad es registrar atenciones y conservar datos localmente.

Servicios habilitados:

- `gateway`
- `frontend`
- `backend`
- `db`
- `status`
- `ssl`

Servicios deshabilitados por defecto:

- `keycloak`
- `hapi`
- `imaging`
- `monitoring`
- `logs`
- `portainer` (instalado bare metal)

Requisitos mínimos:

- 4 CPU
- 8 GB RAM
- 250 GB SSD
- UPS recomendado
- Disco externo o USB para backup semanal

Puertos expuestos:

- `80` o `443` para acceso local
- Ningún puerto técnico expuesto a la red por defecto

Política operativa:

- Debe poder atender pacientes sin internet.
- Debe mostrar estado en `/admin/local`.
- Debe ejecutar backup local diario.
- Debe permitir backup externo semanal.
- Debe mantener instrucciones impresas de recuperación.

## Centro de salud

Perfil para establecimientos con mayor capacidad operativa, más usuarios y posibilidad de servicios complementarios.

Servicios habilitados:

- Todo lo del perfil `puesto remoto`
- `keycloak` opcional si hay gestión formal de usuarios
- `imaging` solo si existe flujo real de imágenes médicas

Servicios deshabilitados por defecto:

- `hapi`
- `monitoring`
- `logs`
- `portainer`

Requisitos mínimos:

- 4 a 8 CPU
- 16 GB RAM
- 500 GB SSD
- UPS recomendado
- Backup externo obligatorio

Política operativa:

- Keycloak solo debe habilitarse si existe procedimiento local de recuperación de usuarios.
- Imaging solo debe habilitarse si hay responsable de almacenamiento y retención DICOM.
- El panel local debe indicar si el sistema puede atender pacientes y si el último backup es válido.

## Cabecera de microred

Perfil para nodos con capacidad de consolidación, soporte y monitoreo de varios establecimientos.

Servicios habilitados:

- Todo lo del perfil `centro de salud`
- `hapi`
- `monitoring`
- `logs` opcional
- `replica`
- `sync` cuando exista

Servicios restringidos:

- `portainer` solo para soporte técnico autorizado

Requisitos mínimos:

- 8 CPU
- 32 GB RAM
- 1 TB SSD o más según carga
- UPS obligatorio
- Política de backup externo y réplica probado

Política operativa:

- Debe consolidar paquetes de sincronización de puestos remotos.
- Debe centralizar monitoreo técnico.
- Debe mantener evidencia de backups y actualizaciones.
- Debe evitar exponer herramientas administrativas fuera de redes de soporte.

## Brigada

Perfil portátil para brigadas o atención itinerante.

Servicios habilitados:

- `gateway`
- `frontend`
- `backend`
- `db`
- `status`
- `ssl`
- `sync` cuando exista

Servicios deshabilitados por defecto:

- `keycloak`
- `hapi`
- `imaging`
- `monitoring`
- `logs`
- `portainer`

Requisitos mínimos:

- Laptop o mini PC
- 8 GB RAM
- 250 GB SSD
- Batería o UPS portátil
- Red WiFi local

Política operativa:

- Debe operar sin internet durante la jornada.
- Debe exportar paquete de jornada al volver a la cabecera.
- Debe mostrar claramente si quedan datos pendientes de exportación.
- Debe incluir backup antes de apagar o trasladar el equipo.

## Soporte técnico

Perfil restringido para diagnóstico, mantenimiento y recuperación.

Servicios permitidos:

- `monitoring`
- `logs`
- `portainer` si se decide incorporarlo
- herramientas de diagnóstico

Restricciones:

- No debe estar habilitado por defecto.
- No debe ser visible para personal clínico o administrativo.
- No debe exponer Docker socket a redes no administrativas.
- Debe requerir credenciales de soporte.
- Debe registrar acciones que cambien estado del sistema.

## Mapeo inicial de perfiles técnicos

| Perfil operativo | Compose/profiles esperados |
| --- | --- |
| Puesto remoto | `docker-compose.yml` + `compose/ssl.yml` + `compose/status.yml` |
| Centro de salud | Puesto remoto + `compose/keycloak.yml` o `compose/imaging.yml` según necesidad |
| Cabecera de microred | Centro + `--profile hapi` + `--profile monitoring` + `--profile replica` |
| Brigada | Puesto remoto + configuración local de jornada/exportacion |
| Soporte técnico | `--profile monitoring`, `--profile logs`, futuro `--profile support` |

## Criterios de auditoría

- Cada servicio habilitado por defecto debe estar justificado por perfil operativo.
- Un puesto remoto debe poder funcionar sin `monitoring`, `hapi`, `keycloak`, `imaging` y `portainer`.
- Toda herramienta técnica con capacidad administrativa debe estar separada del semáforo local.
- El semáforo local debe ser de solo lectura para personal no técnico.
- El semáforo local no debe mostrar datos personales ni datos clínicos.
- Toda actualización debe dejar versión anterior, versión nueva, operador, fecha y resultado.
- Todo backup debe poder verificarse por fecha, checksum y resultado.

Ver también:

- [Semáforo local: privacidad y cumplimiento](status-compliance.md)
- [Métricas de seed restore y arranque OpenMRS](seed-restore-metrics.md)
