-- Pami Finance · 0400 · Row Level Security, grants, storage and realtime.
--
-- Model (docs/SECURITY.md):
--   * RLS is enabled on every table in `public`.
--   * Ledger tables (transactions, payments, splits, receipts, lines,
--     allocations, settlements, members, invitations, workspaces) are
--     READ-ONLY for API roles. Every write goes through SECURITY DEFINER RPCs
--     in 0500 that check permissions explicitly and write the audit trail.
--   * Self-owned configuration tables (preferences, accounts, categories,
--     budgets, goals, notifications) accept direct writes guarded by RLS.
--   * `anon` gets nothing except what Supabase Auth itself needs.

-- ---------------------------------------------------------------------------
-- Membership helpers (SECURITY DEFINER so policies don't recurse into RLS)
-- ---------------------------------------------------------------------------
create or replace function private.try_uuid(p text) returns uuid
language plpgsql immutable set search_path = '' as $$
begin
  return p::uuid;
exception when others then
  return null;
end $$;

create or replace function private.member_role(p_workspace uuid) returns public.member_role
language sql stable security definer set search_path = '' as $$
  select m.role from public.workspace_members m
  join public.workspaces w on w.id = m.workspace_id
  where m.workspace_id = p_workspace and m.user_id = auth.uid() and m.status = 'active';
$$;

create or replace function private.is_member(p_workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select private.member_role(p_workspace) is not null;
$$;

create or replace function private.can_write(p_workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.member_role(p_workspace) in ('owner', 'admin', 'member'), false)
     and not exists (select 1 from public.workspaces where id = p_workspace and archived_at is not null);
$$;

create or replace function private.can_admin(p_workspace uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(private.member_role(p_workspace) in ('owner', 'admin'), false);
$$;

-- True when the current user is an ACTIVE member of a workspace where `p_user`
-- is (or was) a member: lets people see co-members' names, including people
-- who left, without exposing anything else about them.
create or replace function private.shares_workspace(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.workspace_members me
    join public.workspace_members them on them.workspace_id = me.workspace_id
    where me.user_id = auth.uid() and me.status = 'active' and them.user_id = p_user
  );
$$;

create or replace function private.tx_workspace(p_tx uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select workspace_id from public.transactions where id = p_tx;
$$;

create or replace function private.receipt_workspace(p_receipt uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select workspace_id from public.receipts where id = p_receipt;
$$;

create or replace function private.item_workspace(p_item uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select r.workspace_id from public.receipt_items i join public.receipts r on r.id = i.receipt_id where i.id = p_item;
$$;

create or replace function private.goal_workspace(p_goal uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select workspace_id from public.savings_goals where id = p_goal;
$$;

create or replace function private.budget_workspace(p_budget uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select workspace_id from public.budgets where id = p_budget;
$$;

create or replace function private.rule_workspace(p_rule uuid) returns uuid
language sql stable security definer set search_path = '' as $$
  select workspace_id from public.recurring_rules where id = p_rule;
$$;

revoke all on all functions in schema private from public;
grant execute on function
  private.try_uuid(text), private.member_role(uuid), private.is_member(uuid), private.can_write(uuid),
  private.can_admin(uuid), private.shares_workspace(uuid), private.tx_workspace(uuid),
  private.receipt_workspace(uuid), private.item_workspace(uuid), private.goal_workspace(uuid),
  private.budget_workspace(uuid), private.rule_workspace(uuid)
to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Start from zero privileges, then grant the minimum.
-- ---------------------------------------------------------------------------
revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

do $$
declare t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    -- Not FORCE: the table owner (used only by audited SECURITY DEFINER RPCs
    -- with explicit permission checks) must be able to write.
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Reference data -----------------------------------------------------------
grant select on public.currencies to authenticated;
create policy currencies_read on public.currencies for select to authenticated using (true);

-- Profiles -----------------------------------------------------------------
grant select on public.profiles to authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or private.shares_workspace(id));
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid() and deleted_at is null) with check (id = auth.uid());

grant select on public.user_preferences to authenticated;
grant update (country_code, default_currency, locale, timezone, theme, income_frequency, income_day,
              financial_goals, show_amounts_in_notifications, notification_settings, onboarding_completed_at)
  on public.user_preferences to authenticated;
create policy prefs_self_read on public.user_preferences for select to authenticated using (user_id = auth.uid());
create policy prefs_self_update on public.user_preferences for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Workspaces & membership (writes only through RPC) ------------------------
grant select on public.workspaces, public.workspace_members, public.workspace_invitations to authenticated;
create policy workspaces_read on public.workspaces for select to authenticated using (private.is_member(id));
create policy members_read on public.workspace_members for select to authenticated using (private.is_member(workspace_id));
create policy invitations_read on public.workspace_invitations for select to authenticated using (private.can_admin(workspace_id));

-- Categories ---------------------------------------------------------------
grant select, insert on public.categories to authenticated;
grant update (name, icon, color, budget_bucket, sort_order, archived_at) on public.categories to authenticated;
create policy categories_read on public.categories for select to authenticated
  using (workspace_id is null or private.is_member(workspace_id));
create policy categories_insert on public.categories for insert to authenticated
  with check (workspace_id is not null and system_key is null and created_by = auth.uid() and private.can_write(workspace_id));
create policy categories_update on public.categories for update to authenticated
  using (workspace_id is not null and private.can_write(workspace_id))
  with check (workspace_id is not null and private.can_write(workspace_id));

-- Accounts (owner only) ----------------------------------------------------
grant select, insert on public.accounts to authenticated;
grant update (name, type, opening_balance_minor, credit_limit_minor, archived_at) on public.accounts to authenticated;
create policy accounts_owner_read on public.accounts for select to authenticated using (owner_id = auth.uid());
create policy accounts_owner_insert on public.accounts for insert to authenticated with check (owner_id = auth.uid());
create policy accounts_owner_update on public.accounts for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Ledger (read-only for clients) -------------------------------------------
grant select on public.transactions, public.transaction_payments, public.transaction_splits,
  public.receipts, public.receipt_items, public.receipt_item_allocations,
  public.settlements, public.settlement_allocations to authenticated;
create policy transactions_read on public.transactions for select to authenticated using (private.is_member(workspace_id));
create policy payments_read on public.transaction_payments for select to authenticated using (private.is_member(private.tx_workspace(transaction_id)));
create policy splits_read on public.transaction_splits for select to authenticated using (private.is_member(private.tx_workspace(transaction_id)));
create policy receipts_read on public.receipts for select to authenticated using (private.is_member(workspace_id));
create policy receipt_items_read on public.receipt_items for select to authenticated using (private.is_member(private.receipt_workspace(receipt_id)));
create policy receipt_allocs_read on public.receipt_item_allocations for select to authenticated using (private.is_member(private.item_workspace(item_id)));
create policy settlements_read on public.settlements for select to authenticated using (private.is_member(workspace_id));
create policy settlement_allocs_read on public.settlement_allocations for select to authenticated
  using (private.is_member(private.tx_workspace(transaction_id)));

-- Budgets ------------------------------------------------------------------
grant select, insert on public.budgets to authenticated;
grant update (name, amount_minor, income_share_bp, alert_threshold_bp, starts_on, ends_on, archived_at) on public.budgets to authenticated;
create policy budgets_read on public.budgets for select to authenticated using (private.is_member(workspace_id));
create policy budgets_insert on public.budgets for insert to authenticated
  with check (created_by = auth.uid() and private.can_write(workspace_id));
create policy budgets_update on public.budgets for update to authenticated
  using (private.can_write(workspace_id)) with check (private.can_write(workspace_id));

grant select, insert, delete on public.budget_categories to authenticated;
create policy budget_categories_read on public.budget_categories for select to authenticated
  using (private.is_member(private.budget_workspace(budget_id)));
create policy budget_categories_insert on public.budget_categories for insert to authenticated
  with check (private.can_write(private.budget_workspace(budget_id)));
create policy budget_categories_delete on public.budget_categories for delete to authenticated
  using (private.can_write(private.budget_workspace(budget_id)));

-- Goals --------------------------------------------------------------------
grant select, insert on public.savings_goals to authenticated;
grant update (kind, name, target_minor, target_date, planned_monthly_minor, priority, account_id, achieved_at, archived_at)
  on public.savings_goals to authenticated;
create policy goals_read on public.savings_goals for select to authenticated using (private.is_member(workspace_id));
create policy goals_insert on public.savings_goals for insert to authenticated
  with check (created_by = auth.uid() and private.can_write(workspace_id));
create policy goals_update on public.savings_goals for update to authenticated
  using (private.can_write(workspace_id)) with check (private.can_write(workspace_id));

grant select, insert on public.savings_contributions to authenticated;
grant update (deleted_at) on public.savings_contributions to authenticated;
create policy contributions_read on public.savings_contributions for select to authenticated
  using (private.is_member(private.goal_workspace(goal_id)));
create policy contributions_insert on public.savings_contributions for insert to authenticated
  with check (created_by = auth.uid() and deleted_at is null and private.can_write(private.goal_workspace(goal_id)));
create policy contributions_soft_delete on public.savings_contributions for update to authenticated
  using (created_by = auth.uid() and private.can_write(private.goal_workspace(goal_id)))
  with check (created_by = auth.uid());

-- Recurring ----------------------------------------------------------------
grant select, insert on public.recurring_rules to authenticated;
grant update (label, category_id, expected_minor, frequency, anchor_date, end_date, remind_days_before, active)
  on public.recurring_rules to authenticated;
create policy recurring_read on public.recurring_rules for select to authenticated using (private.is_member(workspace_id));
create policy recurring_insert on public.recurring_rules for insert to authenticated
  with check (created_by = auth.uid() and private.can_write(workspace_id));
create policy recurring_update on public.recurring_rules for update to authenticated
  using (private.can_write(workspace_id)) with check (private.can_write(workspace_id));

grant select on public.scheduled_occurrences to authenticated;
create policy occurrences_read on public.scheduled_occurrences for select to authenticated
  using (private.is_member(private.rule_workspace(rule_id)));

-- Self-only records --------------------------------------------------------
grant select on public.monthly_reports to authenticated;
create policy reports_self on public.monthly_reports for select to authenticated using (user_id = auth.uid());

grant select on public.ai_insights to authenticated;
grant update (dismissed_at) on public.ai_insights to authenticated;
create policy insights_self_read on public.ai_insights for select to authenticated using (user_id = auth.uid());
create policy insights_self_update on public.ai_insights for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select on public.notifications to authenticated;
grant update (read_at) on public.notifications to authenticated;
create policy notifications_self_read on public.notifications for select to authenticated using (user_id = auth.uid());
create policy notifications_self_update on public.notifications for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select, insert on public.import_jobs to authenticated;
grant update (status, column_mapping, row_count, imported_count, duplicate_count, error, completed_at) on public.import_jobs to authenticated;
create policy imports_self_read on public.import_jobs for select to authenticated using (user_id = auth.uid());
create policy imports_self_insert on public.import_jobs for insert to authenticated
  with check (user_id = auth.uid() and private.can_write(workspace_id));
create policy imports_self_update on public.import_jobs for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

grant select on public.integration_connections to authenticated;
create policy integrations_self_read on public.integration_connections for select to authenticated using (user_id = auth.uid());

grant select on public.audit_events to authenticated;
create policy audit_read on public.audit_events for select to authenticated
  using ((workspace_id is not null and private.is_member(workspace_id))
      or (workspace_id is null and actor_id = auth.uid()));

-- ---------------------------------------------------------------------------
-- Storage: private bucket, path = <workspace_id>/<receipt_uuid>/<file>
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('receipts', 'receipts', false, 10485760,
        array['image/jpeg', 'image/png', 'image/heic', 'image/webp', 'application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create policy receipts_bucket_read on storage.objects for select to authenticated
  using (bucket_id = 'receipts' and private.is_member(private.try_uuid((storage.foldername(name))[1])));
create policy receipts_bucket_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'receipts'
              and array_length(storage.foldername(name), 1) = 2
              and private.try_uuid((storage.foldername(name))[2]) is not null
              and private.can_write(private.try_uuid((storage.foldername(name))[1])));
create policy receipts_bucket_delete on storage.objects for delete to authenticated
  using (bucket_id = 'receipts' and private.can_write(private.try_uuid((storage.foldername(name))[1])));

-- ---------------------------------------------------------------------------
-- Realtime: postgres_changes honours the RLS policies above.
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['transactions', 'transaction_splits', 'transaction_payments', 'settlements',
                             'workspace_members', 'receipts', 'receipt_items', 'notifications', 'budgets'] loop
      execute format('alter publication supabase_realtime add table public.%I', t);
    end loop;
  end if;
end $$;
