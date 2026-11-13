# NEXO Finance

Aplicación de finanzas personales y compartidas para Colombia (COP, español, `America/Bogota`), con Flutter en el cliente y Supabase (PostgreSQL + RLS, Auth, Storage, Realtime, Edge Functions) en el servidor.

Gestiona tus gastos personales en privado y comparte, solo cuando quieras, los gastos de un hogar, una pareja, un grupo de amigos o un viaje. Una misma factura se reparte producto por producto **sin duplicarse**, y la app distingue siempre **quién pagó** de **a quién le corresponde** cada gasto.

> Estado: primera versión funcional de extremo a extremo, verificada con pruebas automáticas contra un backend real (ver [Pruebas](#pruebas)). No está publicada en tiendas: faltan credenciales, cuentas de desarrollador y decisiones comerciales ([docs/PENDING.md](docs/PENDING.md)).

## Qué funciona hoy

| Área | Estado |
|---|---|
| Registro, inicio de sesión, recuperación de contraseña, cierre de sesión (local, otros dispositivos, todos) | ✅ |
| Verificación de correo | Implementada; verificada solo con autoconfirmación local (falta SMTP) |
| Onboarding progresivo y omitible (nombre, país/moneda, tema, ingresos, presupuestos iniciales, objetivos) | ✅ |
| Espacio personal privado + espacios compartidos (hogar, pareja, amigos, viaje, otro) | ✅ |
| Invitaciones por enlace de un solo uso (opcionalmente ligadas a un correo), aceptar/rechazar/revocar, roles propietario/administrador/miembro/lector, salir, retirar, transferir propiedad | ✅ |
| Registro manual de gastos, ingresos y transferencias entre cuentas | ✅ |
| Reparto: una persona, partes iguales, porcentajes, importes fijos, proporciones, fijos + resto, **por producto** | ✅ |
| Factura única con líneas, IVA incluido o añadido, propina, descuentos, conciliación con diferencia exacta | ✅ |
| Saldos entre miembros, sugerencia mínima de pagos, reembolsos parciales/totales (no crean gasto nuevo) | ✅ |
| Historial auditado de cambios y control de concurrencia (versión) | ✅ |
| Captura por texto natural (intérprete local en español; IA si está configurada) | ✅ |
| Captura de factura: galería/PDF, rotar/recortar/mejorar, almacenamiento privado, lectura con IA si está configurada | ✅ (IA: pendiente de clave; cámara: sin verificar en dispositivo) |
| Captura por voz: grabar, escuchar, repetir, transcribir, interpretar | Implementada, sin verificar en dispositivo (transcripción: pendiente de proveedor) |
| Importación CSV/XLSX con mapeo de columnas, normalización, duplicados e idempotencia | ✅ |
| Presupuestos (fijos o % de ingresos, por categoría y por espacio, alertas, proyección) | ✅ |
| Metas de ahorro con aportes, proyección y prioridad | ✅ |
| Recurrentes y calendario (previsto ≠ confirmado; confirmar solo con movimiento real) | ✅ |
| Estadísticas con filtros, gráficos accesibles y vista de tabla | ✅ |
| Cierre mensual inmutable con versiones y aviso de desactualización | ✅ |
| Planificador (50/30/20 opcional, escenarios), educación e inversión hipotética (nominal vs. real) | ✅ |
| Copiloto financiero con herramientas de solo lectura | ✅ (pendiente de clave de IA) |
| Exportación CSV y JSON completa, eliminación de cuenta (Ley 1581) | ✅ |
| Borradores sin conexión cifrados, tema claro/oscuro | ✅ |
| Bloqueo biométrico opcional | Implementado, sin verificar en dispositivo |
| Notificaciones dentro de la app y preferencias | ✅ (push: pendiente de FCM/APNs) |
| Conexión bancaria automática | ⏳ módulo preparado, sin proveedor |
| Widgets de pantalla de inicio | ⏳ accesos rápidos sí; widgets nativos no |

El detalle de lo parcial y pendiente está en [docs/LIMITATIONS.md](docs/LIMITATIONS.md) y [docs/PENDING.md](docs/PENDING.md).

## Estructura

```
app/                       Aplicación Flutter (iOS, Android y web para pruebas)
  lib/core/finance/        Motor financiero puro (reparto, facturas, saldos, importación, proyecciones)
  lib/core/money/          Dinero en enteros y asignación por mayor resto
  lib/data/                Modelos y repositorios (único acceso a Supabase)
  lib/features/            Pantallas por funcionalidad
  lib/ui/                  Sistema de diseño (componentes reutilizables)
  test/                    Pruebas unitarias y de widgets
supabase/
  migrations/              Esquema versionado, RLS, RPC y analítica
  functions/               Edge Functions (IA, copiloto, eliminación de cuenta) + pruebas
  tests/                   Pruebas SQL de contabilidad, seguridad y planificación
tools/
  local-stack/             Stack local sin Docker (Postgres + Auth + PostgREST + Functions + gateway)
  e2e/                     Prueba de extremo a extremo (Playwright sobre la build web)
  test-all.sh              Ejecuta todas las pruebas
docs/                      Arquitectura, modelo de datos, seguridad, despliegue, privacidad…
```

## Puesta en marcha local

Requisitos: Flutter 3.47+, PostgreSQL 16, Node 22, y los binarios de Supabase Auth (GoTrue), PostgREST y Deno (ver [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#stack-local-sin-docker)). Con Docker disponible puedes usar en su lugar `supabase start` con la misma carpeta `supabase/`.

```bash
bash tools/local-stack/start.sh            # crea la base, aplica migraciones y arranca todo en :54321
cd app
flutter run --dart-define-from-file=env/development.json   # copia env/development.example.json
```

`start.sh` imprime `SUPABASE_URL` y `SUPABASE_ANON_KEY` locales. Sin esos valores la app muestra una pantalla honesta de «Configuración pendiente» y no inventa datos.

Las funciones de IA quedan en estado «no configurado» hasta definir secretos en el servidor ([docs/AI_PROVIDERS.md](docs/AI_PROVIDERS.md)); la app sigue siendo plenamente usable sin ellas.

## Pruebas

```bash
tools/test-all.sh           # base de datos + Edge Functions + Flutter + extremo a extremo
E2E=0 tools/test-all.sh     # sin la prueba de navegador
```

| Suite | Qué cubre | Resultado |
|---|---|---|
| SQL (`supabase/tests`) | Ejemplo contable de 300.000 COP, invariantes, idempotencia, conflictos de versión, borrado lógico, IVA, conciliación, RLS entre usuarios, roles, expulsión, Storage, anon, presupuestos, metas, cierres, exportación, eliminación de cuenta, saldos de cuentas | 136 aserciones ✅ |
| Deno (`supabase/functions/tests`) | Auth + PostgREST + Storage + Functions por HTTP; IA con proveedores falsos: alias, saneamiento, inyección de instrucciones, tipos de archivo, herramientas del copiloto | 16 pruebas ✅ |
| Flutter (`app/test`) | Dinero, mayor resto, reglas de reparto, motor de facturas, saldos, intérprete en español, importación, CSV, proyecciones, pantallas clave, modo oscuro y pantallas pequeñas | 61 pruebas ✅ |
| Extremo a extremo (`tools/e2e`) | App web real + backend real con dos usuarios: registro, onboarding, gastos, invitación, factura por producto, saldos, reembolso parcial, privacidad, capturas | 12 pasos ✅ |

Las capturas generadas por la prueba están en [docs/screenshots](docs/screenshots).

## Documentación

- [Arquitectura y decisiones](docs/ARCHITECTURE.md)
- [Modelo de datos y políticas contables](docs/DATA_MODEL.md)
- [Fórmulas oficiales](docs/FORMULAS.md)
- [Seguridad y RLS](docs/SECURITY.md)
- [Proveedores de IA](docs/AI_PROVIDERS.md)
- [Despliegue, compilación iOS/Android y stack local](docs/DEPLOYMENT.md)
- [Privacidad y Ley 1581 de 2012](docs/PRIVACY_CO.md)
- [Pendientes de credenciales y decisiones](docs/PENDING.md)
- [Limitaciones conocidas](docs/LIMITATIONS.md)
