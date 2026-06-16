# Perfiles operativos SIH Salus

Este documento define los perfiles operativos para despliegues de SIH Salus en establecimientos con conectividad limitada. Los perfiles operativos describen realidades de uso; no son solo perfiles tecnicos de Docker Compose.

## Principios

- El perfil por defecto debe permitir atencion clinica local sin internet.
- Todo servicio habilitado debe tener un responsable operativo claro.
- Los puestos remotos deben usar la menor cantidad posible de servicios.
- Las herramientas tecnicas no deben exponerse al personal clinico o administrativo.
- Los paneles de estado no deben mostrar datos personales, datos de salud, tokens ni secretos.
- El semaforo local debe considerarse un control parcial de disponibilidad, no una certificacion de cumplimiento normativo.
- Las acciones administrativas deben quedar registradas cuando afecten continuidad, seguridad, backup o restauracion.

## Puesto remoto

Perfil para establecimientos pequenos o aislados donde la prioridad es registrar atenciones y conservar datos localmente.

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

Requisitos minimos:

- 4 CPU
- 8 GB RAM
- 250 GB SSD
- UPS recomendado
- Disco externo o USB para backup semanal

Puertos expuestos:

- `80` o `443` para acceso local
- Ningun puerto tecnico expuesto a la red por defecto

Politica operativa:

- Debe poder atender pacientes sin internet.
- Debe mostrar estado en `/admin/local`.
- Debe ejecutar backup local diario.
- Debe permitir backup externo semanal.
- Debe mantener instrucciones impresas de recuperacion.

## Centro de salud

Perfil para establecimientos con mayor capacidad operativa, mas usuarios y posibilidad de servicios complementarios.

Servicios habilitados:

- Todo lo del perfil `puesto remoto`
- `keycloak` opcional si hay gestion formal de usuarios
- `imaging` solo si existe flujo real de imagenes medicas

Servicios deshabilitados por defecto:

- `hapi`
- `monitoring`
- `logs`
- `portainer`

Requisitos minimos:

- 4 a 8 CPU
- 16 GB RAM
- 500 GB SSD
- UPS recomendado
- Backup externo obligatorio

Politica operativa:

- Keycloak solo debe habilitarse si existe procedimiento local de recuperacion de usuarios.
- Imaging solo debe habilitarse si hay responsable de almacenamiento y retencion DICOM.
- El panel local debe indicar si el sistema puede atender pacientes y si el ultimo backup es valido.

## Cabecera de microred

Perfil para nodos con capacidad de consolidacion, soporte y monitoreo de varios establecimientos.

Servicios habilitados:

- Todo lo del perfil `centro de salud`
- `hapi`
- `monitoring`
- `logs` opcional
- `replica`
- `sync` cuando exista

Servicios restringidos:

- `portainer` solo para soporte tecnico autorizado

Requisitos minimos:

- 8 CPU
- 32 GB RAM
- 1 TB SSD o mas segun carga
- UPS obligatorio
- Politica de backup externo y restore probado

Politica operativa:

- Debe consolidar paquetes de sincronizacion de puestos remotos.
- Debe centralizar monitoreo tecnico.
- Debe mantener evidencia de backups, restauraciones y actualizaciones.
- Debe evitar exponer herramientas administrativas fuera de redes de soporte.

## Brigada

Perfil portatil para campanas o atencion itinerante.

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

Requisitos minimos:

- Laptop o mini PC
- 8 GB RAM
- 250 GB SSD
- Bateria o UPS portatil
- Red WiFi local

Politica operativa:

- Debe operar sin internet durante la jornada.
- Debe exportar paquete de jornada al volver a la cabecera.
- Debe mostrar claramente si quedan datos pendientes de exportacion.
- Debe incluir backup antes de apagar o trasladar el equipo.

## Soporte tecnico

Perfil restringido para diagnostico, mantenimiento y recuperacion.

Servicios permitidos:

- `monitoring`
- `logs`
- `portainer` si se decide incorporarlo
- herramientas de diagnostico

Restricciones:

- No debe estar habilitado por defecto.
- No debe ser visible para personal clinico o administrativo.
- No debe exponer Docker socket a redes no administrativas.
- Debe requerir credenciales de soporte.
- Debe registrar acciones que cambien estado del sistema.

## Mapeo inicial de perfiles tecnicos

| Perfil operativo | Compose/profiles esperados |
| --- | --- |
| Puesto remoto | `docker-compose.yml` + `compose/ssl.yml` + `compose/status.yml` |
| Centro de salud | Puesto remoto + `compose/keycloak.yml` o `compose/imaging.yml` segun necesidad |
| Cabecera de microred | Centro + `--profile hapi` + `--profile monitoring` + `--profile replica` |
| Brigada | Puesto remoto + configuracion local de jornada/exportacion |
| Soporte tecnico | `--profile monitoring`, `--profile logs`, futuro `--profile support` |

## Criterios de auditoria

- Cada servicio habilitado por defecto debe estar justificado por perfil operativo.
- Un puesto remoto debe poder funcionar sin `monitoring`, `hapi`, `keycloak`, `imaging` y `portainer`.
- Toda herramienta tecnica con capacidad administrativa debe estar separada del semaforo local.
- El semaforo local debe ser de solo lectura para personal no tecnico.
- El semaforo local no debe mostrar datos personales ni datos clinicos.
- Toda actualizacion debe dejar version anterior, version nueva, operador, fecha y resultado.
- Todo backup debe poder verificarse por fecha, checksum y resultado.

Ver tambien: [Semaforo local: privacidad y cumplimiento](status-compliance.md).
