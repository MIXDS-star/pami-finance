# Fórmulas oficiales

Todas usan enteros en la unidad mínima de la moneda. Los porcentajes se expresan en puntos básicos (100 pb = 1 %).

## Reparto y redondeo

**Mayor resto (Hamilton).** Para repartir `T` según pesos `w₁…wₙ`: cada parte recibe `⌊T·wᵢ / Σw⌋`; las unidades sobrantes se asignan una a una a los mayores restos; los empates van al primero en el orden de la lista. La suma es siempre exactamente `T`. Partes iguales = pesos 1; porcentajes = pesos en pb (deben sumar 10.000); proporciones = pesos enteros.

**Importes fijos** deben sumar exactamente el total. **Fijos + resto**: se restan los fijos y el resto se reparte a partes iguales entre las personas elegidas.

**Por producto.** Cada línea se reparte con su regla. Los extras del documento `E = propina + otros cargos + (IVA si no está incluido) − descuento` se prorratean por mayor resto en proporción a lo que cada persona tiene asignado en líneas. Parte final = líneas asignadas + extras prorrateados.

**Ejemplo de la especificación (probado).** Factura de 300.000: A 80.000, B 70.000, compartidos 150.000 al 50 % → A 155.000, B 145.000. Si A pagó todo: saldo de A +145.000, de B −145.000; B debe 145.000 a A.

## Saldos entre miembros (por espacio y moneda)

`saldo = pagado − asignado + reembolsos enviados − reembolsos recibidos`

Positivo: le deben; negativo: debe. La suma de todos los saldos es cero. La sugerencia de pagos empareja al mayor deudor con el mayor acreedor (empates por id) hasta saldar.

## Resumen personal de un periodo (`my_period_summary`)

- **Gasto asignado** = suma de tu parte (`transaction_splits`) en gastos confirmados de todos tus espacios activos.
- **Pagado** = suma de tus pagos (puede ser mayor o menor que el gasto asignado).
- **Ingresos** = ingresos registrados en tu espacio personal.
- **Ahorro neto** = ingresos − gasto asignado.
- **Tasa de ahorro** = (ingresos − gasto asignado) ÷ ingresos. Usa **ingresos registrados**, no ingresos brutos antes de impuestos. Sin ingresos registrados no se calcula.

Transferencias entre cuentas, pagos de tarjeta y reembolsos entre personas **no** son gasto.

## Presupuestos (`budget_status`)

- Límite: importe fijo o `ingresos del mes × pb / 10.000` (solo en el espacio personal).
- Gastado: espacio personal → tu parte asignada en todos tus espacios; espacio compartido → total del espacio. Filtrado por categorías si las hay.
- Consumido = gastado × 10.000 / límite (redondeo a la mitad).
- Proyección lineal = gastado × días del mes / días transcurridos (en mes en curso).
- Alerta cuando consumido ≥ umbral.

## Metas (`goal_progress`)

- Ahorrado = suma de aportes no anulados (los retiros son negativos).
- Progreso = ahorrado × 10.000 / objetivo (máx. 100 %).
- Aporte mensual necesario = ⌈restante / meses hasta la fecha objetivo⌉.
- Fecha proyectada = hoy + ⌈restante / aporte planificado⌉ meses (sin rendimientos).

## Saldos de cuentas (`my_account_balances`)

`saldo = saldo inicial + ingresos recibidos − gastos que pagaste con la cuenta + transferencias entrantes − transferencias salientes`. En tarjetas de crédito, un saldo negativo es deuda.

## Simulaciones (educativas, hipotéticas)

Capitalización mensual con tasa anual/12 y redondeo a la mitad cada mes; valor real = valor nominal deflactado por un índice de precios con la inflación supuesta. Escenarios de ahorro: conservador 25 %, intermedio 50 %, ambicioso 80 % del margen mensual (ingresos − gasto asignado). Los nombres describen cuánto se aparta, no una rentabilidad.
