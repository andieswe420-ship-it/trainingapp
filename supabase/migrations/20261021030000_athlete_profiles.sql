-- Bestående information om personen som både coach och planerare följer.
create table public.athlete_profiles (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  goals text,
  -- Veckoschema: {"monday": "Vila", "tuesday": "Intervaller inomhus", ...}. Saknad dag = flexibel.
  weekly_schedule jsonb not null default '{}'::jsonb,
  limitations text,
  notes text,
  updated_at timestamptz not null default now()
);

alter table public.athlete_profiles enable row level security;
create policy "Egen profil: läsa" on public.athlete_profiles for select to authenticated using ((select auth.uid()) = user_id);
create policy "Egen profil: skapa" on public.athlete_profiles for insert to authenticated with check ((select auth.uid()) = user_id);
create policy "Egen profil: uppdatera" on public.athlete_profiles for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
create policy "Egen profil: ta bort" on public.athlete_profiles for delete to authenticated using ((select auth.uid()) = user_id);

-- När coachen uppdaterar profilen visas det i chatten: {"summary": "...", "fields": ["weekly_schedule"]}.
alter table public.coach_messages add column profile_update jsonb;
