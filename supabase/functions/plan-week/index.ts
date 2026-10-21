// plan-week: skapar en AI-genererad träningsplan för de kommande 7 dagarna.
//
// Flöde: appen anropar funktionen (med användarens JWT) → en rad med status 'pending'
// skapas i training_plans och dess id returneras direkt → planen genereras i bakgrunden
// (EdgeRuntime.waitUntil) → raden uppdateras till 'ready' eller 'failed'. Appen pollar raden.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { type Plan, PlanSchema } from "./schema.ts";
import { addDays, buildSummary, dayKey, type SampleRow, type WorkoutRow } from "./summary.ts";

const MODEL = "claude-opus-5-5";
const HISTORY_DAYS = 90;
const PLAN_DAYS = 7;
const PAGE_SIZE = 1000;

const SYSTEM_PROMPT = `Du är en erfaren uthållighetscoach som planerar träning för en enskild motionär.
Du får hela personens träningshistorik och återhämtningsdata från Apple Watch för de senaste 90 dagarna,
och skapar ett träningsschema för de kommande 7 dagarna.

Så här resonerar du:
- Bedöm först återhämtningen: jämför HRV och vilopuls senaste 7 dagarna mot baslinjen. Klart sänkt HRV
  eller förhöjd vilopuls (mer än ~3 bpm) betyder att belastningen ska sänkas. Enstaka extrema
  HRV-värden är oftast mätfel.
- Utgå från personens faktiska vanor: vilka aktiviteter, hur många pass och hur mycket tid per vecka.
  Öka total veckovolym med högst ~10 % jämfört med snittet för de senaste 3-4 veckorna.
- Fördela belastningen: högst två hårda pass i veckan, aldrig två hårda dagar i rad, och minst en vilodag.
- Använd personens egna tempon och pulsnivåer från historiken när du sätter mål. Pulszoner 1-5 avser
  klockans standardzoner; ange hellre ett pulsintervall i bpm när du kan härleda det ur historiken.
- Följ personens önskemål om de anges, men säg ifrån i texten om något är orimligt givet återhämtningen.

Formatet ska kunna läggas in direkt som pass på klockan:
- Uppvärmning och nedvarvning anges i minuter (warmup_minutes/cooldown_minutes), inte som block.
- Huvuddelen är block med steg. Ett distanspass är ett block med iterations=1 och ett work-steg.
  Intervaller är ett block med iterations=N och ett work-steg följt av ett recovery-steg.
- Styrka, HIIT och rörlighet: ett block med tidsbaserade steg och target_type "none".
- Vilodagar tas inte med i workouts; skriv råd för dem i rest_day_notes.
All text ska vara på svenska.`;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "Använd POST." }, 405);
  }
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return json({ error: "Inloggning krävs." }, 401);

  // Klient som agerar som användaren – RLS gäller för alla frågor.
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: userError } = await supabase.auth.getUser(authHeader.replace(/^Bearer /, ""));
  if (userError || !user) return json({ error: "Ogiltig inloggning." }, 401);

  const body = await req.json().catch(() => ({})) as { notes?: unknown };
  const notes = typeof body.notes === "string" ? body.notes.trim().slice(0, 2000) : "";

  const startDate = dayKey(new Date());
  const endDate = addDays(startDate, PLAN_DAYS - 1);

  const { data: row, error: insertError } = await supabase
    .from("training_plans")
    .insert({ start_date: startDate, end_date: endDate, notes: notes || null, model: MODEL })
    .select("id")
    .single();
  if (insertError || !row) {
    console.error("insert failed", insertError);
    return json({ error: "Kunde inte skapa plan." }, 500);
  }

  EdgeRuntime.waitUntil(generatePlan(supabase, row.id, startDate, endDate, notes));
  return json({ id: row.id, status: "pending" }, 202);
});

async function generatePlan(
  supabase: SupabaseClient,
  planId: string,
  startDate: string,
  endDate: string,
  notes: string,
) {
  try {
    const since = new Date(Date.now() - HISTORY_DAYS * 24 * 3600 * 1000).toISOString();
    const [workouts, samples] = await Promise.all([
      fetchAll<WorkoutRow>(
        supabase,
        "workouts",
        "activity_name, started_at, duration_seconds, avg_heart_rate, distance_meters",
        "started_at",
        since,
      ),
      fetchAll<SampleRow>(supabase, "health_samples", "kind, value, measured_at", "measured_at", since),
    ]);

    const summary = buildSummary(workouts, samples, startDate);
    const plan = await askClaude(summary, startDate, endDate, notes);

    const { error } = await supabase
      .from("training_plans")
      .update({ status: "ready", plan: cleanPlan(plan, startDate, endDate), updated_at: new Date().toISOString() })
      .eq("id", planId);
    if (error) throw new Error(`Kunde inte spara planen: ${error.message}`);
  } catch (err) {
    console.error("plan generation failed", err);
    await supabase
      .from("training_plans")
      .update({ status: "failed", error: errorMessage(err), updated_at: new Date().toISOString() })
      .eq("id", planId);
  }
}

async function askClaude(summary: string, startDate: string, endDate: string, notes: string): Promise<Plan> {
  const anthropic = new Anthropic({ apiKey: Deno.env.get("ANTHROPIC_API_KEY") });

  const userContent = [
    `Planera träningen ${startDate} till ${endDate} (idag är ${startDate}).`,
    notes ? `\nPersonens önskemål:\n${notes}` : "\nPersonen har inte angett några särskilda önskemål.",
    `\n# Data\n${summary}`,
  ].join("\n");

  const stream = anthropic.beta.messages.stream({
    model: MODEL,
    max_tokens: 32000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default",
    output_config: { effort: "medium", format: betaZodOutputFormat(PlanSchema) },
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: userContent }],
  });
  const message = await stream.finalMessage();

  if (message.stop_reason === "refusal") {
    throw new Error("AI-coachen avböjde att skapa en plan. Försök igen med andra önskemål.");
  }
  if (message.stop_reason === "max_tokens") {
    throw new Error("Planen blev för lång och avbröts. Försök igen.");
  }
  if (!message.parsed_output) {
    throw new Error("AI-coachen returnerade ingen giltig plan.");
  }
  return message.parsed_output;
}

/** Håller passen inom perioden, sorterade, och rimliga värden för WorkoutKit. */
function cleanPlan(plan: Plan, startDate: string, endDate: string): Plan {
  const workouts = plan.workouts
    .filter((w) => w.date >= startDate && w.date <= endDate)
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
  return { ...plan, workouts };
}

async function fetchAll<T>(
  supabase: SupabaseClient,
  table: string,
  columns: string,
  dateColumn: string,
  since: string,
): Promise<T[]> {
  const rows: T[] = [];
  for (let from = 0;; from += PAGE_SIZE) {
    const { data, error } = await supabase
      .from(table)
      .select(columns)
      .gte(dateColumn, since)
      .order(dateColumn, { ascending: true })
      .range(from, from + PAGE_SIZE - 1);
    if (error) throw new Error(`Kunde inte läsa ${table}: ${error.message}`);
    rows.push(...(data as T[]));
    if (data.length < PAGE_SIZE) return rows;
  }
}

function errorMessage(err: unknown): string {
  if (err instanceof Anthropic.APIError) {
    if (err.status === 401) return "Fel API-nyckel för Claude (ANTHROPIC_API_KEY).";
    if (err.status === 429) return "AI-tjänsten är överbelastad just nu. Försök igen om en stund.";
    return `AI-tjänsten svarade med fel ${err.status}.`;
  }
  return err instanceof Error ? err.message : String(err);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
