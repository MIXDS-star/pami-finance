-- Account balances are derived once on the server and stay private.
begin;
select tests.create_user('ana@test.co', 'Ana') as ana \gset
select tests.create_user('bruno@test.co', 'Bruno') as bruno \gset
select tests.login(:'ana');
insert into public.accounts (owner_id, name, type, currency, opening_balance_minor) values (:'ana', 'Ahorros', 'bank', 'COP', 1000000) returning id as bank \gset
insert into public.accounts (owner_id, name, type, currency) values (:'ana', 'Visa', 'credit_card', 'COP') returning id as card \gset
select public.save_transaction(jsonb_build_object('client_request_id', gen_random_uuid(), 'workspace_id', tests.personal_ws(:'ana'),
  'kind', 'income', 'description', 'Salario', 'occurred_on', current_date, 'currency', 'COP', 'total_minor', 3000000, 'account_id', :'bank'));
select public.save_transaction(jsonb_set(tests.expense(tests.personal_ws(:'ana'), 200000, :'ana', jsonb_build_object(:'ana', 200000)),
  '{payments,0,account_id}', to_jsonb(:'card'::text)));
select public.save_transaction(jsonb_build_object('client_request_id', gen_random_uuid(), 'workspace_id', tests.personal_ws(:'ana'),
  'kind', 'transfer', 'description', 'Pago tarjeta', 'occurred_on', current_date, 'currency', 'COP', 'total_minor', 200000,
  'account_id', :'bank', 'to_account_id', :'card'));
select tests.eq((select balance_minor from public.my_account_balances() where account_id = :'bank'), 3800000::bigint,
  'bank = 1.000.000 opening + 3.000.000 income − 200.000 card payment');
select tests.eq((select balance_minor from public.my_account_balances() where account_id = :'card'), 0::bigint,
  'card: −200.000 purchase + 200.000 payment = 0 (no double counting)');
select tests.eq((public.my_period_summary(current_date, current_date) ->> 'expense_assigned_minor')::bigint, 200000::bigint,
  'spending counts the purchase once, not the card payment');
select tests.login(:'bruno');
select tests.eq((select count(*)::int from public.my_account_balances()), 0, 'other users never see these balances');
select tests.logout();
rollback;
