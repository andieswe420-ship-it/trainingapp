// plan-week: skapar en AI-genererad träningsplan för de kommande 7 dagarna.
//
// Flöde: appen anropar funktionen (med användarens JWT) → en rad med status 'pending'
// skapas i training_plans och dess id returneras direkt → planen genereras i bakgrunden
// (EdgeRuntime.waitUntil) → raden uppdateras till 'ready' eller 'failed'. Appen pollar raden.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { userClient } from "../_shared/auth.ts";
import { addDays, buildSummary, dayKey, loadAthleteData } from "../_shared/context.ts";
import { AIError, chat, errorMessage, json, MODELS } from "../_shared/openrouter.ts";
import { cleanWorkouts, type Plan, PlanSchema } from "../_shared/schema.ts";

const HISTORY_DAYS = 90;
const PLAN_DAYS = 7;
/** Med effort "medium" reserveras ~hälften av max_tokens för resonemang. */
const MAX_TOKENS = 48000;

// JSON-schema för strukturerad output (strict: alla fält krävs, additionalProperties: false).
const { $schema: _ignored, ...PLAN_JSON_SCHEMA } = z.toJSONSchema(PlanSchema, { target: "draft-7" });

const SYSTEM_PROMPT = `Du är en erfaren uthållighetscoach som planerar träning för en enskild motionär.
Du får hela personens träningshistorik och återhämtningsdata från Apple Watch för de senaste 90 dagarna
(pass, HRV, vilopuls, sömn, steg, aktivitet, andning och handledstemperatur), och skapar ett
träningsschema för de kommande 7 dagarna.

Så här resonerar du:
- Bedöm först återhämtningen: jämför HRV, vilopuls och sömn senaste 7 dagarna mot baslinjen. Klart sänkt
  HRV, förhöjd vilopuls (mer än ~3 bpm), kort sömn flera nätter i rad, eller förhöjd andningsfrekvens
  och handledstemperatur samtidigt betyder att belastningen ska sänkas. Enstaka extrema värden är oftast mätfel.
- Utgå från personens faktiska vanor: vilka aktiviteter, hur många pass och hur mycket tid per vecka.
  Öka total veckovolym med högst ~10 % jämfört med snittet för de senaste 3-4 veckorna. Räkna in hög
  vardagsaktivitet (många steg) i den totala belastningen.
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
  if (req.method !== "POST") return json({ error: "Använd POST." }, 405);
  const supabase = await userClient(req);
  if (!supabase) return json({ error: "Inloggning krävs." }, 401);

  const body = await req.json().catch(() => ({})) as { notes?: unknown };
  const notes = typeof body.notes === "string" ? body.notes.trim().slice(0, 2000) : "";

  const startDate = dayKey(new Date());
  const endDate = addDays(startDate, PLAN_DAYS - 1);

  const { data: row, error: insertError } = await supabase
    .from("training_plans")
    .insert({ start_date: startDate, end_date: endDate, notes: notes || null, model: MODELS[0] })
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
    const data = await loadAthleteData(supabase, HISTORY_DAYS);
    const summary = buildSummary(data, startDate);
    const { plan, model } = await askModel(summary, startDate, endDate, notes);

    const { error } = await supabase
      .from("training_plans")
      .update({
        status: "ready",
        plan: { ...plan, workouts: cleanWorkouts(plan.workouts, startDate, endDate) },
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

async function askModel(
  summary: string,
  startDate: string,
  endDate: string,
  notes: string,
): Promise<{ plan: Plan; model: string }> {
  const userContent = [
    `Planera träningen ${startDate} till ${endDate} (idag är ${startDate}).`,
    notes ? `\nPersonens önskemål:\n${notes}` : "\nPersonen har inte angett några särskilda önskemål.",
    `\n# Data\n${summary}`,
  ].join("\n");

  const result = await chat({
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: userContent },
    ],
    effort: "medium",
    maxTokens: MAX_TOKENS,
    responseFormat: { name: "training_plan", schema: PLAN_JSON_SCHEMA },
  });
  if (!result.content) throw new AIError("AI-coachen returnerade ingen plan.");

  let parsedJson: unknown;
  try {
    parsedJson = JSON.parse(result.content);
  } catch {
    throw new AIError("AI-coachen returnerade ogiltig JSON. Försök igen.");
  }
  const parsed = PlanSchema.safeParse(parsedJson);
  if (!parsed.success) {
    console.error("plan schema mismatch", parsed.error.issues.slice(0, 5));
    throw new AIError("AI-coachens plan hade fel format. Försök igen.");
  }
  return { plan: parsed.data, model: result.model };
}
