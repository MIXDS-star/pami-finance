// Read-only tools for the copilot. Each one calls an official aggregation RPC
// with the USER's JWT (RLS applies), so the model can only see what the user
// can see and every number comes from the server's formulas.
// No tool writes data or moves money.
import type { UserContext } from '../_shared/auth.ts';
import type { CopilotTool } from '../_shared/ai/types.ts';
import { HttpError } from '../_shared/http.ts';

const dateProp = { type: 'string', description: 'Fecha AAAA-MM-DD' };
const obj = (properties: Record<string, unknown>, required: string[] = Object.keys(properties)) =>
  ({ type: 'object', additionalProperties: false, properties, required });

function date(v: unknown, field: string): string {
  if (typeof v !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(v) || isNaN(Date.parse(v))) throw new Error(`${field} inválida`);
  return v;
}
function currency(v: unknown): string {
  return typeof v === 'string' && /^[A-Z]{3}$/.test(v) ? v : 'COP';
}

async function rpc(ctx: UserContext, fn: string, args: Record<string, unknown>) {
  const { data, error } = await ctx.db.rpc(fn, args);
  if (error) throw new Error(`No se pudo consultar ${fn}`);
  return data;
}

/** Hypothetical savings projection: integer math, nominal, no promise. */
export function simulateSavings(monthlyMinor: number, months: number, annualRateBp: number, initialMinor = 0) {
  if (!Number.isInteger(monthlyMinor) || monthlyMinor < 0 || monthlyMinor > 1e12) throw new Error('aporte inválido');
  if (!Number.isInteger(months) || months < 1 || months > 600) throw new Error('plazo inválido');
  if (!Number.isInteger(annualRateBp) || annualRateBp < 0 || annualRateBp > 3000) throw new Error('tasa inválida');
  let balance = BigInt(initialMinor);
  let contributed = BigInt(initialMinor);
  // Monthly compounding with rate = annual / 12, rounded half-up each month.
  for (let m = 0; m < months; m++) {
    balance += (balance * BigInt(annualRateBp) + 60000n) / 120000n;
    balance += BigInt(monthlyMinor);
    contributed += BigInt(monthlyMinor);
  }
  return {
    kind: 'Escenario hipotético',
    contributed_minor: Number(contributed),
    projected_balance_minor: Number(balance),
    assumed_return_minor: Number(balance - contributed),
    assumptions: `Aporte fijo mensual, tasa nominal anual de ${(annualRateBp / 100).toFixed(2)} % con capitalización mensual; ` +
      'sin inflación, impuestos ni comisiones. No es una predicción ni una promesa de rentabilidad.',
  };
}

export function buildTools(ctx: UserContext, workspaceIds: Map<string, string>): CopilotTool[] {
  const ws = (alias: unknown) => {
    if (alias === null || alias === undefined || alias === '') return null;
    const id = typeof alias === 'string' ? workspaceIds.get(alias) : undefined;
    if (!id) throw new Error('Espacio desconocido');
    return id;
  };
  return [
    {
      name: 'get_period_summary',
      description: 'Resumen oficial del usuario en un periodo: ingresos registrados, gasto asignado (personal + su parte en espacios compartidos), importe pagado, ahorro neto y tasa de ahorro, con fórmulas y calidad de datos.',
      input_schema: obj({ from: dateProp, to: dateProp, currency: { type: 'string' } }),
      run: (i) => rpc(ctx, 'my_period_summary', { p_from: date(i.from, 'from'), p_to: date(i.to, 'to'), p_currency: currency(i.currency) }),
    },
    {
      name: 'get_spending_by_category',
      description: 'Gasto por categoría en un periodo. Sin workspace_alias: la parte asignada al usuario en todos sus espacios. Con workspace_alias: el total del espacio compartido.',
      input_schema: obj({ from: dateProp, to: dateProp, currency: { type: 'string' }, workspace_alias: { type: ['string', 'null'] } }),
      run: (i) => rpc(ctx, 'spending_by_category', { p_from: date(i.from, 'from'), p_to: date(i.to, 'to'), p_currency: currency(i.currency), p_workspace: ws(i.workspace_alias) }),
    },
    {
      name: 'get_monthly_trend',
      description: 'Serie mensual (hasta 24 meses) de ingresos registrados y gasto asignado del usuario.',
      input_schema: obj({ months: { type: 'integer' }, currency: { type: 'string' } }),
      run: (i) => rpc(ctx, 'monthly_trend', { p_months: Number(i.months) || 6, p_currency: currency(i.currency) }),
    },
    {
      name: 'get_top_merchants',
      description: 'Comercios con mayor gasto asignado al usuario en un periodo.',
      input_schema: obj({ from: dateProp, to: dateProp, currency: { type: 'string' } }),
      run: (i) => rpc(ctx, 'top_merchants', { p_from: date(i.from, 'from'), p_to: date(i.to, 'to'), p_currency: currency(i.currency), p_limit: 5 }),
    },
    {
      name: 'get_budget_status',
      description: 'Estado de los presupuestos visibles para el usuario en el mes de la fecha dada: límite, gastado, disponible, % consumido y proyección lineal de cierre.',
      input_schema: obj({ month: dateProp }),
      run: (i) => rpc(ctx, 'budget_status', { p_month: date(i.month, 'month') }),
    },
    {
      name: 'get_shared_balances',
      description: 'Saldos de liquidación del usuario en un espacio compartido (positivo: le deben; negativo: debe). Incluye pagado, asignado y reembolsos.',
      input_schema: obj({ workspace_alias: { type: 'string' } }),
      run: async (i) => {
        const rows = await rpc(ctx, 'workspace_balances', { p_workspace: ws(i.workspace_alias) }) as { user_id: string }[];
        return rows.map((r) => ({ ...r, is_me: r.user_id === ctx.user.id }));
      },
    },
    {
      name: 'get_pending_shared_expenses',
      description: 'Gastos compartidos recientes de un espacio con la parte de cada persona y quién pagó (máx. 30).',
      input_schema: obj({ workspace_alias: { type: 'string' } }),
      run: async (i) => {
        const { data, error } = await ctx.db.from('transactions')
          .select('description, occurred_on, currency, total_minor, transaction_payments(payer_id, amount_minor), transaction_splits(user_id, amount_minor)')
          .eq('workspace_id', ws(i.workspace_alias)).eq('kind', 'expense').is('deleted_at', null)
          .order('occurred_on', { ascending: false }).limit(30);
        if (error) throw new Error('No se pudo consultar los gastos');
        return data;
      },
    },
    {
      name: 'get_goals',
      description: 'Metas de ahorro del usuario con ahorrado, restante, progreso, aporte mensual necesario y fecha proyectada.',
      input_schema: obj({}),
      run: async () => {
        const [{ data: goals }, progress] = await Promise.all([
          ctx.db.from('savings_goals').select('id, name, kind, currency, target_minor, target_date, planned_monthly_minor').is('archived_at', null),
          rpc(ctx, 'goal_progress', {}),
        ]);
        return { goals, progress };
      },
    },
    {
      name: 'simulate_savings',
      description: 'Escenario HIPOTÉTICO de ahorro con aporte mensual fijo y una tasa anual supuesta (puntos básicos, 0 = sin rendimiento). No usa datos reales ni garantiza resultados.',
      input_schema: obj({ monthly_minor: { type: 'integer' }, months: { type: 'integer' }, annual_rate_bp: { type: 'integer' } }),
      run: async (i) => simulateSavings(Number(i.monthly_minor), Number(i.months), Number(i.annual_rate_bp)),
    },
  ];
}

export function assertQuestion(q: unknown): string {
  const text = typeof q === 'string' ? q.trim() : '';
  if (!text) throw new HttpError(422, 'question_required');
  if (text.length > 1000) throw new HttpError(422, 'question_too_long');
  return text;
}
