// Account deletion (Ley 1581: derecho de supresión). Requires the user's own
// session plus an explicit confirmation word. Uses the service role only to
// erase data and delete the auth identity after verifying who is asking.
import { handle, HttpError, json, readJson } from '../_shared/http.ts';
import { requireUser, serviceClient } from '../_shared/auth.ts';

export default handle(async (req) => {
  const ctx = await requireUser(req);
  const body = await readJson<{ confirm?: unknown }>(req);
  if (body.confirm !== 'ELIMINAR') throw new HttpError(422, 'confirmation_required');

  const { error: reqErr } = await ctx.db.rpc('request_account_deletion');
  if (reqErr) throw new HttpError(500, 'deletion_request_failed');

  const admin = serviceClient();
  const uid = ctx.user.id;
  // Receipt files of the personal workspace are erased with it.
  const { data: personal } = await admin.from('workspaces').select('id').eq('created_by', uid).eq('kind', 'personal').maybeSingle();
  if (personal) {
    const { data: files } = await admin.from('receipts').select('storage_path').eq('workspace_id', personal.id).not('storage_path', 'is', null);
    const paths = (files ?? []).map((f) => f.storage_path as string);
    if (paths.length) {
      const { error } = await admin.storage.from('receipts').remove(paths);
      if (error) throw new HttpError(502, 'storage_cleanup_failed');
    }
  }
  const { error: eraseErr } = await admin.rpc('admin_erase_user', { p_user: uid });
  if (eraseErr) throw new HttpError(500, 'erase_failed');
  const { error: authErr } = await admin.auth.admin.deleteUser(uid);
  if (authErr) throw new HttpError(500, 'auth_delete_failed');
  return json({ deleted: true });
});
