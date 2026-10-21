// Defensive re-validation of model output. Structured outputs constrain the
// shape; these checks enforce our business ranges and drop anything that
// references people or spaces the user did not provide.
import { EXPENSE_CATEGORY_KEYS, PAYMENT_METHODS, type ExpenseDraft, type ReceiptExtraction } from './types.ts';

const MAX_MINOR = 1_000_000_000_000;
const isDate = (s: unknown): s is string => typeof s === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(s) && !isNaN(Date.parse(s));
const money = (v: unknown): number | null =>
  typeof v === 'number' && Number.isInteger(v) && v >= 0 && v <= MAX_MINOR ? v : null;
const clamp01 = (v: unknown) => (typeof v === 'number' && isFinite(v) ? Math.min(Math.max(v, 0), 1) : 0);
const text = (v: unknown, max: number) => (typeof v === 'string' ? v.trim().slice(0, max) : '');
const nullableText = (v: unknown, max: number) => (typeof v === 'string' && v.trim() ? v.trim().slice(0, max) : null);
const currency = (v: unknown) => (typeof v === 'string' && /^[A-Z]{3}$/.test(v) ? v : null);
const category = (v: unknown) => ((EXPENSE_CATEGORY_KEYS as readonly unknown[]).includes(v) ? v as ExpenseDraft['category_key'] : null);
const method = (v: unknown) => ((PAYMENT_METHODS as readonly unknown[]).includes(v) ? v as ExpenseDraft['payment_method'] : null);

export function sanitizeDraft(d: ExpenseDraft, knownAliases: Set<string>): ExpenseDraft {
  const alias = (a: unknown) => (typeof a === 'string' && knownAliases.has(a) ? a : null);
  const warnings: string[] = [];
  const participants = (Array.isArray(d.participants) ? d.participants : []).flatMap((p) => {
    const a = alias(p?.alias);
    if (!a) { warnings.push('Se ignoró una persona que no pertenece a tus espacios.'); return []; }
    const share = ['equal', 'percent', 'fixed'].includes(p.share_type) ? p.share_type : 'equal';
    return [{ alias: a, share_type: share, value: money(p.value) }];
  });
  return {
    description: text(d.description, 140) || 'Gasto',
    merchant: nullableText(d.merchant, 120),
    amount_minor: money(d.amount_minor),
    currency: currency(d.currency),
    occurred_on: isDate(d.occurred_on) ? d.occurred_on : null,
    category_key: category(d.category_key),
    payment_method: method(d.payment_method),
    workspace_alias: alias(d.workspace_alias),
    payer_alias: alias(d.payer_alias),
    participants,
    items: (Array.isArray(d.items) ? d.items : []).slice(0, 100).map((i) => ({
      description: text(i?.description, 140) || 'Artículo',
      amount_minor: money(i?.amount_minor),
      participant_aliases: (Array.isArray(i?.participant_aliases) ? i.participant_aliases : []).flatMap((a) => alias(a) ?? []),
    })),
    missing_fields: (Array.isArray(d.missing_fields) ? d.missing_fields : []).map((m) => text(m, 60)).filter(Boolean).slice(0, 20),
    ambiguities: [...(Array.isArray(d.ambiguities) ? d.ambiguities : []).map((m) => text(m, 300)).filter(Boolean), ...new Set(warnings)].slice(0, 10),
    confidence: clamp01(d.confidence),
  };
}

export function sanitizeReceipt(r: ReceiptExtraction): ReceiptExtraction {
  return {
    merchant_name: nullableText(r.merchant_name, 120),
    merchant_tax_id: nullableText(r.merchant_tax_id, 40),
    invoice_number: nullableText(r.invoice_number, 60),
    issued_on: isDate(r.issued_on) ? r.issued_on : null,
    currency: currency(r.currency),
    printed_subtotal_minor: money(r.printed_subtotal_minor),
    printed_total_minor: money(r.printed_total_minor),
    discount_minor: money(r.discount_minor),
    tax_minor: money(r.tax_minor),
    taxes_included: typeof r.taxes_included === 'boolean' ? r.taxes_included : null,
    tip_minor: money(r.tip_minor),
    payment_method: method(r.payment_method),
    items: (Array.isArray(r.items) ? r.items : []).slice(0, 200).map((i) => ({
      raw_text: text(i?.raw_text, 300),
      description: text(i?.description, 140) || text(i?.raw_text, 140) || 'Artículo',
      quantity: typeof i?.quantity === 'number' && i.quantity > 0 && i.quantity < 1e6 ? i.quantity : null,
      unit_price_minor: money(i?.unit_price_minor),
      line_discount_minor: money(i?.line_discount_minor),
      line_total_minor: money(i?.line_total_minor),
      category_key: category(i?.category_key),
      confidence: clamp01(i?.confidence),
    })),
    legibility: ['good', 'partial', 'poor'].includes(r.legibility) ? r.legibility : 'poor',
    warnings: (Array.isArray(r.warnings) ? r.warnings : []).map((w) => text(w, 300)).filter(Boolean).slice(0, 10),
  };
}

/** Real file type from magic bytes. The declared type is never trusted. */
export function sniffDocument(b: Uint8Array): 'image/jpeg' | 'image/png' | 'image/webp' | 'application/pdf' | 'image/heic' | null {
  const ascii = (from: number, to: number) => String.fromCharCode(...b.subarray(from, to));
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg';
  if (b.length >= 8 && b[0] === 0x89 && ascii(1, 4) === 'PNG') return 'image/png';
  if (b.length >= 5 && ascii(0, 5) === '%PDF-') return 'application/pdf';
  if (b.length >= 12 && ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WEBP') return 'image/webp';
  if (b.length >= 12 && ascii(4, 8) === 'ftyp' && /hei|mif|msf/.test(ascii(8, 12))) return 'image/heic';
  return null;
}
