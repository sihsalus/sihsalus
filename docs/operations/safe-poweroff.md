# Apagado automático seguro y auditable

## Objetivo

El apagado automático solo puede ejecutarse dentro de una ventana local
aprobada y después de comprobar dos veces que no hay uso clínico reciente ni
conexiones activas. Un cron que ejecuta `shutdown` o `poweroff` a una hora fija
sin estas verificaciones no cumple este contrato.

La política es deliberadamente conservadora: si falta una señal, la
configuración es inválida o existe duda, difiere el apagado. No consulta
pacientes, encuentros, usuarios ni otros datos clínicos.

## Señales y garantías

El timer evalúa la política cada cinco minutos, pero solo puede solicitar un
apagado cuando se cumplen todas estas condiciones:

1. `ENABLED=true` y `DRY_RUN=false`;
2. la hora local está dentro de la ventana configurada;
3. terminó la gracia posterior al arranque del host;
4. no existe el inhibidor operativo explícito;
5. no hay conexiones TCP establecidas hacia SSH, HTTP o HTTPS;
6. el gateway puede entregar una señal de actividad válida y su último
   heartbeat es anterior al umbral de inactividad; y
7. las condiciones anteriores siguen siendo ciertas después de una gracia
   final de 60 segundos.

El SPA global envía un `POST` sin cuerpo a
`/_sihsalus/clinical-activity` cada 30 segundos mientras la pestaña está visible
y hubo interacción del operador durante los últimos 30 minutos. El gateway
registra únicamente el timestamp Unix en
`/var/log/nginx/clinical-activity.log`: no registra IP, cookie, usuario,
documento, UUID, URL clínica, cuerpo ni user-agent en ese archivo.

Después de solicitar el apagado, systemd detiene sus unidades normalmente. La
unidad `sihsalus-compose.service`, si está instalada, ejecuta `docker compose
stop` con un timeout de cinco minutos. La política no detiene primero el stack:
si la solicitud de poweroff fuese rechazada, los servicios deben seguir
funcionando.

## Límite importante

Esta protección depende de desplegar de forma coordinada:

- el gateway con el endpoint y log PHI-free;
- el frontend con el heartbeat global; y
- el script y unidades systemd de este repositorio.

No habilites el apagado real con un frontend antiguo: el gateway tendría un log
válido, pero un navegador activo no enviaría el heartbeat. Las conexiones TCP
son una defensa adicional, no reemplazan esa señal porque un navegador puede
cerrar keep-alive mientras el operador sigue leyendo o llenando un formulario.

El heartbeat protege actividad visible reciente; no es persistencia del
formulario. Un dato que aún no fue guardado o puesto en una cola offline puede
perderse si se cierra el navegador o el equipo por cualquier causa.

Una partición entre el navegador y el servidor tampoco puede ser observada por
el servidor: si ya no existe una conexión TCP y no llegan heartbeats, la
política solo puede razonar con esas señales locales. Por eso la cola offline
del formulario y esta política deben desplegarse y probarse juntas; el
heartbeat protege el uso conectado, mientras que la cola protege un registro
que perdió conectividad antes de confirmarse en OpenMRS.

El endpoint no autentica ni identifica al operador porque no recibe datos
clínicos ni credenciales. Cualquier equipo con acceso al gateway podría enviar
heartbeats y diferir el apagado, pero no puede adelantarlo ni autorizarlo. Esta
preferencia por un falso positivo de actividad es intencional: ante duda, el
servidor permanece encendido. El acceso al gateway debe seguir limitado a la
red hospitalaria.

## Instalación inicial

Primero inventaría sin modificar los mecanismos existentes:

```bash
sudo crontab -l
sudo systemctl list-timers --all
sudo grep -RniE 'shutdown|poweroff|halt' /etc/cron.d /etc/crontab /var/spool/cron/crontabs 2>/dev/null
```

Conserva esa salida como evidencia restringida fuera del repositorio. No
publiques crontabs ni logs del servidor en un issue.

Desde el checkout versionado en `/opt/sihsalus`:

```bash
sudo install -d -m 0755 /etc/sihsalus
sudo install -m 0755 scripts/utils/sihsalus-safe-poweroff.sh /usr/local/sbin/sihsalus-safe-poweroff
sudo install -m 0644 scripts/utils/sihsalus-safe-poweroff.service /etc/systemd/system/
sudo install -m 0644 scripts/utils/sihsalus-safe-poweroff.timer /etc/systemd/system/
sudo install -m 0644 scripts/utils/sihsalus-safe-poweroff.tmpfiles /etc/tmpfiles.d/sihsalus-safe-poweroff.conf
sudo install -m 0600 scripts/utils/sihsalus-safe-poweroff.env.example /etc/sihsalus/safe-poweroff.env
sudo systemd-tmpfiles --create /etc/tmpfiles.d/sihsalus-safe-poweroff.conf
sudo systemctl daemon-reload
```

Edita `/etc/sihsalus/safe-poweroff.env` con la ventana aprobada por el
establecimiento. No existe un horario predeterminado en Git. Para comisionar,
usa primero:

```env
SIHSALUS_SAFE_POWEROFF_ENABLED=true
SIHSALUS_SAFE_POWEROFF_DRY_RUN=true
SIHSALUS_SAFE_POWEROFF_NOT_BEFORE=HH:MM
SIHSALUS_SAFE_POWEROFF_NOT_AFTER=HH:MM
SIHSALUS_SAFE_POWEROFF_IDLE_SECONDS=900
SIHSALUS_SAFE_POWEROFF_BOOT_GRACE_SECONDS=1800
SIHSALUS_SAFE_POWEROFF_FINAL_GRACE_SECONDS=60
```

Luego activa el evaluador, todavía en dry-run:

```bash
sudo systemctl enable --now sihsalus-safe-poweroff.timer
sudo systemctl start sihsalus-safe-poweroff.service
sudo systemctl status sihsalus-safe-poweroff.timer
sudo journalctl -u sihsalus-safe-poweroff.service --since today
```

## Aceptación antes de apagar realmente

Usa solo una sesión y un paciente sintéticos durante la prueba funcional.
Registra cada resultado como `PASSED`, `FAILED` o `BLOCKED`:

| Prueba                             | Resultado esperado                                  |
| ---------------------------------- | --------------------------------------------------- |
| Política fuera de la ventana       | `decision=skip reason=outside_window`               |
| Navegador visible con interacción  | `decision=defer reason=recent_clinical_activity`    |
| Sesión SSH o conexión web activa   | `decision=defer reason=active_connection`           |
| Archivo inhibidor presente         | `decision=defer reason=operator_inhibit`            |
| Gateway antiguo, caído o sin log   | `decision=defer reason=activity_signal_unavailable` |
| Host recién iniciado               | `decision=defer reason=boot_grace`                  |
| Inactividad real dentro de ventana | `decision=would_power_off dry_run=true`             |

Verifica el heartbeat sin leer el access log general:

```bash
docker compose exec -T gateway stat -c '%y' /var/log/nginx/clinical-activity.log
```

Abre el SPA, interactúa con una pantalla sintética y repite el comando después
de 30 segundos. El timestamp debe avanzar. Déjalo abierto sin interacción
durante más de 30 minutos para comprobar que el heartbeat termina; ajusta la
duración de la prueba únicamente en un build no productivo, no reduciendo el
umbral del servidor en producción.

Observa al menos tres ventanas reales en dry-run. Solo con evidencia aprobada,
cambia `SIHSALUS_SAFE_POWEROFF_DRY_RUN=false` y reinicia el timer:

```bash
sudo systemctl restart sihsalus-safe-poweroff.timer
```

## Retiro del cron incondicional

Retira el cron viejo únicamente después de instalar y validar el timer nuevo.
Antes de editarlo, guarda una copia con permisos de root y fecha:

```bash
sudo sh -c 'umask 077; crontab -l > /root/sihsalus-root-crontab-before-safe-poweroff.txt'
sudo crontab -e
```

Elimina solo la línea identificada que ejecuta el apagado incondicional. No
uses filtros masivos sobre el crontab y no elimines tareas de backup. Después,
verifica que quede un solo mecanismo de apagado:

```bash
sudo crontab -l
sudo systemctl list-timers --all | grep sihsalus-safe-poweroff
```

## Inhibición operativa

Para una atención extendida, restore, backup físico, migración o despliegue:

```bash
sudo touch /run/sihsalus/poweroff.inhibit
sudo journalctl -u sihsalus-safe-poweroff.service --since -30min
```

Al terminar y comprobar que no queda una operación crítica:

```bash
sudo rm -f /run/sihsalus/poweroff.inhibit
```

También se puede envolver una tarea con el inhibidor nativo de systemd:

```bash
sudo systemd-inhibit --what=shutdown --mode=block --why='mantenimiento SIH Salus' comando-aprobado
```

No dejes el archivo inhibidor como sustituto permanente de una ventana mal
configurada. La razón de cada inhibición prolongada debe quedar en la bitácora
operativa.

## Auditoría, rollback e incidente

Las decisiones se registran en journald con el prefijo
`SIHSALUS_SAFE_POWEROFF`; no contienen datos clínicos. Para exportar evidencia:

```bash
sudo journalctl -u sihsalus-safe-poweroff.service --since 'YYYY-MM-DD HH:MM' --until 'YYYY-MM-DD HH:MM'
```

Si la política se comporta de forma inesperada:

```bash
sudo systemctl disable --now sihsalus-safe-poweroff.timer
```

No restaures automáticamente el cron incondicional. Usa apagado manual aprobado
hasta corregir y volver a ejecutar la aceptación. Ante un apagado durante uso
clínico, conserva journal, inventario de timers y versión desplegada; no copies
logs de acceso generales ni datos del paciente al reporte.
