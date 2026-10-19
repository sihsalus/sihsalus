# Revisión humana de cambios y operaciones

El mantenedor decide sobre un resultado concreto. La IA puede investigar,
preparar cambios y reunir evidencia; debe explicar problema, solución,
alternativas, riesgos y límites antes de solicitar una decisión. Los cambios
deben poder revisarse sin reconstruir una conversación con el agente.

## Qué se aprueba

- **Merge:** PR y SHA exacto, diff completo, pruebas ejecutadas y pendientes,
  revisión clínica/de seguridad cuando corresponda, y efectos automáticos de
  publicación. Un nuevo cambio sustancial requiere nueva revisión.
- **Despliegue o rollback:** versión publicada y entorno/nodo; la herramienta registra SHA/digest,
  versión anterior, respaldo comprobado, interrupción prevista y recuperación.
  Validar un asset o aprobar un merge no aprueba su aplicación.
- **Administración:** instalación, cuenta, permisos actuales y propuestos, y
  efecto sobre credenciales. Confirmar estos datos antes de ejecutarlos.

La aprobación puede incluir el rollback a un manifiesto anterior concreto y la
limpieza acotada de recursos sintéticos propios. Si se cumple la señal acordada,
ejecutar esa recuperación sin pedir otra aprobación; no ampliar su alcance.
Los efectos automáticos de publicación de un merge deben aprobarse junto con
ese SHA y la versión prevista. La aplicación a hosts sigue siendo separada.

El agente deja la decisión pendiente y puede ofrecer una explicación guiada.
“Yolo”, “continúa”, un plan aprobado o CI verde no sustituyen esa revisión.
No debe aprobar mediante API/CLI usando la identidad del mantenedor, marcar su
propio trabajo como revisado por una persona ni habilitar auto-merge.
Los cambios clínicos o de permisos deben contar con el responsable del dominio;
una recomendación del agente no constituye esa aprobación.

## Protección nativa de GitHub

En **Settings → Environments**, configurar `development` y `quality`:

1. Añadir personas o equipos humanos a **Required reviewers**.
2. Desactivar **Allow administrators to bypass configured protection rules**.
3. Activar **Prevent self-review** cuando haya otro mantenedor para autorizar
   la operación. Si un único mantenedor inicia y revisa el run, debe hacerlo
   personalmente en GitHub; el agente no puede aprobar en su nombre.
4. Restringir las ramas de despliegue a las revisiones mantenidas y conservar
   los secretos de SSH dentro de sus environments.

Los workflows de despliegue comprueban revisores y ausencia de bypass antes de
programar los jobs con acceso SSH. Si falta configuración, el API no responde o
el token no permite comprobarla, se detienen. Las aprobaciones y el acceso a
secretos los aplica GitHub; el script no implementa un sistema de aprobación.
Consultar la [configuración oficial de environments](https://docs.github.com/en/actions/how-tos/deploy/configure-and-manage-deployments/manage-environments)
y la [revisión de despliegues](https://docs.github.com/en/actions/how-tos/managing-workflow-runs-and-deployments/managing-deployments/reviewing-deployments).

Un administrador debe configurar estas protecciones en GitHub: editar YAML no
las crea. Sin revisores configurados, los workflows de despliegue se detienen;
mantener la comprobación y no eliminarla para recuperar la automatización.

Para `main`, mantener reglas nativas de PR obligatorio, revisión humana,
desestimación de aprobaciones obsoletas, conversaciones resueltas, CI requerido
y ausencia de bypass. La revisión de un bot no acredita revisión humana.
Estas reglas también se configuran en GitHub, fuera de los archivos del repo.

[`.github/rulesets/main.json`](../../.github/rulesets/main.json) contiene la
propuesta nativa para `main`: una aprobación, revisión del último push,
desestimación de aprobaciones obsoletas, conversaciones resueltas, `PR Gate`
obligatorio de GitHub Actions y ningún bypass. Tras revisar y autorizar ese JSON,
un administrador puede aplicarlo con la [API nativa de rulesets](https://docs.github.com/en/rest/repos/rules)
y comprobar el resultado en **Settings → Rules → Rulesets**. Actualizar la regla
existente correspondiente sin sustituir otras reglas. El archivo por sí solo no
configura GitHub. La aprobación
requiere otra persona con permisos de revisión; identificarla antes de activar
la regla. Si cambian los nombres del CI, revisar también los checks requeridos.

## Aplicación y evidencia

El mantenedor autoriza el cambio y sus ambientes; el flujo de **Deploy Frontend**
está en [scripts/deploy/README.md](../../scripts/deploy/README.md#github-actions-y-conexión-remota).
GitHub aplica la revisión humana de cada environment; el agente no aprueba en
nombre del usuario.

Por SSH, usar `deploy.py`: prepara el candidato, conserva automáticamente la
versión anterior y registra las identidades exactas. No pedir al operador que
redacte, publique o apruebe JSON por nodo. La autorización explícita del usuario
para una actualización concreta se conserva durante su preparación y ejecución;
no solicitarla de nuevo por cada archivo interno generado. Una ampliación de
ambientes, componentes o efectos sí requiere una nueva decisión.

El estado de instalaciones anteriores se adopta sin eliminar sus protecciones.
Conservar los registros y las imágenes de recuperación; no quitar marcadores
para usar un camino que ignore el estado instalado.

Registrar por separado imágenes/identidad, salud, autenticación, aceptación
clínica y recuperación. Un login correcto no demuestra corrección clínica.
