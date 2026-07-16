# Seed cifrado de staging

El seed transporta los volúmenes de MariaDB, OpenMRS y, si existe, PostgreSQL
del generador FUA. Está pensado únicamente para contenido base sin registros
clínicos.

## Crear

Requisitos previos:

- backend saludable;
- `patient`, `obs`, `encounter` y errores OCL en cero;
- árbol Git limpio;
- `gh auth` configurado;
- `SIHSALUS_SEED_PASSPHRASE_FILE` apuntando a un archivo mode `600`, de una sola línea y fuera del repositorio.

```bash
export SIHSALUS_SEED_PASSPHRASE_FILE="$HOME/.config/sihsalus/seed-passphrase"
./scripts/seed/create-seed-release.sh
```

El script detiene solo los cuatro contenedores de aplicación/base involucrados,
captura los volúmenes en reposo y restablece exactamente los que estaban
ejecutándose. Publica únicamente el artifact cifrado, su SHA-256 y un manifiesto
sin secretos. Por defecto crea un draft; publícalo después de validar el asset.

## Restaurar en una máquina limpia

Mantén el stack abajo y no guardes el profile `seed` en `COMPOSE_PROFILES`.

```bash
export SIHSALUS_SEED_URL='https://github.com/sihsalus/sihsalus/releases/download/<tag>/sihsalus-seed.tar.gz.enc'
export SIHSALUS_SEED_SHA256='<sha256-del-asset-cifrado>'
export SIHSALUS_SEED_PASSPHRASE_FILE="$HOME/.config/sihsalus/seed-passphrase"

# Usa aquí el mismo COMPOSE_FILE/perfiles del despliegue normal. No agregues -v.
docker compose down

docker compose \
  -f docker-compose.yml \
  -f compose/seed.yml \
  --profile seed \
  run --build --rm --no-deps seed

docker compose up -d
```

El checksum y el archivo de contraseña son obligatorios. Si algún volumen ya contiene
datos, el restore falla antes de modificar ninguno. `SIHSALUS_SEED_FORCE=true`
permite reemplazarlos deliberadamente.

## Seguridad

El artifact incluye credenciales, llaves de OpenMRS y cuentas de la base. No
publiques la contraseña, no la reutilices como contraseña SSH y no generes un
seed si el guard SQL detecta datos clínicos o errores OCL.
