# Monitoring - Observabilidad (Grafana, Prometheus, Loki, Alloy)

Stack completo de observabilidad: métricas, logs, alertas y dashboards.

## Stack

- **Grafana** - Dashboards y alertas (v12.3)
- **Prometheus** - Series de tiempo (métricas) - v3.2.1
- **Loki** - Agregador de logs (búsqueda rápida)
- **Alloy** - Colector de métricas y logs (distribuido)
- **Blackbox Exporter** - Probes de disponibilidad (health checks)

---

## Activación

```bash
docker compose --profile monitoring up -d
```

---

## Acceso

| Herramienta | URL | Usuario | Contraseña |
|-------------|-----|---------|-----------|
| Grafana | `http://localhost:3001` | `admin` | `$GRAFANA_ADMIN_PASSWORD` |
| Prometheus | `http://localhost:9090` (localhost only) | - | - |
| Loki | `http://localhost:3100` (localhost only) | - | - |

> Prometheus y Loki están limitados a localhost por seguridad. Accede a través de Grafana.

---

## Servicios

### Grafana

**Imagen**: `grafana/grafana:12.3`

**Rol**: Visualización, dashboards, alertas.

**Puertos**: 
- `3001` - Web UI (http://localhost:3001)

**Características**:
- Dashboards pre-configurados
- Datasources Prometheus y Loki
- Alertas via webhooks, email, etc.
- Usuarios y permisos

**Plugins instalados**:
```
grafana-clock-panel
grafana-simple-json-datasource
grafana-piechart-panel
```

**Variables de entorno**:
```env
GRAFANA_ADMIN_PASSWORD=<password>        # Contraseña admin
GRAFANA_ADMIN_USER=admin                 # Usuario (default)
GRAFANA_ROOT_URL=http://localhost:3001   # URL base (para links)
```

**Dashboards preconfigurados**:
- Docker Overview
- OpenMRS Overview
- Logs aggregation

**Volumen persistente**: `grafana-data` (configuración, usuarios, dashboards)

---

### Prometheus

**Imagen**: `prom/prometheus:v3.2.1`

**Rol**: Base de datos de series de tiempo. Recolecta métricas cada 15 segundos.

**Puertos**: 
- `9090` - Web UI (http://localhost:9090, solo localhost)

**Configuración**: [prometheus.yml](prometheus/prometheus.yml)

**Targets monitoreados**:
- Prometheus itself
- Grafana
- Loki
- Blackbox HTTP probes (Gateway, OpenMRS endpoints)

**Retención**: 30 días (configurable)

**Volumen persistente**: `prometheus-data` (base de datos TSDB)

**Health checks**:
```bash
# Verificar que Prometheus funciona
curl http://localhost:9090/-/healthy

# Ver targets
curl http://localhost:9090/api/v1/targets
```

---

### Loki

**Rol**: Indexador y almacén de logs. Optimizado para búsquedas.

**Puertos**: 
- `3100` - API (http://localhost:3100, solo localhost)

**Configuración**: [loki-config.yaml](loki/loki-config.yml)

**Retención**: Configurable (default: 168 horas / 7 días)

**Fuentes de logs**:
- Docker daemon (via Alloy)
- OpenMRS backend
- Nginx gateway
- Demás servicios

**Query examples**:
```logql
# Todos los logs de la última hora
{job="docker"}

# Logs ERROR en OpenMRS
{job="docker"} |= "ERROR" | json | service="backend"

# Tasa de errores (logs)
rate({job="docker"} |= "ERROR" [5m])
```

---

### Alloy (antes Grafana Agent)

**Rol**: Recolector de métricas y logs distribuido (corre en cada nodo/contenedor).

**Imagen**: Integrada en compose

**Configuración**: [config.alloy](alloy/config.alloy)

**Funciones**:
1. Scrape de métricas Prometheus
2. Recolección de logs de Docker
3. Transformación de datos
4. Envío a Prometheus y Loki

---

### Blackbox Exporter

**Rol**: Probes de disponibilidad HTTP/HTTPS, DNS, TCP.

**Imagen**: Incluido en configuración

**Targets monitoreados**:
- `http://gateway:80/` - Gateway disponible
- `http://gateway:80/openmrs` - OpenMRS accesible
- `http://gateway:80/openmrs/ws/rest/v1/session` - API OpenMRS

---

## Dashboards

### Docker Overview

Métricas de:
- CPU y memoria por contenedor
- Tráfico de red
- I/O de disco
- Uptime/restarts

### OpenMRS Overview

Métricas de:
- Respuesta de API
- Errores HTTP
- Disponibilidad de endpoints
- Latencia

### Logs Dashboard

Agregación y búsqueda de:
- Logs de todos los servicios
- Filtros por servicio/nivel
- Estadísticas de errores

---

## Alertas

### Reglas de alerta

Ubicación: [monitoring/prometheus/alerts/](prometheus/alerts/)

**Ejemplo**: Contenedor en estado crítico
```yaml
alert: ContainerDown
expr: up{job="docker"} == 0
for: 5m
annotations:
  summary: "Contenedor {{ $labels.name }} no está disponible"
```

### Configurar notificaciones

En Grafana:
1. Alerting → Notification channels
2. Agregar: Slack, Discord, Email, PagerDuty, Webhook, etc.
3. Enlazar a alertas

---

## Queries útiles

### PromQL (Prometheus)

```promql
# Tasa de requests exitosos en gateway
rate(http_requests_total{job="gateway", status="200"}[5m])

# CPU por contenedor
container_cpu_usage_seconds_total

# Memoria disponible
container_memory_limit_bytes - container_memory_usage_bytes

# Uptime de servicios
up{job="docker"}
```

### LogQL (Loki)

```logql
# Logs ERROR en el backend
{job="docker", service="backend"} |= "ERROR"

# Tasa de logs por segundo
sum(rate({job="docker"}[5m]))

# Logs de OpenMRS últimas 2 horas
{job="docker", service="backend"} | since(2h)
```

---

## Almacenamiento

### Volúmenes persistentes

| Servicio | Volumen | Uso | Tamaño típico |
|----------|---------|-----|---|
| Prometheus | `prometheus-data` | TSDB (30 días) | 1-5 GB |
| Loki | `loki-data` | Índices y logs (7 días) | 2-10 GB |
| Grafana | `grafana-data` | Config, dashboards, usuarios | 100-500 MB |

### Limpieza de datos antiguos

```bash
# Prometheus: configurado via retention
# storage.tsdb.retention.time=30d

# Loki: configurado en loki-config.yaml
# retention_enabled: true
# retention_days: 7

# Manual: eliminar volumen
docker volume rm sihsalus_prometheus-data
```

---

## Troubleshooting

### "No data in Prometheus"

1. Verifica que Prometheus está scrapeando:
   ```bash
   curl http://localhost:9090/api/v1/targets
   ```

2. Revisa logs:
   ```bash
   docker compose --profile monitoring logs prometheus | grep -i error
   ```

3. Verifica conectividad:
   ```bash
   docker compose --profile monitoring exec prometheus curl http://grafana:3000/metrics
   ```

### "No logs in Loki"

1. Revisa que Alloy esté recolectando:
   ```bash
   docker compose --profile monitoring logs alloy | grep -i loki
   ```

2. Verifica configuración Alloy: [config.alloy](alloy/config.alloy)

3. Manual: enviar logs de prueba
   ```bash
   curl -X POST http://localhost:3100/loki/api/v1/push \
     -H "Content-Type: application/json" \
     -d '{"streams":[{"stream":{"job":"test"},"values":[["'$(date +%s%N)'","test"]]}]}'
   ```

### Alertas no se disparan

1. Verifica reglas:
   ```bash
   curl http://localhost:9090/api/v1/rules
   ```

2. Revisa configuración de notificación en Grafana

3. Test manual:
   ```
   Grafana → Alerting → Alert rules → Test rule
   ```

### Bajo rendimiento / memoria alta

1. Reduce retención Prometheus:
   ```yaml
   prometheus:
     command:
       - '--storage.tsdb.retention.time=7d'  # En lugar de 30d
   ```

2. Reduce verbosidad de logs en Alloy

3. Optimiza queries (evitar demasiadas métricas)

---

## Configuración Avanzada

### Agregar métricas personalizadas

1. **OpenMRS JMX**: Descomentar en [prometheus.yml](prometheus/prometheus.yml)
   ```yaml
   - job_name: 'openmrs-backend'
     metrics_path: '/openmrs/metrics'
     static_configs:
       - targets: ['backend:8080']
   ```

2. **MariaDB**: Agregar exporter
   ```bash
   docker run -d \
     --network sihsalus_default \
     --name mariadb-exporter \
     -e DATA_SOURCE_NAME="openmrs:password@(db:3306)/" \
     prom/mysqld-exporter
   ```

3. **Keycloak**: Descomentar en [prometheus.yml](prometheus/prometheus.yml)

### SSL/HTTPS para Grafana

Ver [compose/ssl.yml](../compose/ssl.yml)

### Backup de dashboards

```bash
# Exportar dashboards como JSON
docker compose --profile monitoring exec grafana grafana-cli admin export-dashboard 1 > dashboard1.json

# Importar
curl -X POST http://localhost:3001/api/dashboards/db \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer TOKEN" \
  -d @dashboard1.json
```

---

## Integración con OpenMRS

### Logs en OpenMRS

Los logs del backend se recolectan automáticamente via Alloy y están disponibles en Loki.

Búsqueda en Grafana:
```
Explore → Loki → {job="docker", service="backend"}
```

### Métricas personalizadas

OpenMRS 3.x expone métricas en `/openmrs/metrics` (vía Micrometer).

Para activar:
1. Descomentar `openmrs-backend` job en prometheus.yml
2. Reiniciar Prometheus
3. Buscar en Grafana: `openmrs_*`

---

## Links y recursos

- [Grafana Documentation](https://grafana.com/docs/grafana/latest/)
- [Prometheus Documentation](https://prometheus.io/docs/)
- [Loki Documentation](https://grafana.com/docs/loki/latest/)
- [Alloy Documentation](https://grafana.com/docs/alloy/latest/)
- [PromQL Cheat Sheet](https://prometheus.io/docs/prometheus/latest/querying/examples/)
- [LogQL Documentation](https://grafana.com/docs/loki/latest/logql/)

---

## SLA/Health checks

### Verificar stack operacional

```bash
# Health check de todos los servicios
docker compose --profile monitoring exec grafana curl -f http://grafana:3000/api/health
docker compose --profile monitoring exec prometheus curl -f http://localhost:9090/-/healthy
docker compose --profile monitoring exec loki curl -f http://localhost:3100/ready
```

### Dashboard de salud

Crear dashboard personalizado con:
- `up{job="..."}` - Disponibilidad de servicios
- `rate(http_requests_total{status=~"5.."}[5m])` - Tasa de errores
- Count de eventos de alertas últimas 24h
