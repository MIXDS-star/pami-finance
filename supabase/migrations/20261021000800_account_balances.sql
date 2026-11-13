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
