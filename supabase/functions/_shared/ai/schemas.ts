// JSON Schemas used for structured outputs. The model's answer is constrained
// to these shapes and then re-validated in code before reaching the app.
import { EXPENSE_CATEGORY_KEYS, PAYMENT_METHODS } from './types.ts';

const nullableString = { type: ['string', 'null'] };
const nullableInt = { type: ['integer', 'null'] };
const categoryKey = { type: ['string', 'null'], enum: [...EXPENSE_CATEGORY_KEYS, null] };
const paymentMethod = { type: ['string', 'null'], enum: [...PAYMENT_METHODS, null] };

export const expenseDraftSchema = {
  type: 'object',
  additionalProperties: false,
  required: ['description', 'merchant', 'amount_minor', 'currency', 'occurred_on', 'category_key', 'payment_method',
    'workspace_alias', 'payer_alias', 'participants', 'items', 'missing_fields', 'ambiguities', 'confidence'],
  properties: {
    description: { type: 'string' },
    merchant: nullableString,
    amount_minor: nullableInt,
    currency: nullableString,
    occurred_on: nullableString,
    category_key: categoryKey,
    payment_method: paymentMethod,
    workspace_alias: nullableString,
    payer_alias: nullableString,
    participants: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['alias', 'share_type', 'value'],
        properties: {
          alias: { type: 'string' },
          share_type: { type: 'string', enum: ['equal', 'percent', 'fixed'] },
          value: nullableInt,
        },
      },
    },
    items: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['description', 'amount_minor', 'participant_aliases'],
        properties: {
          description: { type: 'string' },
          amount_minor: nullableInt,
          participant_aliases: { type: 'array', items: { type: 'string' } },
        },
      },
    },
    missing_fields: { type: 'array', items: { type: 'string' } },
    ambiguities: { type: 'array', items: { type: 'string' } },
    confidence: { type: 'number' },
  },
} as const;

export const receiptSchema = {
  type: 'object',
  additionalProperties: false,
  required: ['merchant_name', 'merchant_tax_id', 'invoice_number', 'issued_on', 'currency', 'printed_subtotal_minor',
    'printed_total_minor', 'discount_minor', 'tax_minor', 'taxes_included', 'tip_minor', 'payment_method', 'items',
    'legibility', 'warnings'],
  properties: {
    merchant_name: nullableString,
    merchant_tax_id: nullableString,
    invoice_number: nullableString,
    issued_on: nullableString,
    currency: nullableString,
    printed_subtotal_minor: nullableInt,
    printed_total_minor: nullableInt,
    discount_minor: nullableInt,
    tax_minor: nullableInt,
    taxes_included: { type: ['boolean', 'null'] },
    tip_minor: nullableInt,
    payment_method: paymentMethod,
    items: {
      type: 'array',
      items: {
        type: 'object',
        additionalProperties: false,
        required: ['raw_text', 'description', 'quantity', 'unit_price_minor', 'line_discount_minor', 'line_total_minor',
          'category_key', 'confidence'],
        properties: {
          raw_text: { type: 'string' },
          description: { type: 'string' },
          quantity: { type: ['number', 'null'] },
          unit_price_minor: nullableInt,
          line_discount_minor: nullableInt,
          line_total_minor: nullableInt,
          category_key: categoryKey,
          confidence: { type: 'number' },
        },
      },
    },
    legibility: { type: 'string', enum: ['good', 'partial', 'poor'] },
    warnings: { type: 'array', items: { type: 'string' } },
  },
} as const;
