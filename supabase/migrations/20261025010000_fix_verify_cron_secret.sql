-- Rättelse: i SQL-funktioner vinner kolumnnamn över parameternamn, och vault.decrypted_secrets har en
-- kolumn som heter secret (det krypterade värdet). Jämförelsen blev därför alltid falsk och söndagsjobbet
-- fick 401. Parametern kvalificeras med funktionsnamnet (namnet behålls – Edge Function anropar med det).
create or replace function public.verify_cron_secret(secret text)
returns boolean
language sql
security definer
set search_path = ''
as $$
  select exists (
    select 1 from vault.decrypted_secrets
    where name = 'weekly_plans_cron_secret' and decrypted_secret = verify_cron_secret.secret
  );
$$;
