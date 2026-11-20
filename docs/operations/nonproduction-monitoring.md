# Logs y alertas de DEV y QLTY

Los Compose de servicios limitan stdout/stderr de Docker a tres archivos de
50 MB por contenedor. El límite se aplica al recrear cada servicio; un reinicio
no actualiza su configuración de logging. No limita archivos escritos por la
aplicación dentro de volúmenes, y no se deben truncar archivos JSON de Docker
con herramientas externas. Conservar los logs que deban retenerse antes de
recrear servicios o cambiar la retención.

## Configuración de monitoreo

El override de no producción reutiliza Prometheus, Node Exporter, cAdvisor,
Blackbox y Alertmanager. No exige arrancar Grafana, Loki, Alloy ni la UPS.
Prometheus conserva hasta siete días o 512 MB de métricas. Comprueba recursos
cada minuto y alerta tras cinco minutos de disco al 80%/90%, falta de readiness,
identidad inesperada, exporter caído o reinicios repetidos. Alertmanager agrupa
avisos, repite cada cuatro horas y comunica recuperaciones. Su alerta de fallo
SMTP no puede garantizar entrega por el mismo canal averiado.

Generar la configuración en un directorio nuevo fuera del checkout:

```sh
python3 scripts/monitoring/render-nonproduction.py \
  --environment qlty --output-dir /ruta/privada/monitoring-qlty
```

El generador admite `dev`, `qlty` y `observer`, y no sobrescribe archivos.
Los JSON son YAML válido y no contienen contraseñas. El remitente predeterminado
es `sihsalus@gmail.com` y el destinatario `sih.salus.ia-grupo@pucp.edu.pe`.

Configurar `SIHSALUS_MONITORING_CONFIG_DIR` con ese directorio absoluto y
`SIHSALUS_ALERT_SMTP_PASSWORD_FILE` con una **copia privada** de la contraseña
SMTP de aplicación autorizada. El archivo se monta solo en Alertmanager, como
`/run/secrets/smtp-password`, en modo de solo lectura; no usar la contraseña
habitual ni un token OAuth personal. Verificar el UID del artefacto elegido
(nobody/65534 en la imagen revisada) y preparar la copia con propietario y
permisos que permitan leerla únicamente a ese proceso. No volver mundialmente
legible la credencial utilizada por los cron del host.

El despliegue conserva los Compose/perfiles reales, agrega
`compose/nonproduction-monitoring.yml` al final y elige explícitamente
`prometheus alertmanager node-exporter cadvisor blackbox`. cAdvisor conserva
sus permisos de observación de host; revisar ese acceso antes de habilitarlo en
un entorno que todavía no lo tiene. No ejecutar un `up` de todos los perfiles
para aplicar solamente monitoreo.

Las reglas de identidad conservan DEV
`700e430a-1c32-5241-b7cf-78ccea17f8c1` y QLTY
`0cefb0c8-c860-48c5-856f-408594775cbb`. No sustituir el primero por el UUID de la
VM antigua para silenciar #243. Mientras continúe ese incidente, es esperable
una alerta de identidad de DEV y no se debe desplegar en el destino incorrecto.

## Observador independiente

Generar configuración con `--environment observer` en un tercer servidor Linux
con disponibilidad independiente de DEV y QLTY. La propuesta es usar el servidor
de Terminología, sujeto a comprobar capacidad y aprobar la instalación concreta.
El proyecto separado comprueba `/ready`, certificado e identidad de ambos
entornos por HTTPS; no consulta pacientes ni necesita credenciales de OpenMRS.

El modelo se resuelve sin arrancar servicios:

```sh
docker compose --project-directory . -f compose/nonproduction-observer.yml config --quiet
```

Publica sus interfaces solo en loopback, puertos 9094 y 9095. El observador no
puede avisar de su propia caída; deben supervisarlo otra instancia o un servicio
independiente si se requiere cubrir esa situación. La limpieza semanal y su
correo continúan ejecutándose directamente en cada VM.

## Verificación y aplicación

1. Revisar PR/SHA y preparar el cambio coordinado con las herramientas de
   despliegue; no modificar el historial para eludir discrepancias del runtime.
2. Confirmar respaldo, identidades y recursos disponibles. Los límites de logs
   necesitan recreación por servicio, incluyendo una interrupción si se cambia
   un contenedor de aplicación o base de datos.
3. Validar Compose, reglas con `promtool`, receptor con `amtool` y sondas Blackbox.
   Probar lectura de la copia SMTP desde el UID real sin imprimir su contenido.
4. Tras aprobación del despliegue, comprobar targets, disco y `/ready`, enviar un
   aviso sintético a la lista acordada y verificar recuperación/deduplicación.
5. Para recuperar la configuración, volver a los archivos y selección anteriores
   mediante el procedimiento coordinado; conservar métricas, volúmenes y
   credenciales. No usar `down -v` ni borrar historiales o respaldos.

Los chequeos de sintaxis y pruebas sintéticas no acreditan que el monitoreo esté
activo. Registrar por separado la aplicación real y la entrega de correo.
