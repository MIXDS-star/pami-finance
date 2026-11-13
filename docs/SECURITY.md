# Seguridad

## Modelo de acceso

- **RLS activado en todas las tablas de `public`** (comprobado por las pruebas). `anon` no tiene acceso a ninguna tabla ni RPC.
- **Tablas del libro de solo lectura para la API** (`transactions`, pagos, asignaciones, facturas, líneas, liquidaciones, miembros, invitaciones, espacios). Toda escritura pasa por RPC `SECURITY DEFINER` con comprobaciones explícitas de pertenencia y rol, y deja rastro en `audit_events`.
- **Tablas de configuración propia** (preferencias, cuentas, categorías, presupuestos, metas, notificaciones) aceptan escrituras directas limitadas por RLS y por privilegios de columna (`grant update (col, …)`), de modo que no se pueden tocar columnas como `owner_id` o `created_by`.
- **Agregados `SECURITY INVOKER`**: saldos, resúmenes, presupuestos, metas y exportación respetan RLS; adivinar un identificador devuelve vacío.
- **Funciones auxiliares** (`private.is_member`, `can_write`, `can_admin`, `shares_workspace`…) viven en el esquema `private`, que PostgREST no expone.

### Matriz de permisos por rol (espacio compartido)

| Acción | Propietario | Administrador | Miembro | Lector |
|---|:-:|:-:|:-:|:-:|
| Ver gastos, saldos, miembros | ✓ | ✓ | ✓ | ✓ |
| Registrar/editar gastos, reembolsos | ✓ | ✓ | ✓ | — |
| Eliminar gasto ajeno | ✓ | ✓ | — | — |
| Invitar miembro/lector | ✓ | ✓ | — | — |
| Invitar administrador | ✓ | — | — | — |
| Cambiar rol / retirar miembro o lector | ✓ | ✓ | — | — |
| Cambiar rol de administrador | ✓ | — | — | — |
| Transferir propiedad, archivar | ✓ | — | — | — |
| Ver invitaciones pendientes | ✓ | ✓ | — | — |

Nadie puede cambiar su propio rol; el propietario no puede ser retirado; un miembro retirado o que abandona pierde el acceso inmediato pero su historial se conserva.

### Privacidad entre miembros

Compartir un espacio no da acceso a ingresos, cuentas, preferencias, gastos personales ni documentos de otros espacios. Los demás ven el nombre visible y, en los gastos del espacio, quién pagó (no con qué cuenta: solo el pagador puede asociar o ver su cuenta).

## Invitaciones

Token aleatorio de 256 bits mostrado una sola vez; en la base solo se guarda su SHA-256. Un solo uso, caducidad de 7 días, revocable, opcionalmente ligado a un correo (se compara con el del JWT), máximo 20 pendientes por espacio.

## Archivos (Storage)

Bucket `receipts` privado, 10 MB, tipos JPEG/PNG/WEBP/HEIC/PDF. Ruta `<espacio>/<uuid>/<archivo>`; las políticas de `storage.objects` exigen pertenencia activa para leer y rol de escritura para subir o borrar. Las descargas usan la sesión del usuario o URLs firmadas de 120 s. `extract-receipt` verifica el tipo real por los bytes antes de enviar nada al proveedor. Ver la limitación sobre la verificación de bytes en la subida en [LIMITATIONS.md](LIMITATIONS.md).

## Secretos

- La app solo contiene la URL y la clave pública (anon/publishable) del proyecto, que no concede nada sin RLS.
- Claves de IA y `service_role` existen solo como secretos de Edge Functions. La `service_role` se usa únicamente en `delete-account`, después de verificar la identidad del solicitante.
- Los tokens de futuros proveedores bancarios irían cifrados en `private.integration_secrets`, sin privilegios para la API.
- Los registros de las funciones nunca incluyen documentos, importes ni tokens (`errorResponse` solo registra el tipo de error).

## Cliente

Sesión en almacenamiento seguro del sistema; borradores sin conexión cifrados (Keychain/Keystore); bloqueo biométrico opcional tras 60 s en segundo plano; `FLAG_SECURE` en Android (sin capturas ni vista previa en recientes); sin respaldo en la nube de datos de la app (`data_extraction_rules`); tráfico en claro prohibido salvo hacia el stack local en compilaciones de depuración.

## IA y prompt injection

Las funciones reciben contexto pseudonimizado (alias `w1`, `m1`, nombres de pila), validan la salida con esquemas JSON estrictos y la sanean de nuevo en código (personas o espacios desconocidos se descartan y se avisa). Las instrucciones del sistema tratan el contenido de facturas, notas y textos como datos. El copiloto solo tiene herramientas de lectura que ejecutan RPC con el JWT del usuario; no puede escribir ni mover dinero. Límite de frecuencia por usuario y capacidad (`consume_rate_limit`).

## Pruebas de seguridad (automáticas)

`supabase/tests/02_security.sql` (50 aserciones) y `supabase/functions/tests/*`: un usuario no ve datos personales de otro; un extraño no lee gastos, asignaciones, facturas ni saldos aunque conozca los identificadores; inserciones y actualizaciones directas del libro denegadas; escalada de rol denegada (tabla y RPC); auditoría no falsificable; RPC solo de servidor inaccesible; lector sin escritura; reglas de administrador; miembro retirado sin acceso y sin poder ser asignado a gastos nuevos; Storage por ruta para miembros, extraños y retirados; `anon` sin acceso; funciones sin sesión → 401; alias inventados por la IA descartados.

## Pendiente antes de producción

Revisión externa (pentest), política de retención y copias de seguridad del proyecto Supabase, alertas de abuso, rotación de claves, CAPTCHA en registro y verificación real de correo. Ver [PENDING.md](PENDING.md).
