-- Test helpers: impersonate users exactly like PostgREST does (role +
-- request.jwt.claims), and assert results. Loaded before every test file.
create schema if not exists tests;
grant usage on schema tests to authenticated, anon;

create or replace function tests.create_user(p_email text, p_name text) returns uuid
language plpgsql as $$
declare v uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, raw_user_meta_data, aud, role, created_at)
  values (v, p_email, jsonb_build_object('display_name', p_name), 'authenticated', 'authenticated', now());
  return v;
end $$;

create or replace function tests.login(p_user uuid) returns void
language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', json_build_object(
    'sub', p_user, 'role', 'authenticated',
    'email', (select email from auth.users where id = p_user))::text, true);
  perform set_config('request.jwt.claim.sub', p_user::text, true);
  perform set_config('role', 'authenticated', true);
end $$;

create or replace function tests.login_anon() returns void
language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('role', 'anon', true);
end $$;

create or replace function tests.logout() returns void
language plpgsql as $$
begin
  perform set_config('role', 'postgres', true);
  perform set_config('request.jwt.claims', '', true);
  perform set_config('request.jwt.claim.sub', '', true);
end $$;

create or replace function tests.ok(p_cond boolean, p_msg text) returns void
language plpgsql as $$
begin
  if p_cond is not true then
    raise exception 'FAIL: %', p_msg;
  end if;
  raise notice 'ok - %', p_msg;
end $$;

create or replace function tests.eq(p_actual anyelement, p_expected anyelement, p_msg text) returns void
language plpgsql as $$
begin
  if p_actual is distinct from p_expected then
    raise exception 'FAIL: % (expected %, got %)', p_msg, p_expected, p_actual;
  end if;
  raise notice 'ok - %', p_msg;
end $$;

-- Runs p_sql and requires it to fail. p_expect matches the HINT (our stable
-- error code) or, when it starts with 'sqlstate:', the SQLSTATE.
create or replace function tests.throws(p_sql text, p_expect text, p_msg text) returns void
language plpgsql as $$
declare
  v_hint text;
  v_state text;
  v_text text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_hint = pg_exception_hint, v_state = returned_sqlstate, v_text = message_text;
    if p_expect like 'sqlstate:%' then
      if v_state <> substr(p_expect, 10) then
        raise exception 'FAIL: % (expected sqlstate %, got % / % / %)', p_msg, substr(p_expect, 10), v_state, v_hint, v_text;
      end if;
    elsif v_hint is distinct from p_expect then
      raise exception 'FAIL: % (expected %, got % / % / %)', p_msg, p_expect, v_state, v_hint, v_text;
    end if;
    raise notice 'ok - %', p_msg;
    return;
  end;
  raise exception 'FAIL: % (statement succeeded: %)', p_msg, p_sql;
end $$;

create or replace function tests.personal_ws(p_user uuid) returns uuid
language sql security definer as $$
  select id from public.workspaces where created_by = p_user and kind = 'personal';
$$;

create or replace function tests.category(p_key text) returns uuid
language sql security definer as $$
  select id from public.categories where system_key = p_key;
$$;

-- Builds a simple expense payload paid by one person and split as given.
create or replace function tests.expense(p_ws uuid, p_total bigint, p_payer uuid, p_splits jsonb,
                                         p_desc text default 'Compra', p_date date default current_date)
returns jsonb language sql as $$
  select jsonb_build_object(
    'client_request_id', gen_random_uuid(), 'workspace_id', p_ws, 'kind', 'expense',
    'description', p_desc, 'occurred_on', p_date, 'currency', 'COP', 'total_minor', p_total,
    'category_id', tests.category('groceries'), 'split_method', 'fixed', 'split_spec', '{}'::jsonb,
    'payments', jsonb_build_array(jsonb_build_object('payer_id', p_payer, 'amount_minor', p_total)),
    'splits', (select jsonb_agg(jsonb_build_object('user_id', key, 'amount_minor', value::bigint)) from jsonb_each_text(p_splits)));
$$;

grant execute on all functions in schema tests to authenticated, anon;
