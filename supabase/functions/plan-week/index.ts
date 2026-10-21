// plan-week: skapar en AI-genererad träningsplan för de kommande 7 dagarna.
//
// Flöde: appen anropar funktionen (med användarens JWT) → en rad med status 'pending'
// skapas i training_plans och dess id returneras direkt → planen genereras i bakgrunden
// (EdgeRuntime.waitUntil) → raden uppdateras till 'ready' eller 'failed'. Appen pollar raden.
// Modellen anropas via OpenRouter (OPENROUTER_API_KEY).

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { type Plan, PlanSchema } from "./schema.ts";
import { addDays, buildSummary, dayKey, type SampleRow, type WorkoutRow } from "./summary.ts";

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";
/** Primär modell först; OpenRouter faller tillbaka på nästa vid fel eller överbelastning. */
const MODELS = ["anthropic/claude-opus-5.5", "anthropic/claude-opus-5"];
const MODEL = MODELS[0];
/** Med effort "medium" reserveras ~hälften av max_tokens för resonemang. */
const MAX_TOKENS = 48000;
const REQUEST_TIMEOUT_MS = 300_000;
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
    const { plan, model } = await askModel(summary, startDate, endDate, notes);

    const { error } = await supabase
      .from("training_plans")
      .update({
        status: "ready",
        plan: cleanPlan(plan, startDate, endDate),
        model,
        updated_at: new Date().toISOString(),
      })
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

// JSON-schema för OpenRouters strukturerade output (strict: alla fält krävs,
// additionalProperties: false – vilket z.toJSONSchema ger för z.object).
const { $schema: _ignored, ...PLAN_JSON_SCHEMA } = z.toJSONSchema(PlanSchema, { target: "draft-7" });

class PlanError extends Error {}

interface ChatCompletion {
  model?: string;
  choices?: { finish_reason?: string | null; message?: { content?: string | null } }[];
  error?: { code?: number | string; message?: string };
}

async function askModel(
  summary: string,
  startDate: string,
  endDate: string,
  notes: string,
): Promise<{ plan: Plan; model: string }> {
  const apiKey = Deno.env.get("OPENROUTER_API_KEY");
  if (!apiKey) throw new PlanError("OPENROUTER_API_KEY saknas i Supabase (Edge Functions → Secrets).");

  const userContent = [
    `Planera träningen ${startDate} till ${endDate} (idag är ${startDate}).`,
    notes ? `\nPersonens önskemål:\n${notes}` : "\nPersonen har inte angett några särskilda önskemål.",
    `\n# Data\n${summary}`,
  ].join("\n");

  const response = await fetch(OPENROUTER_URL, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
      "X-Title": "TrainingApp",
    },
    body: JSON.stringify({
      models: MODELS,
      max_tokens: MAX_TOKENS,
      reasoning: { effort: "medium" },
      response_format: {
        type: "json_schema",
        json_schema: { name: "training_plan", strict: true, schema: PLAN_JSON_SCHEMA },
      },
      // Skicka bara till leverantörer som faktiskt stöder strukturerad output.
      provider: { require_parameters: true },
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: userContent },
      ],
    }),
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
  });

  const body = await response.json().catch(() => ({})) as ChatCompletion;
  if (!response.ok || body.error) {
    throw new PlanError(openRouterError(response.status, body.error?.message));
  }

  const choice = body.choices?.[0];
  if (choice?.finish_reason === "length") {
    throw new PlanError("Planen blev för lång och avbröts. Försök igen.");
  }
  if (choice?.finish_reason === "content_filter") {
    throw new PlanError("AI-coachen avböjde att skapa en plan. Försök igen med andra önskemål.");
  }
  const content = choice?.message?.content;
  if (!content) throw new PlanError("AI-coachen returnerade ingen plan.");

  let json: unknown;
  try {
    json = JSON.parse(content);
  } catch {
    throw new PlanError("AI-coachen returnerade ogiltig JSON. Försök igen.");
  }
  const parsed = PlanSchema.safeParse(json);
  if (!parsed.success) {
    console.error("plan schema mismatch", parsed.error.issues.slice(0, 5));
    throw new PlanError("AI-coachens plan hade fel format. Försök igen.");
  }
  return { plan: parsed.data, model: body.model ?? MODEL };
}

function openRouterError(status: number, message?: string): string {
  switch (status) {
    case 401:
      return "Fel API-nyckel för OpenRouter (OPENROUTER_API_KEY).";
    case 402:
      return "Slut på krediter hos OpenRouter. Fyll på på openrouter.ai.";
    case 429:
      return "AI-tjänsten är överbelastad just nu. Försök igen om en stund.";
    default:
      return `AI-tjänsten svarade med fel ${status}${message ? `: ${message}` : ""}.`;
  }
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
  if (err instanceof PlanError) return err.message;
  if (err instanceof DOMException && err.name === "TimeoutError") {
    return "AI-tjänsten svarade inte i tid. Försök igen.";
  }
  return err instanceof Error ? err.message : String(err);
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}
