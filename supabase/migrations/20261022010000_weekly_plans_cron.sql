-- Automatisk veckoplan: söndagskvällen skapar Edge Function weekly-plans nästa veckas plan
-- (måndag–söndag) för alla som har det påslaget i profilen.

alter table public.athlete_profiles
  add column auto_weekly_plan boolean not null default true;

create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- Hemlighet som cron-jobbet skickar i headern x-cron-secret. Värdet slumpas när migrationen körs
-- och finns bara i Vault.
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'weekly_plans_cron_secret')
where not exists (select 1 from vault.secrets where name = 'weekly_plans_cron_secret');

-- Edge Function weekly-plans (service role) kontrollerar headern mot Vault via den här funktionen.
create or replace function public.verify_cron_secret(secret text)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select exists (
    select 1 from vault.decrypted_secrets
    where name = 'weekly_plans_cron_secret' and decrypted_secret = secret
  );
$$;
revoke execute on function public.verify_cron_secret(text) from public, anon, authenticated;
grant execute on function public.verify_cron_secret(text) to service_role;

-- Söndagar 17:00 UTC = 18:00 svensk vintertid / 19:00 sommartid.
select cron.schedule(
  'weekly-plans',
  '0 17 * * 0',
  $$
  select net.http_post(
    url := 'https://whuleymkapsysrjxyfyx.supabase.co/functions/v1/weekly-plans',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'weekly_plans_cron_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 10000
  );
  $$
);
