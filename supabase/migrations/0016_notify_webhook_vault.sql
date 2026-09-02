-- 0016 — notify_webhook reads its target URL and shared secret from Supabase
-- Vault instead of literals baked into 0001 (which shipped <PROJECT_REF> /
-- <WEBHOOK_SECRET> placeholders that prod had patched by hand — git no
-- longer reproduced prod, and a fresh `db push` from git was BROKEN: pg_net
-- rejects the placeholder host, so every insert into tenants / profiles /
-- reservations failed inside the trigger). A backend is configured ONCE, in
-- the SQL editor, never by editing a migration:
--
--   select vault.create_secret(
--     'https://<project-ref>.supabase.co/functions/v1/notify', 'notify_url');
--   select vault.create_secret('<value>', 'webhook_secret');
--
-- `webhook_secret` must equal the notify Edge Function's WEBHOOK_SECRET env
-- (supabase secrets set). PROD: create both secrets BEFORE this migration
-- lands, or notifications pause (with a warning in Postgres logs) until
-- they exist.

create or replace function notify_webhook_config()
returns table (url text, secret text)
language sql stable security definer set search_path = ''
as $$
  select
    (select decrypted_secret from vault.decrypted_secrets
      where name = 'notify_url'),
    (select decrypted_secret from vault.decrypted_secrets
      where name = 'webhook_secret');
$$;

-- The trigger runs as the function owner, which keeps EXECUTE; every app
-- role loses it — PostgREST would otherwise serve the secret as an RPC to
-- any signed-in user.
revoke all on function notify_webhook_config() from public, anon, authenticated;

-- Same body as 0001, literals swapped for the Vault lookup, plus a guard so
-- an unconfigured backend logs a warning instead of failing the write.
create or replace function notify_webhook()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  select c.url, c.secret into v_url, v_secret from notify_webhook_config() c;
  if v_url is null or v_secret is null then
    raise warning 'notify_webhook: vault secrets notify_url / webhook_secret missing, notification skipped';
    return coalesce(new, old);
  end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-webhook-secret', v_secret
    ),
    body := jsonb_build_object(
      'type', tg_op,
      'table', tg_table_name,
      'schema', tg_table_schema,
      'record', case when tg_op = 'DELETE' then null else to_jsonb(new) end,
      'old_record', case when tg_op = 'INSERT' then null else to_jsonb(old) end
    )
  );
  return coalesce(new, old);
end;
$$;
