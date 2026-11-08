-- Röstcoachens personliga repliker inför ett löppass (Edge Function run-brief). Sparas för
-- historik och för att AI-anropets CO₂ ska synas i appens kort "AI-användningens klimatavtryck".
create table public.run_briefs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  workout_title text not null,
  content jsonb not null,
  model text,
  co2_grams double precision
);

alter table public.run_briefs enable row level security;

create policy "Egna repliker" on public.run_briefs
  for all to authenticated
  using ((select auth.uid()) = user_id)
  with check ((select auth.uid()) = user_id);

create index run_briefs_user_created on public.run_briefs (user_id, created_at desc);

create or replace view public.ai_usage with (security_invoker = true) as
  select 'coach'::text as kind, created_at, model, co2_grams
    from public.coach_messages where role = 'assistant' and status = 'done'
  union all
  select 'plan', created_at, model, co2_grams from public.training_plans where status = 'ready'
  union all
  select 'insight', created_at, model, co2_grams from public.trend_insights where status = 'ready'
  union all
  select 'run', created_at, model, co2_grams from public.run_briefs;

revoke all on public.ai_usage from anon;
grant select on public.ai_usage to authenticated;
