-- Pami Finance: todas las migraciones en un solo archivo, para pegar en el SQL Editor
-- de un proyecto Supabase NUEVO. Generado desde supabase/migrations (no editar a mano).

-- ===================== 20261021000100_core.sql =====================
-- Pami Finance · 0100 · Core identity, workspaces, categories and accounts.
--
-- Conventions (see docs/DATA_MODEL.md):
--   * Money is stored as BIGINT in the currency's minor unit (`*_minor`).
--     COP is configured with 0 decimals, so 280.000 COP is stored as 280000.
--   * Every user reference points to public.profiles(id), which survives account
--     deletion as an anonymised record so shared history stays consistent.
--   * Financial rows are soft-deleted (`deleted_at`) and carry `version` for
--     optimistic concurrency.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists citext with schema extensions;

create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Enumerations
-- ---------------------------------------------------------------------------
create type public.workspace_kind as enum ('personal', 'household', 'couple', 'friends', 'trip', 'other');
create type public.member_role as enum ('owner', 'admin', 'member', 'viewer');
create type public.member_status as enum ('active', 'left', 'removed');
create type public.category_kind as enum ('expense', 'income');
create type public.account_type as enum ('cash', 'bank', 'credit_card', 'wallet', 'other');
create type public.theme_preference as enum ('system', 'light', 'dark');
create type public.income_frequency as enum ('monthly', 'biweekly', 'weekly', 'irregular');

-- ---------------------------------------------------------------------------
-- Generic triggers
-- ---------------------------------------------------------------------------
create or replace function private.touch_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function private.bump_version() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.version := old.version + 1;
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- Currencies (reference data, not demo data)
-- ---------------------------------------------------------------------------
create table public.currencies (
  code text primary key check (code ~ '^[A-Z]{3}$'),
  name text not null,
  symbol text not null,
  -- Number of decimals used by Pami for this currency. COP deliberately uses
  -- 0 (centavos are not used in practice); ISO 4217 lists 2.
  minor_unit smallint not null check (minor_unit between 0 and 4)
);

insert into public.currencies (code, name, symbol, minor_unit) values
  ('COP', 'Peso colombiano', '$', 0),
  ('USD', 'Dólar estadounidense', 'US$', 2),
  ('EUR', 'Euro', '€', 2),
  ('MXN', 'Peso mexicano', 'MX$', 2);

-- ---------------------------------------------------------------------------
-- Profiles & preferences
-- ---------------------------------------------------------------------------
-- Only what co-members may see lives in profiles. Everything else is in
-- user_preferences, which is strictly self-only.
create table public.profiles (
  id uuid primary key,  -- = auth.users.id (no FK: survives account deletion, see docs)
  display_name text not null check (char_length(btrim(display_name)) between 1 and 60),
  avatar_url text,
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();

create table public.user_preferences (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  country_code text not null default 'CO' check (country_code ~ '^[A-Z]{2}$'),
  default_currency text not null default 'COP' references public.currencies(code),
  locale text not null default 'es-CO',
  timezone text not null default 'America/Bogota',
  theme public.theme_preference not null default 'system',
  income_frequency public.income_frequency,
  income_day smallint check (income_day between 1 and 31),
  financial_goals text[] not null default '{}',
  -- Lock-screen notifications never show amounts unless the user opts in.
  show_amounts_in_notifications boolean not null default false,
  notification_settings jsonb not null default '{
    "budget_alerts": true, "due_reminders": true, "shared_expenses": true,
    "receipt_changes": true, "invitations": true, "settlements": true,
    "goals": true, "monthly_close": true }'::jsonb,
  onboarding_completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger user_preferences_touch before update on public.user_preferences
  for each row execute function private.touch_updated_at();

-- ---------------------------------------------------------------------------
-- Workspaces
-- ---------------------------------------------------------------------------
create table public.workspaces (
  id uuid primary key default gen_random_uuid(),
  kind public.workspace_kind not null,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  base_currency text not null references public.currencies(code),
  -- Default split rule for new expenses, e.g. {"method":"equal"} or
  -- {"method":"percent","shares":{"<uuid>":6000,"<uuid>":4000}}.
  default_split jsonb not null default '{"method":"equal"}'::jsonb,
  created_by uuid not null references public.profiles(id),
  archived_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index workspaces_one_personal_per_user on public.workspaces (created_by) where kind = 'personal';
create trigger workspaces_version before update on public.workspaces
  for each row execute function private.bump_version();

create table public.workspace_members (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  role public.member_role not null,
  status public.member_status not null default 'active',
  invited_by uuid references public.profiles(id),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (workspace_id, user_id),
  check ((status = 'active') = (left_at is null))
);
create index workspace_members_user_idx on public.workspace_members (user_id) where status = 'active';
create unique index workspace_members_one_owner on public.workspace_members (workspace_id) where role = 'owner' and status = 'active';
create trigger workspace_members_touch before update on public.workspace_members
  for each row execute function private.touch_updated_at();

create table public.workspace_invitations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  email extensions.citext,
  role public.member_role not null check (role <> 'owner'),
  -- Only the SHA-256 of the token is stored; the raw token is shown once.
  token_hash bytea not null unique,
  invited_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  accepted_at timestamptz,
  accepted_by uuid references public.profiles(id),
  declined_at timestamptz,
  revoked_at timestamptz,
  check (num_nonnulls(accepted_at, declined_at, revoked_at) <= 1)
);
create index workspace_invitations_ws_idx on public.workspace_invitations (workspace_id);

-- ---------------------------------------------------------------------------
-- Categories
-- ---------------------------------------------------------------------------
-- workspace_id NULL = system category shared by everyone (the common taxonomy
-- used by personal budgets across workspaces).
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid references public.workspaces(id) on delete cascade,
  system_key text unique,
  kind public.category_kind not null,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  icon text not null default 'category',
  color text not null default '#6B7C78' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  -- 50/30/20 bucket used only as an optional, editable reference.
  budget_bucket text check (budget_bucket in ('needs', 'wants', 'savings')),
  sort_order smallint not null default 100,
  created_by uuid references public.profiles(id),
  archived_at timestamptz,
  created_at timestamptz not null default now(),
  check ((workspace_id is null) = (system_key is not null))
);
create index categories_ws_idx on public.categories (workspace_id);

insert into public.categories (system_key, kind, name, icon, color, budget_bucket, sort_order) values
  ('groceries',      'expense', 'Mercado',              'shopping_basket', '#2E8B6E', 'needs',   10),
  ('restaurants',    'expense', 'Restaurantes',         'restaurant',      '#D9822B', 'wants',   20),
  ('transport',      'expense', 'Transporte',           'directions_bus',  '#3E7CB1', 'needs',   30),
  ('housing',        'expense', 'Vivienda y arriendo',  'home',            '#7A5C99', 'needs',   40),
  ('utilities',      'expense', 'Servicios públicos',   'bolt',            '#C9A227', 'needs',   50),
  ('health',         'expense', 'Salud',                'favorite',        '#C8553D', 'needs',   60),
  ('education',      'expense', 'Educación',            'school',          '#4F6D7A', 'needs',   70),
  ('entertainment',  'expense', 'Entretenimiento',      'movie',           '#B05E8F', 'wants',   80),
  ('shopping',       'expense', 'Compras',              'shopping_bag',    '#8C6A4F', 'wants',   90),
  ('subscriptions',  'expense', 'Suscripciones',        'subscriptions',   '#5B6ABF', 'wants',  100),
  ('travel',         'expense', 'Viajes',               'flight',          '#1F8A9E', 'wants',  110),
  ('pets',           'expense', 'Mascotas',             'pets',            '#9A7B4F', 'needs',  120),
  ('personal_care',  'expense', 'Cuidado personal',     'spa',             '#C27C9E', 'wants',  130),
  ('gifts',          'expense', 'Regalos',              'redeem',          '#D1495B', 'wants',  140),
  ('debt',           'expense', 'Deudas y créditos',    'credit_card',     '#5C5C5C', 'needs',  150),
  ('taxes',          'expense', 'Impuestos y trámites', 'account_balance', '#6D6875', 'needs',  160),
  ('other_expense',  'expense', 'Otros gastos',         'more_horiz',      '#6B7C78', null,     900),
  ('salary',         'income',  'Salario',              'work',            '#2E8B6E', null,      10),
  ('variable_income','income',  'Ingreso variable',     'trending_up',     '#3E7CB1', null,      20),
  ('extra_income',   'income',  'Ingreso extraordinario','star',           '#C9A227', null,      30),
  ('other_income',   'income',  'Otros ingresos',       'more_horiz',      '#6B7C78', null,     900);

-- ---------------------------------------------------------------------------
-- Accounts (always private to their owner, even when used in shared expenses)
-- ---------------------------------------------------------------------------
create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  type public.account_type not null,
  currency text not null references public.currencies(code),
  opening_balance_minor bigint not null default 0,
  credit_limit_minor bigint check (credit_limit_minor is null or credit_limit_minor >= 0),
  archived_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index accounts_owner_idx on public.accounts (owner_id);
create trigger accounts_version before update on public.accounts
  for each row execute function private.bump_version();

-- ---------------------------------------------------------------------------
-- New user bootstrap: profile, preferences and the private personal workspace.
-- ---------------------------------------------------------------------------
create or replace function private.handle_new_user() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text;
  v_ws uuid;
begin
  v_name := nullif(btrim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), '');
  if v_name is null then
    v_name := coalesce(nullif(split_part(coalesce(new.email, ''), '@', 1), ''), 'Usuario');
  end if;
  v_name := left(v_name, 60);

  insert into public.profiles (id, display_name) values (new.id, v_name);
  insert into public.user_preferences (user_id) values (new.id);

  insert into public.workspaces (kind, name, base_currency, created_by, default_split)
  values ('personal', 'Personal', 'COP', new.id, '{"method":"single"}'::jsonb)
  returning id into v_ws;

  insert into public.workspace_members (workspace_id, user_id, role)
  values (v_ws, new.id, 'owner');
  return new;
end $$;

create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();

-- ===================== 20261021000200_ledger.sql =====================
-- Pami Finance · 0200 · Ledger: transactions, payments, splits, receipts and
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

-- ===================== 20261021000300_planning.sql =====================
-- Pami Finance · 0300 · Budgets, goals, recurring items, monthly reports,
-- AI insights, notifications, imports, integrations and audit trail.

-- ---------------------------------------------------------------------------
-- Budgets
-- ---------------------------------------------------------------------------
-- Spent formula (private.budget_spent):
--   personal workspace -> the owner's ASSIGNED share (transaction_splits) of
--                         expenses in every workspace they belong to.
--   shared workspace   -> total of the workspace's expenses.
-- Only confirmed, non-deleted expenses in the budget currency are counted.
create table public.budgets (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 60),
  currency text not null references public.currencies(code),
  -- Either a fixed amount, or a share of the month's registered income.
  amount_minor bigint check (amount_minor is null or amount_minor > 0),
  income_share_bp integer check (income_share_bp is null or income_share_bp between 1 and 10000),
  alert_threshold_bp integer not null default 8000 check (alert_threshold_bp between 1000 and 10000),
  starts_on date not null default date_trunc('month', now())::date,
  ends_on date,
  created_by uuid not null references public.profiles(id),
  archived_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (num_nonnulls(amount_minor, income_share_bp) = 1)
);
create index budgets_ws_idx on public.budgets (workspace_id);
create trigger budgets_version before update on public.budgets
  for each row execute function private.bump_version();

-- No rows = the budget covers every expense category.
create table public.budget_categories (
  budget_id uuid not null references public.budgets(id) on delete cascade,
  category_id uuid not null references public.categories(id),
  primary key (budget_id, category_id)
);

-- ---------------------------------------------------------------------------
-- Savings goals (accumulated amount = sum of contributions; single source)
-- ---------------------------------------------------------------------------
create type public.goal_kind as enum ('emergency_fund', 'travel', 'housing', 'education', 'purchase', 'investment', 'custom');

create table public.savings_goals (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  kind public.goal_kind not null default 'custom',
  name text not null check (char_length(btrim(name)) between 1 and 60),
  currency text not null references public.currencies(code),
  target_minor bigint not null check (target_minor > 0),
  target_date date,
  planned_monthly_minor bigint check (planned_monthly_minor is null or planned_monthly_minor >= 0),
  priority smallint not null default 2 check (priority between 1 and 3),
  account_id uuid references public.accounts(id) on delete set null,
  created_by uuid not null references public.profiles(id),
  achieved_at timestamptz,
  archived_at timestamptz,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index savings_goals_ws_idx on public.savings_goals (workspace_id);
create trigger savings_goals_version before update on public.savings_goals
  for each row execute function private.bump_version();

create table public.savings_contributions (
  id uuid primary key default gen_random_uuid(),
  goal_id uuid not null references public.savings_goals(id) on delete cascade,
  -- Negative values are withdrawals.
  amount_minor bigint not null check (amount_minor <> 0),
  occurred_on date not null,
  note text check (note is null or char_length(note) <= 300),
  client_request_id uuid not null,
  created_by uuid not null references public.profiles(id),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (created_by, client_request_id)
);
create index savings_contributions_goal_idx on public.savings_contributions (goal_id) where deleted_at is null;

-- ---------------------------------------------------------------------------
-- Recurring rules & scheduled occurrences (expected != confirmed)
-- ---------------------------------------------------------------------------
create type public.recurrence_frequency as enum ('weekly', 'biweekly', 'monthly', 'yearly');
create type public.occurrence_status as enum ('scheduled', 'confirmed', 'skipped');

create table public.recurring_rules (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  kind public.transaction_kind not null check (kind in ('expense', 'income')),
  label text not null check (char_length(btrim(label)) between 1 and 80),
  category_id uuid references public.categories(id),
  currency text not null references public.currencies(code),
  expected_minor bigint not null check (expected_minor > 0),
  frequency public.recurrence_frequency not null,
  anchor_date date not null,
  end_date date,
  remind_days_before smallint not null default 2 check (remind_days_before between 0 and 30),
  active boolean not null default true,
  created_by uuid not null references public.profiles(id),
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index recurring_rules_ws_idx on public.recurring_rules (workspace_id);
create trigger recurring_rules_version before update on public.recurring_rules
  for each row execute function private.bump_version();

create table public.scheduled_occurrences (
  id uuid primary key default gen_random_uuid(),
  rule_id uuid not null references public.recurring_rules(id) on delete cascade,
  due_on date not null,
  expected_minor bigint not null check (expected_minor > 0),
  status public.occurrence_status not null default 'scheduled',
  -- Only a real transaction confirms an occurrence.
  transaction_id uuid references public.transactions(id) on delete set null,
  resolved_by uuid references public.profiles(id),
  resolved_at timestamptz,
  unique (rule_id, due_on),
  check ((status = 'confirmed') = (transaction_id is not null))
);

-- ---------------------------------------------------------------------------
-- Monthly reports: immutable snapshots; corrections create a new version.
-- ---------------------------------------------------------------------------
create table public.monthly_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  period_start date not null check (extract(day from period_start) = 1),
  currency text not null references public.currencies(code),
  report_version integer not null default 1,
  snapshot jsonb not null,
  data_quality jsonb not null default '{}'::jsonb,
  superseded_at timestamptz,
  closed_at timestamptz not null default clock_timestamp(),
  unique (user_id, period_start, currency, report_version)
);
create unique index monthly_reports_current on public.monthly_reports (user_id, period_start, currency) where superseded_at is null;

-- ---------------------------------------------------------------------------
-- AI insights (persisted explanations always cite their aggregates)
-- ---------------------------------------------------------------------------
create table public.ai_insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  workspace_id uuid references public.workspaces(id) on delete cascade,
  kind text not null,
  period_start date,
  content jsonb not null,
  sources jsonb not null default '[]'::jsonb,
  provider text,
  dismissed_at timestamptz,
  created_at timestamptz not null default now()
);
create index ai_insights_user_idx on public.ai_insights (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Notifications (body never contains private amounts by default)
-- ---------------------------------------------------------------------------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  workspace_id uuid references public.workspaces(id) on delete cascade,
  kind text not null,
  title text not null,
  body text,
  entity_type text,
  entity_id uuid,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index notifications_user_idx on public.notifications (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Imports & external integrations
-- ---------------------------------------------------------------------------
create type public.import_status as enum ('draft', 'imported', 'failed', 'cancelled');

create table public.import_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  source_type text not null check (source_type in ('csv', 'xlsx', 'bank_statement')),
  file_name text,
  status public.import_status not null default 'draft',
  column_mapping jsonb,
  row_count integer not null default 0,
  imported_count integer not null default 0,
  duplicate_count integer not null default 0,
  error jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);
alter table public.transactions
  add constraint transactions_import_job_fk foreign key (import_job_id) references public.import_jobs(id) on delete set null;

create type public.integration_status as enum ('not_configured', 'pending_consent', 'active', 'error', 'revoked');

create table public.integration_connections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  provider text not null,
  status public.integration_status not null default 'pending_consent',
  scopes text[] not null default '{}',
  consented_at timestamptz,
  revoked_at timestamptz,
  last_sync_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create trigger integration_connections_touch before update on public.integration_connections
  for each row execute function private.touch_updated_at();

-- Provider tokens never reach the client: private schema, service_role only.
create table private.integration_secrets (
  connection_id uuid primary key references public.integration_connections(id) on delete cascade,
  encrypted_payload bytea not null,
  rotated_at timestamptz not null default now()
);
revoke all on private.integration_secrets from public, authenticated;

-- Simple per-user rate limiting for AI and other expensive server calls.
create table private.usage_events (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  bucket text not null,
  created_at timestamptz not null default now()
);
create index usage_events_lookup on private.usage_events (user_id, bucket, created_at desc);
revoke all on private.usage_events from public, authenticated;

create table private.account_deletion_requests (
  user_id uuid primary key,
  requested_at timestamptz not null default now(),
  completed_at timestamptz
);
revoke all on private.account_deletion_requests from public, authenticated;

-- ---------------------------------------------------------------------------
-- Audit trail: who changed what, with a minimal diff (no notes, no documents).
-- ---------------------------------------------------------------------------
create table public.audit_events (
  id bigint generated always as identity primary key,
  workspace_id uuid references public.workspaces(id) on delete cascade,
  actor_id uuid references public.profiles(id),
  entity_type text not null,
  entity_id uuid not null,
  action text not null,
  changes jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default clock_timestamp()
);
create index audit_events_entity_idx on public.audit_events (entity_type, entity_id, occurred_at desc);
create index audit_events_ws_idx on public.audit_events (workspace_id, occurred_at desc);

create or replace function private.audit(p_workspace uuid, p_entity_type text, p_entity_id uuid, p_action text, p_changes jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into public.audit_events (workspace_id, actor_id, entity_type, entity_id, action, changes)
  values (p_workspace, auth.uid(), p_entity_type, p_entity_id, p_action, coalesce(p_changes, '{}'::jsonb));
$$;
revoke all on function private.audit(uuid, text, uuid, text, jsonb) from public;

-- ===================== 20261021000400_security.sql =====================
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

-- ===================== 20261021000500_workspace_rpc.sql =====================
-- Pami Finance · 0500 · Workspace, membership and invitation RPCs.
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

-- ===================== 20261021000600_ledger_rpc.sql =====================
-- Pami Finance · 0600 · Ledger write RPCs.
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

-- ===================== 20261021000700_analytics_rpc.sql =====================
-- Pami Finance · 0700 · Verifiable aggregations, budgets, goals, recurring
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
    'format', 'pami-export-v1',
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

-- ===================== 20261021000800_account_balances.sql =====================
-- Pami Finance · 0800 · Manual account balances, derived in ONE place.
-- balance = opening + income received − expenses I paid from it
--           − transfers out + transfers in
-- (for credit cards a negative balance is the amount owed).
create or replace function public.my_account_balances()
returns table (account_id uuid, currency text, opening_minor bigint, income_minor bigint, spent_minor bigint,
               transfers_in_minor bigint, transfers_out_minor bigint, balance_minor bigint)
language sql stable security invoker set search_path = '' as $$
  select a.id, a.currency, a.opening_balance_minor,
    coalesce((select sum(t.total_minor) from public.transactions t
              where t.account_id = a.id and t.kind = 'income' and t.deleted_at is null), 0)::bigint,
    coalesce((select sum(p.amount_minor) from public.transaction_payments p join public.transactions t on t.id = p.transaction_id
              where p.account_id = a.id and p.payer_id = auth.uid() and t.deleted_at is null), 0)::bigint,
    coalesce((select sum(t.total_minor) from public.transactions t
              where t.to_account_id = a.id and t.kind = 'transfer' and t.deleted_at is null), 0)::bigint,
    coalesce((select sum(t.total_minor) from public.transactions t
              where t.account_id = a.id and t.kind = 'transfer' and t.deleted_at is null), 0)::bigint,
    (a.opening_balance_minor
      + coalesce((select sum(t.total_minor) from public.transactions t where t.account_id = a.id and t.kind = 'income' and t.deleted_at is null), 0)
      - coalesce((select sum(p.amount_minor) from public.transaction_payments p join public.transactions t on t.id = p.transaction_id
                  where p.account_id = a.id and p.payer_id = auth.uid() and t.deleted_at is null), 0)
      + coalesce((select sum(t.total_minor) from public.transactions t where t.to_account_id = a.id and t.kind = 'transfer' and t.deleted_at is null), 0)
      - coalesce((select sum(t.total_minor) from public.transactions t where t.account_id = a.id and t.kind = 'transfer' and t.deleted_at is null), 0)
    )::bigint
  from public.accounts a
  where a.owner_id = auth.uid();
$$;
revoke execute on function public.my_account_balances() from public, anon;
grant execute on function public.my_account_balances() to authenticated;

-- ===================== 20261113000900_service_role_grants.sql =====================
-- Pami Finance · 0900 · Explicit privileges for the server role.
-- Projects created with "automatically expose new tables" disabled give no
-- default privileges to API roles. The client roles already receive explicit,
-- minimal grants (0400). The service role (used only by trusted Edge Functions,
-- e.g. delete-account) gets them explicitly here too. It still never reaches
-- the app: its key exists only as a server secret.
grant usage on schema public to service_role;
grant select, insert, update, delete on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;
grant execute on all functions in schema public to service_role;
