-- Tillämpad på Supabase-projektet "trainingapp" (whuleymkapsysrjxyfyx).

-- Träningspass från HealthKit. id = HKWorkout.uuid (idempotent upsert).
create table public.workouts (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  activity_type integer not null,
  activity_name text not null,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  duration_seconds double precision not null,
  avg_heart_rate double precision,
  distance_meters double precision,
  active_energy_kcal double precision,
  synced_at timestamptz not null default now()
);
create index workouts_user_started_idx on public.workouts (user_id, started_at desc);

-- Hälsomätningar (vilopuls, HRV, VO2 max). id = HKSample.uuid.
create table public.health_samples (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  kind text not null check (kind in ('resting_heart_rate', 'hrv_sdnn', 'vo2_max')),
  value double precision not null,
  unit text not null,
  measured_at timestamptz not null,
  synced_at timestamptz not null default now()
);
create index health_samples_user_kind_measured_idx on public.health_samples (user_id, kind, measured_at desc);

alter table public.workouts enable row level security;
alter table public.health_samples enable row level security;

create policy "Egna pass: läsa" on public.workouts for select to authenticated using ((select auth.uid()) = user_id);
create policy "Egna pass: skapa" on public.workouts for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Egna pass: uppdatera" on public.workouts for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Egna pass: ta bort" on public.workouts for delete to authenticated using ((select auth.uid()) = user_id);

create policy "Egna mätningar: läsa" on public.health_samples for select to authenticated using ((select auth.uid()) = user_id);
create policy "Egna mätningar: skapa" on public.health_samples for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Egna mätningar: uppdatera" on public.health_samples for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Egna mätningar: ta bort" on public.health_samples for delete to authenticated using ((select auth.uid()) = user_id);
