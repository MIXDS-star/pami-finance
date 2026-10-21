-- NEXO Finance · 0600 · Ledger write RPCs.
--
-- public.save_transaction is the ONLY write path for expenses, income and
-- transfers, whatever the capture method (manual, text, voice, receipt,
-- import). The app computes allocations with the shared Dart engine
-- (app/lib/core/finance) for preview; the database re-validates every
-- invariant at commit (0200) so a buggy or malicious client cannot persist an
-- unbalanced ledger.
--
-- Payload (jsonb):
-- {
--   "id": uuid|null, "expected_version": int|null, "client_request_id": uuid,
--   "workspace_id": uuid, "kind": "expense"|"income"|"transfer",
--   "description": text, "merchant": text?, "occurred_on": "YYYY-MM-DD",
--   "currency": "COP", "total_minor": int, "category_id": uuid?, "notes": text?,
--   "source": "manual"|..., "account_id": uuid?, "to_account_id": uuid?,
--   "split_method": "...", "split_spec": {...},
--   "payments": [{"payer_id", "account_id"?, "method"?, "amount_minor"}],
--   "splits":   [{"user_id", "amount_minor"}],
--   "receipt":  null | { ...header..., "items": [{..., "allocations": [{"user_id","amount_minor"}]}] }
-- }
-- Omitting "receipt" keeps the stored receipt; "receipt": null removes it.

create or replace function private.tx_snapshot(p_tx uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'description', t.description,
    'merchant', t.merchant,
    'occurred_on', t.occurred_on,
    'currency', t.currency,
    'total_minor', t.total_minor,
    'category_id', t.category_id,
    'split_method', t.split_method,
    'has_notes', t.notes is not null,
    'payments', coalesce((select jsonb_object_agg(payer_id, amount_minor) from public.transaction_payments where transaction_id = t.id), '{}'::jsonb),
    'splits', coalesce((select jsonb_object_agg(user_id, amount_minor) from public.transaction_splits where transaction_id = t.id), '{}'::jsonb),
    'receipt_lines', (select count(*) from public.receipt_items i join public.receipts r on r.id = i.receipt_id where r.transaction_id = t.id)
  )
  from public.transactions t where t.id = p_tx;
$$;

create or replace function private.jsonb_diff(p_before jsonb, p_after jsonb) returns jsonb
language sql immutable set search_path = '' as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_object('from', p_before -> k, 'to', p_after -> k)), '{}'::jsonb)
  from (select jsonb_object_keys(coalesce(p_before, '{}'::jsonb) || coalesce(p_after, '{}'::jsonb)) k) keys
  where (p_before -> k) is distinct from (p_after -> k);
$$;

create or replace function private.validation_error(p_code text, p_message text default 'invalid input') returns void
language plpgsql set search_path = '' as $$
begin
  raise exception '%', p_message using errcode = 'PT422', hint = p_code;
end $$;

-- A person may be referenced if they are an active member, or if they already
-- appeared in this transaction before the edit (keeps history editable after
-- someone leaves without letting new movements target former members).
create or replace function private.assert_participant(p_workspace uuid, p_user uuid, p_before jsonb) returns void
language plpgsql stable security definer set search_path = '' as $$
declare v_status public.member_status;
begin
  select status into v_status from public.workspace_members where workspace_id = p_workspace and user_id = p_user;
  if v_status is null then
    perform private.validation_error('participant_not_member', 'participant is not a member of this workspace');
  end if;
  if v_status <> 'active'
     and not (coalesce(p_before -> 'splits', '{}'::jsonb) ? p_user::text or coalesce(p_before -> 'payments', '{}'::jsonb) ? p_user::text) then
    perform private.validation_error('participant_inactive', 'participant is no longer an active member');
  end if;
end $$;

create or replace function public.save_transaction(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  v_id uuid := private.try_uuid(p ->> 'id');
  v_req uuid := private.try_uuid(p ->> 'client_request_id');
  v_ws uuid := private.try_uuid(p ->> 'workspace_id');
  v_kind public.transaction_kind;
  v_ws_row public.workspaces%rowtype;
  v_old public.transactions%rowtype;
  v_tx public.transactions%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_category uuid := private.try_uuid(p ->> 'category_id');
  v_account uuid := private.try_uuid(p ->> 'account_id');
  v_to_account uuid := private.try_uuid(p ->> 'to_account_id');
  v_cat_kind public.category_kind;
  v_cat_ws uuid;
  v_total bigint;
  v_date date;
  v_receipt jsonb;
  v_receipt_id uuid;
  v_item jsonb;
  v_alloc jsonb;
  v_item_id uuid;
  v_pay jsonb;
  v_split jsonb;
  v_payer uuid;
  v_pay_account uuid;
  v_old_pay_account uuid;
  v_pos integer := 0;
begin
  -- Invariants are checked once the whole write is in place (see the end).
  set constraints all deferred;
  begin
    v_kind := coalesce(p ->> 'kind', 'expense')::public.transaction_kind;
    v_total := (p ->> 'total_minor')::bigint;
    v_date := (p ->> 'occurred_on')::date;
  exception when others then
    perform private.validation_error('payload_invalid', 'kind, total_minor or occurred_on are invalid');
  end;
  if v_req is null then perform private.validation_error('client_request_id_required'); end if;
  if v_ws is null then perform private.validation_error('workspace_required'); end if;
  if v_total is null or v_total <= 0 then perform private.validation_error('amount_positive', 'amount must be greater than zero'); end if;
  if v_total > 1000000000000000 then perform private.validation_error('amount_too_large'); end if;
  if v_date is null then perform private.validation_error('date_required'); end if;
  if v_date > (now() at time zone 'America/Bogota')::date + 366 or v_date < date '1990-01-01' then
    perform private.validation_error('date_out_of_range');
  end if;
  if nullif(btrim(p ->> 'description'), '') is null then perform private.validation_error('description_required'); end if;
  if not exists (select 1 from public.currencies where code = p ->> 'currency') then
    perform private.validation_error('currency_unknown');
  end if;

  select * into v_ws_row from public.workspaces where id = v_ws;
  if not found or not private.can_write(v_ws) then perform private.forbid('forbidden_workspace'); end if;

  if v_id is null then
    -- Idempotent create: a retried request returns the original row.
    select * into v_old from public.transactions where created_by = v_uid and client_request_id = v_req;
    if found then
      return jsonb_build_object('id', v_old.id, 'version', v_old.version, 'replayed', true);
    end if;
  else
    select * into v_old from public.transactions where id = v_id for update;
    if not found or not private.can_write(v_old.workspace_id) then perform private.forbid('forbidden_transaction'); end if;
    if v_old.deleted_at is not null then
      raise exception 'transaction was deleted' using errcode = 'PT409', hint = 'transaction_deleted';
    end if;
    if v_old.workspace_id <> v_ws then perform private.validation_error('workspace_change_not_supported'); end if;
    if v_old.kind <> v_kind then perform private.validation_error('kind_change_not_supported'); end if;
    if (p ->> 'expected_version')::integer is distinct from v_old.version then
      raise exception 'transaction changed since it was loaded (current version %)', v_old.version
        using errcode = 'PT409', hint = 'version_conflict', detail = v_old.version::text;
    end if;
    v_before := private.tx_snapshot(v_id);
  end if;

  if v_category is not null then
    select kind, workspace_id into v_cat_kind, v_cat_ws from public.categories where id = v_category and archived_at is null;
    if v_cat_kind is null or (v_cat_ws is not null and v_cat_ws <> v_ws) then
      perform private.validation_error('category_invalid');
    end if;
    if (v_kind = 'expense' and v_cat_kind <> 'expense') or (v_kind = 'income' and v_cat_kind <> 'income') then
      perform private.validation_error('category_kind_mismatch');
    end if;
  end if;

  if v_kind in ('income', 'transfer') then
    if v_ws_row.kind <> 'personal' then perform private.validation_error('ledger_private_kind', 'income and transfers belong to the personal workspace'); end if;
    if v_account is not null and not exists (select 1 from public.accounts where id = v_account and owner_id = v_uid) then
      perform private.validation_error('account_invalid');
    end if;
    if v_kind = 'transfer' then
      if v_account is null or v_to_account is null or v_account = v_to_account
         or not exists (select 1 from public.accounts where id = v_to_account and owner_id = v_uid) then
        perform private.validation_error('transfer_accounts_invalid');
      end if;
      if exists (select 1 from public.accounts where id in (v_account, v_to_account) and currency <> p ->> 'currency') then
        perform private.validation_error('transfer_currency_mismatch');
      end if;
    else
      v_to_account := null;
    end if;
  else
    v_account := null;
    v_to_account := null;
    if jsonb_typeof(p -> 'payments') <> 'array' or jsonb_array_length(p -> 'payments') = 0 then
      perform private.validation_error('payer_required');
    end if;
    if jsonb_typeof(p -> 'splits') <> 'array' or jsonb_array_length(p -> 'splits') = 0 then
      perform private.validation_error('participants_required');
    end if;
    begin
      perform (p ->> 'split_method')::public.split_method;
    exception when others then
      perform private.validation_error('split_method_invalid');
    end;
    if p ->> 'split_method' is null then perform private.validation_error('split_method_invalid'); end if;
  end if;

  if v_id is null then
    insert into public.transactions (workspace_id, kind, description, merchant, occurred_on, currency, total_minor,
      category_id, split_method, split_spec, notes, source, account_id, to_account_id, client_request_id, created_by, updated_by)
    values (v_ws, v_kind, btrim(p ->> 'description'), nullif(btrim(p ->> 'merchant'), ''), v_date, p ->> 'currency', v_total,
      v_category, case when v_kind = 'expense' then (p ->> 'split_method')::public.split_method end,
      case when v_kind = 'expense' then p -> 'split_spec' end,
      nullif(btrim(p ->> 'notes'), ''), coalesce(p ->> 'source', 'manual')::public.transaction_source,
      v_account, v_to_account, v_req, v_uid, v_uid)
    returning * into v_tx;
  else
    update public.transactions set
      description = btrim(p ->> 'description'), merchant = nullif(btrim(p ->> 'merchant'), ''), occurred_on = v_date,
      currency = p ->> 'currency', total_minor = v_total, category_id = v_category,
      split_method = case when v_kind = 'expense' then (p ->> 'split_method')::public.split_method end,
      split_spec = case when v_kind = 'expense' then p -> 'split_spec' end,
      notes = nullif(btrim(p ->> 'notes'), ''), account_id = v_account, to_account_id = v_to_account, updated_by = v_uid
    where id = v_id returning * into v_tx;
  end if;

  if v_kind = 'expense' then
    -- Payments: who paid. Only the payer can attach one of their own accounts;
    -- other editors keep whatever account the payer had chosen.
    create temporary table if not exists _old_payments (payer_id uuid primary key, account_id uuid) on commit drop;
    truncate _old_payments;
    insert into _old_payments select payer_id, account_id from public.transaction_payments where transaction_id = v_tx.id;
    delete from public.transaction_payments where transaction_id = v_tx.id;

    for v_pay in select * from jsonb_array_elements(p -> 'payments') loop
      v_payer := private.try_uuid(v_pay ->> 'payer_id');
      if v_payer is null then perform private.validation_error('payer_required'); end if;
      perform private.assert_participant(v_ws, v_payer, v_before);
      v_pay_account := private.try_uuid(v_pay ->> 'account_id');
      v_old_pay_account := null;
      select account_id into v_old_pay_account from _old_payments where payer_id = v_payer;
      if v_payer = v_uid then
        if v_pay_account is not null and not exists (select 1 from public.accounts where id = v_pay_account and owner_id = v_uid) then
          perform private.validation_error('account_invalid');
        end if;
      else
        if v_pay_account is not null and v_pay_account is distinct from v_old_pay_account then
          perform private.validation_error('account_not_yours', 'only the payer can choose their account');
        end if;
        v_pay_account := v_old_pay_account;
      end if;
      begin
        insert into public.transaction_payments (transaction_id, payer_id, account_id, method, amount_minor)
        values (v_tx.id, v_payer, v_pay_account, (v_pay ->> 'method')::public.payment_method, (v_pay ->> 'amount_minor')::bigint);
      exception
        when unique_violation then perform private.validation_error('payer_duplicated');
        when check_violation or invalid_text_representation or numeric_value_out_of_range then
          perform private.validation_error('payment_invalid');
      end;
    end loop;

    delete from public.transaction_splits where transaction_id = v_tx.id;
    for v_split in select * from jsonb_array_elements(p -> 'splits') loop
      if private.try_uuid(v_split ->> 'user_id') is null then perform private.validation_error('participants_required'); end if;
      perform private.assert_participant(v_ws, (v_split ->> 'user_id')::uuid, v_before);
      begin
        insert into public.transaction_splits (transaction_id, user_id, amount_minor)
        values (v_tx.id, (v_split ->> 'user_id')::uuid, (v_split ->> 'amount_minor')::bigint);
      exception
        when unique_violation then perform private.validation_error('participant_duplicated');
        when check_violation or invalid_text_representation or numeric_value_out_of_range then
          perform private.validation_error('split_invalid');
      end;
    end loop;

    -- Receipt: one original document with its lines, never copied per person.
    if p ? 'receipt' then
      v_receipt := p -> 'receipt';
      if v_receipt is null or jsonb_typeof(v_receipt) = 'null' then
        delete from public.receipts where transaction_id = v_tx.id;
      else
        insert into public.receipts (transaction_id, workspace_id, storage_path, mime_type, merchant_name, merchant_tax_id,
          invoice_number, issued_on, currency, printed_subtotal_minor, printed_total_minor, discount_minor, tax_minor,
          taxes_included, tip_minor, other_charges_minor, extraction_status, extraction_provider, extraction_confidence, created_by)
        values (v_tx.id, v_ws, nullif(v_receipt ->> 'storage_path', ''), v_receipt ->> 'mime_type',
          nullif(btrim(v_receipt ->> 'merchant_name'), ''), nullif(btrim(v_receipt ->> 'merchant_tax_id'), ''),
          nullif(btrim(v_receipt ->> 'invoice_number'), ''), (v_receipt ->> 'issued_on')::date, v_tx.currency,
          (v_receipt ->> 'printed_subtotal_minor')::bigint, (v_receipt ->> 'printed_total_minor')::bigint,
          coalesce((v_receipt ->> 'discount_minor')::bigint, 0), coalesce((v_receipt ->> 'tax_minor')::bigint, 0),
          coalesce((v_receipt ->> 'taxes_included')::boolean, true), coalesce((v_receipt ->> 'tip_minor')::bigint, 0),
          coalesce((v_receipt ->> 'other_charges_minor')::bigint, 0),
          coalesce(v_receipt ->> 'extraction_status', 'manual')::public.extraction_status,
          v_receipt ->> 'extraction_provider', (v_receipt ->> 'extraction_confidence')::numeric, v_uid)
        on conflict (transaction_id) do update set
          storage_path = excluded.storage_path, mime_type = excluded.mime_type, merchant_name = excluded.merchant_name,
          merchant_tax_id = excluded.merchant_tax_id, invoice_number = excluded.invoice_number, issued_on = excluded.issued_on,
          currency = excluded.currency, printed_subtotal_minor = excluded.printed_subtotal_minor,
          printed_total_minor = excluded.printed_total_minor, discount_minor = excluded.discount_minor,
          tax_minor = excluded.tax_minor, taxes_included = excluded.taxes_included, tip_minor = excluded.tip_minor,
          other_charges_minor = excluded.other_charges_minor, extraction_status = excluded.extraction_status,
          extraction_provider = excluded.extraction_provider, extraction_confidence = excluded.extraction_confidence
        returning id into v_receipt_id;

        if v_receipt ->> 'storage_path' is not null
           and private.try_uuid(split_part(v_receipt ->> 'storage_path', '/', 1)) is distinct from v_ws then
          perform private.validation_error('receipt_path_invalid');
        end if;

        delete from public.receipt_items where receipt_id = v_receipt_id;
        for v_item in select * from jsonb_array_elements(coalesce(v_receipt -> 'items', '[]'::jsonb)) loop
          if private.try_uuid(v_item ->> 'category_id') is not null and not exists (
            select 1 from public.categories where id = (v_item ->> 'category_id')::uuid and kind = 'expense'
              and (workspace_id is null or workspace_id = v_ws)) then
            perform private.validation_error('category_invalid');
          end if;
          begin
            insert into public.receipt_items (receipt_id, position, kind, raw_text, description, quantity, unit_price_minor,
              line_discount_minor, line_total_minor, category_id, confidence, allocation_method, allocation_spec)
            values (v_receipt_id, v_pos, coalesce(v_item ->> 'kind', 'item')::public.receipt_line_kind,
              left(v_item ->> 'raw_text', 300), btrim(v_item ->> 'description'), coalesce((v_item ->> 'quantity')::numeric, 1),
              (v_item ->> 'unit_price_minor')::bigint, coalesce((v_item ->> 'line_discount_minor')::bigint, 0),
              (v_item ->> 'line_total_minor')::bigint, private.try_uuid(v_item ->> 'category_id'),
              (v_item ->> 'confidence')::numeric, coalesce(v_item ->> 'allocation_method', 'equal')::public.split_method,
              v_item -> 'allocation_spec')
            returning id into v_item_id;
          exception when check_violation or not_null_violation or invalid_text_representation
                         or numeric_value_out_of_range or invalid_parameter_value then
            perform private.validation_error('receipt_line_invalid', 'receipt line ' || v_pos || ' is invalid');
          end;
          for v_alloc in select * from jsonb_array_elements(coalesce(v_item -> 'allocations', '[]'::jsonb)) loop
            begin
              insert into public.receipt_item_allocations (item_id, user_id, amount_minor)
              values (v_item_id, (v_alloc ->> 'user_id')::uuid, (v_alloc ->> 'amount_minor')::bigint);
            exception
              when unique_violation then perform private.validation_error('participant_duplicated');
              when others then perform private.validation_error('receipt_allocation_invalid');
            end;
          end loop;
          v_pos := v_pos + 1;
        end loop;
      end if;
    end if;
  end if;

  -- Evaluate the deferred ledger invariants now so violations surface as a
  -- regular, translatable error instead of a failed COMMIT.
  set constraints all immediate;

  v_after := private.tx_snapshot(v_tx.id);
  perform private.audit(v_ws, 'transaction', v_tx.id, case when v_id is null then 'created' else 'updated' end,
    case when v_id is null then jsonb_build_object('after', v_after) else private.jsonb_diff(v_before, v_after) end);

  -- In-app notification for the other participants of shared expenses.
  if v_ws_row.kind <> 'personal' and v_kind = 'expense' then
    insert into public.notifications (user_id, workspace_id, kind, title, entity_type, entity_id)
    select s.user_id, v_ws, case when v_id is null then 'shared_expense_created' else 'shared_expense_updated' end,
           case when v_id is null then 'Nuevo gasto compartido en ' else 'Gasto actualizado en ' end || v_ws_row.name,
           'transaction', v_tx.id
    from public.transaction_splits s
    join public.workspace_members m on m.workspace_id = v_ws and m.user_id = s.user_id and m.status = 'active'
    join public.user_preferences up on up.user_id = s.user_id
    where s.transaction_id = v_tx.id and s.user_id <> v_uid
      and coalesce((up.notification_settings ->> 'shared_expenses')::boolean, true);
  end if;

  return jsonb_build_object('id', v_tx.id, 'version', (select version from public.transactions where id = v_tx.id), 'replayed', false);
end $$;

-- Soft delete: the row stays for audit/history but stops counting anywhere.
create or replace function public.delete_transaction(p_id uuid, p_expected_version integer)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  t public.transactions%rowtype;
begin
  select * into t from public.transactions where id = p_id for update;
  if not found or not private.can_write(t.workspace_id) then perform private.forbid('forbidden_transaction'); end if;
  if t.created_by <> v_uid and not private.can_admin(t.workspace_id) then perform private.forbid('creator_or_admin_required'); end if;
  if t.deleted_at is not null then return; end if;
  if t.version <> p_expected_version then
    raise exception 'transaction changed' using errcode = 'PT409', hint = 'version_conflict', detail = t.version::text;
  end if;
  update public.transactions set deleted_at = now(), deleted_by = v_uid, updated_by = v_uid where id = p_id;
  update public.scheduled_occurrences set status = 'scheduled', transaction_id = null, resolved_by = null, resolved_at = null
  where transaction_id = p_id;
  perform private.audit(t.workspace_id, 'transaction', p_id, 'deleted', jsonb_build_object('before', private.tx_snapshot(p_id)));
end $$;

create or replace function public.restore_transaction(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  t public.transactions%rowtype;
begin
  select * into t from public.transactions where id = p_id for update;
  if not found or not private.can_write(t.workspace_id) then perform private.forbid('forbidden_transaction'); end if;
  if t.created_by <> v_uid and not private.can_admin(t.workspace_id) then perform private.forbid('creator_or_admin_required'); end if;
  update public.transactions set deleted_at = null, deleted_by = null, updated_by = v_uid where id = p_id;
  perform private.audit(t.workspace_id, 'transaction', p_id, 'restored', '{}'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Settlements (reimbursements between members; never a consumption expense)
-- ---------------------------------------------------------------------------
create or replace function public.record_settlement(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  v_ws uuid := private.try_uuid(p ->> 'workspace_id');
  v_from uuid := private.try_uuid(p ->> 'from_user_id');
  v_to uuid := private.try_uuid(p ->> 'to_user_id');
  v_req uuid := private.try_uuid(p ->> 'client_request_id');
  v_amount bigint;
  s public.settlements%rowtype;
  v_alloc jsonb;
begin
  set constraints all deferred;
  begin
    v_amount := (p ->> 'amount_minor')::bigint;
  exception when others then perform private.validation_error('amount_positive'); end;
  if v_req is null then perform private.validation_error('client_request_id_required'); end if;
  if v_amount is null or v_amount <= 0 then perform private.validation_error('amount_positive'); end if;
  if v_ws is null or not private.can_write(v_ws) then perform private.forbid('forbidden_workspace'); end if;
  if v_from is null or v_to is null or v_from = v_to then perform private.validation_error('settlement_parties_invalid'); end if;
  if v_uid not in (v_from, v_to) and not private.can_admin(v_ws) then perform private.forbid('settlement_party_required'); end if;
  if not exists (select 1 from public.currencies where code = p ->> 'currency') then perform private.validation_error('currency_unknown'); end if;

  select * into s from public.settlements where created_by = v_uid and client_request_id = v_req;
  if found then
    return jsonb_build_object('id', s.id, 'replayed', true);
  end if;

  insert into public.settlements (workspace_id, from_user_id, to_user_id, amount_minor, currency, occurred_on, method, note, client_request_id, created_by)
  values (v_ws, v_from, v_to, v_amount, p ->> 'currency', coalesce((p ->> 'occurred_on')::date, (now() at time zone 'America/Bogota')::date),
          (p ->> 'method')::public.payment_method, nullif(btrim(p ->> 'note'), ''), v_req, v_uid)
  returning * into s;

  for v_alloc in select * from jsonb_array_elements(coalesce(p -> 'allocations', '[]'::jsonb)) loop
    if private.tx_workspace((v_alloc ->> 'transaction_id')::uuid) is distinct from v_ws then
      perform private.validation_error('settlement_allocation_invalid');
    end if;
    insert into public.settlement_allocations (settlement_id, transaction_id, amount_minor)
    values (s.id, (v_alloc ->> 'transaction_id')::uuid, (v_alloc ->> 'amount_minor')::bigint);
  end loop;
  set constraints all immediate;

  perform private.audit(v_ws, 'settlement', s.id, 'created',
    jsonb_build_object('from', v_from, 'to', v_to, 'amount_minor', v_amount, 'currency', s.currency));
  insert into public.notifications (user_id, workspace_id, kind, title, entity_type, entity_id)
  select u, v_ws, 'settlement_recorded', 'Se registró un reembolso', 'settlement', s.id
  from unnest(array[v_from, v_to]) u where u <> v_uid;
  return jsonb_build_object('id', s.id, 'replayed', false);
end $$;

create or replace function public.delete_settlement(p_id uuid, p_expected_version integer)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.require_uid();
  s public.settlements%rowtype;
begin
  select * into s from public.settlements where id = p_id for update;
  if not found or not private.can_write(s.workspace_id) then perform private.forbid('forbidden_workspace'); end if;
  if s.created_by <> v_uid and not private.can_admin(s.workspace_id) then perform private.forbid('creator_or_admin_required'); end if;
  if s.deleted_at is not null then return; end if;
  if s.version <> p_expected_version then
    raise exception 'settlement changed' using errcode = 'PT409', hint = 'version_conflict';
  end if;
  update public.settlements set deleted_at = now(), deleted_by = v_uid where id = p_id;
  perform private.audit(s.workspace_id, 'settlement', p_id, 'deleted', jsonb_build_object('amount_minor', s.amount_minor));
end $$;

-- ---------------------------------------------------------------------------
-- Balances: the single source of truth for "who owes whom", per currency.
-- ---------------------------------------------------------------------------
create or replace function public.workspace_balances(p_workspace uuid)
returns table (user_id uuid, currency text, paid_minor bigint, assigned_minor bigint,
               sent_minor bigint, received_minor bigint, net_minor bigint)
language sql stable security invoker set search_path = '' as $$
  with tx as (
    select id, currency from public.transactions
    where workspace_id = p_workspace and kind = 'expense' and deleted_at is null
  ),
  paid as (select p.payer_id as uid, tx.currency, sum(p.amount_minor) as amt
           from public.transaction_payments p join tx on tx.id = p.transaction_id group by 1, 2),
  assigned as (select s.user_id as uid, tx.currency, sum(s.amount_minor) as amt
               from public.transaction_splits s join tx on tx.id = s.transaction_id group by 1, 2),
  sent as (select from_user_id as uid, s.currency, sum(amount_minor) as amt from public.settlements s
           where workspace_id = p_workspace and deleted_at is null group by 1, 2),
  received as (select to_user_id as uid, s.currency, sum(amount_minor) as amt from public.settlements s
               where workspace_id = p_workspace and deleted_at is null group by 1, 2),
  keys as (select uid, currency from paid union select uid, currency from assigned
           union select uid, currency from sent union select uid, currency from received)
  select k.uid, k.currency,
         coalesce(paid.amt, 0)::bigint, coalesce(assigned.amt, 0)::bigint,
         coalesce(sent.amt, 0)::bigint, coalesce(received.amt, 0)::bigint,
         (coalesce(paid.amt, 0) - coalesce(assigned.amt, 0) + coalesce(sent.amt, 0) - coalesce(received.amt, 0))::bigint
  from keys k
  left join paid on paid.uid = k.uid and paid.currency = k.currency
  left join assigned on assigned.uid = k.uid and assigned.currency = k.currency
  left join sent on sent.uid = k.uid and sent.currency = k.currency
  left join received on received.uid = k.uid and received.currency = k.currency
  where private.is_member(p_workspace)
  order by k.currency, k.uid;
$$;

-- Possible duplicates: scored hints, never a hard block.
create or replace function public.find_possible_duplicates(
  p_workspace uuid, p_total_minor bigint, p_occurred_on date,
  p_merchant text default null, p_invoice_number text default null, p_exclude uuid default null)
returns table (transaction_id uuid, description text, occurred_on date, total_minor bigint, score integer, reasons text[])
language sql stable security invoker set search_path = '' as $$
  with c as (
    select t.id, t.description, t.occurred_on, t.total_minor, t.merchant, r.invoice_number
    from public.transactions t
    left join public.receipts r on r.transaction_id = t.id
    where t.workspace_id = p_workspace and t.deleted_at is null and t.kind = 'expense'
      and (p_exclude is null or t.id <> p_exclude)
      and ((t.total_minor = p_total_minor and t.occurred_on between p_occurred_on - 3 and p_occurred_on + 3)
           or (p_invoice_number is not null and r.invoice_number = btrim(p_invoice_number)))
  ), scored as (
    select c.*,
      (case when c.total_minor = p_total_minor then 40 else 0 end
       + case when c.occurred_on = p_occurred_on then 25 when abs(c.occurred_on - p_occurred_on) <= 3 then 10 else 0 end
       + case when p_merchant is not null and lower(btrim(coalesce(c.merchant, c.description))) = lower(btrim(p_merchant)) then 20 else 0 end
       + case when p_invoice_number is not null and c.invoice_number = btrim(p_invoice_number) then 60 else 0 end) as score,
      array_remove(array[
        case when c.total_minor = p_total_minor then 'same_amount' end,
        case when c.occurred_on = p_occurred_on then 'same_date' when abs(c.occurred_on - p_occurred_on) <= 3 then 'near_date' end,
        case when p_merchant is not null and lower(btrim(coalesce(c.merchant, c.description))) = lower(btrim(p_merchant)) then 'same_merchant' end,
        case when p_invoice_number is not null and c.invoice_number = btrim(p_invoice_number) then 'same_invoice' end], null) as reasons
    from c
  )
  select id, description, occurred_on, total_minor, score, reasons from scored
  where score >= 50 and private.is_member(p_workspace)
  order by score desc, occurred_on desc limit 5;
$$;
