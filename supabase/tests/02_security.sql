-- Security: users only reach what their memberships allow, the client can't
-- write the ledger or escalate roles, removed members lose access.
begin;

select tests.create_user('ana@test.co', 'Ana') as ana \gset
select tests.create_user('bruno@test.co', 'Bruno') as bruno \gset
select tests.create_user('carla@test.co', 'Carla') as carla \gset
select tests.create_user('intruso@test.co', 'Intruso') as eve \gset

-- Ana: personal expense, private account and a shared household with Bruno (member) and Carla (viewer).
select tests.login(:'ana');
insert into public.accounts (owner_id, name, type, currency) values (:'ana', 'Bancolombia', 'bank', 'COP') returning id as ana_account \gset
select public.save_transaction(tests.expense(tests.personal_ws(:'ana'), 52000, :'ana', jsonb_build_object(:'ana', 52000), 'Farmacia')) ->> 'id' as ana_private_tx \gset
update public.user_preferences set income_day = 30 where user_id = :'ana';
select public.create_workspace('Casa', 'household', 'COP') as casa \gset
select (public.create_invitation(:'casa', 'member', 'bruno@test.co') ->> 'token') as tok_bruno \gset
select (public.create_invitation(:'casa', 'viewer', null) ->> 'token') as tok_carla \gset
select (public.create_invitation(:'casa', 'member', 'someone@else.co') ->> 'token') as tok_other \gset

select tests.login(:'bruno');
select public.accept_invitation(:'tok_bruno');
select tests.login(:'carla');
select public.accept_invitation(:'tok_carla');
select tests.login(:'eve');
select tests.throws(format('select public.accept_invitation(%L)', :'tok_other'), 'invite_email_mismatch', 'an email-bound invitation cannot be used by someone else');

select tests.login(:'ana');
select public.save_transaction(jsonb_set(tests.expense(:'casa', 90000, :'ana', jsonb_build_object(:'ana', 45000, :'bruno', 45000), 'Internet'),
  '{payments,0,account_id}', to_jsonb(:'ana_account'::text))) ->> 'id' as shared_tx \gset

-- Personal data stays personal --------------------------------------------
select tests.login(:'bruno');
select tests.eq((select count(*)::int from public.transactions where id = :'ana_private_tx'), 0, 'B cannot read A''s personal expense');
select tests.eq((select count(*)::int from public.transactions where workspace_id = tests.personal_ws(:'ana')), 0, 'B cannot list A''s personal workspace');
select tests.eq((select count(*)::int from public.workspaces where id = tests.personal_ws(:'ana')), 0, 'B cannot see A''s personal workspace');
select tests.eq((select count(*)::int from public.accounts where owner_id = :'ana'), 0, 'B cannot read A''s accounts');
select tests.eq((select count(*)::int from public.user_preferences where user_id = :'ana'), 0, 'B cannot read A''s preferences');
select tests.eq((select count(*)::int from public.transactions where id = :'shared_tx'), 1, 'B reads the shared expense');
select tests.eq((select count(*)::int from public.accounts a join public.transaction_payments p on p.account_id = a.id
                 where p.transaction_id = :'shared_tx'), 0, 'B cannot resolve the account A used to pay');
select tests.eq((select count(*)::int from public.profiles where id = :'ana'), 1, 'co-members can see each other''s display name');
select tests.eq((select count(*)::int from public.profiles where id = :'eve'), 0, 'strangers'' profiles are hidden');
select tests.eq((select count(*)::int from public.workspace_invitations), 0, 'members cannot read invitations (tokens and emails)');
select tests.eq((select count(*)::int from public.my_period_summary(current_date, current_date) x
                 where (x ->> 'expense_personal_minor')::bigint > 0), 0, 'B''s summary does not include A''s personal spending');
select tests.eq((select count(*)::int from public.workspace_balances(tests.personal_ws(:'ana'))), 0, 'B gets no balances for A''s personal workspace');
select tests.eq((select count(*)::int from public.audit_events where workspace_id = tests.personal_ws(:'ana')), 0, 'B cannot read A''s personal audit trail');

-- Outsiders ----------------------------------------------------------------
select tests.login(:'eve');
select tests.eq((select count(*)::int from public.transactions), 0, 'an outsider reads no transactions');
select tests.eq((select count(*)::int from public.transaction_splits), 0, 'an outsider reads no splits');
select tests.eq((select count(*)::int from public.receipts), 0, 'an outsider reads no receipts');
select tests.eq((select count(*)::int from public.workspace_balances(:'casa')), 0, 'an outsider gets no balances by guessing the workspace id');
select tests.throws(format('select public.save_transaction(%L::jsonb)', tests.expense(:'casa', 1000, :'eve', jsonb_build_object(:'eve', 1000))),
  'forbidden_workspace', 'an outsider cannot write into the workspace');
select tests.throws(format('select public.create_invitation(%L)', :'casa'), 'admin_required', 'an outsider cannot create invitations');

-- No direct writes to the ledger, no role escalation -----------------------
select tests.login(:'bruno');
select tests.throws(format($q$insert into public.transactions (workspace_id, kind, description, occurred_on, currency, total_minor, split_method, client_request_id, created_by)
  values (%L, 'expense', 'x', current_date, 'COP', 1, 'single', gen_random_uuid(), %L)$q$, :'casa', :'bruno'), 'sqlstate:42501', 'direct INSERT into transactions is denied');
select tests.throws(format('update public.transaction_splits set amount_minor = 0 where transaction_id = %L', :'shared_tx'), 'sqlstate:42501', 'direct UPDATE of splits is denied');
select tests.throws(format('delete from public.transactions where id = %L', :'shared_tx'), 'sqlstate:42501', 'direct DELETE of transactions is denied');
select tests.throws(format('update public.workspace_members set role = %L where workspace_id = %L and user_id = %L', 'owner', :'casa', :'bruno'),
  'sqlstate:42501', 'a member cannot promote themselves by updating the table');
select tests.throws(format('insert into public.workspace_members (workspace_id, user_id, role) values (%L, %L, %L)', :'casa', :'eve', 'admin'),
  'sqlstate:42501', 'a member cannot add members directly');
select tests.throws(format('select public.change_member_role(%L, %L, %L)', :'casa', :'carla', 'admin'), 'admin_required', 'a member cannot change roles');
select tests.throws(format('select public.change_member_role(%L, %L, %L)', :'casa', :'bruno', 'admin'), 'cannot_change_own_role', 'nobody can change their own role');
select tests.throws(format('select public.create_invitation(%L, %L)', :'casa', 'member'), 'admin_required', 'a member cannot invite');
select tests.throws(format('insert into public.audit_events (entity_type, entity_id, action) values (%L, gen_random_uuid(), %L)', 'x', 'y'),
  'sqlstate:42501', 'clients cannot forge audit events');
select tests.throws(format('select public.admin_erase_user(%L)', :'ana'), 'sqlstate:42501', 'clients cannot call the server-only erase function');
select tests.throws(format('select public.save_transaction(%L::jsonb)', jsonb_set(tests.expense(:'casa', 1000, :'ana', jsonb_build_object(:'ana', 1000)),
  '{payments,0,account_id}', to_jsonb(:'ana_account'::text))), 'account_not_yours', 'nobody can attach another member''s account to a payment');

-- Viewer can read but not write --------------------------------------------
select tests.login(:'carla');
select tests.eq((select count(*)::int from public.transactions where id = :'shared_tx'), 1, 'a viewer can read shared expenses');
select tests.throws(format('select public.save_transaction(%L::jsonb)', tests.expense(:'casa', 1000, :'carla', jsonb_build_object(:'carla', 1000))),
  'forbidden_workspace', 'a viewer cannot create expenses');
select tests.throws(format('select public.record_settlement(%L::jsonb)', jsonb_build_object('client_request_id', gen_random_uuid(),
  'workspace_id', :'casa', 'from_user_id', :'carla', 'to_user_id', :'ana', 'amount_minor', 1, 'currency', 'COP')),
  'forbidden_workspace', 'a viewer cannot record settlements');

-- Admin rules --------------------------------------------------------------
select tests.login(:'ana');
select public.change_member_role(:'casa', :'bruno', 'admin');
select tests.login(:'bruno');
select tests.throws(format('select public.remove_member(%L, %L)', :'casa', :'ana'), 'cannot_remove_owner', 'an admin cannot remove the owner');
select tests.throws(format('select public.create_invitation(%L, %L)', :'casa', 'admin'), 'owner_required', 'only the owner can invite admins');
select tests.login(:'ana');
select public.change_member_role(:'casa', :'bruno', 'member');

-- Removing a member revokes access but keeps history -----------------------
select public.remove_member(:'casa', :'bruno');
select tests.login(:'bruno');
select tests.eq((select count(*)::int from public.transactions where workspace_id = :'casa'), 0, 'a removed member loses access to shared expenses');
select tests.eq((select count(*)::int from public.workspaces where id = :'casa'), 0, 'a removed member no longer sees the workspace');
select tests.throws(format('select public.save_transaction(%L::jsonb)', tests.expense(:'casa', 1000, :'bruno', jsonb_build_object(:'bruno', 1000))),
  'forbidden_workspace', 'a removed member cannot write');
select tests.login(:'ana');
select tests.eq((select net_minor from public.workspace_balances(:'casa') where user_id = :'bruno'), -45000::bigint,
  'the removed member''s debt remains in the history');
select tests.eq((select display_name from public.profiles where id = :'bruno'), 'Bruno', 'remaining members still see the former member''s name');
select tests.throws(format('select public.save_transaction(%L::jsonb)', tests.expense(:'casa', 2000, :'ana', jsonb_build_object(:'ana', 1000, :'bruno', 1000))),
  'participant_inactive', 'new expenses cannot be assigned to a former member');
select tests.eq((select count(*)::int from public.audit_events where workspace_id = :'casa' and action = 'removed'), 1, 'the removal is audited');

-- Storage: receipts bucket is reachable only by workspace members ---------
select tests.logout();
insert into storage.objects (bucket_id, name, owner) values ('receipts', :'casa' || '/' || gen_random_uuid() || '/factura.jpg', :'ana');
select tests.login(:'ana');
select tests.eq((select count(*)::int from storage.objects where bucket_id = 'receipts'), 1, 'a member can read the workspace receipts');
select tests.login(:'eve');
select tests.eq((select count(*)::int from storage.objects where bucket_id = 'receipts'), 0, 'an outsider cannot read receipt files even knowing the path');
select tests.throws(format('insert into storage.objects (bucket_id, name) values (%L, %L)', 'receipts', :'casa' || '/' || gen_random_uuid() || '/x.jpg'),
  'sqlstate:42501', 'an outsider cannot upload into another workspace folder');
select tests.login(:'bruno');
select tests.eq((select count(*)::int from storage.objects where bucket_id = 'receipts'), 0, 'a removed member cannot download receipts');

-- Anonymous role gets nothing ----------------------------------------------
select tests.login_anon();
select tests.throws('select count(*) from public.transactions', 'sqlstate:42501', 'anon cannot read transactions');
select tests.throws('select count(*) from public.profiles', 'sqlstate:42501', 'anon cannot read profiles');
select tests.throws(format('select public.workspace_balances(%L)', :'casa'), 'sqlstate:42501', 'anon cannot call RPCs');

select tests.logout();
rollback;
