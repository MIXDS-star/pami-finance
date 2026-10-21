-- Budgets, analytics, goals, recurring calendar, monthly close, export and
-- account erasure.
begin;

select tests.create_user('ana@test.co', 'Ana') as ana \gset
select tests.create_user('bruno@test.co', 'Bruno') as bruno \gset
select (date_trunc('month', current_date) - interval '10 days')::date as last_month_day \gset
select date_trunc('month', :'last_month_day'::date)::date as last_month \gset

select tests.login(:'ana');
select tests.personal_ws(:'ana') as pws \gset
select public.create_workspace('Casa', 'household', 'COP') as casa \gset
select (public.create_invitation(:'casa') ->> 'token') as tok \gset
select tests.login(:'bruno');
select public.accept_invitation(:'tok');
select tests.login(:'ana');

-- Last month: income 4.000.000; personal groceries 200.000; shared groceries 300.000 split 50/50.
select public.save_transaction(jsonb_build_object('client_request_id', gen_random_uuid(), 'workspace_id', :'pws', 'kind', 'income',
  'description', 'Salario', 'occurred_on', :'last_month_day', 'currency', 'COP', 'total_minor', 4000000, 'category_id', tests.category('salary')));
select public.save_transaction(tests.expense(:'pws', 200000, :'ana', jsonb_build_object(:'ana', 200000), 'Mercado', :'last_month_day'));
select public.save_transaction(tests.expense(:'casa', 300000, :'ana', jsonb_build_object(:'ana', 150000, :'bruno', 150000), 'Mercado casa', :'last_month_day'));

select public.my_period_summary(:'last_month', (:'last_month'::date + interval '1 month - 1 day')::date) as s \gset
select tests.eq((:'s'::jsonb ->> 'expense_assigned_minor')::bigint, 350000::bigint, 'assigned spending = 200.000 personal + 150.000 share');
select tests.eq((:'s'::jsonb ->> 'expense_shared_assigned_minor')::bigint, 150000::bigint, 'shared share is reported separately');
select tests.eq((:'s'::jsonb ->> 'paid_minor')::bigint, 500000::bigint, 'paid includes the full shared bill Ana paid');
select tests.eq((:'s'::jsonb ->> 'savings_rate_bp')::int, 9125, 'savings rate = (4.000.000 − 350.000) / 4.000.000 = 91,25 %');
select tests.eq((select amount_minor from public.spending_by_category(:'last_month', (:'last_month'::date + 40)) where category_id = tests.category('groceries')),
  350000::bigint, 'category breakdown uses Ana''s share');
select tests.eq((select amount_minor from public.spending_by_category(:'last_month', (:'last_month'::date + 40), 'COP', :'casa')),
  300000::bigint, 'workspace breakdown uses the full workspace total');

-- Budgets -----------------------------------------------------------------
insert into public.budgets (workspace_id, name, currency, amount_minor, alert_threshold_bp, starts_on, created_by)
values (:'pws', 'Mercado', 'COP', 400000, 8000, :'last_month', :'ana') returning id as b1 \gset
insert into public.budget_categories values (:'b1', tests.category('groceries'));
insert into public.budgets (workspace_id, name, currency, income_share_bp, starts_on, created_by)
values (:'pws', '10 % ingresos', 'COP', 1000, :'last_month', :'ana') returning id as b2 \gset
select tests.eq((select spent_minor from public.budget_status(:'last_month') where budget_id = :'b1'), 350000::bigint, 'personal budget counts Ana''s share');
select tests.eq((select consumed_bp from public.budget_status(:'last_month') where budget_id = :'b1'), 8750, 'consumed 87,5 %');
select tests.eq((select alert from public.budget_status(:'last_month') where budget_id = :'b1'), true, 'alert threshold of 80 % is reached');
select tests.eq((select limit_minor from public.budget_status(:'last_month') where budget_id = :'b2'), 400000::bigint, 'income-based limit = 10 % of 4.000.000');
select tests.throws(format($q$insert into public.budgets (workspace_id, name, currency, income_share_bp, created_by) values (%L, 'x', 'COP', 1000, %L)$q$, :'casa', :'ana'),
  'budget_income_personal_only', 'income-based budgets are not allowed in shared workspaces');

-- Monthly close is a snapshot; corrections need an explicit re-close ----------
select tests.throws(format('select public.close_month(%L)', current_date), 'month_not_finished', 'the current month cannot be closed yet');
select public.close_month(:'last_month') ->> 'id' as r1 \gset
select tests.eq((select (snapshot -> 'summary' ->> 'expense_assigned_minor')::bigint from public.monthly_reports where id = :'r1'),
  350000::bigint, 'the closed report stores the confirmed figures');
select tests.throws(format('select public.close_month(%L)', :'last_month'), 'report_exists', 'closing twice requires an explicit replace');
select public.save_transaction(tests.expense(:'pws', 50000, :'ana', jsonb_build_object(:'ana', 50000), 'Olvidado', :'last_month_day'));
select tests.eq((select (snapshot -> 'summary' ->> 'expense_assigned_minor')::bigint from public.monthly_reports where id = :'r1'),
  350000::bigint, 'a late correction does not silently rewrite the closed report');
select tests.eq((select count(*)::int from public.stale_monthly_reports()), 1, 'the closed month is flagged as outdated');
select public.close_month(:'last_month', 'COP', true) ->> 'report_version' as v2 \gset
select tests.eq(:'v2'::int, 2, 're-closing creates version 2');
select tests.eq((select count(*)::int from public.monthly_reports where superseded_at is not null), 1, 'version 1 is kept as superseded history');
select tests.ok((select data_quality is not null from public.monthly_reports where superseded_at is null), 'the report carries data-quality notes');

-- Goals ---------------------------------------------------------------------
insert into public.savings_goals (workspace_id, kind, name, currency, target_minor, planned_monthly_minor, target_date, created_by)
values (:'pws', 'emergency_fund', 'Fondo de emergencia', 'COP', 3000000, 500000, (current_date + interval '6 months')::date, :'ana') returning id as g \gset
insert into public.savings_contributions (goal_id, amount_minor, occurred_on, client_request_id, created_by)
values (:'g', 1000000, current_date, gen_random_uuid(), :'ana');
select tests.eq((select saved_minor from public.goal_progress() where goal_id = :'g'), 1000000::bigint, 'goal savings = sum of contributions');
select tests.eq((select progress_bp from public.goal_progress() where goal_id = :'g'), 3333, 'progress 33,33 %');
select tests.eq((select required_monthly_minor from public.goal_progress() where goal_id = :'g'), 333334::bigint, 'needs 333.334/month for 6 months (rounded up)');
select tests.login(:'bruno');
select tests.eq((select count(*)::int from public.goal_progress()), 0, 'other users cannot see Ana''s personal goals');

-- Recurring: expected is not paid --------------------------------------------
select tests.login(:'ana');
insert into public.recurring_rules (workspace_id, kind, label, currency, expected_minor, frequency, anchor_date, created_by)
values (:'casa', 'expense', 'Arriendo', 'COP', 1800000, 'monthly', date_trunc('month', current_date)::date, :'ana') returning id as rule \gset
select tests.eq((select count(*)::int from public.upcoming_occurrences(current_date, (current_date + interval '62 days')::date) where rule_id = :'rule'),
  2, 'two monthly rent occurrences in the next 62 days');
select tests.eq((select count(*)::int from public.upcoming_occurrences(date_trunc('month', current_date)::date, (current_date + 62)) where status = 'confirmed'),
  0, 'scheduled items are not confirmed automatically');
select tests.eq((public.my_period_summary(date_trunc('month', current_date)::date, current_date) ->> 'expense_assigned_minor')::bigint, 0::bigint,
  'expected rent is not counted as real spending');
select tests.throws(format('select public.resolve_occurrence(%L, %L, %L)', :'rule', date_trunc('month', current_date)::date, 'confirmed'),
  'occurrence_needs_transaction', 'confirming requires a real transaction');

-- Export & erasure ----------------------------------------------------------
select tests.ok((select (public.export_my_data() -> 'personal_transactions') is not null), 'Ana can export her data');
select tests.eq((select jsonb_array_length(public.export_my_data() -> 'shared_participation')), 1, 'export includes her share of shared expenses');

select tests.logout();
select public.admin_erase_user(:'ana');
select tests.eq((select display_name from public.profiles where id = :'ana'), 'Usuario eliminado', 'the erased profile is anonymised');
select tests.eq((select count(*)::int from public.workspaces where id = :'pws'), 0, 'the personal workspace and its data are erased');
select tests.eq((select role::text from public.workspace_members where workspace_id = :'casa' and user_id = :'bruno'), 'owner',
  'ownership passes to the remaining member');
select tests.login(:'bruno');
select tests.eq((select net_minor from public.workspace_balances(:'casa') where user_id = :'bruno'), -150000::bigint,
  'the remaining member''s shared history and balance are intact');

select tests.logout();
rollback;
