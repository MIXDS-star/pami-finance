# Limitaciones conocidas

## Del entorno en que se construyó

- **Sin dispositivos ni SDK móviles.** No había Android SDK ni Xcode: no se compilaron APK/IPA ni se probó en teléfonos. Cámara, micrófono, biometría, accesos rápidos y enlaces profundos nativos están implementados y configurados, pero **sin verificar en dispositivo**. La app sí se compiló para web y se probó de extremo a extremo con Playwright.
- **Sin Docker.** El backend se probó con un stack equivalente (PostgreSQL + GoTrue + PostgREST + Deno + gateway). No incluye Realtime, así que la sincronización en vivo entre dispositivos no se pudo probar; la app recarga al guardar, al volver a primer plano y al tirar para refrescar.
- **Verificación de correo** solo probada con autoconfirmación local.

## Del producto actual

- **Tipo real de archivo al subir.** La emulación local de Storage valida los bytes; Supabase Storage alojado valida solo el tipo declarado. En producción los bytes se comprueban en `extract-receipt` antes de usarlos; queda pendiente una validación en la subida (función intermedia o webhook de Storage que borre archivos inválidos).
- **Vista previa de PDF** de facturas no implementada en la app (se adjunta y procesa, pero no se visualiza).
- **Recorte de imagen** por rangos horizontales/verticales, sin detección automática de bordes.
- **Liquidaciones** a nivel de saldo neto por persona; `settlement_allocations` existe pero la app aún no vincula un reembolso a gastos concretos.
- **Cierres mensuales** por moneda principal del usuario; no hay cierre por espacio compartido.
- **Presupuestos** solo mensuales; sin "rollover" de sobrantes.
- **Categorías propias**: la base y el repositorio las admiten, pero no hay pantalla para crearlas todavía.
- **Edición de un movimiento** no permite moverlo a otro espacio ni cambiar su tipo (decisión para preservar la trazabilidad).
- **Importación** solo al espacio personal y sin reglas de categorización automática.
- **Copiloto**: la conversación no se guarda (privacidad) y no hay recomendaciones proactivas.
- **Notificaciones**: se generan dentro de la app para gastos compartidos, invitaciones aceptadas y reembolsos; faltan alertas automáticas programadas (presupuesto, vencimientos, cierre) y push.
- **Accesibilidad**: etiquetas semánticas, tamaños adaptables y contraste revisados; falta una auditoría con TalkBack/VoiceOver en dispositivo.
- **Rendimiento**: probado con volúmenes pequeños; las listas cargan hasta 200 movimientos por consulta, sin paginación incremental.
