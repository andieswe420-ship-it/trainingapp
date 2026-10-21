// Bygger en kompakt textsammanfattning av träningshistorik och återhämtning
// som skickas till modellen.

export interface WorkoutRow {
  activity_name: string;
  started_at: string;
  duration_seconds: number;
  avg_heart_rate: number | null;
  distance_meters: number | null;
}

export interface SampleRow {
  kind: "resting_heart_rate" | "hrv_sdnn" | "vo2_max";
  value: number;
  measured_at: string;
}

const TIME_ZONE = "Europe/Stockholm";
const dayFormatter = new Intl.DateTimeFormat("sv-SE", {
  timeZone: TIME_ZONE,
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});
const weekdayFormatter = new Intl.DateTimeFormat("sv-SE", { timeZone: TIME_ZONE, weekday: "short" });

/** YYYY-MM-DD i svensk tid. */
export function dayKey(date: Date | string): string {
  return dayFormatter.format(new Date(date));
}

export function addDays(day: string, days: number): string {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

function weekday(day: string): string {
  return weekdayFormatter.format(new Date(`${day}T12:00:00Z`));
}

/** Måndag i veckan som `day` tillhör. */
function weekStart(day: string): string {
  const d = new Date(`${day}T12:00:00Z`);
  const offset = (d.getUTCDay() + 6) % 7;
  return addDays(day, -offset);
}

function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

function mean(values: number[]): number | null {
  return values.length ? values.reduce((a, b) => a + b, 0) / values.length : null;
}

function fmt(value: number | null, decimals = 0): string {
  return value === null ? "–" : value.toFixed(decimals);
}

function pace(seconds: number, meters: number): string {
  const perKm = seconds / (meters / 1000);
  const min = Math.floor(perKm / 60);
  const sec = Math.round(perKm % 60);
  return `${min}:${String(sec).padStart(2, "0")}/km`;
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

function windowValues(series: Map<string, number>, today: string, fromDaysAgo: number, toDaysAgo: number): number[] {
  const from = addDays(today, -fromDaysAgo);
  const to = addDays(today, -toDaysAgo);
  return [...series].filter(([day]) => day >= from && day <= to).map(([, v]) => v);
}

export function buildSummary(workouts: WorkoutRow[], samples: SampleRow[], today: string): string {
  const lines: string[] = [];

  // Återhämtning
  const hrv = dailySeries(samples, "hrv_sdnn");
  const rhr = dailySeries(samples, "resting_heart_rate");
  const vo2 = dailySeries(samples, "vo2_max");

  lines.push("## Återhämtning (dagliga värden: HRV = dagsmedian SDNN, vilopuls = dagsmedel)");
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
      `VO2 max: senast ${fmt(vo2.get(latest)!, 1)} (${latest}), för ~60 d sedan ${fmt(vo2.get(old)!, 1)} (${old})`,
    );
  }
  lines.push("");
  lines.push("Senaste 21 dagarna (datum: HRV ms / vilopuls bpm):");
  for (let i = 20; i >= 0; i--) {
    const day = addDays(today, -i);
    lines.push(`${day} ${weekday(day)}: ${fmt(hrv.get(day) ?? null)} / ${fmt(rhr.get(day) ?? null)}`);
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

  // Maxvärden som hjälp för pulszoner
  const hrValues = workouts.map((w) => w.avg_heart_rate).filter((v): v is number => v !== null);
  if (hrValues.length) {
    lines.push("");
    lines.push(`Högsta snittpuls i ett pass senaste 90 d: ${Math.round(Math.max(...hrValues))} bpm`);
  }

  // Passlista
  lines.push("");
  lines.push("## Alla pass senaste 90 dagarna (nyast först)");
  const sorted = [...workouts].sort((a, b) => b.started_at.localeCompare(a.started_at));
  for (const w of sorted) {
    const day = dayKey(w.started_at);
    const parts = [`${day} ${weekday(day)}`, w.activity_name, `${Math.round(w.duration_seconds / 60)} min`];
    if (w.distance_meters && w.distance_meters > 100) {
      parts.push(`${(w.distance_meters / 1000).toFixed(1)} km`);
      if (["Löpning", "Promenad", "Vandring"].includes(w.activity_name)) {
        parts.push(pace(w.duration_seconds, w.distance_meters));
      }
    }
    if (w.avg_heart_rate) parts.push(`snittpuls ${Math.round(w.avg_heart_rate)}`);
    lines.push(parts.join(" | "));
  }

  return lines.join("\n");
}
