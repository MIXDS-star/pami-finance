-- NEXO Finance · 0700 · Verifiable aggregations, budgets, goals, recurring
-- calendar, monthly close, data export and account deletion.
--
-- Every aggregation is SECURITY INVOKER: RLS decides what is visible, so the
-- AI copilot (which calls these with the user's JWT) can never read more than
-- the user can. Official formulas are documented in docs/FORMULAS.md and
-- returned alongside the numbers.

create or replace function private.user_today() returns date
language sql stable security definer set search_path = '' as $$
  select (now() at time zone coalesce(
    (select timezone from public.user_preferences where user_id = auth.uid()), 'America/Bogota'))::date;
$$;
grant execute on function private.user_today() to authenticated;

-- ---------------------------------------------------------------------------
-- Period summary for the current user
-- ---------------------------------------------------------------------------
create or replace function public.my_period_summary(p_from date, p_to date, p_currency text default 'COP')
returns jsonb language sql stable security invoker set search_path = '' as $$
  with mine as (
    select t.id, w.kind as ws_kind, s.amount_minor
    from public.transaction_splits s
    join public.transactions t on t.id = s.transaction_id
    join public.workspaces w on w.id = t.workspace_id
    where s.user_id = auth.uid() and t.kind = 'expense' and t.deleted_at is null
      and t.currency = p_currency and t.occurred_on between p_from and p_to
  ), paid as (
    select coalesce(sum(p.amount_minor), 0) as amt
    from public.transaction_payments p join public.transactions t on t.id = p.transaction_id
    where p.payer_id = auth.uid() and t.kind = 'expense' and t.deleted_at is null
      and t.currency = p_currency and t.occurred_on between p_from and p_to
  ), income as (
    select coalesce(sum(t.total_minor), 0) as amt, count(*) as n
    from public.transactions t join public.workspaces w on w.id = t.workspace_id
    where w.kind = 'personal' and w.created_by = auth.uid() and t.kind = 'income' and t.deleted_at is null
      and t.currency = p_currency and t.occurred_on between p_from and p_to
  ), agg as (
    select coalesce(sum(amount_minor), 0) as assigned,
           coalesce(sum(amount_minor) filter (where ws_kind = 'personal'), 0) as personal,
           coalesce(sum(amount_minor) filter (where ws_kind <> 'personal'), 0) as shared,
           count(*) as n
    from mine
  )
  select jsonb_build_object(
    'period', jsonb_build_object('from', p_from, 'to', p_to),
    'currency', p_currency,
    'income_minor', income.amt,
    'expense_assigned_minor', agg.assigned,
    'expense_personal_minor', agg.personal,
    'expense_shared_assigned_minor', agg.shared,
    'paid_minor', paid.amt,
    'net_savings_minor', income.amt - agg.assigned,
    'savings_rate_bp', case when income.amt > 0 then round((income.amt - agg.assigned) * 10000.0 / income.amt)::int end,
    'counts', jsonb_build_object('expenses', agg.n, 'incomes', income.n),
    'formulas', jsonb_build_object(
      'expense_assigned', 'Suma de tu parte asignada en gastos confirmados (personales + tu parte en espacios compartidos)',
      'net_savings', 'Ingresos registrados − gasto asignado',
      'savings_rate', '(Ingresos registrados − gasto asignado) ÷ ingresos registrados; no usa ingresos brutos antes de impuestos'),
    'data_quality', jsonb_build_object(
      'period_complete', p_to < private.user_today(),
      'has_income', income.n > 0,
      'has_expenses', agg.n > 0)
  )
  from agg, paid, income;
$$;

-- Category breakdown. p_workspace NULL = my assigned share everywhere;
-- otherwise the full totals of that workspace.
create or replace function public.spending_by_category(p_from date, p_to date, p_currency text default 'COP', p_workspace uuid default null)
returns table (category_id uuid, category_name text, color text, icon text, amount_minor bigint, tx_count integer)
language sql stable security invoker set search_path = '' as $$
  with rows as (
    select t.id, t.category_id,
           case when p_workspace is null then s.amount_minor else t.total_minor end as amount
    from public.transactions t
    left join public.transaction_splits s on s.transaction_id = t.id and s.user_id = auth.uid()
    where t.kind = 'expense' and t.deleted_at is null and t.currency = p_currency
      and t.occurred_on between p_from and p_to
      and (case when p_workspace is null then s.id is not null else t.workspace_id = p_workspace end)
  )
  select r.category_id, coalesce(c.name, 'Sin categoría'), coalesce(c.color, '#6B7C78'), coalesce(c.icon, 'more_horiz'),
         sum(r.amount)::bigint, count(*)::int
  from rows r left join public.categories c on c.id = r.category_id
  group by r.category_id, c.name, c.color, c.icon
  having sum(r.amount) > 0
  order by 5 desc;
$$;

create or replace function public.monthly_trend(p_months integer default 6, p_currency text default 'COP')
returns table (month date, income_minor bigint, expense_assigned_minor bigint)
language sql stable security invoker set search_path = '' as $$
  with months as (
    select generate_series(date_trunc('month', private.user_today()) - make_interval(months => least(greatest(p_months, 1), 24) - 1),
                           date_trunc('month', private.user_today()), interval '1 month')::date as m
  )
  select m,
    coalesce((select sum(t.total_minor) from public.transactions t join public.workspaces w on w.id = t.workspace_id
              where w.kind = 'personal' and w.created_by = auth.uid() and t.kind = 'income' and t.deleted_at is null
                and t.currency = p_currency and date_trunc('month', t.occurred_on) = m), 0)::bigint,
    coalesce((select sum(s.amount_minor) from public.transaction_splits s join public.transactions t on t.id = s.transaction_id
              where s.user_id = auth.uid() and t.kind = 'expense' and t.deleted_at is null
                and t.currency = p_currency and date_trunc('month', t.occurred_on) = m), 0)::bigint
  from months order by m;
$$;

create or replace function public.top_merchants(p_from date, p_to date, p_currency text default 'COP', p_limit integer default 5)
returns table (merchant text, amount_minor bigint, tx_count integer)
language sql stable security invoker set search_path = '' as $$
  select coalesce(nullif(t.merchant, ''), t.description), sum(s.amount_minor)::bigint, count(*)::int
  from public.transaction_splits s join public.transactions t on t.id = s.transaction_id
  where s.user_id = auth.uid() and t.kind = 'expense' and t.deleted_at is null
    and t.currency = p_currency and t.occurred_on between p_from and p_to
  group by 1 order by 2 desc limit least(greatest(p_limit, 1), 20);
$$;

-- ---------------------------------------------------------------------------
-- Budgets
-- ---------------------------------------------------------------------------
create or replace function private.check_budget() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.income_share_bp is not null and (select kind from public.workspaces where id = new.workspace_id) <> 'personal' then
    raise exception 'income-based budgets are only available in the personal workspace' using errcode = 'PT422', hint = 'budget_income_personal_only';
  end if;
  return new;
end $$;
create trigger budgets_check before insert or update on public.budgets for each row execute function private.check_budget();

create or replace function public.budget_status(p_month date default null)
returns table (budget_id uuid, workspace_id uuid, name text, currency text, limit_minor bigint, spent_minor bigint,
               available_minor bigint, consumed_bp integer, projected_minor bigint, alert boolean,
               period_start date, period_end date, days_elapsed integer, days_in_period integer, category_ids uuid[])
language plpgsql stable security invoker set search_path = '' as $$
declare
  b record;
  v_today date := private.user_today();
  v_start date := date_trunc('month', coalesce(p_month, v_today))::date;
  v_end date := (date_trunc('month', coalesce(p_month, v_today)) + interval '1 month - 1 day')::date;
  v_cats uuid[];
  v_income bigint;
begin
  for b in
    select bu.*, w.kind as ws_kind, w.created_by as ws_owner from public.budgets bu
    join public.workspaces w on w.id = bu.workspace_id
    where bu.archived_at is null and bu.starts_on <= v_end and (bu.ends_on is null or bu.ends_on >= v_start)
    order by bu.created_at
  loop
    select coalesce(array_agg(bc.category_id), '{}') into v_cats from public.budget_categories bc where bc.budget_id = b.id;

    budget_id := b.id; workspace_id := b.workspace_id; name := b.name; currency := b.currency;
    period_start := v_start; period_end := v_end; category_ids := v_cats;
    days_in_period := v_end - v_start + 1;
    days_elapsed := least(greatest(v_today - v_start + 1, 0), days_in_period);

    if b.income_share_bp is not null then
      select coalesce(sum(t.total_minor), 0) into v_income from public.transactions t
      where t.workspace_id = b.workspace_id and t.kind = 'income' and t.deleted_at is null
        and t.currency = b.currency and t.occurred_on between v_start and v_end;
      limit_minor := (v_income * b.income_share_bp) / 10000;
    else
      limit_minor := b.amount_minor;
    end if;

    if b.ws_kind = 'personal' then
      select coalesce(sum(s.amount_minor), 0) into spent_minor
      from public.transaction_splits s join public.transactions t on t.id = s.transaction_id
      where s.user_id = b.ws_owner and t.kind = 'expense' and t.deleted_at is null and t.currency = b.currency
        and t.occurred_on between v_start and v_end
        and (cardinality(v_cats) = 0 or t.category_id = any (v_cats));
    else
      select coalesce(sum(t.total_minor), 0) into spent_minor from public.transactions t
      where t.workspace_id = b.workspace_id and t.kind = 'expense' and t.deleted_at is null and t.currency = b.currency
        and t.occurred_on between v_start and v_end
        and (cardinality(v_cats) = 0 or t.category_id = any (v_cats));
    end if;

    available_minor := limit_minor - spent_minor;
    consumed_bp := case when limit_minor > 0 then ((spent_minor * 10000 + limit_minor / 2) / limit_minor)::int end;
    projected_minor := case
      when v_today > v_end or days_elapsed = days_in_period then spent_minor
      when days_elapsed = 0 then 0
      else (spent_minor * days_in_period + days_elapsed / 2) / days_elapsed end;
    alert := consumed_bp is not null and consumed_bp >= b.alert_threshold_bp;
    return next;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Goals
-- ---------------------------------------------------------------------------
create or replace function public.goal_progress()
returns table (goal_id uuid, saved_minor bigint, remaining_minor bigint, progress_bp integer,
               months_left integer, required_monthly_minor bigint, projected_completion date)
language sql stable security invoker set search_path = '' as $$
  with g as (
    select sg.*, coalesce((select sum(c.amount_minor) from public.savings_contributions c
                           where c.goal_id = sg.id and c.deleted_at is null), 0)::bigint as saved
    from public.savings_goals sg where sg.archived_at is null
  ), calc as (
    select g.*, greatest(g.target_minor - g.saved, 0) as remaining,
      case when g.target_date is null then null
           else greatest((extract(year from age(g.target_date, private.user_today())) * 12
                        + extract(month from age(g.target_date, private.user_today())))::int, 0) end as m_left
    from g
  )
  select id, saved, remaining,
    least((saved * 10000 / target_minor)::int, 10000),
    m_left,
    case when m_left is null then null when m_left = 0 then remaining else (remaining + m_left - 1) / m_left end,
    case when remaining = 0 then private.user_today()
         when coalesce(planned_monthly_minor, 0) > 0
           then (private.user_today() + make_interval(months => ((remaining + planned_monthly_minor - 1) / planned_monthly_minor)::int))::date
    end
  from calc;
$$;

-- ---------------------------------------------------------------------------
-- Recurring calendar: expected items are computed, never booked as paid.
-- ---------------------------------------------------------------------------
create or replace function public.upcoming_occurrences(p_from date, p_to date)
returns table (rule_id uuid, workspace_id uuid, kind public.transaction_kind, label text, category_id uuid,
               currency text, due_on date, expected_minor bigint, status public.occurrence_status, transaction_id uuid)
language sql stable security invoker set search_path = '' as $$
  with dates as (
    select r.*, d::date as due
    from public.recurring_rules r,
    lateral generate_series(r.anchor_date,
                            least(coalesce(r.end_date, p_to), p_to),
                            case r.frequency when 'weekly' then interval '1 week' when 'biweekly' then interval '2 weeks'
                                             when 'monthly' then interval '1 month' else interval '1 year' end) d
    where r.active and r.anchor_date <= p_to
  )
  select d.id, d.workspace_id, d.kind, d.label, d.category_id, d.currency, d.due,
         coalesce(o.expected_minor, d.expected_minor), coalesce(o.status, 'scheduled'), o.transaction_id
  from dates d left join public.scheduled_occurrences o on o.rule_id = d.id and o.due_on = d.due
  where d.due between p_from and p_to
  order by d.due, d.label;
$$;

-- Confirm with a real transaction, or skip. Never marks something paid on its own.
create or replace function public.resolve_occurrence(p_rule uuid, p_due_on date, p_status public.occurrence_status, p_transaction uuid default null)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  r public.recurring_rules%rowtype;
begin
  select * into r from public.recurring_rules where id = p_rule;
  if not found or not private.can_write(r.workspace_id) then perform private.forbid('forbidden_workspace'); end if;
  if p_status = 'confirmed' and (p_transaction is null or private.tx_workspace(p_transaction) is distinct from r.workspace_id
     or exists (select 1 from public.transactions where id = p_transaction and deleted_at is not null)) then
    perform private.validation_error('occurrence_needs_transaction');
  end if;
  insert into public.scheduled_occurrences (rule_id, due_on, expected_minor, status, transaction_id, resolved_by, resolved_at)
  values (p_rule, p_due_on, r.expected_minor, p_status, case when p_status = 'confirmed' then p_transaction end,
          case when p_status <> 'scheduled' then v_uid end, case when p_status <> 'scheduled' then now() end)
  on conflict (rule_id, due_on) do update set status = excluded.status, transaction_id = excluded.transaction_id,
    resolved_by = excluded.resolved_by, resolved_at = excluded.resolved_at;
end $$;

-- ---------------------------------------------------------------------------
-- Monthly close: immutable snapshot; a correction creates a new version.
-- ---------------------------------------------------------------------------
create or replace function private.store_monthly_report(p_period date, p_currency text, p_snapshot jsonb, p_quality jsonb, p_replace boolean)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  v_current public.monthly_reports%rowtype;
  v_new public.monthly_reports%rowtype;
begin
  select * into v_current from public.monthly_reports
  where user_id = v_uid and period_start = p_period and currency = p_currency and superseded_at is null for update;
  if found and not p_replace then
    raise exception 'this month is already closed' using errcode = 'PT409', hint = 'report_exists';
  end if;
  if found then
    update public.monthly_reports set superseded_at = now() where id = v_current.id;
  end if;
  insert into public.monthly_reports (user_id, period_start, currency, report_version, snapshot, data_quality)
  values (v_uid, p_period, p_currency, coalesce(v_current.report_version, 0) + 1, p_snapshot, p_quality)
  returning * into v_new;
  perform private.audit(null, 'monthly_report', v_new.id, case when v_current.id is null then 'closed' else 'reclosed' end,
                        jsonb_build_object('period', p_period, 'version', v_new.report_version));
  return jsonb_build_object('id', v_new.id, 'report_version', v_new.report_version);
end $$;
revoke all on function private.store_monthly_report(date, text, jsonb, jsonb, boolean) from public;
grant execute on function private.store_monthly_report(date, text, jsonb, jsonb, boolean) to authenticated;

create or replace function public.close_month(p_month date, p_currency text default 'COP', p_replace boolean default false)
returns jsonb language plpgsql volatile security invoker set search_path = '' as $$
declare
  v_start date := date_trunc('month', p_month)::date;
  v_end date := (date_trunc('month', p_month) + interval '1 month - 1 day')::date;
  v_prev_start date := (date_trunc('month', p_month) - interval '1 month')::date;
  v_summary jsonb;
  v_prev jsonb;
  v_snapshot jsonb;
  v_quality jsonb;
begin
  perform private.require_uid();
  if v_end >= private.user_today() then
    raise exception 'the month has not finished yet' using errcode = 'PT422', hint = 'month_not_finished';
  end if;
  v_summary := public.my_period_summary(v_start, v_end, p_currency);
  v_prev := public.my_period_summary(v_prev_start, v_start - 1, p_currency);
  v_snapshot := jsonb_build_object(
    'summary', v_summary,
    'previous_summary', v_prev,
    'by_category', coalesce((select jsonb_agg(to_jsonb(c)) from public.spending_by_category(v_start, v_end, p_currency) c), '[]'::jsonb),
    'previous_by_category', coalesce((select jsonb_agg(to_jsonb(c)) from public.spending_by_category(v_prev_start, v_start - 1, p_currency) c), '[]'::jsonb),
    'budgets', coalesce((select jsonb_agg(to_jsonb(b)) from public.budget_status(v_start) b where b.currency = p_currency), '[]'::jsonb),
    'pending_balances', coalesce((
      select jsonb_agg(jsonb_build_object('workspace_id', w.id, 'workspace_name', w.name, 'net_minor', bal.net_minor))
      from public.workspaces w
      cross join lateral public.workspace_balances(w.id) bal
      where w.kind <> 'personal' and bal.user_id = auth.uid() and bal.currency = p_currency and bal.net_minor <> 0), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(jsonb_build_object('goal_id', g.goal_id, 'saved_minor', g.saved_minor, 'progress_bp', g.progress_bp))
                       from public.goal_progress() g), '[]'::jsonb),
    'generated_at', now()
  );
  v_quality := jsonb_build_object(
    'has_income', (v_summary -> 'data_quality' ->> 'has_income')::boolean,
    'has_expenses', (v_summary -> 'data_quality' ->> 'has_expenses')::boolean,
    'notes', to_jsonb(array_remove(array[
      case when not (v_summary -> 'data_quality' ->> 'has_income')::boolean then 'No registraste ingresos este mes: la tasa de ahorro no se puede calcular.' end,
      case when not (v_summary -> 'data_quality' ->> 'has_expenses')::boolean then 'No hay gastos registrados en este mes.' end], null)));
  return private.store_monthly_report(v_start, p_currency, v_snapshot, v_quality, p_replace);
end $$;

-- Months whose closed report no longer matches the ledger (an old movement was
-- corrected after closing). The app offers an explicit re-close.
create or replace function public.stale_monthly_reports()
returns table (report_id uuid, period_start date, currency text, closed_at timestamptz, changes_after_close bigint)
language sql stable security invoker set search_path = '' as $$
  select * from (
    select r.id, r.period_start, r.currency, r.closed_at,
      (select count(*) from public.audit_events a
       join public.transactions t on t.id = a.entity_id
       where a.entity_type = 'transaction' and a.occurred_at > r.closed_at and t.currency = r.currency
         and t.occurred_on between r.period_start and (r.period_start + interval '1 month - 1 day')::date
         and ((t.kind = 'expense' and exists (select 1 from public.transaction_splits s
                                              where s.transaction_id = t.id and s.user_id = auth.uid()))
              or (t.kind = 'income' and t.created_by = auth.uid()))) as changes
    from public.monthly_reports r where r.user_id = auth.uid() and r.superseded_at is null
  ) x where x.changes > 0;
$$;

-- ---------------------------------------------------------------------------
-- Data portability & account deletion (Ley 1581 de 2012: acceso y supresión)
-- ---------------------------------------------------------------------------
create or replace function public.export_my_data()
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object(
    'format', 'nexo-export-v1',
    'generated_at', now(),
    'money_format', 'Importes enteros en la unidad mínima de cada moneda (COP sin decimales).',
    'profile', (select to_jsonb(p) from public.profiles p where p.id = auth.uid()),
    'preferences', (select to_jsonb(u) - 'user_id' from public.user_preferences u where u.user_id = auth.uid()),
    'accounts', coalesce((select jsonb_agg(to_jsonb(a)) from public.accounts a where a.owner_id = auth.uid()), '[]'::jsonb),
    'workspaces', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'name', w.name, 'kind', w.kind, 'role', m.role))
                            from public.workspace_members m join public.workspaces w on w.id = m.workspace_id
                            where m.user_id = auth.uid() and m.status = 'active'), '[]'::jsonb),
    'personal_transactions', coalesce((select jsonb_agg(to_jsonb(t) order by t.occurred_on)
                            from public.transactions t join public.workspaces w on w.id = t.workspace_id
                            where w.kind = 'personal' and w.created_by = auth.uid()), '[]'::jsonb),
    'shared_participation', coalesce((select jsonb_agg(jsonb_build_object(
                              'transaction_id', t.id, 'workspace_id', t.workspace_id, 'description', t.description,
                              'occurred_on', t.occurred_on, 'currency', t.currency, 'total_minor', t.total_minor,
                              'my_share_minor', s.amount_minor,
                              'i_paid_minor', (select amount_minor from public.transaction_payments p where p.transaction_id = t.id and p.payer_id = auth.uid()),
                              'deleted', t.deleted_at is not null) order by t.occurred_on)
                            from public.transaction_splits s join public.transactions t on t.id = s.transaction_id
                            join public.workspaces w on w.id = t.workspace_id
                            where s.user_id = auth.uid() and w.kind <> 'personal'), '[]'::jsonb),
    'settlements', coalesce((select jsonb_agg(to_jsonb(st)) from public.settlements st
                            where auth.uid() in (st.from_user_id, st.to_user_id)), '[]'::jsonb),
    'budgets', coalesce((select jsonb_agg(to_jsonb(b)) from public.budgets b where b.created_by = auth.uid()), '[]'::jsonb),
    'goals', coalesce((select jsonb_agg(to_jsonb(g)) from public.savings_goals g where g.created_by = auth.uid()), '[]'::jsonb),
    'monthly_reports', coalesce((select jsonb_agg(to_jsonb(r)) from public.monthly_reports r where r.user_id = auth.uid()), '[]'::jsonb)
  );
$$;

create or replace function public.request_account_deletion()
returns void language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.require_uid();
begin
  insert into private.account_deletion_requests (user_id) values (v_uid)
  on conflict (user_id) do update set requested_at = now(), completed_at = null;
  perform private.audit(null, 'account', v_uid, 'deletion_requested', '{}'::jsonb);
end $$;

-- Executed by the `delete-account` Edge Function with the service role, right
-- before deleting the auth user. Personal data is erased; shared history is
-- kept with an anonymised participant so other members' balances stay true.
create or replace function public.admin_erase_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_personal uuid;
  w record;
  v_successor uuid;
begin
  select id into v_personal from public.workspaces where created_by = p_user and kind = 'personal';

  for w in select m.workspace_id from public.workspace_members m
           join public.workspaces ws on ws.id = m.workspace_id
           where m.user_id = p_user and m.status = 'active' and m.role = 'owner' and ws.kind <> 'personal' loop
    select user_id into v_successor from public.workspace_members
    where workspace_id = w.workspace_id and status = 'active' and user_id <> p_user
    order by case role when 'admin' then 0 when 'member' then 1 else 2 end, joined_at limit 1;
    if v_successor is null then
      update public.workspaces set archived_at = coalesce(archived_at, now()) where id = w.workspace_id;
    else
      update public.workspace_members set role = 'admin' where workspace_id = w.workspace_id and user_id = p_user;
      update public.workspace_members set role = 'owner' where workspace_id = w.workspace_id and user_id = v_successor;
    end if;
  end loop;

  update public.workspace_members set status = 'removed', left_at = now()
  where user_id = p_user and status = 'active' and workspace_id <> coalesce(v_personal, '00000000-0000-0000-0000-000000000000');
  update public.workspace_invitations set revoked_at = now()
  where invited_by = p_user and accepted_at is null and declined_at is null and revoked_at is null;

  if v_personal is not null then
    delete from public.workspaces where id = v_personal;
  end if;
  delete from public.accounts where owner_id = p_user;
  delete from public.notifications where user_id = p_user;
  delete from public.ai_insights where user_id = p_user;
  delete from public.monthly_reports where user_id = p_user;
  delete from public.import_jobs where user_id = p_user;
  delete from public.integration_connections where user_id = p_user;
  delete from public.user_preferences where user_id = p_user;
  delete from public.audit_events where workspace_id is null and actor_id = p_user;
  update public.profiles set display_name = 'Usuario eliminado', avatar_url = null, deleted_at = now() where id = p_user;
  update private.account_deletion_requests set completed_at = now() where user_id = p_user;
  return jsonb_build_object('personal_workspace', v_personal);
end $$;

-- ---------------------------------------------------------------------------
-- Function privileges: nothing for anon; admin_erase_user only for the server.
-- ---------------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
revoke execute on function public.admin_erase_user(uuid) from authenticated;

revoke all on all functions in schema private from public;
grant execute on all functions in schema private to authenticated, service_role;
revoke execute on function private.audit(uuid, text, uuid, text, jsonb) from authenticated;
