-- Dagliga värden från Hälsa: sömn, aktivitet, andning och handledstemperatur.
create table public.daily_metrics (
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  date date not null,
  steps integer,
  active_energy_kcal double precision,
  exercise_minutes double precision,
  stand_hours integer,
  sleep_total_minutes double precision,
  sleep_deep_minutes double precision,
  sleep_rem_minutes double precision,
  sleep_core_minutes double precision,
  sleep_awake_minutes double precision,
  respiratory_rate double precision,
  wrist_temperature_celsius double precision,
  synced_at timestamptz not null default now(),
  primary key (user_id, date)
);

alter table public.daily_metrics enable row level security;
create policy "Egna dagsvärden: läsa" on public.daily_metrics for select to authenticated using ((select auth.uid()) = user_id);
create policy "Egna dagsvärden: skapa" on public.daily_metrics for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Egna dagsvärden: uppdatera" on public.daily_metrics for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Egna dagsvärden: ta bort" on public.daily_metrics for delete to authenticated using ((select auth.uid()) = user_id);

-- Löpdynamik och pulsförlopp per pass.
alter table public.workouts
  add column max_heart_rate double precision,
  add column heart_rate_recovery_1min double precision,
  add column heart_rate_buckets jsonb,
  add column running_power_watts double precision,
  add column stride_length_meters double precision,
  add column ground_contact_ms double precision,
  add column vertical_oscillation_cm double precision;

comment on column public.workouts.heart_rate_buckets is
  'Sekunder per 10-bpm-intervall, t.ex. {"130": 420, "140": 900} = 130-139 bpm i 420 s.';

-- Coachchatt. Assistentsvar skapas som 'pending' och fylls i bakgrunden av Edge Function coach.
create table public.coach_messages (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  role text not null check (role in ('user', 'assistant')),
  content text not null default '',
  status text not null default 'done' check (status in ('pending', 'done', 'failed')),
  workout_id uuid references public.workouts (id) on delete set null,
  proposal jsonb,
  proposal_status text check (proposal_status in ('pending', 'accepted', 'rejected')),
  plan_id uuid references public.training_plans (id) on delete set null,
  error text,
  model text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index coach_messages_user_created_idx on public.coach_messages (user_id, created_at desc);
create unique index coach_messages_checkin_once_idx on public.coach_messages (user_id, workout_id)
  where workout_id is not null;

alter table public.coach_messages enable row level security;
create policy "Egna meddelanden: läsa" on public.coach_messages for select to authenticated using ((select auth.uid()) = user_id);
create policy "Egna meddelanden: skapa" on public.coach_messages for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Egna meddelanden: uppdatera" on public.coach_messages for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Egna meddelanden: ta bort" on public.coach_messages for delete to authenticated using ((select auth.uid()) = user_id);
