# Imaging - Stack DICOM (Radiografías y Tomografías)

Stack completo para almacenamiento y visualización de imágenes médicas DICOM (rayos X, tomografías, resonancias, ecografías, etc.).

## Stack

- **Orthanc** - Servidor DICOM + REST API (almacenamiento)
- **OHIF Viewer** - Visualizador web moderno para DICOM
- **Protocolo**: DICOM (C-MOVE, C-FIND, C-STORE)

---

## Activación

```bash
docker compose --profile imaging up -d
```

---

## Servicios

### Orthanc (Servidor DICOM)

**Imagen**: `orthancteam/orthanc:25.8.2`

**Rol**: Servidor DICOM + almacenamiento. Recibe estudios desde modalidades (escáneres) y actúa como repositorio.

**Puertos**:
- `8042` - REST API (HTTP)
- `4242` - Servidor DICOM (TCP, protocolo DICOM/DIMSE)

**Almacenamiento**:
- Volumen: `orthanc-data` (persistente)
- Archivos: Estructura DICOM comprimada

**API REST Examples**:
```bash
# Listar pacientes
curl http://localhost:8042/patients

# Listar estudios de un paciente
curl http://localhost:8042/patients/{patientId}/studies

# Obtener info de un estudio
curl http://localhost:8042/studies/{studyId}

# Descargar archivo DICOM
curl http://localhost:8042/instances/{instanceId}/file > image.dcm
```

**Autenticación**: Deshabilitada en desarrollo (**HABILITAR EN PRODUCCIÓN**)

**Configuración**: Inline JSON en docker-compose

---

### OHIF Viewer (Visualizador web)

**Imagen**: `ohif/app:v3.9.3`

**Rol**: Interfaz web para visualizar y manipular imágenes DICOM.

**Puertos**:
- `3000` - Web UI (HTTP)

**Acceso**: `http://localhost:3000`

**URL de acceso**:
```
http://localhost:3000/?url=dicomweb:http://localhost:8042/dicom-web
```

**Funcionalidades**:
- Ver estudios (listado de pacientes)
- Manipulación de imágenes (zoom, pan, medidas)
- Herramientas: Distancia, ángulos, densidad ósea
- Soporte para 2D y 3D
- Multi-estudio, multi-serie

**Configuración**: [app-config.js](app-config.js)

---

## Configuración

### OHIF (`app-config.js`)

```javascript
window.config = {
  routerBasename: "/",                 // Path base de la aplicación
  i18n: {
    defaultLocale: "es",               // Español por defecto
    supportedLocales: ["es", "en"]
  },
  showStudyList: true,                 // Mostrar listado de estudios
  dataSources: [
    {
      namespace: "@ohif/extension-default.dataSourcesModule.dicomweb",
      sourceName: "dicomweb",
      configuration: {
        friendlyName: "SIHSALUS Orthanc",
        qidoRoot: "/dicom-web",         // Query URL (estudio/series/instancias)
        wadoRoot: "/dicom-web",         // Web Access to DICOM Objects
        wadoUriRoot: "/wado"            // Legacy WADO URI
      }
    }
  ]
};
```

### Orthanc (docker-compose)

```yaml
orthanc:
  environment:
    ORTHANC_JSON: |
      {
        "Name": "SIHSALUS Orthanc",
        "RemoteAccessAllowed": true,
        "AuthenticationEnabled": false,    # ⚠️ Cambiar a true en prod
        "DicomAet": "ORTHANC",             # Application Entity Title
        "DicomPort": 4242                  # Puerto DICOM
      }
```

---

## Casos de Uso

### 1. Recibir imágenes de un escáner (modalidad)

**Del lado del escáner (configurar)**:
- Host: IP del servidor (ej: 192.168.1.100)
- Puerto: 4242
- AET (Application Entity Title): ORTHANC

**Comando DICOM** (ej: desde otro servidor):
```bash
dcmsend -aec ORTHANC 192.168.1.100 4242 images/*.dcm
```

### 2. Ver imágenes en OHIF

1. Ir a `http://localhost:3000`
2. Click en "Study List"
3. Buscar por paciente
4. Click en estudio → Click en serie
5. Visualizar/manipular imágenes

### 3. Exportar estudio

```bash
# Exportar estudio como ZIP
curl http://localhost:8042/studies/{studyId}/archive -o estudio.zip

# Exportar serie
curl http://localhost:8042/series/{seriesId}/archive -o serie.zip
```

### 4. Integración con OpenMRS

El módulo `radiology` de OpenMRS puede:
1. Crear órdenes de radiología
2. Enviar órdenes a Orthanc
3. Mostrar estudios en la historia del paciente (si está integrado)

---

## Solución de Problemas

### "No images found in OHIF"

1. Verifica que Orthanc esté saludable:
   ```bash
   docker compose --profile imaging logs orthanc | grep -i error
   ```

2. Verifica que haya estudios en Orthanc:
   ```bash
   curl http://localhost:8042/patients
   ```

3. Revisa la consola del navegador (F12 → Console)

### "Connection refused" desde escáner

1. Verifica que el puerto 4242 esté abierto:
   ```bash
   docker compose --profile imaging port orthanc
   ```

2. Verifica firewall:
   ```bash
   sudo netstat -tulpn | grep 4242
   ```

3. Usa IP real del servidor (no localhost):
   ```bash
   # Obtener IP
   docker inspect sihsalus-orthanc | grep IPAddress
   ```

### OHIF no carga estudios

1. Verifica que Orthanc REST API responde:
   ```bash
   curl http://localhost:8042/instances
   ```

2. Revisa logs de OHIF:
   ```bash
   docker compose --profile imaging logs ohif
   ```

3. Revisa tab Network en DevTools (F12) para ver requests

### Estudios desaparecen después de reinicio

- Verifica que el volumen `orthanc-data` es persistente:
  ```bash
  docker volume ls | grep orthanc
  docker volume inspect sihsalus_orthanc-data
  ```

---

## Seguridad en Producción

⚠️ **CRÍTICO**: El actual setup deshabilita autenticación. Para producción:

### 1. Habilitar autenticación Orthanc

```yaml
ORTHANC_JSON: |
  {
    "AuthenticationEnabled": true,
    "RegisteredUsers": {
      "radiologist": "hashed_password_here"
    }
  }
```

### 2. Agregar HTTPS

Ver [compose/ssl.yml](../compose/ssl.yml)

### 3. Restringir acceso DICOM

```yaml
ORTHANC_JSON: |
  {
    "RemoteAccessAllowed": false,  # Solo localhost puede enviar
    "DicomModalities": [
      {
        "AET": "MODALIDAD1",
        "Host": "192.168.1.50",
        "Port": 104
      }
    ]
  }
```

### 4. Cifrar datos en reposo

Orthanc soporta plugins de encriptación (requiere compilación custom).

---

## Backup de imágenes DICOM

```bash
# Backup completo del volumen
docker run --rm -v sihsalus_orthanc-data:/data \
  -v $(pwd):/backup busybox tar czf /backup/orthanc-backup.tar.gz /data

# Exportar todos los estudios como ZIP
for study in $(curl -s http://localhost:8042/studies | jq -r '.[] | .ID'); do
  curl -s "http://localhost:8042/studies/$study/archive" -o "study_$study.zip"
done
```

---

## Compatibilidad DICOM

### Modalidades soportadas

- Radiografía (CR, DR, RG)
- Tomografía Computarizada (CT)
- Resonancia Magnética (MR)
- Ecografía (US)
- Mamografía (MG)
- Positron Emission Tomography (PT)
- Angiografía (XA)
- Fluoroscopia (RF)
- Y muchas más (DICOM 3.0 completo)

### Compresión soportada

- JPEG baseline
- JPEG lossless
- JPEG 2000 lossless
- Run-length encoding
- Implícito/Explícito VR

---

## Límites y Consideraciones

| Aspecto | Límite | Notas |
|---------|--------|-------|
| Tamaño de estudio | 2+ GB | Requiere almacenamiento suficiente |
| Instancias por serie | 10,000+ | Típicamente <500 por serie |
| Número de series | Ilimitado | Depende de disco |
| Concurrencia DICOM | 10+ | Orthanc es single-threaded |
| Memoria OHIF | 500 MB | Para imágenes 2D, más para 3D |

---

## Links y recursos

- [Orthanc Documentation](https://orthanc.uclouvain.be/)
- [OHIF Viewer Documentation](https://v3-docs.ohif.org/)
- [DICOM Standard Overview](https://www.dicomstandard.org/)
- [HL7 DICOM Web (DICOMweb) Standard](https://www.dicomstandard.org/using/dicomweb)
- [Orthanc REST API Reference](https://orthanc.uclouvain.be/static/apidoc/)

---

## Ejemplo: Setup completo para radiología

```bash
# 1. Iniciar stack
docker compose --profile imaging up -d

# 2. Esperar a que Orthanc esté listo
docker compose --profile imaging logs orthanc | grep "Startup"

# 3. Acceder a OHIF
open http://localhost:3000

# 4. Enviar imágenes de prueba (si tienes DICOM files)
dcmsend -aec ORTHANC localhost 4242 samples/*.dcm

# 5. Ver en OHIF
# → Study List → Buscar paciente → Click → Ver imágenes
```
