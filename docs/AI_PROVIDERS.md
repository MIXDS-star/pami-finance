# Proveedores de IA

Cada capacidad es una interfaz independiente (`supabase/functions/_shared/ai/types.ts`) y se elige por secretos del servidor (`_shared/ai/registry.ts`). Sin secretos, la función responde `503 ai_not_configured` y la app lo muestra como pendiente; nunca se simulan resultados.

| Capacidad | Función | Interfaz | Implementación incluida | Secretos |
|---|---|---|---|---|
| Interpretar texto (y lo transcrito) | `parse-expense` | `ExpenseParser` | Claude (`AnthropicProvider`) | `ANTHROPIC_API_KEY`, `ANTHROPIC_MODEL` (por defecto `claude-opus-5-5`) |
| Leer facturas (imagen o PDF) | `extract-receipt` | `ReceiptExtractor` | Claude, visión + PDF | igual |
| Copiloto | `copilot` | `CopilotModel` | Claude con herramientas de solo lectura | igual |
| Transcribir voz | `transcribe-audio` | `Transcriber` | Cualquier API compatible con `POST /audio/transcriptions` | `TRANSCRIPTION_API_URL`, `TRANSCRIPTION_API_KEY`, `TRANSCRIPTION_MODEL` |
| Estado | `ai-status` | — | Informa qué está configurado (sin revelar claves) | — |

Clasificación, resúmenes y predicciones se resuelven hoy con reglas y agregaciones SQL verificables (categoría propuesta por el intérprete, `budget_status`, `goal_progress`, escenarios); el copiloto las explica. Añadir un modelo para ellas es implementar otra interfaz.

## Configurar Claude

```bash
supabase secrets set ANTHROPIC_API_KEY=... ANTHROPIC_MODEL=claude-opus-5-5
supabase functions deploy parse-expense extract-receipt copilot ai-status
```

Detalles de la integración (SDK oficial `@anthropic-ai/sdk`):

- Salidas estructuradas (`output_config.format` con JSON Schema) para texto y facturas, revalidadas después en código.
- Esfuerzo `low` para interpretar texto y `medium` para facturas y copiloto; pensamiento adaptativo (siempre activo en este modelo).
- Respaldo del servidor ante rechazos (`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`); un rechazo final se devuelve como `ai_refused`.
- Las imágenes HEIC se rechazan con un mensaje claro (la app toma fotos en JPEG).

## Configurar la transcripción

Cualquier servicio con el contrato multipart `audio/transcriptions` (por ejemplo, un endpoint de Whisper):

```bash
supabase secrets set TRANSCRIPTION_API_URL=https://<proveedor>/v1 TRANSCRIPTION_API_KEY=... TRANSCRIPTION_MODEL=whisper-1
supabase functions deploy transcribe-audio
```

El audio se procesa en memoria y no se almacena.

## Datos enviados y consentimiento

Solo el texto, la factura o el audio que la persona decide procesar, más nombres de pila y alias de sus espacios. Nunca saldos, cuentas ni datos de otros espacios. Antes del lanzamiento: firmar el acuerdo de tratamiento de datos con cada proveedor, confirmar su política de retención (idealmente sin entrenamiento con los datos), declarar la transferencia internacional en la política de privacidad y documentarla según la Ley 1581 ([PRIVACY_CO.md](PRIVACY_CO.md)).

## Probar sin proveedor

`supabase/functions/tests/ai_functions_test.ts` inyecta proveedores falsos deterministas en los manejadores (`createHandler(registry)`) y prueba alias, saneamiento, inyección de instrucciones, tipos de archivo y herramientas del copiloto contra el backend real.
