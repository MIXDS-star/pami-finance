// Provider-neutral contracts. Each capability is a separate interface so a
// provider can be swapped per capability (e.g. Claude for text and receipts,
// another vendor for speech-to-text) without touching product code.

export const EXPENSE_CATEGORY_KEYS = [
  'groceries', 'restaurants', 'transport', 'housing', 'utilities', 'health', 'education',
  'entertainment', 'shopping', 'subscriptions', 'travel', 'pets', 'personal_care', 'gifts',
  'debt', 'taxes', 'other_expense',
] as const;
export type ExpenseCategoryKey = typeof EXPENSE_CATEGORY_KEYS[number];

export const PAYMENT_METHODS = ['cash', 'debit_card', 'credit_card', 'bank_transfer', 'digital_wallet', 'other'] as const;
export type PaymentMethod = typeof PAYMENT_METHODS[number];

/** Minimal, pseudonymised context: aliases instead of ids, first names only. */
export interface ParseContext {
  today: string; // YYYY-MM-DD in the user's timezone
  defaultCurrency: string;
  workspaces: { alias: string; name: string; kind: string; members: { alias: string; name: string; isMe: boolean }[] }[];
}

export interface ExpenseDraft {
  description: string;
  merchant: string | null;
  amount_minor: number | null;
  currency: string | null;
  occurred_on: string | null;
  category_key: ExpenseCategoryKey | null;
  payment_method: PaymentMethod | null;
  workspace_alias: string | null;
  payer_alias: string | null;
  participants: { alias: string; share_type: 'equal' | 'percent' | 'fixed'; value: number | null }[];
  items: { description: string; amount_minor: number | null; participant_aliases: string[] }[];
  missing_fields: string[];
  ambiguities: string[];
  confidence: number;
}

export interface ReceiptExtraction {
  merchant_name: string | null;
  merchant_tax_id: string | null;
  invoice_number: string | null;
  issued_on: string | null;
  currency: string | null;
  printed_subtotal_minor: number | null;
  printed_total_minor: number | null;
  discount_minor: number | null;
  tax_minor: number | null;
  taxes_included: boolean | null;
  tip_minor: number | null;
  payment_method: PaymentMethod | null;
  items: {
    raw_text: string;
    description: string;
    quantity: number | null;
    unit_price_minor: number | null;
    line_discount_minor: number | null;
    line_total_minor: number | null;
    category_key: ExpenseCategoryKey | null;
    confidence: number;
  }[];
  legibility: 'good' | 'partial' | 'poor';
  warnings: string[];
}

export interface DocumentInput {
  mediaType: 'image/jpeg' | 'image/png' | 'image/webp' | 'application/pdf';
  base64: string;
}

export interface ExpenseParser {
  readonly id: string;
  parseExpense(text: string, ctx: ParseContext): Promise<ExpenseDraft>;
}

export interface ReceiptExtractor {
  readonly id: string;
  extractReceipt(doc: DocumentInput, hint: { defaultCurrency: string; today: string }): Promise<ReceiptExtraction>;
}

export interface Transcriber {
  readonly id: string;
  transcribe(audio: Uint8Array, mimeType: string, language: string): Promise<{ text: string; durationSeconds?: number }>;
}

/** Read-only tool the copilot may call. `run` executes with the user's JWT. */
export interface CopilotTool {
  name: string;
  description: string;
  input_schema: Record<string, unknown>;
  run(input: Record<string, unknown>): Promise<unknown>;
}

export interface CopilotTurn {
  role: 'user' | 'assistant';
  text: string;
}

export interface CopilotAnswer {
  text: string;
  toolCalls: { name: string; input: Record<string, unknown> }[];
}

export interface CopilotModel {
  readonly id: string;
  answer(history: CopilotTurn[], question: string, tools: CopilotTool[], systemContext: string): Promise<CopilotAnswer>;
}

/** Raised when the model declines or returns something we cannot trust. */
export class AiOutputError extends Error {
  constructor(public code: 'refused' | 'invalid_output' | 'truncated' | 'provider_error', message?: string) {
    super(message ?? code);
  }
}
