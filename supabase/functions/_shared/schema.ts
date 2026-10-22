import { z } from "zod";

// Planformatet är gjort för att översättas rakt till WorkoutKit (fas 4):
// Workout → CustomWorkout, warmup/cooldown → WorkoutStep, Block → IntervalBlock,
// Step → IntervalStep med WorkoutGoal (time/distance/open) och WorkoutAlert.

export const StepSchema = z.object({
  purpose: z.enum(["work", "recovery"]),
  goal_type: z.enum(["time", "distance", "open"]),
  goal_value: z.number().describe("Sekunder om goal_type=time, meter om distance, 0 om open."),
  target_type: z.enum(["none", "heart_rate_zone", "heart_rate_range", "pace"]),
  target_low: z.number().describe(
    "heart_rate_zone: zonnummer 1-5 (samma i target_high). heart_rate_range: lägsta puls (bpm). " +
      "pace: snabbaste tempo i sekunder per km. none: 0.",
  ),
  target_high: z.number().describe(
    "heart_rate_zone: samma zon som target_low. heart_rate_range: högsta puls (bpm). " +
      "pace: långsammaste tempo i sekunder per km. none: 0.",
  ),
  description: z.string().describe("Kort instruktion på svenska, t.ex. 'Lugnt jogg' eller '400 m i 10 km-fart'."),
});

export const BlockSchema = z.object({
  iterations: z.number().describe("Antal repetitioner av stegen, minst 1."),
  steps: z.array(StepSchema),
});

export const WorkoutSchema = z.object({
  date: z.string().describe("Datum YYYY-MM-DD inom planperioden."),
  activity: z.enum(["running", "walking", "cycling", "hiit", "strength", "mobility"]),
  location: z.enum(["outdoor", "indoor"]),
  title: z.string().describe("Kort titel på svenska, max 30 tecken (visas på klockan)."),
  description: z.string().describe("Syfte och utförande på svenska, 1-3 meningar."),
  intensity: z.enum(["easy", "moderate", "hard"]),
  estimated_minutes: z.number(),
  warmup_minutes: z.number().describe("0 om ingen separat uppvärmning."),
  cooldown_minutes: z.number().describe("0 om ingen separat nedvarvning."),
  blocks: z.array(BlockSchema).describe("Huvuddelen. Ett distanspass är ett block med ett work-steg."),
});

export const PlanSchema = z.object({
  summary: z.string().describe("Sammanfattning av veckan på svenska, 2-4 meningar."),
  readiness: z.enum(["recover", "maintain", "build"]),
  readiness_explanation: z.string().describe("Varför, baserat på HRV, vilopuls och belastning. Svenska."),
  weekly_focus: z.string().describe("Veckans fokus i en mening."),
  workouts: z.array(WorkoutSchema),
  rest_day_notes: z.string().describe("Råd för vilodagarna, svenska."),
});

export type Plan = z.infer<typeof PlanSchema>;
export type Workout = z.infer<typeof WorkoutSchema>;

/** Håller passen inom [start, end], sorterade, och med rimliga värden för WorkoutKit. */
export function cleanWorkouts(workouts: Workout[], start: string, end: string): Workout[] {
  return workouts
    .filter((w) => w.date >= start && w.date <= end)
    .map((w) => ({
      ...w,
      title: w.title.slice(0, 40),
      warmup_minutes: Math.max(0, Math.round(w.warmup_minutes)),
      cooldown_minutes: Math.max(0, Math.round(w.cooldown_minutes)),
      blocks: w.blocks
        .filter((b) => b.steps.length > 0)
        .map((b) => ({ ...b, iterations: Math.max(1, Math.round(b.iterations)) })),
    }))
    .sort((a, b) => a.date.localeCompare(b.date));
}
