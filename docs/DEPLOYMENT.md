# Despliegue y compilación

## 1. Proyecto Supabase

1. Crea un proyecto por entorno (desarrollo, pruebas, producción) en la región más cercana a Colombia disponible.
2. Vincula y aplica migraciones:
   ```bash
   supabase link --project-ref <ref>
   supabase db push              # aplica supabase/migrations en orden
   ```
3. **Auth** (Dashboard → Authentication):
   - Site URL y Redirect URLs: `co.nexofinance://auth-callback` (y el dominio web si lo usas).
   - Confirmación de correo **activada** y un SMTP propio (el de Supabase tiene límites muy bajos).
   - Plantillas de correo en español.
   - Opcional: Google/Apple solo cuando tengas credenciales; la app no muestra esos botones hasta entonces.
4. **Storage**: la migración crea el bucket privado `receipts`; verifica que no sea público.
5. **Realtime**: la migración añade las tablas a `supabase_realtime`.
6. **Edge Functions**:
   ```bash
   supabase secrets set --env-file supabase/functions/.env    # ver .env.example
   supabase functions deploy ai-status parse-expense extract-receipt transcribe-audio copilot delete-account
   ```
7. Copias de seguridad diarias / PITR según el plan contratado.

## 2. App Flutter

Configuración por entorno sin secretos (`app/env/*.example.json` → copia sin `.example`):

```bash
cd app
flutter pub get
flutter run --dart-define-from-file=env/development.json
```

### Android

- `minSdk 24`, `FlutterFragmentActivity` (biometría), permisos de Internet, micrófono, cámara y biometría, enlaces `co.nexofinance://auth-callback` e `co.nexofinance://invite/<token>`, sin respaldo en la nube y `FLAG_SECURE`.
- Firma: crea un keystore y `android/key.properties` (no versionado), configura `signingConfigs` en `android/app/build.gradle.kts`.
- `flutter build appbundle --release --dart-define-from-file=env/production.json`.
- Antes de publicar: icono e imagen de arranque, `applicationId` definitivo, formulario de seguridad de datos de Google Play y política de privacidad pública.

### iOS

- `Info.plist` ya incluye textos de micrófono, cámara, fotos y Face ID, el esquema `co.nexofinance` y `ITSAppUsesNonExemptEncryption = false`.
- En Xcode: equipo de firma, bundle id, objetivo mínimo iOS 13+, capacidad *Associated Domains* si usarás enlaces universales para invitaciones.
- `flutter build ipa --release --dart-define-from-file=env/production.json`.
- Antes de publicar: etiquetas de privacidad de App Store, política de privacidad, cuenta de prueba para revisión.

### Web (solo pruebas internas)

`flutter build web` sirve CanvasKit desde el mismo origen (`web/flutter_bootstrap.js`). La web se usa para pruebas E2E; no es un objetivo de producto.

## 3. CI

`.github/workflows/ci.yml`: análisis, pruebas y build web de Flutter; `supabase start` + pruebas SQL; chequeo de tipos y pruebas de Edge Functions.

## Stack local sin Docker

Para máquinas sin Docker (como el contenedor donde se construyó el proyecto):

| Pieza | Versión probada | Puerto |
|---|---|---|
| PostgreSQL | 16 | 54322 |
| Supabase Auth (GoTrue) | v2.177.0 | 9999 |
| PostgREST | v13.0.4 | 3001 |
| Deno (Edge Functions) | 2.4.5 | 54329 |
| Gateway Node (Kong + emulación de Storage) | Node 22 | **54321** |

```bash
bash tools/local-stack/start-postgres.sh   # inicializa y arranca PostgreSQL si hace falta
RESET=1 bash tools/local-stack/start.sh    # recrea la base y arranca todo
bash tools/local-stack/stop.sh
```

Variables en `tools/local-stack/env.sh` (`NEXO_BIN` apunta a los binarios de GoTrue, PostgREST y Deno). Las claves locales se firman con un secreto público de desarrollo: **nunca** las uses fuera de tu máquina. El stack local confirma correos automáticamente y no incluye Realtime (la app lo desactiva con `REALTIME_ENABLED=false`).

Con Docker, `supabase start` usa la misma carpeta `supabase/` (migraciones, `config.toml` y funciones).
