-- AI-analys av trender. En rad per användare, dag och period; skapas som 'pending' av Edge Function
-- insights och fylls i bakgrunden. input = nyckeltalen appen räknade fram.
create table public.trend_insights (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  date date not null,
  period text not null check (period in ('4w', '3m', '6m')),
  status text not null default 'pending' check (status in ('pending', 'ready', 'failed')),
  input jsonb,
  content jsonb,
  error text,
  model text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, date, period)
);

alter table public.trend_insights enable row level security;
create policy "Egna analyser: läsa" on public.trend_insights for select to authenticated using ((select auth.uid()) = user_id);
create policy "Egna analyser: skapa" on public.trend_insights for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Egna analyser: uppdatera" on public.trend_insights for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Egna analyser: ta bort" on public.trend_insights for delete to authenticated using ((select auth.uid()) = user_id);
