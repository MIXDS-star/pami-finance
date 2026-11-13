# Modelo de datos

Migraciones versionadas en `supabase/migrations` (orden por prefijo):

| Migración | Contenido |
|---|---|
| `0100_core` | monedas, perfiles, preferencias, espacios, miembros, invitaciones, categorías, cuentas, alta de usuario |
| `0200_ledger` | movimientos, pagos, asignaciones, facturas, líneas, asignaciones por línea, liquidaciones, invariantes |
| `0300_planning` | presupuestos, metas, aportes, recurrentes, ocurrencias, informes mensuales, IA, notificaciones, importaciones, integraciones, auditoría |
| `0400_security` | funciones de pertenencia, RLS, privilegios mínimos, Storage, Realtime |
| `0500_workspace_rpc` | espacios, invitaciones, roles, salida/expulsión, límite de frecuencia |
| `0600_ledger_rpc` | `save_transaction`, borrar/restaurar, liquidaciones, saldos, duplicados |
| `0700_analytics_rpc` | resúmenes, categorías, tendencia, comercios, presupuestos, metas, calendario, cierre mensual, exportación, eliminación |
| `0800_account_balances` | saldos de cuentas manuales |

## Entidades

| Entidad (tabla) | Rol |
|---|---|
| `profiles` | Nombre visible (lo único que ven otros miembros). Sobrevive anonimizado a la eliminación de cuenta. |
| `user_preferences` | País, moneda, zona horaria, tema, ingresos, notificaciones, onboarding. Solo el titular. |
| `currencies` | Código ISO y decimales usados por NEXO (COP = 0). |
| `workspaces` | Espacio personal o compartido: tipo, moneda base, regla de reparto por defecto, archivo, versión. |
| `workspace_members` | Pertenencia con rol y estado (`active`, `left`, `removed`). Nunca se borra: conserva el historial. |
| `workspace_invitations` | Invitación con hash SHA-256 del token, rol, correo opcional, vencimiento y estado. |
| `categories` | Taxonomía del sistema (común) + categorías propias de cada espacio; cubo 50/30/20 opcional. |
| `accounts` | Efectivo, banco, tarjeta, billetera… Privadas del titular. |
| `transactions` | Gasto, ingreso o transferencia: total, fecha, categoría, método de reparto y su especificación, origen, versión. |
| `transaction_payments` | Quién pagó y cuánto (y, solo para el pagador, con qué cuenta). |
| `transaction_splits` | A quién corresponde y cuánto. |
| `receipts` | La factura original (una por movimiento): comercio, NIT, número, fecha, cifras impresas, impuestos, propina, descuentos, archivo, estado de extracción. |
| `receipt_items` | Líneas: texto original detectado, descripción, cantidad (milésimas), precio, descuento, total de la línea, confianza, regla. |
| `receipt_item_allocations` | Asignación de cada línea por persona. |
| `settlements` / `settlement_allocations` | Reembolsos entre miembros y, opcionalmente, a qué gastos se aplican. |
| `budgets` / `budget_categories` | Límite mensual fijo o % de ingresos, umbral de alerta, categorías. |
| `savings_goals` / `savings_contributions` | Metas y aportes (el acumulado es la suma de aportes). |
| `recurring_rules` / `scheduled_occurrences` | Pagos/ingresos previstos y su resolución (confirmado con movimiento real u omitido). |
| `monthly_reports` | Cierres inmutables por usuario, mes y moneda, con versión. |
| `ai_insights` | Recomendaciones persistidas con sus fuentes (reservado). |
| `notifications` | Notificaciones dentro de la app (sin importes privados). |
| `audit_events` | Quién cambió qué y cuándo (diferencias mínimas, sin notas ni documentos). |
| `import_jobs` | Importaciones de archivos con mapeo y conteos. |
| `integration_connections` (+ `private.integration_secrets`) | Conexiones con proveedores; los tokens viven cifrados en un esquema sin acceso de la API. |

## Políticas

**Dinero.** `BIGINT` en la unidad mínima de la moneda (`*_minor`). COP se trata con 0 decimales: 280.000 COP = `280000` (ISO 4217 lista 2 decimales; en la práctica los centavos no se usan). USD/EUR/MXN usan centavos. Nunca coma flotante. La importación rechaza centavos distintos de cero en COP en vez de redondearlos.

**Monedas.** Cada movimiento conserva su moneda. Los totales nunca mezclan monedas: resúmenes, saldos y presupuestos se calculan por moneda. No hay conversión automática; cuando se implemente deberá registrar tasa, fuente y fecha.

**Borrado.** Lógico (`deleted_at`, `deleted_by`) para movimientos, liquidaciones y aportes; los elementos borrados dejan de contar en todo cálculo y se pueden restaurar. Miembros: cambio de estado. Presupuestos, metas y cuentas: archivo. La eliminación física solo ocurre en la supresión de cuenta (datos personales).

**Correcciones.** Se editan con control de versión y quedan en `audit_events` con el diff. Los cierres mensuales no se reescriben: `stale_monthly_reports()` detecta cambios posteriores al cierre y la persona genera una nueva versión explícitamente.

**Idempotencia.** `client_request_id` único por creador en movimientos, liquidaciones y aportes. Importaciones: UUIDv5 determinista a partir del archivo y la fila.

**Duplicados.** `find_possible_duplicates` puntúa coincidencias (importe, fecha cercana, comercio, número de factura) y devuelve candidatos; la app avisa pero permite guardar.

**Conciliación de facturas.** Suma de líneas − descuento + propina + otros cargos + (IVA solo si no está incluido) debe igualar el total pagado. Si no cuadra, el servidor rechaza (`ledger_receipt_unreconciled`) y la app muestra la diferencia exacta; la persona puede corregir o añadir una línea de ajuste explícita.

**Zona horaria.** Las fechas contables son `DATE` en la zona del usuario (`user_preferences.timezone`, por defecto `America/Bogota`); los registros técnicos son `timestamptz` en UTC.

**Concurrencia.** `version` + `expected_version` → HTTP 409 ante conflicto. `SELECT … FOR UPDATE` dentro de las RPC.

**Identidad.** Todas las referencias a personas apuntan a `profiles.id` (= `auth.users.id`) sin cascada, para que eliminar una cuenta no destruya el historial compartido de otros.
