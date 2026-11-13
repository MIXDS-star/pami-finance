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
