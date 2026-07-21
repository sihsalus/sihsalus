# Migración canónica de citas, consultas y colas 1.23.0

Fecha: 2026-07-18  
Entornos autorizados: DEV y QLTY  
PROD: prohibido hasta completar la validación funcional y aprobar una migración independiente

## Objetivo

Desplegar `sihsalus-content 1.23.0`, reemplazar los tipos de consulta que codificaban una
especialidad por cinco ámbitos canónicos y verificar el contrato cita → consulta → cola sin
conservar metadata obsoleta en los entornos no productivos.

El paquete canónico contiene únicamente:

| Ámbito | UUID |
|---|---|
| Atención Ambulatoria | `b1f0e8a1-9c5d-4f0e-8892-81f3140fbc09` |
| Sesión Grupal Ambulatoria | `23939157-9af0-457b-8f6c-211eb5459311` |
| Hospitalización | `e4c8b6d9-7f3a-4e7b-91a2-58b9f6c2d4b5` |
| Emergencia | `c2a1d3e2-4b8f-4326-94d9-7f6c9a1b7c98` |
| Atención Extramural | `c80410d7-e0cb-488f-9b23-be78bd244548` |

## Condiciones previas

1. Confirmar por nombre de host y URL que el entorno sea DEV o QLTY.
2. Crear y verificar un respaldo con `scripts/backup/backup_dump.sh`.
3. Detener temporalmente el backend y cualquier proceso que pueda crear consultas o citas.
4. Guardar los resultados de las consultas de inventario de este documento.
5. Publicar primero `sihsalus-content 1.23.0`; después construir el distro que lo referencia.

No se debe ejecutar una limpieza si existe una cita o consulta activa durante la ventana.

## Inventario de solo lectura

```sql
SELECT vt.uuid, vt.name, vt.retired, COUNT(v.visit_id) AS consultas
FROM visit_type vt
LEFT JOIN visit v ON v.visit_type_id = vt.visit_type_id
GROUP BY vt.visit_type_id, vt.uuid, vt.name, vt.retired
ORDER BY vt.name;

SELECT COUNT(*) AS consultas_activas
FROM visit
WHERE voided = 0 AND date_stopped IS NULL;

SELECT COUNT(*) AS citas_futuras_en_servicios_no_programables
FROM appointments a
JOIN appointment_service_definition s ON s.appointment_service_id = a.service_id
WHERE s.uuid IN (
  'd4e5f6a7-b8c9-41e2-93f3-1a9b8c7d6e04',
  'e5f6a7b8-c9d0-42f3-93e4-2b0a9c8d7e05',
  'f7a8b9c0-d1e2-43f4-93e5-3b1a9c8d7e06'
)
AND a.start_date_time >= CURRENT_TIMESTAMP
AND a.status NOT IN ('Cancelled', 'Completed');
```

Los nombres de las tablas de Appointments deben confirmarse contra el esquema instalado antes de
usar la tercera consulta. Si difieren, detenerse; no adaptar nombres por suposición.

## Estrategia preferida

Como DEV y QLTY aún no son producción, la opción preferida es restaurar un seed limpio y ejecutar
Initializer con content `1.23.0`. Esto evita conservar tipos, atributos y variantes de servicio
obsoletos. Antes de resetear, exportar los casos de prueba que deban recrearse.

## Estrategia conservando datos de prueba

Si el equipo decide conservar consultas, primero se reasignan por UUID:

| Tipos anteriores | Destino |
|---|---|
| `Consulta Ambulatoria - *`, Dispensación, Procedimientos Especializados, Consulta Diagnóstica | Atención Ambulatoria |
| `Hospitalización - *` | Hospitalización |
| `Emergencia - *` | Emergencia |

La operación debe ejecutarse en una transacción preparada y revisada por dos personas. El SQL
debe resolver los `visit_type_id` por UUID, comprobar que cada destino existe exactamente una vez,
actualizar `visit.visit_type_id` y abortar si queda alguna referencia anterior. Solo entonces se
eliminan los tipos antiguos, el atributo `Parent Visit Type` y los tipos de servicio uno-a-uno.

No se incluye SQL destructivo ejecutable en el repositorio porque el módulo Appointments puede
variar sus nombres de tabla entre versiones. La sentencia final se genera después del inventario
del esquema efectivo de cada entorno y se adjunta al registro de cambio.

## Orden de despliegue

1. Respaldar e inventariar.
2. Limpiar o restaurar DEV/QLTY.
3. Desplegar backend con content `1.23.0` y esperar a que Initializer finalice sin errores.
4. Verificar los cinco `VisitType`, los Concepts de cola y las 13 reglas de llegada.
5. Desplegar el frontend compatible con `careRoutingContractVersion = 2026-07-18`.
6. Ejecutar aceptación funcional.

## Aceptación mínima

- Odontología general no referencia Cirugía Bucal y Maxilofacial.
- Los 13 servicios programables tienen una regla exacta por servicio y ubicación.
- Rehabilitación, hemodiálisis y nutrición permiten registrar llegada con su cola configurada.
- Una ruta directa no crea `QueueEntry`.
- Una ruta con cola crea una sola consulta y una sola `QueueEntry`.
- Reintentar una respuesta ambigua no duplica cita, consulta ni entrada de cola.
- No existe ningún `VisitType` fuera de los cinco UUID canónicos.
- No existe el atributo `Parent Visit Type`.
- No existen variantes `AppointmentServiceType` uno-a-uno heredadas.
- Los cuatro microfrontends que usan `Consulta Especializada` siguen creando encuentros; ese
  `EncounterType` permanece activo porque representa un evento clínico, no una especialidad.

## Reversión

Ante cualquier fallo, detener backend/frontend, restaurar el respaldo completo y redesplegar las
versiones anteriores coordinadas de distro, content y frontend. No intentar una reversión parcial
de UUID o filas de metadata.
