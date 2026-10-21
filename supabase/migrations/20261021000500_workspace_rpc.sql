-- NEXO Finance · 0500 · Workspace, membership and invitation RPCs.
-- Errors use SQLSTATE PTxxx (PostgREST maps it to HTTP xxx) and a stable
-- machine code in HINT that the app translates (app/lib/core/errors).

create or replace function private.require_uid() returns uuid
language plpgsql stable set search_path = '' as $$
declare v uuid := auth.uid();
begin
  if v is null then
    raise exception 'authentication required' using errcode = 'PT401', hint = 'auth_required';
  end if;
  if exists (select 1 from public.profiles where id = v and deleted_at is not null) then
    raise exception 'account deleted' using errcode = 'PT403', hint = 'account_deleted';
  end if;
  return v;
end $$;

create or replace function private.forbid(p_code text default 'forbidden') returns void
language plpgsql set search_path = '' as $$
begin
  raise exception 'not allowed' using errcode = 'PT403', hint = p_code;
end $$;

-- ---------------------------------------------------------------------------
create or replace function public.create_workspace(p_name text, p_kind public.workspace_kind, p_currency text default 'COP')
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  v_id uuid;
begin
  if p_kind = 'personal' then
    raise exception 'personal workspaces are created automatically' using errcode = 'PT422', hint = 'workspace_personal_reserved';
  end if;
  if (select count(*) from public.workspace_members where user_id = v_uid and status = 'active') >= 50 then
    raise exception 'too many workspaces' using errcode = 'PT422', hint = 'workspace_limit';
  end if;
  insert into public.workspaces (kind, name, base_currency, created_by)
  values (p_kind, btrim(p_name), p_currency, v_uid) returning id into v_id;
  insert into public.workspace_members (workspace_id, user_id, role) values (v_id, v_uid, 'owner');
  perform private.audit(v_id, 'workspace', v_id, 'created', jsonb_build_object('name', btrim(p_name), 'kind', p_kind));
  return v_id;
end $$;

create or replace function public.update_workspace(p_workspace uuid, p_expected_version integer, p_name text, p_default_split jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  w public.workspaces%rowtype;
begin
  select * into w from public.workspaces where id = p_workspace for update;
  if not found or not private.can_admin(p_workspace) then perform private.forbid('forbidden_workspace'); end if;
  if w.version <> p_expected_version then
    raise exception 'workspace changed' using errcode = 'PT409', hint = 'version_conflict';
  end if;
  if w.kind = 'personal' and p_default_split is distinct from w.default_split then
    raise exception 'personal workspaces have no split rule' using errcode = 'PT422', hint = 'workspace_personal_reserved';
  end if;
  if p_default_split is not null and not (p_default_split ? 'method') then
    raise exception 'invalid split rule' using errcode = 'PT422', hint = 'split_rule_invalid';
  end if;
  update public.workspaces set name = coalesce(nullif(btrim(p_name), ''), name),
    default_split = coalesce(p_default_split, default_split)
  where id = p_workspace returning * into w;
  perform private.audit(p_workspace, 'workspace', p_workspace, 'updated', jsonb_build_object('name', w.name, 'default_split', w.default_split));
  return w.version;
end $$;

-- The base currency can only change while the workspace has no movements,
-- so no existing amount is ever reinterpreted in another currency.
create or replace function public.set_workspace_currency(p_workspace uuid, p_currency text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_uid();
  if not private.can_admin(p_workspace) then perform private.forbid('forbidden_workspace'); end if;
  if exists (select 1 from public.transactions where workspace_id = p_workspace) then
    raise exception 'currency is locked once there are movements' using errcode = 'PT409', hint = 'currency_locked';
  end if;
  update public.workspaces set base_currency = p_currency where id = p_workspace;
end $$;

create or replace function public.archive_workspace(p_workspace uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  perform private.require_uid();
  if private.member_role(p_workspace) is distinct from 'owner' then perform private.forbid('owner_required'); end if;
  if (select kind from public.workspaces where id = p_workspace) = 'personal' then
    raise exception 'personal workspace cannot be archived' using errcode = 'PT422', hint = 'workspace_personal_reserved';
  end if;
  update public.workspaces set archived_at = now() where id = p_workspace and archived_at is null;
  perform private.audit(p_workspace, 'workspace', p_workspace, 'archived', '{}'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Invitations
-- ---------------------------------------------------------------------------
create or replace function public.create_invitation(p_workspace uuid, p_role public.member_role default 'member', p_email text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  v_role public.member_role := private.member_role(p_workspace);
  v_token text;
  v_inv public.workspace_invitations%rowtype;
begin
  if v_role is null or v_role not in ('owner', 'admin') then perform private.forbid('admin_required'); end if;
  if (select kind from public.workspaces where id = p_workspace) = 'personal' then
    raise exception 'personal workspaces cannot be shared' using errcode = 'PT422', hint = 'workspace_personal_reserved';
  end if;
  if not private.can_write(p_workspace) then perform private.forbid('workspace_archived'); end if;
  if p_role = 'owner' then
    raise exception 'ownership is transferred, not invited' using errcode = 'PT422', hint = 'invite_owner_role';
  end if;
  if p_role = 'admin' and v_role <> 'owner' then perform private.forbid('owner_required'); end if;
  if (select count(*) from public.workspace_invitations
      where workspace_id = p_workspace and accepted_at is null and declined_at is null and revoked_at is null and expires_at > now()) >= 20 then
    raise exception 'too many pending invitations' using errcode = 'PT429', hint = 'invite_limit';
  end if;

  v_token := translate(encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');
  insert into public.workspace_invitations (workspace_id, email, role, token_hash, invited_by)
  values (p_workspace, nullif(btrim(p_email), ''), p_role, extensions.digest(v_token, 'sha256'), v_uid)
  returning * into v_inv;

  perform private.audit(p_workspace, 'invitation', v_inv.id, 'created', jsonb_build_object('role', p_role, 'by_email', v_inv.email is not null));
  return jsonb_build_object('invitation_id', v_inv.id, 'token', v_token, 'expires_at', v_inv.expires_at);
end $$;

create or replace function private.find_invitation(p_token text) returns public.workspace_invitations
language sql stable security definer set search_path = '' as $$
  select * from public.workspace_invitations where token_hash = extensions.digest(coalesce(p_token, ''), 'sha256');
$$;

create or replace function private.invitation_state(i public.workspace_invitations) returns text
language sql stable set search_path = '' as $$
  select case
    when i.id is null then 'not_found'
    when i.accepted_at is not null then 'accepted'
    when i.declined_at is not null then 'declined'
    when i.revoked_at is not null then 'revoked'
    when i.expires_at <= now() then 'expired'
    else 'pending' end;
$$;

create or replace function public.preview_invitation(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  i public.workspace_invitations;
  v_state text;
begin
  perform private.require_uid();
  i := private.find_invitation(p_token);
  v_state := private.invitation_state(i);
  if v_state = 'not_found' then
    return jsonb_build_object('status', 'not_found');
  end if;
  return jsonb_build_object(
    'status', v_state,
    'role', i.role,
    'expires_at', i.expires_at,
    'workspace_name', (select name from public.workspaces where id = i.workspace_id),
    'workspace_kind', (select kind from public.workspaces where id = i.workspace_id),
    'invited_by_name', (select display_name from public.profiles where id = i.invited_by),
    'already_member', exists (select 1 from public.workspace_members where workspace_id = i.workspace_id and user_id = auth.uid() and status = 'active')
  );
end $$;

create or replace function public.accept_invitation(p_token text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  i public.workspace_invitations;
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  i := private.find_invitation(p_token);
  if private.invitation_state(i) <> 'pending' then
    raise exception 'invitation is not valid' using errcode = 'PT410', hint = 'invite_' || private.invitation_state(i);
  end if;
  if i.email is not null and lower(i.email::text) <> v_email then
    perform private.forbid('invite_email_mismatch');
  end if;
  if (select archived_at from public.workspaces where id = i.workspace_id) is not null then
    perform private.forbid('workspace_archived');
  end if;

  insert into public.workspace_members (workspace_id, user_id, role, invited_by)
  values (i.workspace_id, v_uid, i.role, i.invited_by)
  on conflict (workspace_id, user_id) do update
    set status = 'active', left_at = null, joined_at = now(), invited_by = excluded.invited_by,
        role = case when public.workspace_members.status = 'active' then public.workspace_members.role else excluded.role end;

  update public.workspace_invitations set accepted_at = now(), accepted_by = v_uid where id = i.id;
  perform private.audit(i.workspace_id, 'member', v_uid, 'joined', jsonb_build_object('role', i.role));
  insert into public.notifications (user_id, workspace_id, kind, title, entity_type, entity_id)
  select m.user_id, i.workspace_id, 'member_joined', 'Nuevo miembro en tu espacio', 'workspace', i.workspace_id
  from public.workspace_members m where m.workspace_id = i.workspace_id and m.status = 'active' and m.role in ('owner', 'admin') and m.user_id <> v_uid;
  return i.workspace_id;
end $$;

create or replace function public.decline_invitation(p_token text)
returns void language plpgsql security definer set search_path = '' as $$
declare i public.workspace_invitations;
begin
  perform private.require_uid();
  i := private.find_invitation(p_token);
  if private.invitation_state(i) <> 'pending' then
    raise exception 'invitation is not valid' using errcode = 'PT410', hint = 'invite_' || private.invitation_state(i);
  end if;
  update public.workspace_invitations set declined_at = now() where id = i.id;
end $$;

create or replace function public.revoke_invitation(p_invitation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_ws uuid;
begin
  perform private.require_uid();
  select workspace_id into v_ws from public.workspace_invitations where id = p_invitation;
  if v_ws is null or not private.can_admin(v_ws) then perform private.forbid('admin_required'); end if;
  update public.workspace_invitations set revoked_at = now()
  where id = p_invitation and accepted_at is null and declined_at is null and revoked_at is null;
  perform private.audit(v_ws, 'invitation', p_invitation, 'revoked', '{}'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Membership changes (history is kept: members are deactivated, never deleted)
-- ---------------------------------------------------------------------------
create or replace function public.leave_workspace(p_workspace uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  v_role public.member_role := private.member_role(p_workspace);
begin
  if v_role is null then perform private.forbid('not_member'); end if;
  if (select kind from public.workspaces where id = p_workspace) = 'personal' then
    raise exception 'you cannot leave your personal workspace' using errcode = 'PT422', hint = 'workspace_personal_reserved';
  end if;
  if v_role = 'owner' then
    if exists (select 1 from public.workspace_members where workspace_id = p_workspace and status = 'active' and user_id <> v_uid) then
      raise exception 'transfer ownership before leaving' using errcode = 'PT409', hint = 'owner_must_transfer';
    end if;
    update public.workspaces set archived_at = coalesce(archived_at, now()) where id = p_workspace;
  end if;
  update public.workspace_members set status = 'left', left_at = now()
  where workspace_id = p_workspace and user_id = v_uid;
  perform private.audit(p_workspace, 'member', v_uid, 'left', '{}'::jsonb);
end $$;

create or replace function public.change_member_role(p_workspace uuid, p_user uuid, p_role public.member_role)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  v_actor public.member_role := private.member_role(p_workspace);
  v_target public.member_role;
begin
  select role into v_target from public.workspace_members where workspace_id = p_workspace and user_id = p_user and status = 'active';
  if v_target is null then perform private.forbid('not_member'); end if;
  if p_user = v_uid then perform private.forbid('cannot_change_own_role'); end if;
  if p_role = 'owner' or v_target = 'owner' then perform private.forbid('use_transfer_ownership'); end if;
  if v_actor = 'owner' then
    null;
  elsif v_actor = 'admin' and v_target in ('member', 'viewer') and p_role in ('member', 'viewer') then
    null;
  else
    perform private.forbid('admin_required');
  end if;
  update public.workspace_members set role = p_role where workspace_id = p_workspace and user_id = p_user;
  perform private.audit(p_workspace, 'member', p_user, 'role_changed', jsonb_build_object('from', v_target, 'to', p_role));
end $$;

create or replace function public.remove_member(p_workspace uuid, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  v_actor public.member_role := private.member_role(p_workspace);
  v_target public.member_role;
begin
  select role into v_target from public.workspace_members where workspace_id = p_workspace and user_id = p_user and status = 'active';
  if v_target is null then perform private.forbid('not_member'); end if;
  if p_user = v_uid then perform private.forbid('use_leave'); end if;
  if v_target = 'owner' then perform private.forbid('cannot_remove_owner'); end if;
  if not (v_actor = 'owner' or (v_actor = 'admin' and v_target in ('member', 'viewer'))) then
    perform private.forbid('admin_required');
  end if;
  update public.workspace_members set status = 'removed', left_at = now() where workspace_id = p_workspace and user_id = p_user;
  perform private.audit(p_workspace, 'member', p_user, 'removed', jsonb_build_object('role', v_target));
end $$;

create or replace function public.transfer_ownership(p_workspace uuid, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid();
begin
  if private.member_role(p_workspace) is distinct from 'owner' then perform private.forbid('owner_required'); end if;
  if p_user = v_uid or not exists (select 1 from public.workspace_members where workspace_id = p_workspace and user_id = p_user and status = 'active') then
    perform private.forbid('not_member');
  end if;
  update public.workspace_members set role = 'admin' where workspace_id = p_workspace and user_id = v_uid;
  update public.workspace_members set role = 'owner' where workspace_id = p_workspace and user_id = p_user;
  perform private.audit(p_workspace, 'member', p_user, 'ownership_transferred', jsonb_build_object('from', v_uid));
end $$;

-- ---------------------------------------------------------------------------
-- Generic per-user rate limiting (used by Edge Functions with the user's JWT)
-- ---------------------------------------------------------------------------
create or replace function public.consume_rate_limit(p_bucket text, p_max integer, p_window_seconds integer)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  v_count integer;
begin
  delete from private.usage_events where created_at < now() - interval '1 day';
  select count(*) into v_count from private.usage_events
  where user_id = v_uid and bucket = p_bucket and created_at > now() - make_interval(secs => p_window_seconds);
  if v_count >= p_max then
    return false;
  end if;
  insert into private.usage_events (user_id, bucket) values (v_uid, p_bucket);
  return true;
end $$;
