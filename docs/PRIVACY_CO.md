# Privacidad y protección de datos en Colombia

> Resumen técnico para orientar el producto. **No es asesoría legal.** Antes del lanzamiento, un abogado debe revisar la normativa vigente y la Superintendencia de Industria y Comercio (SIC) es la autoridad de referencia.

## Marco aplicable (a verificar antes del lanzamiento)

- **Ley Estatutaria 1581 de 2012** (protección de datos personales / habeas data).
- **Decreto 1377 de 2013**, compilado en el **Decreto Único Reglamentario 1074 de 2015** (autorización, políticas de tratamiento, transferencias).
- **Registro Nacional de Bases de Datos (RNBD)** ante la SIC: verificar si la empresa responsable está obligada a inscribir sus bases según los umbrales vigentes.
- **Ley 1266 de 2008** (habeas data financiero): aplica a información crediticia reportada a centrales; NEXO no reporta ni consulta centrales, pero conviene confirmarlo.
- Si se conecta con entidades financieras: normas de la Superintendencia Financiera sobre finanzas abiertas y el esquema de consentimiento de cada proveedor.

## Cómo lo aborda el producto

| Requisito | Implementación |
|---|---|
| Autorización previa, expresa e informada | Casilla obligatoria en el registro con enlace al resumen de la política (`SignUpScreen`). |
| Finalidad y minimización | Registro solo con nombre, correo y contraseña; el resto es opcional y progresivo. |
| Derecho a conocer y acceder | Exportación completa en JSON (`export_my_data`) y CSV desde Perfil › Datos y privacidad. |
| Actualizar y rectificar | Edición de perfil, preferencias y movimientos (con historial). |
| Supresión y revocatoria | Eliminación de cuenta (`delete-account`): borra datos personales y anonimiza la participación en espacios compartidos para no alterar los saldos de terceros. |
| Seguridad | RLS, cifrado en tránsito, almacenamiento seguro en el dispositivo, bloqueo biométrico, auditoría ([SECURITY.md](SECURITY.md)). |
| Datos de terceros | En espacios compartidos solo se exponen nombre visible y lo registrado en ese espacio. |
| Transferencia/transmisión internacional | Supabase y los proveedores de IA pueden procesar fuera de Colombia: debe declararse en la política y contar con contratos de transmisión adecuados. |

## Pendiente (no técnico)

- Redactar y publicar la **política de tratamiento de datos** completa (responsable, finalidades, derechos, canal de consultas y reclamos, plazos de respuesta de la ley).
- Designar el responsable/encargado y el canal de atención.
- Contratos de transmisión con Supabase, el proveedor de correo y los proveedores de IA.
- Definir la política de retención (por ejemplo, facturas y registros de auditoría) y documentarla.
- Evaluar el registro en el RNBD.
