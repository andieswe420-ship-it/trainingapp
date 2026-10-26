-- Koldioxidutsläpp per AI-anrop. Berget AI rapporterar det i usage.co2_grams; för andra leverantörer
-- (OpenRouter) finns ingen mätning och värdet är null.
alter table public.coach_messages add column co2_grams double precision;
alter table public.training_plans add column co2_grams double precision;
alter table public.trend_insights add column co2_grams double precision;

-- Alla färdiga AI-svar i en vy för appens kort "AI-användning". security_invoker gör att tabellernas
-- RLS gäller, så varje användare ser bara sina egna rader.
create view public.ai_usage with (security_invoker = true) as
  select 'coach'::text as kind, created_at, model, co2_grams
    from public.coach_messages where role = 'assistant' and status = 'done'
  union all
  select 'plan', created_at, model, co2_grams from public.training_plans where status = 'ready'
  union all
  select 'insight', created_at, model, co2_grams from public.trend_insights where status = 'ready';

revoke all on public.ai_usage from anon;
grant select on public.ai_usage to authenticated;
