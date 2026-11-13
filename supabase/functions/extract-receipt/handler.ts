// Reads a receipt the user uploaded to private storage and returns its lines.
// Download uses the user's JWT, so Storage RLS decides access. The file type
// is checked from its bytes before anything is sent to the provider.
import { encodeBase64 } from '@std/encoding/base64';
import { handle, HttpError, json, readJson } from '../_shared/http.ts';
import { rateLimit, requireUser } from '../_shared/auth.ts';
import { loadRegistry, require, type AiRegistry } from '../_shared/ai/registry.ts';
import { AiOutputError } from '../_shared/ai/types.ts';
import { sanitizeReceipt, sniffDocument } from '../_shared/ai/validate.ts';
import { userToday } from '../_shared/context.ts';

const MAX_BYTES = 10 * 1024 * 1024;

export function createHandler(registry: () => AiRegistry = loadRegistry) {
  return handle(async (req) => {
    const ctx = await requireUser(req);
    const body = await readJson<{ storage_path?: unknown }>(req);
    const path = typeof body.storage_path === 'string' ? body.storage_path : '';
    if (!/^[0-9a-f-]{36}\/[0-9a-f-]{36}\/[\w.-]{1,80}$/i.test(path)) throw new HttpError(422, 'storage_path_invalid');

    const extractor = require(registry().receiptExtractor, 'receipt extraction');
    await rateLimit(ctx, 'ai_receipt', 10, 60);

    const { data: blob, error } = await ctx.db.storage.from('receipts').download(path);
    if (error || !blob) throw new HttpError(404, 'receipt_file_not_found');
    if (blob.size > MAX_BYTES) throw new HttpError(413, 'receipt_file_too_large');
    const bytes = new Uint8Array(await blob.arrayBuffer());
    const type = sniffDocument(bytes);
    if (type === 'image/heic') throw new HttpError(415, 'receipt_heic_unsupported');
    if (!type) throw new HttpError(415, 'receipt_file_type_invalid');

    const { today, currency } = await userToday(ctx);
    try {
      const extraction = sanitizeReceipt(await extractor.extractReceipt({ mediaType: type, base64: encodeBase64(bytes) }, { defaultCurrency: currency, today }));
      return json({ provider: extractor.id, extraction });
    } catch (e) {
      if (e instanceof AiOutputError && e.message === 'pdf_unsupported') throw new HttpError(415, 'receipt_pdf_unsupported');
      if (e instanceof AiOutputError && e.message === 'rate_limited') throw new HttpError(429, 'ai_rate_limited');
      if (e instanceof AiOutputError) throw new HttpError(e.code === 'refused' ? 422 : 502, `ai_${e.code}`);
      throw e;
    }
  });
}

export default createHandler();
