// Läser användarens data (via RLS) och bygger den textsammanfattning av träning,
// återhämtning, sömn och aktivitet som skickas till modellen. Delas av plan-week och coach.

import type { SupabaseClient } from "@supabase/supabase-js";
import type { Plan, Workout } from "./schema.ts";

export interface WorkoutRow {
  id: string;
  activity_name: string;
  started_at: string;
  ended_at: string;
  duration_seconds: number;
  avg_heart_rate: number | null;
  max_heart_rate: number | null;
  distance_meters: number | null;
  heart_rate_recovery_1min: number | null;
  heart_rate_buckets: Record<string, number> | null;
  running_power_watts: number | null;
  stride_length_meters: number | null;
  ground_contact_ms: number | null;
  vertical_oscillation_cm: number | null;
}

export interface SampleRow {
  kind: "resting_heart_rate" | "hrv_sdnn" | "vo2_max";
  value: number;
  measured_at: string;
}

export interface DailyRow {
  date: string;
  steps: number | null;
  active_energy_kcal: number | null;
  exercise_minutes: number | null;
  stand_hours: number | null;
  sleep_total_minutes: number | null;
  sleep_deep_minutes: number | null;
  sleep_rem_minutes: number | null;
  sleep_core_minutes: number | null;
  sleep_awake_minutes: number | null;
  respiratory_rate: number | null;
  wrist_temperature_celsius: number | null;
}

export interface PlanRow {
  id: string;
  start_date: string;
  end_date: string;
  plan: Plan | null;
}

export const WEEKDAYS = [
  ["monday", "måndag"],
  ["tuesday", "tisdag"],
  ["wednesday", "onsdag"],
  ["thursday", "torsdag"],
  ["friday", "fredag"],
  ["saturday", "lördag"],
  ["sunday", "söndag"],
] as const;
export type WeekdayKey = (typeof WEEKDAYS)[number][0];

export interface ProfileRow {
  goals: string | null;
  weekly_schedule: Partial<Record<WeekdayKey, string>>;
  limitations: string | null;
  notes: string | null;
  updated_at: string;
}

export interface AthleteData {
  workouts: WorkoutRow[];
  samples: SampleRow[];
  daily: DailyRow[];
}

const WORKOUT_COLUMNS = "id, activity_name, started_at, ended_at, duration_seconds, avg_heart_rate, max_heart_rate, " +
  "distance_meters, heart_rate_recovery_1min, heart_rate_buckets, running_power_watts, stride_length_meters, " +
  "ground_contact_ms, vertical_oscillation_cm";
const DAILY_COLUMNS = "date, steps, active_energy_kcal, exercise_minutes, stand_hours, sleep_total_minutes, " +
  "sleep_deep_minutes, sleep_rem_minutes, sleep_core_minutes, sleep_awake_minutes, respiratory_rate, " +
  "wrist_temperature_celsius";
const PAGE_SIZE = 1000;

// MARK: - Datum (svensk tid)

const TIME_ZONE = "Europe/Stockholm";
const dayFormatter = new Intl.DateTimeFormat("sv-SE", {
  timeZone: TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});
const weekdayFormatter = new Intl.DateTimeFormat("sv-SE", { timeZone: TIME_ZONE, weekday: "short" });
const timeFormatter = new Intl.DateTimeFormat("sv-SE", { timeZone: TIME_ZONE, hour: "2-digit", minute: "2-digit" });

/** YYYY-MM-DD i svensk tid. */
export function dayKey(date: Date | string): string {
  return dayFormatter.format(new Date(date));
}

export function addDays(day: string, days: number): string {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function weekday(day: string): string {
  return weekdayFormatter.format(new Date(`${day}T12:00:00Z`));
}

export function clockTime(date: Date | string): string {
  return timeFormatter.format(new Date(date));
}

/** Måndag i veckan som `day` tillhör. */
function weekStart(day: string): string {
  const d = new Date(`${day}T12:00:00Z`);
  const offset = (d.getUTCDay() + 6) % 7;
  return addDays(day, -offset);
}

// MARK: - Hämtning

export async function loadAthleteData(supabase: SupabaseClient, days: number): Promise<AthleteData> {
  const since = new Date(Date.now() - days * 24 * 3600 * 1000).toISOString();
  const [workouts, samples, daily] = await Promise.all([
    fetchAll<WorkoutRow>(supabase, "workouts", WORKOUT_COLUMNS, "started_at", since),
    fetchAll<SampleRow>(supabase, "health_samples", "kind, value, measured_at", "measured_at", since),
    fetchAll<DailyRow>(supabase, "daily_metrics", DAILY_COLUMNS, "date", since.slice(0, 10)),
  ]);
  return { workouts, samples, daily };
}

export async function loadProfile(supabase: SupabaseClient): Promise<ProfileRow | null> {
  const { data, error } = await supabase
    .from("athlete_profiles")
    .select("goals, weekly_schedule, limitations, notes, updated_at")
    .maybeSingle();
  if (error) throw new Error(`Kunde inte läsa profilen: ${error.message}`);
  return data as ProfileRow | null;
}

/** Senaste planen som fortfarande pågår (slutdatum idag eller senare), om någon. */
export async function loadActivePlan(supabase: SupabaseClient, today: string): Promise<PlanRow | null> {
  const { data, error } = await supabase
    .from("training_plans")
    .select("id, start_date, end_date, plan")
    .eq("status", "ready")
    .gte("end_date", today)
    .order("created_at", { ascending: false })
    .limit(1);
  if (error) throw new Error(`Kunde inte läsa planen: ${error.message}`);
  return (data?.[0] as PlanRow | undefined) ?? null;
}

async function fetchAll<T>(
  supabase: SupabaseClient,
  table: string,
  columns: string,
  orderColumn: string,
  since: string,
): Promise<T[]> {
  const rows: T[] = [];
  for (let from = 0;; from += PAGE_SIZE) {
    const { data, error } = await supabase
      .from(table)
      .select(columns)
      .gte(orderColumn, since)
      .order(orderColumn, { ascending: true })
      .range(from, from + PAGE_SIZE - 1);
    if (error) throw new Error(`Kunde inte läsa ${table}: ${error.message}`);
    rows.push(...(data as T[]));
    if (data.length < PAGE_SIZE) return rows;
  }
}

// MARK: - Hjälpfunktioner

function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function mean(values: number[]): number | null {
  return values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;
}

function fmt(value: number | null | undefined, decimals = 0): string {
  return value === null || value === undefined ? "–" : value.toFixed(decimals);
}

function hm(minutes: number | null | undefined): string {
  if (minutes === null || minutes === undefined) return "–";
  const total = Math.round(minutes);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, "0")}`;
}

function pace(seconds: number, meters: number): string {
  const perKm = seconds / (meters / 1000);
  const min = Math.floor(perKm / 60);
  const sec = Math.round(perKm % 60);
  return `${min}:${String(sec).padStart(2, "0")}/km`;
}

function nonNull(values: (number | null)[]): number[] {
  return values.filter((v): v is number => v !== null);
}

/** Dagliga värden: median för HRV (många mätningar per dag), medel för övriga. */
function dailySeries(samples: SampleRow[], kind: SampleRow["kind"]): Map<string, number> {
  const byDay = new Map<string, number[]>();
  for (const s of samples) {
    if (s.kind !== kind) continue;
    const key = dayKey(s.measured_at);
    byDay.set(key, [...(byDay.get(key) ?? []), s.value]);
  }
  const result = new Map<string, number>();
  for (const [day, values] of byDay) {
    const v = kind === "hrv_sdnn" ? median(values) : mean(values);
    if (v !== null) result.set(day, v);
  }
  return result;
}

function inWindow(day: string, today: string, fromDaysAgo: number, toDaysAgo: number): boolean {
  return day >= addDays(today, -fromDaysAgo) && day <= addDays(today, -toDaysAgo);
}

function windowValues(series: Map<string, number>, today: string, fromDaysAgo: number, toDaysAgo: number): number[] {
  return [...series].filter(([day]) => inWindow(day, today, fromDaysAgo, toDaysAgo)).map(([, v]) => v);
}

/** "130-139: 7 min, 140-149: 15 min" – bara intervall med minst en minut. */
function bucketText(buckets: Record<string, number> | null): string | null {
  if (!buckets) return null;
  const parts = Object.entries(buckets)
    .map(([bpm, seconds]) => [Number(bpm), seconds] as const)
    .filter(([, seconds]) => seconds >= 60)
    .sort(([a], [b]) => a - b)
    .map(([bpm, seconds]) => `${bpm}-${bpm + 9}: ${Math.round(seconds / 60)} min`);
  return parts.length ? parts.join(", ") : null;
}

// MARK: - Sammanfattning

export function describeWorkout(w: WorkoutRow, detailed: boolean): string {
  const day = dayKey(w.started_at);
  const parts = [
    `${day} ${weekday(day)} ${clockTime(w.started_at)}`,
    w.activity_name,
    `${Math.round(w.duration_seconds / 60)} min`,
  ];
  if (w.distance_meters && w.distance_meters > 100) {
    parts.push(`${(w.distance_meters / 1000).toFixed(1)} km`);
    if (["Löpning", "Promenad", "Vandring"].includes(w.activity_name)) {
      parts.push(pace(w.duration_seconds, w.distance_meters));
    }
  }
  if (w.avg_heart_rate) parts.push(`snittpuls ${Math.round(w.avg_heart_rate)}`);
  if (detailed) {
    if (w.max_heart_rate) parts.push(`maxpuls ${Math.round(w.max_heart_rate)}`);
    if (w.heart_rate_recovery_1min) parts.push(`pulsåterhämtning 1 min: ${Math.round(w.heart_rate_recovery_1min)} slag`);
    if (w.running_power_watts) parts.push(`kraft ${Math.round(w.running_power_watts)} W`);
    if (w.stride_length_meters) parts.push(`steglängd ${w.stride_length_meters.toFixed(2)} m`);
    if (w.ground_contact_ms) parts.push(`markkontakt ${Math.round(w.ground_contact_ms)} ms`);
    if (w.vertical_oscillation_cm) parts.push(`vertikal rörelse ${w.vertical_oscillation_cm.toFixed(1)} cm`);
    const buckets = bucketText(w.heart_rate_buckets);
    if (buckets) parts.push(`pulsfördelning (bpm): ${buckets}`);
  }
  return parts.join(" | ");
}

export function buildSummary(data: AthleteData, today: string): string {
  const { workouts, samples, daily } = data;
  const lines: string[] = [];

  // Återhämtning
  const hrv = dailySeries(samples, "hrv_sdnn");
  const rhr = dailySeries(samples, "resting_heart_rate");
  const vo2 = dailySeries(samples, "vo2_max");
  const days = new Map(daily.map((d) => [d.date, d]));

  lines.push("## Återhämtning (HRV = dagsmedian SDNN, vilopuls = dagsmedel)");
  lines.push(
    `HRV senaste 7 d (median): ${fmt(median(windowValues(hrv, today, 6, 0)))} ms | ` +
      `baslinje dag 8-60 (median): ${fmt(median(windowValues(hrv, today, 60, 7)))} ms`,
  );
  lines.push(
    `Vilopuls senaste 7 d (medel): ${fmt(mean(windowValues(rhr, today, 6, 0)), 1)} bpm | ` +
      `baslinje dag 8-60 (medel): ${fmt(mean(windowValues(rhr, today, 60, 7)), 1)} bpm`,
  );
  const vo2Days = [...vo2.keys()].sort();
  if (vo2Days.length) {
    const latest = vo2Days[vo2Days.length - 1];
    const old = vo2Days.find((d) => d >= addDays(today, -60)) ?? vo2Days[0];
    lines.push(
      `VO2 max: senast ${fmt(vo2.get(latest), 1)} (${latest}), för ~60 d sedan ${fmt(vo2.get(old), 1)} (${old})`,
    );
  }

  // Sömn och aktivitet – snitt
  const recent = daily.filter((d) => inWindow(d.date, today, 6, 0));
  const baseline = daily.filter((d) => inWindow(d.date, today, 37, 7));
  const avg = (rows: DailyRow[], pick: (d: DailyRow) => number | null) => mean(nonNull(rows.map(pick)));
  if (daily.length) {
    lines.push("");
    lines.push("## Sömn och aktivitet (snitt senaste 7 d | baslinje dag 8-37)");
    lines.push(
      `Sömn: ${hm(avg(recent, (d) => d.sleep_total_minutes))} | ${hm(avg(baseline, (d) => d.sleep_total_minutes))} h, ` +
        `djupsömn ${fmt(avg(recent, (d) => d.sleep_deep_minutes))} | ${fmt(avg(baseline, (d) => d.sleep_deep_minutes))} min, ` +
        `REM ${fmt(avg(recent, (d) => d.sleep_rem_minutes))} | ${fmt(avg(baseline, (d) => d.sleep_rem_minutes))} min`,
    );
    lines.push(
      `Steg: ${fmt(avg(recent, (d) => d.steps))} | ${fmt(avg(baseline, (d) => d.steps))}, ` +
        `aktiv energi ${fmt(avg(recent, (d) => d.active_energy_kcal))} | ${fmt(avg(baseline, (d) => d.active_energy_kcal))} kcal, ` +
        `träningsminuter ${fmt(avg(recent, (d) => d.exercise_minutes))} | ${fmt(avg(baseline, (d) => d.exercise_minutes))}`,
    );
    lines.push(
      `Andningsfrekvens i sömn: ${fmt(avg(recent, (d) => d.respiratory_rate), 1)} | ` +
        `${fmt(avg(baseline, (d) => d.respiratory_rate), 1)} andetag/min`,
    );
  }
  const tempBaseline = median(nonNull(baseline.map((d) => d.wrist_temperature_celsius)));

  // Dag för dag
  lines.push("");
  lines.push(
    "## Senaste 21 dagarna, dag för dag\n" +
      "(HRV ms / vilopuls / sömn h:mm (djup, REM, vaken min) / steg / aktiv kcal / träningsmin / ståtimmar / " +
      "andning / handledstemp. avvikelse °C mot baslinje)",
  );
  for (let i = 20; i >= 0; i--) {
    const day = addDays(today, -i);
    const d = days.get(day);
    const temp = d?.wrist_temperature_celsius != null && tempBaseline !== null
      ? `${d.wrist_temperature_celsius - tempBaseline >= 0 ? "+" : ""}${(d.wrist_temperature_celsius - tempBaseline).toFixed(1)}`
      : "–";
    lines.push(
      `${day} ${weekday(day)}: ${fmt(hrv.get(day))} / ${fmt(rhr.get(day))} / ` +
        `${hm(d?.sleep_total_minutes)} (${fmt(d?.sleep_deep_minutes)}, ${fmt(d?.sleep_rem_minutes)}, ${fmt(d?.sleep_awake_minutes)}) / ` +
        `${fmt(d?.steps)} / ${fmt(d?.active_energy_kcal)} / ${fmt(d?.exercise_minutes)} / ${fmt(d?.stand_hours)} / ` +
        `${fmt(d?.respiratory_rate, 1)} / ${temp}`,
    );
  }

  // Veckobelastning
  lines.push("");
  lines.push("## Veckobelastning (vecka som börjar måndag)");
  const weeks = new Map<string, { sessions: number; minutes: number; km: number }>();
  for (const w of workouts) {
    const key = weekStart(dayKey(w.started_at));
    const entry = weeks.get(key) ?? { sessions: 0, minutes: 0, km: 0 };
    entry.sessions += 1;
    entry.minutes += w.duration_seconds / 60;
    entry.km += (w.distance_meters ?? 0) / 1000;
    weeks.set(key, entry);
  }
  for (const [week, e] of [...weeks].sort(([a], [b]) => a.localeCompare(b))) {
    lines.push(`v. från ${week}: ${e.sessions} pass, ${Math.round(e.minutes)} min, ${e.km.toFixed(1)} km`);
  }

  const maxValues = nonNull(workouts.map((w) => w.max_heart_rate));
  if (maxValues.length) {
    lines.push("");
    lines.push(`Högsta uppmätta puls i ett pass senaste 90 d: ${Math.round(Math.max(...maxValues))} bpm`);
  }

  // Passlista – detaljer för de senaste tre veckorna
  lines.push("");
  lines.push("## Alla pass senaste 90 dagarna (nyast först, detaljer för senaste 21 dagarna)");
  const sorted = [...workouts].sort((a, b) => b.started_at.localeCompare(a.started_at));
  for (const w of sorted) {
    lines.push(describeWorkout(w, dayKey(w.started_at) >= addDays(today, -20)));
  }

  return lines.join("\n");
}

// MARK: - Profil

export function describeProfile(profile: ProfileRow | null): string {
  if (!profile) return "Ingen profil ifylld ännu.";
  const lines = [
    `Mål: ${profile.goals?.trim() || "inte angivet"}`,
    "Veckoschema (personens önskemål om vad varje veckodag ska innehålla):",
    ...WEEKDAYS.map(([key, name]) => `  ${name}: ${profile.weekly_schedule?.[key]?.trim() || "flexibel"}`),
    `Skador och begränsningar: ${profile.limitations?.trim() || "inga angivna"}`,
    `Övrigt: ${profile.notes?.trim() || "–"}`,
    `(Profilen uppdaterades senast ${dayKey(profile.updated_at)}.)`,
  ];
  return lines.join("\n");
}

// MARK: - Plan

function describeTarget(step: Workout["blocks"][number]["steps"][number]): string {
  switch (step.target_type) {
    case "heart_rate_zone":
      return ` zon ${step.target_low}`;
    case "heart_rate_range":
      return ` ${step.target_low}-${step.target_high} bpm`;
    case "pace":
      return ` ${Math.floor(step.target_low / 60)}:${String(Math.round(step.target_low % 60)).padStart(2, "0")}-` +
        `${Math.floor(step.target_high / 60)}:${String(Math.round(step.target_high % 60)).padStart(2, "0")}/km`;
    default:
      return "";
  }
}

export function describePlannedWorkout(w: Workout): string {
  const blocks = w.blocks.map((b) => {
    const steps = b.steps.map((s) => {
      const goal = s.goal_type === "time"
        ? `${Math.round(s.goal_value / 60 * 10) / 10} min`
        : s.goal_type === "distance"
        ? `${s.goal_value} m`
        : "öppet";
      return `${s.purpose === "work" ? "" : "vila "}${goal}${describeTarget(s)}`;
    }).join(" + ");
    return b.iterations > 1 ? `${b.iterations} × (${steps})` : steps;
  }).join(", ");
  const parts = [`${w.title} (${w.activity}, ${w.intensity}, ca ${Math.round(w.estimated_minutes)} min)`];
  if (w.warmup_minutes) parts.push(`uppvärmning ${w.warmup_minutes} min`);
  parts.push(blocks);
  if (w.cooldown_minutes) parts.push(`nedvarvning ${w.cooldown_minutes} min`);
  return parts.join(": ");
}

/** Planen dag för dag, med genomförda pass för dagar som redan passerat. */
export function describePlan(plan: PlanRow | null, workouts: WorkoutRow[], today: string): string {
  if (!plan?.plan) return "Ingen aktiv plan just nu.";
  const lines = [
    `Plan ${plan.start_date} – ${plan.end_date}. Fokus: ${plan.plan.weekly_focus}`,
    `Bedömning när planen skapades: ${plan.plan.readiness} – ${plan.plan.readiness_explanation}`,
  ];
  for (let day = plan.start_date; day <= plan.end_date; day = addDays(day, 1)) {
    const planned = plan.plan.workouts.filter((w) => w.date === day);
    const done = workouts.filter((w) => dayKey(w.started_at) === day);
    const marker = day < today ? "(passerad)" : day === today ? "(IDAG)" : "";
    lines.push(`${day} ${weekday(day)} ${marker}`.trim());
    lines.push(`  Planerat: ${planned.length ? planned.map(describePlannedWorkout).join(" / ") : "vila"}`);
    if (day <= today) {
      lines.push(`  Genomfört: ${done.length ? done.map((w) => describeWorkout(w, false)).join(" / ") : "inget registrerat pass"}`);
    }
  }
  return lines.join("\n");
}
