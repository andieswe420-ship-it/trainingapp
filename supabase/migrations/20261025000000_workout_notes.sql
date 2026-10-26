-- Coachens minne av vad passen faktiskt var: när personen berättar i chatten att ett pass blev
-- något annat än planerat eller hur det kändes sparas det på passet. Synken från appen skriver bara
-- sina egna kolumner (upsert på id), så anteckningen ligger kvar.
alter table public.workouts add column athlete_note text;

-- Visas i chatten när coachen sparat en anteckning (som profile_update).
alter table public.coach_messages add column workout_note jsonb;
