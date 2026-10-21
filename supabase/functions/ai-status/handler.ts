// Reports which AI capabilities are configured, so the app can show an honest
// "pending configuration" state instead of pretending a feature works.
import { handle, json } from '../_shared/http.ts';
import { requireUser } from '../_shared/auth.ts';
import { capabilities, loadRegistry, type AiRegistry } from '../_shared/ai/registry.ts';

export function createHandler(registry: () => AiRegistry = loadRegistry) {
  return handle(async (req) => {
    await requireUser(req);
    return json({ capabilities: capabilities(registry()) });
  }, ['GET', 'POST']);
}

export default createHandler();
