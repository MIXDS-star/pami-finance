-- NEXO Finance · 0200 · Ledger: transactions, payments, splits, receipts and
-- settlements, plus integrity rules enforced at COMMIT time.
--
-- Accounting model (docs/DATA_MODEL.md#ledger):
--   transaction.total_minor           what was paid for the whole purchase
--   transaction_payments              who actually paid it (sum = total)
--   transaction_splits                who the expense belongs to (sum = total)
--   receipts / receipt_items          ONE original document with its lines
--   receipt_item_allocations          per-line assignment (sum = line total)
--   settlements                       reimbursements; never a new consumption
-- Balance of a member in a workspace (per currency):
--   net = paid - assigned + settlements_sent - settlements_received

create type public.transaction_kind as enum ('expense', 'income', 'transfer');
create type public.transaction_source as enum ('manual', 'text', 'voice', 'receipt', 'import', 'bank');
create type public.split_method as enum ('single', 'equal', 'percent', 'fixed', 'shares', 'mixed', 'by_item');
create type public.payment_method as enum ('cash', 'debit_card', 'credit_card', 'bank_transfer', 'digital_wallet', 'other');
create type public.extraction_status as enum ('manual', 'pending', 'completed', 'failed', 'not_configured');
create type public.receipt_line_kind as enum ('item', 'adjustment');

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  kind public.transaction_kind not null,
  description text not null check (char_length(btrim(description)) between 1 and 140),
  merchant text check (merchant is null or char_length(merchant) <= 120),
  occurred_on date not null,
  currency text not null references public.currencies(code),
  total_minor bigint not null check (total_minor > 0),
  category_id uuid references public.categories(id),
  split_method public.split_method,
  -- Exact parameters of the chosen rule so it can be edited and re-previewed.
  split_spec jsonb,
  notes text check (notes is null or char_length(notes) <= 2000),
  source public.transaction_source not null default 'manual',
  -- income: receiving account; transfer: origin account
  account_id uuid references public.accounts(id) on delete set null,
  -- transfer: destination account
  to_account_id uuid references public.accounts(id) on delete set null,
  import_job_id uuid,
  external_ref text,
  client_request_id uuid not null,
  created_by uuid not null references public.profiles(id),
  updated_by uuid references public.profiles(id),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (created_by, client_request_id),
  check ((kind = 'expense') = (split_method is not null)),
  check (kind <> 'transfer' or (account_id is not null and to_account_id is not null and account_id <> to_account_id))
);
create index transactions_ws_date_idx on public.transactions (workspace_id, occurred_on desc) where deleted_at is null;
create index transactions_category_idx on public.transactions (category_id);
create index transactions_dedupe_idx on public.transactions (workspace_id, total_minor, occurred_on) where deleted_at is null;
create trigger transactions_version before update on public.transactions
  for each row execute function private.bump_version();

create table public.transaction_payments (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.transactions(id) on delete cascade,
  payer_id uuid not null references public.profiles(id),
  -- Private to the payer: other members can see that X paid, never with which account.
  account_id uuid references public.accounts(id) on delete set null,
  method public.payment_method,
  amount_minor bigint not null check (amount_minor > 0),
  unique (transaction_id, payer_id)
);
create index transaction_payments_payer_idx on public.transaction_payments (payer_id);

create table public.transaction_splits (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null references public.transactions(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  amount_minor bigint not null check (amount_minor >= 0),
  unique (transaction_id, user_id)
);
create index transaction_splits_user_idx on public.transaction_splits (user_id);

create table public.receipts (
  id uuid primary key default gen_random_uuid(),
  transaction_id uuid not null unique references public.transactions(id) on delete cascade,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  storage_path text,
  mime_type text,
  merchant_name text,
  merchant_tax_id text,
  invoice_number text,
  issued_on date,
  currency text not null references public.currencies(code),
  -- Figures exactly as printed on the document (null = not printed / not read).
  printed_subtotal_minor bigint,
  printed_total_minor bigint,
  -- Document-level concepts applied on top of line totals.
  discount_minor bigint not null default 0 check (discount_minor >= 0),
  tax_minor bigint not null default 0 check (tax_minor >= 0),
  -- true: tax is already inside line prices (usual in Colombia, IVA incluido)
  -- and tax_minor is informational only; false: tax is added on top.
  taxes_included boolean not null default true,
  tip_minor bigint not null default 0 check (tip_minor >= 0),
  other_charges_minor bigint not null default 0 check (other_charges_minor >= 0),
  extraction_status public.extraction_status not null default 'manual',
  extraction_provider text,
  extraction_confidence numeric(4,3) check (extraction_confidence between 0 and 1),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index receipts_ws_idx on public.receipts (workspace_id);
create index receipts_invoice_idx on public.receipts (workspace_id, merchant_tax_id, invoice_number) where invoice_number is not null;
create trigger receipts_touch before update on public.receipts
  for each row execute function private.touch_updated_at();

create table public.receipt_items (
  id uuid primary key default gen_random_uuid(),
  receipt_id uuid not null references public.receipts(id) on delete cascade,
  position smallint not null check (position >= 0),
  kind public.receipt_line_kind not null default 'item',
  raw_text text check (raw_text is null or char_length(raw_text) <= 300),
  description text not null check (char_length(btrim(description)) between 1 and 140),
  quantity numeric(12,3) not null default 1 check (quantity > 0),
  unit_price_minor bigint,
  line_discount_minor bigint not null default 0 check (line_discount_minor >= 0),
  -- Source of truth for the line: what it costs after its own discount.
  line_total_minor bigint not null,
  category_id uuid references public.categories(id),
  confidence numeric(4,3) check (confidence between 0 and 1),
  allocation_method public.split_method not null default 'equal'
    check (allocation_method in ('single', 'equal', 'percent', 'fixed', 'shares')),
  allocation_spec jsonb,
  unique (receipt_id, position),
  check (kind = 'adjustment' or line_total_minor >= 0)
);

create table public.receipt_item_allocations (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.receipt_items(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  amount_minor bigint not null,
  unique (item_id, user_id)
);

create table public.settlements (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  from_user_id uuid not null references public.profiles(id),
  to_user_id uuid not null references public.profiles(id),
  amount_minor bigint not null check (amount_minor > 0),
  currency text not null references public.currencies(code),
  occurred_on date not null,
  method public.payment_method,
  note text check (note is null or char_length(note) <= 500),
  client_request_id uuid not null,
  created_by uuid not null references public.profiles(id),
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (created_by, client_request_id),
  check (from_user_id <> to_user_id)
);
create index settlements_ws_idx on public.settlements (workspace_id) where deleted_at is null;
create trigger settlements_version before update on public.settlements
  for each row execute function private.bump_version();

-- Optional link between a reimbursement and the expenses it covers.
create table public.settlement_allocations (
  id uuid primary key default gen_random_uuid(),
  settlement_id uuid not null references public.settlements(id) on delete cascade,
  transaction_id uuid not null references public.transactions(id) on delete cascade,
  amount_minor bigint not null check (amount_minor > 0),
  unique (settlement_id, transaction_id)
);

-- ---------------------------------------------------------------------------
-- Integrity (deferred: evaluated once the whole write is in place)
-- ---------------------------------------------------------------------------
create or replace function private.assert_transaction_integrity(p_tx uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare
  t public.transactions%rowtype;
  v_ws_kind public.workspace_kind;
  v_ws_owner uuid;
  v_paid bigint;
  v_split bigint;
  v_n_pay int;
  v_n_split int;
  r public.receipts%rowtype;
  v_items_total bigint;
  v_items int;
  v_expected bigint;
  v_bad_item uuid;
begin
  select * into t from public.transactions where id = p_tx;
  if not found or t.deleted_at is not null then
    return;
  end if;

  select kind, created_by into v_ws_kind, v_ws_owner from public.workspaces where id = t.workspace_id;

  select coalesce(sum(amount_minor), 0), count(*) into v_paid, v_n_pay
    from public.transaction_payments where transaction_id = p_tx;
  select coalesce(sum(amount_minor), 0), count(*) into v_split, v_n_split
    from public.transaction_splits where transaction_id = p_tx;

  if t.kind <> 'expense' then
    if v_n_pay > 0 or v_n_split > 0 then
      raise exception 'only expenses can have payments or splits' using errcode = 'PT422', hint = 'ledger_kind_mismatch';
    end if;
    if v_ws_kind <> 'personal' then
      raise exception 'income and transfers belong to the personal workspace' using errcode = 'PT422', hint = 'ledger_private_kind';
    end if;
    return;
  end if;

  if v_paid <> t.total_minor then
    raise exception 'payments (%) must equal total (%)', v_paid, t.total_minor using errcode = 'PT422', hint = 'ledger_payments_mismatch';
  end if;
  if v_split <> t.total_minor then
    raise exception 'splits (%) must equal total (%)', v_split, t.total_minor using errcode = 'PT422', hint = 'ledger_splits_mismatch';
  end if;

  if exists (
    select 1 from (
      select payer_id as uid from public.transaction_payments where transaction_id = p_tx
      union select user_id from public.transaction_splits where transaction_id = p_tx
    ) p
    where not exists (select 1 from public.workspace_members m where m.workspace_id = t.workspace_id and m.user_id = p.uid)
  ) then
    raise exception 'every payer and participant must belong to the workspace' using errcode = 'PT422', hint = 'ledger_foreign_participant';
  end if;

  if v_ws_kind = 'personal' and exists (
    select 1 from public.transaction_splits where transaction_id = p_tx and user_id <> v_ws_owner
    union all select 1 from public.transaction_payments where transaction_id = p_tx and payer_id <> v_ws_owner
  ) then
    raise exception 'personal expenses belong only to their owner' using errcode = 'PT422', hint = 'ledger_personal_foreign';
  end if;

  select * into r from public.receipts where transaction_id = p_tx;
  if found then
    if r.workspace_id <> t.workspace_id or r.currency <> t.currency then
      raise exception 'receipt must match the transaction workspace and currency' using errcode = 'PT422', hint = 'ledger_receipt_mismatch';
    end if;
    select coalesce(sum(line_total_minor), 0), count(*) into v_items_total, v_items
      from public.receipt_items where receipt_id = r.id;
    if v_items > 0 then
      v_expected := v_items_total - r.discount_minor + r.tip_minor + r.other_charges_minor
                    + case when r.taxes_included then 0 else r.tax_minor end;
      if v_expected <> t.total_minor then
        raise exception 'receipt lines add up to % but the total is % (difference %)', v_expected, t.total_minor, t.total_minor - v_expected
          using errcode = 'PT422', hint = 'ledger_receipt_unreconciled';
      end if;
      select i.id into v_bad_item
        from public.receipt_items i
        left join public.receipt_item_allocations a on a.item_id = i.id
        where i.receipt_id = r.id
        group by i.id, i.line_total_minor
        having (t.split_method = 'by_item' and count(a.id) = 0)
            or (count(a.id) > 0 and coalesce(sum(a.amount_minor), 0) <> i.line_total_minor)
        limit 1;
      if v_bad_item is not null then
        raise exception 'line % allocations must add up to its total', v_bad_item using errcode = 'PT422', hint = 'ledger_item_allocation_mismatch';
      end if;
      if exists (
        select 1 from public.receipt_item_allocations a
        join public.receipt_items i on i.id = a.item_id
        where i.receipt_id = r.id
          and not exists (select 1 from public.transaction_splits s where s.transaction_id = p_tx and s.user_id = a.user_id)
      ) then
        raise exception 'line allocations reference someone without a split' using errcode = 'PT422', hint = 'ledger_item_allocation_orphan';
      end if;
    end if;
  end if;
end $$;

create or replace function private.trg_tx_integrity() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform private.assert_transaction_integrity(old.id);
  else
    perform private.assert_transaction_integrity(new.id);
  end if;
  return null;
end $$;

create or replace function private.trg_tx_child_integrity() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform private.assert_transaction_integrity(old.transaction_id);
  else
    perform private.assert_transaction_integrity(new.transaction_id);
  end if;
  return null;
end $$;

create or replace function private.trg_receipt_item_integrity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_receipt uuid;
begin
  v_receipt := case when tg_op = 'DELETE' then old.receipt_id else new.receipt_id end;
  perform private.assert_transaction_integrity((select transaction_id from public.receipts where id = v_receipt));
  return null;
end $$;

create or replace function private.trg_receipt_alloc_integrity() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_item uuid;
begin
  v_item := case when tg_op = 'DELETE' then old.item_id else new.item_id end;
  perform private.assert_transaction_integrity((
    select r.transaction_id from public.receipt_items i join public.receipts r on r.id = i.receipt_id where i.id = v_item));
  return null;
end $$;

create constraint trigger transactions_integrity after insert or update on public.transactions
  deferrable initially deferred for each row execute function private.trg_tx_integrity();
create constraint trigger transaction_payments_integrity after insert or update or delete on public.transaction_payments
  deferrable initially deferred for each row execute function private.trg_tx_child_integrity();
create constraint trigger transaction_splits_integrity after insert or update or delete on public.transaction_splits
  deferrable initially deferred for each row execute function private.trg_tx_child_integrity();
create constraint trigger receipts_integrity after insert or update on public.receipts
  deferrable initially deferred for each row execute function private.trg_tx_child_integrity();
create constraint trigger receipt_items_integrity after insert or update or delete on public.receipt_items
  deferrable initially deferred for each row execute function private.trg_receipt_item_integrity();
create constraint trigger receipt_item_allocations_integrity after insert or update or delete on public.receipt_item_allocations
  deferrable initially deferred for each row execute function private.trg_receipt_alloc_integrity();

create or replace function private.assert_settlement_integrity() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.workspace_members where workspace_id = new.workspace_id and user_id = new.from_user_id)
     or not exists (select 1 from public.workspace_members where workspace_id = new.workspace_id and user_id = new.to_user_id) then
    raise exception 'both parties must belong to the workspace' using errcode = 'PT422', hint = 'settlement_foreign_party';
  end if;
  if (select kind from public.workspaces where id = new.workspace_id) = 'personal' then
    raise exception 'settlements only exist in shared workspaces' using errcode = 'PT422', hint = 'settlement_personal';
  end if;
  return null;
end $$;

create constraint trigger settlements_integrity after insert or update on public.settlements
  deferrable initially deferred for each row execute function private.assert_settlement_integrity();
