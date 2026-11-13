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
