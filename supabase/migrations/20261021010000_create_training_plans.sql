-- AI-genererade veckoplaner. Skapas som 'pending' av Edge Function plan-week,
-- fylls i bakgrunden och blir 'ready' (eller 'failed').
create table public.training_plans (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'ready', 'failed')),
  start_date date not null,
  end_date date not null,
  notes text,
  plan jsonb,
  error text,
  model text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index training_plans_user_created_idx on public.training_plans (user_id, created_at desc);

alter table public.training_plans enable row level security;

create policy "Egna planer: läsa" on public.training_plans for select to authenticated using ((select auth.uid()) = user_id);
create policy "Egna planer: skapa" on public.training_plans for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Egna planer: uppdatera" on public.training_plans for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Egna planer: ta bort" on public.training_plans for delete to authenticated using ((select auth.uid()) = user_id);
