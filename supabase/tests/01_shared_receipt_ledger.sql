-- Acceptance example from the product spec (section 9):
-- 300.000 COP receipt; A personal 80.000, B personal 70.000, shared 150.000 at
-- 50 %. A paid everything -> A 155.000, B 145.000, B owes A 145.000.
begin;

select tests.create_user('ana@test.co', 'Ana') as ana \gset
select tests.create_user('bruno@test.co', 'Bruno') as bruno \gset

select tests.login(:'ana');
select public.create_workspace('Casa', 'household', 'COP') as casa \gset
select (public.create_invitation(:'casa', 'member', null) ->> 'token') as token \gset

select tests.login(:'bruno');
select tests.eq((public.preview_invitation(:'token') ->> 'status'), 'pending', 'invitation preview shows pending status');
select tests.eq(public.accept_invitation(:'token'), :'casa'::uuid, 'Bruno accepts the invitation');
select tests.throws(format('select public.accept_invitation(%L)', :'token'), 'invite_accepted', 'an invitation cannot be reused');

select tests.login(:'ana');
select public.save_transaction(jsonb_build_object(
  'client_request_id', gen_random_uuid(), 'workspace_id', :'casa', 'kind', 'expense',
  'description', 'Mercado semanal', 'merchant', 'Éxito', 'occurred_on', current_date, 'currency', 'COP',
  'total_minor', 300000, 'category_id', tests.category('groceries'), 'source', 'receipt',
  'split_method', 'by_item', 'split_spec', '{}'::jsonb,
  'payments', jsonb_build_array(jsonb_build_object('payer_id', :'ana', 'amount_minor', 300000, 'method', 'debit_card')),
  'splits', jsonb_build_array(
    jsonb_build_object('user_id', :'ana', 'amount_minor', 155000),
    jsonb_build_object('user_id', :'bruno', 'amount_minor', 145000)),
  'receipt', jsonb_build_object(
    'merchant_name', 'Almacenes Éxito', 'merchant_tax_id', '890900608-9', 'invoice_number', 'FE-1001',
    'printed_total_minor', 300000, 'taxes_included', true, 'tax_minor', 47899,
    'items', jsonb_build_array(
      jsonb_build_object('description', 'Productos de Ana', 'raw_text', 'PROD ANA 80.000', 'line_total_minor', 80000,
        'allocation_method', 'single', 'allocations', jsonb_build_array(jsonb_build_object('user_id', :'ana', 'amount_minor', 80000))),
      jsonb_build_object('description', 'Productos de Bruno', 'line_total_minor', 70000,
        'allocation_method', 'single', 'allocations', jsonb_build_array(jsonb_build_object('user_id', :'bruno', 'amount_minor', 70000))),
      jsonb_build_object('description', 'Compartidos', 'line_total_minor', 150000, 'allocation_method', 'equal',
        'allocations', jsonb_build_array(
          jsonb_build_object('user_id', :'ana', 'amount_minor', 75000),
          jsonb_build_object('user_id', :'bruno', 'amount_minor', 75000))))
  )
)) ->> 'id' as tx \gset

select tests.eq((select count(*)::int from public.receipts where transaction_id = :'tx'), 1, 'exactly one receipt is stored (not one per participant)');
select tests.eq((select count(*)::int from public.receipt_items i join public.receipts r on r.id = i.receipt_id where r.transaction_id = :'tx'), 3, 'three receipt lines are stored');
select tests.eq((select amount_minor from public.transaction_splits where transaction_id = :'tx' and user_id = :'ana'), 155000::bigint, 'A is assigned 155.000');
select tests.eq((select amount_minor from public.transaction_splits where transaction_id = :'tx' and user_id = :'bruno'), 145000::bigint, 'B is assigned 145.000');
select tests.eq((select paid_minor from public.workspace_balances(:'casa') where user_id = :'ana'), 300000::bigint, 'A paid 300.000');
select tests.eq((select net_minor from public.workspace_balances(:'casa') where user_id = :'ana'), 145000::bigint, 'A is owed 145.000');
select tests.eq((select net_minor from public.workspace_balances(:'casa') where user_id = :'bruno'), -145000::bigint, 'B owes 145.000');

-- Bruno sees the shared expense and its lines, from his own session.
select tests.login(:'bruno');
select tests.eq((select count(*)::int from public.transactions where id = :'tx'), 1, 'B can read the shared expense');
select tests.eq((select count(*)::int from public.receipt_item_allocations a join public.receipt_items i on i.id = a.item_id
                 join public.receipts r on r.id = i.receipt_id where r.transaction_id = :'tx'), 4, 'B can read the line allocations');

-- Partial reimbursement, then total.
select public.record_settlement(jsonb_build_object('client_request_id', gen_random_uuid(), 'workspace_id', :'casa',
  'from_user_id', :'bruno', 'to_user_id', :'ana', 'amount_minor', 45000, 'currency', 'COP', 'method', 'bank_transfer', 'note', 'Primera parte'));
select tests.eq((select net_minor from public.workspace_balances(:'casa') where user_id = :'bruno'), -100000::bigint, 'partial settlement leaves B owing 100.000');
select tests.eq((select count(*)::int from public.transactions where workspace_id = :'casa' and deleted_at is null), 1, 'a settlement does not create a consumption expense');

select gen_random_uuid() as req \gset
select public.record_settlement(jsonb_build_object('client_request_id', :'req', 'workspace_id', :'casa',
  'from_user_id', :'bruno', 'to_user_id', :'ana', 'amount_minor', 100000, 'currency', 'COP'));
select tests.eq((public.record_settlement(jsonb_build_object('client_request_id', :'req', 'workspace_id', :'casa',
  'from_user_id', :'bruno', 'to_user_id', :'ana', 'amount_minor', 100000, 'currency', 'COP')) ->> 'replayed')::boolean, true,
  'retrying a settlement with the same request id is idempotent');
select tests.eq((select net_minor from public.workspace_balances(:'casa') where user_id = :'bruno'), 0::bigint, 'B is fully settled');
select tests.eq((select net_minor from public.workspace_balances(:'casa') where user_id = :'ana'), 0::bigint, 'A is fully settled');

-- Personal spending totals use assigned amounts, not amounts paid.
select tests.login(:'ana');
select tests.eq((public.my_period_summary(current_date - 1, current_date, 'COP') ->> 'expense_assigned_minor')::bigint, 155000::bigint,
  'A''s spending counts her 155.000 share, not the 300.000 she paid');
select tests.eq((public.my_period_summary(current_date - 1, current_date, 'COP') ->> 'paid_minor')::bigint, 300000::bigint,
  'A''s paid amount is reported separately');

select tests.logout();
rollback;
