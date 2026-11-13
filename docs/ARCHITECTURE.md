# Arquitectura

## Visión general

```
 Flutter (iOS / Android / web de pruebas)
 ├─ ui/              sistema de diseño
 ├─ features/        pantallas por funcionalidad
 ├─ core/finance     motor financiero puro (Dart, sin E/S, probado)
 ├─ data/            repositorios → único acceso al backend
 └─ core/providers   Riverpod: dependencias, sesión, "revisión del libro"
        │  HTTPS (JWT del usuario)
        ▼
 Supabase
 ├─ Auth (GoTrue)           identidad, sesiones, verificación, recuperación
 ├─ PostgREST               tablas (lectura) + RPC (escritura) con RLS
 ├─ PostgreSQL 16           fuente de verdad financiera, RLS, invariantes en COMMIT
 ├─ Storage (privado)       facturas: <espacio>/<uuid>/<archivo>
 ├─ Realtime                cambios autorizados (postgres_changes respeta RLS)
 └─ Edge Functions (Deno)   IA (texto, factura, voz, copiloto), eliminación de cuenta
        │  secretos solo en el servidor
        ▼
 Proveedores externos       Claude (texto/visión/copiloto), STT compatible, (banca: pendiente)
```

## Decisiones principales

1. **La base de datos es la autoridad contable.** Toda escritura de movimientos pasa por una sola RPC, `public.save_transaction`, sea cual sea el método de captura (manual, texto, voz, factura, importación). Las tablas del libro son de solo lectura para la API. Los invariantes (pagos = total, reparto = total, líneas = total de la factura, participantes miembros del espacio, gastos personales solo del propietario) se comprueban con *constraint triggers* diferidos en el `COMMIT`, así que ni un cliente defectuoso ni uno malicioso puede dejar el libro descuadrado.

2. **Un solo motor de cálculo en el cliente para la vista previa.** `app/lib/core/finance` implementa las reglas de reparto, la asignación por mayor resto y la prorrata de impuestos/propinas/descuentos. Lo usan todas las pantallas. El servidor no recalcula la regla: valida que el resultado cuadre exactamente. Si en el futuro hiciera falta calcular en el servidor (por ejemplo, importación masiva sin cliente), el algoritmo está especificado en [FORMULAS.md](FORMULAS.md) y probado con los mismos casos.

3. **Agregados con una única fuente.** Saldos entre miembros (`workspace_balances`), saldos de cuentas (`my_account_balances`), resúmenes (`my_period_summary`), presupuestos (`budget_status`) y metas (`goal_progress`) se calculan en SQL con `SECURITY INVOKER`: RLS decide qué filas cuentan. No se almacenan saldos derivados en varias tablas.

4. **Privacidad por diseño.** El espacio personal es privado por construcción (un solo miembro, no admite invitaciones). Las cuentas son privadas aunque se usen en gastos compartidos. Los perfiles solo exponen el nombre visible a quienes comparten espacio; el resto vive en `user_preferences` (solo el titular).

5. **IA desacoplada y honesta.** Cada capacidad (texto, factura, voz, copiloto) es una interfaz en `supabase/functions/_shared/ai/types.ts` con su proveedor intercambiable. Sin credenciales, la función devuelve `503 ai_not_configured` y la app lo muestra como "pendiente de configuración"; nunca simula resultados. La IA produce **borradores** que la persona revisa y confirma.

6. **Concurrencia optimista.** Las filas editables tienen `version`; la edición envía `expected_version` y un conflicto devuelve HTTP 409 con la versión actual. La app ofrece recargar en vez de sobrescribir.

7. **Idempotencia.** Cada creación lleva `client_request_id` (único por usuario). Reintentos, borradores sin conexión e importaciones repetidas (identificador determinista por fila) nunca duplican movimientos.

## Módulos de la app

| Módulo | Ruta | Contenido |
|---|---|---|
| Autenticación | `features/auth` | bienvenida, registro, inicio, verificación, recuperación, configuración pendiente |
| Onboarding | `features/onboarding` | pasos progresivos y omitibles |
| Shell | `features/shell` | barra inferior: Inicio · Movimientos · [+] · Espacios · Plan |
| Inicio | `features/home` | resumen del mes, saldos compartidos, presupuestos, categorías, próximos pagos |
| Movimientos | `features/movements` | lista y filtros, detalle con historial, editor unificado, editor de reparto, editor de factura, flujo de guardado |
| Captura | `features/capture` | hoja de opciones, texto, voz, factura, importación |
| Espacios | `features/spaces` | lista, creación, detalle (gastos, saldos, miembros, ajustes), invitaciones |
| Plan | `features/plan` | presupuestos, metas, calendario, planificador, informes, educación |
| Estadísticas | `features/stats` | KPIs y gráficos con filtros y tablas |
| Copiloto | `features/copilot` | chat de solo lectura con fuentes citadas |
| Perfil | `features/profile` | cuentas, preferencias, notificaciones, seguridad, datos y privacidad, estado de IA |

Gestión de estado: Riverpod 3. `ledgerRevisionProvider` se incrementa tras cada escritura confirmada y con eventos de Realtime; todo lo derivado del libro lo observa, así que ninguna pantalla muestra totales viejos tras un cambio. Navegación: go_router con `StatefulShellRoute` y redirecciones por sesión, onboarding y recuperación de contraseña.

## Sincronización y resiliencia

- **Confirmado vs. local.** La app solo muestra como guardado lo que el servidor confirmó. Si un guardado falla por falta de conexión, el borrador queda **cifrado en el dispositivo** (Keychain/Keystore vía `flutter_secure_storage`) en "Pendientes de sincronizar", sin contar en saldos ni estadísticas, y se reintenta con el mismo `client_request_id`.
- **Tiempo real.** Suscripción a `postgres_changes` de las tablas del libro (RLS aplicada por Realtime) con refresco al volver a primer plano y "tirar para refrescar".
- **Conflictos de factura.** Una edición simultánea produce 409; se informa quién cambió qué mediante el historial (`audit_events`) y se recarga la versión actual.

## Limitaciones del entorno de desarrollo

Este repositorio se construyó en un contenedor sin Docker, sin Android SDK ni Xcode. Por eso:

- El backend se ejecuta con un **stack local equivalente** (PostgreSQL 16 + GoTrue + PostgREST + Deno + un gateway Node que emula Storage aplicando las mismas políticas RLS). Las migraciones son compatibles con un proyecto Supabase real y con `supabase start`.
- La app se verificó con `flutter analyze`, pruebas de widgets y una **build web** conducida por Playwright. No se compilaron APK/IPA ni se probó en dispositivos (cámara, micrófono, biometría, enlaces profundos nativos).

Detalle en [LIMITATIONS.md](LIMITATIONS.md).
