-- Ledger invariants, idempotency, optimistic concurrency, soft delete,
-- receipt reconciliation and double-counting rules.
begin;

select tests.create_user('ana@test.co', 'Ana') as ana \gset
select tests.create_user('bruno@test.co', 'Bruno') as bruno \gset
select tests.create_user('eve@test.co', 'Eve') as eve \gset

select tests.login(:'ana');
select public.create_workspace('Viaje', 'trip', 'COP') as trip \gset
select (public.create_invitation(:'trip') ->> 'token') as tok \gset
select tests.login(:'bruno');
select public.accept_invitation(:'tok');
select tests.login(:'ana');

-- Sums must match ---------------------------------------------------------
select tests.throws(format('select public.save_transaction(%L::jsonb)',
  tests.expense(:'trip', 100000, :'ana', jsonb_build_object(:'ana', 50000, :'bruno', 40000))),
  'ledger_splits_mismatch', 'splits that do not add up to the total are rejected');
select tests.throws(format('select public.save_transaction(%L::jsonb)',
  jsonb_set(tests.expense(:'trip', 100000, :'ana', jsonb_build_object(:'ana', 100000)), '{payments,0,amount_minor}', '90000')),
  'ledger_payments_mismatch', 'payments that do not add up to the total are rejected');
select tests.throws(format('select public.save_transaction(%L::jsonb)',
  tests.expense(:'trip', 1000, :'ana', jsonb_build_object(:'ana', 500, :'eve', 500))),
  'participant_not_member', 'non-members cannot be assigned a share');
select tests.throws(format('select public.save_transaction(%L::jsonb)',
  tests.expense(tests.personal_ws(:'ana'), 1000, :'ana', jsonb_build_object(:'ana', 500, :'bruno', 500))),
  'participant_not_member', 'personal expenses cannot include anybody else');
select tests.throws(format('select public.save_transaction(%L::jsonb)',
  jsonb_set(tests.expense(:'trip', 1000, :'ana', jsonb_build_object(:'ana', 1000)), '{total_minor}', '0')),
  'amount_positive', 'zero amounts are rejected');
select tests.throws(format('select public.save_transaction(%L::jsonb)',
  jsonb_set(tests.expense(:'trip', 1000, :'ana', jsonb_build_object(:'ana', 1000)), '{total_minor}', '"12.5"')),
  'payload_invalid', 'fractional COP amounts are rejected (integers only)');
select tests.throws(format('select public.save_transaction(%L::jsonb)',
  jsonb_set(tests.expense(:'trip', 1000, :'ana', jsonb_build_object(:'ana', 1000)), '{category_id}', to_jsonb(tests.category('salary')::text))),
  'category_kind_mismatch', 'an income category cannot classify an expense');

-- Income and transfers are private and never mixed with consumption --------
select tests.throws(format('select public.save_transaction(%L::jsonb)', jsonb_build_object('client_request_id', gen_random_uuid(),
  'workspace_id', :'trip', 'kind', 'income', 'description', 'Salario', 'occurred_on', current_date, 'currency', 'COP', 'total_minor', 5000000)),
  'ledger_private_kind', 'income cannot be recorded in a shared workspace');
insert into public.accounts (owner_id, name, type, currency) values (:'ana', 'Ahorros', 'bank', 'COP') returning id as acc1 \gset
insert into public.accounts (owner_id, name, type, currency) values (:'ana', 'Visa', 'credit_card', 'COP') returning id as acc2 \gset
select public.save_transaction(jsonb_build_object('client_request_id', gen_random_uuid(), 'workspace_id', tests.personal_ws(:'ana'),
  'kind', 'income', 'description', 'Salario', 'occurred_on', current_date, 'currency', 'COP', 'total_minor', 5000000,
  'category_id', tests.category('salary'), 'account_id', :'acc1'));
select public.save_transaction(jsonb_build_object('client_request_id', gen_random_uuid(), 'workspace_id', tests.personal_ws(:'ana'),
  'kind', 'transfer', 'description', 'Pago tarjeta', 'occurred_on', current_date, 'currency', 'COP', 'total_minor', 800000,
  'account_id', :'acc1', 'to_account_id', :'acc2'));
select tests.eq((public.my_period_summary(current_date, current_date) ->> 'expense_assigned_minor')::bigint, 0::bigint,
  'a credit-card payment (transfer) is not counted as spending');
select tests.eq((public.my_period_summary(current_date, current_date) ->> 'income_minor')::bigint, 5000000::bigint, 'income is counted once');

-- Idempotency ---------------------------------------------------------------
select tests.expense(:'trip', 60000, :'ana', jsonb_build_object(:'ana', 30000, :'bruno', 30000), 'Taxi') as payload \gset
select public.save_transaction(:'payload'::jsonb) ->> 'id' as taxi \gset
select tests.eq(public.save_transaction(:'payload'::jsonb) ->> 'id', :'taxi', 'a retried create returns the same transaction');
select tests.eq((select count(*)::int from public.transactions where description = 'Taxi'), 1, 'a retried create does not duplicate the expense');

-- Optimistic concurrency -----------------------------------------------------
select (:'payload'::jsonb || jsonb_build_object('id', :'taxi', 'expected_version', 1, 'description', 'Taxi aeropuerto')) as edit_a \gset
select tests.login(:'bruno');
select public.save_transaction(:'payload'::jsonb || jsonb_build_object('id', :'taxi', 'expected_version', 1, 'notes', 'Edición de Bruno'));
select tests.login(:'ana');
select tests.throws(format('select public.save_transaction(%L::jsonb)', :'edit_a'), 'version_conflict',
  'a stale edit is rejected instead of silently overwriting another member''s change');
select tests.eq((select notes from public.transactions where id = :'taxi'), 'Edición de Bruno', 'the first edit is preserved');
select public.save_transaction(:'edit_a'::jsonb || '{"expected_version": 2}');
select tests.eq((select version from public.transactions where id = :'taxi'), 3, 'versions increase with each edit');
select tests.ok((select count(*) = 3 from public.audit_events where entity_id = :'taxi'), 'create and both edits are audited');
select tests.ok((select changes ? 'description' and not (changes::text like '%Edición de Bruno%')
                 from public.audit_events where entity_id = :'taxi' order by id desc limit 1),
  'the audit diff records changed fields without copying note contents');

-- Soft delete: excluded from balances, kept for history ---------------------
select tests.eq((select net_minor from public.workspace_balances(:'trip') where user_id = :'bruno'), -30000::bigint, 'B owes his taxi share');
select tests.login(:'bruno');
select tests.throws(format('select public.delete_transaction(%L, 3)', :'taxi'), 'creator_or_admin_required', 'members cannot delete other people''s expenses');
select tests.login(:'ana');
select tests.throws(format('select public.delete_transaction(%L, 1)', :'taxi'), 'version_conflict', 'deleting with a stale version is rejected');
select public.delete_transaction(:'taxi', 3);
select tests.eq((select count(*)::int from public.workspace_balances(:'trip')), 0, 'a deleted expense no longer affects balances');
select tests.eq((select count(*)::int from public.transactions where id = :'taxi' and deleted_at is not null), 1, 'the deleted expense is kept for history');
select tests.throws(format('select public.save_transaction(%L::jsonb)', :'edit_a'::jsonb || '{"expected_version": 4}'), 'transaction_deleted', 'a deleted expense cannot be edited');
select public.restore_transaction(:'taxi');
select tests.eq((select net_minor from public.workspace_balances(:'trip') where user_id = :'bruno'), -30000::bigint, 'restoring brings the balance back');

-- Receipts: reconciliation, taxes, tips and discounts -----------------------
select jsonb_build_object('client_request_id', gen_random_uuid(), 'workspace_id', :'trip', 'kind', 'expense',
  'description', 'Restaurante', 'occurred_on', current_date, 'currency', 'COP', 'total_minor', 110000,
  'split_method', 'by_item', 'split_spec', '{}'::jsonb,
  'payments', jsonb_build_array(jsonb_build_object('payer_id', :'ana', 'amount_minor', 110000)),
  'splits', jsonb_build_array(jsonb_build_object('user_id', :'ana', 'amount_minor', 60500), jsonb_build_object('user_id', :'bruno', 'amount_minor', 49500)),
  'receipt', jsonb_build_object('taxes_included', true, 'tax_minor', 8000, 'tip_minor', 10000, 'discount_minor', 0,
    'items', jsonb_build_array(
      jsonb_build_object('description', 'Bandeja', 'line_total_minor', 55000, 'allocation_method', 'single',
        'allocations', jsonb_build_array(jsonb_build_object('user_id', :'ana', 'amount_minor', 55000))),
      jsonb_build_object('description', 'Ajiaco', 'line_total_minor', 45000, 'allocation_method', 'single',
        'allocations', jsonb_build_array(jsonb_build_object('user_id', :'bruno', 'amount_minor', 45000)))))) as rest \gset
select tests.throws(format('select public.save_transaction(%L::jsonb)', jsonb_set(jsonb_set(jsonb_set(:'rest'::jsonb,
  '{total_minor}', '120000'), '{payments,0,amount_minor}', '120000'), '{splits,0,amount_minor}', '70500')),
  'ledger_receipt_unreconciled', 'a receipt whose lines do not explain the total is rejected (no invented items)');
select public.save_transaction(:'rest'::jsonb) ->> 'id' as rest_tx \gset
select tests.ok(:'rest_tx' is not null, 'included IVA is not added twice: lines 100.000 + tip 10.000 = 110.000');
select tests.throws(format('select public.save_transaction(%L::jsonb)', jsonb_set(:'rest'::jsonb || jsonb_build_object('client_request_id', gen_random_uuid()),
  '{receipt,taxes_included}', 'false')), 'ledger_receipt_unreconciled', 'with IVA on top the same lines need a higher total');
select tests.throws(format('select public.save_transaction(%L::jsonb)', jsonb_set(:'rest'::jsonb || jsonb_build_object('client_request_id', gen_random_uuid()),
  '{receipt,items,1,allocations,0,amount_minor}', '40000')), 'ledger_item_allocation_mismatch', 'line allocations must add up to the line');

-- Duplicates are flagged, not blocked ---------------------------------------
select tests.ok((select count(*) >= 1 from public.find_possible_duplicates(:'trip', 110000, current_date, 'Restaurante', null)),
  'a same-amount same-day expense is flagged as a possible duplicate');
select tests.eq((select count(*)::int from public.find_possible_duplicates(:'trip', 110000, current_date - 30, null, null)), 0,
  'a similar amount a month apart is not flagged');

select tests.logout();
rollback;
