// Skapar veckoplaner. Används av plan-week (knappen i appen) och weekly-plans (söndagsjobbet).

import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { buildSummary, dayKey, describeProfile, loadAthleteData, loadProfile } from "./context.ts";
import { AIError, chat, defaultModel, errorMessage } from "./ai.ts";
import { cleanWorkouts, type Plan, PlanSchema } from "./schema.ts";

const HISTORY_DAYS = 90;
/** Med effort "medium" reserveras ~hälften av max_tokens för resonemang. */
const MAX_TOKENS = 48000;
/** Kimi hinner inte skriva en hel plan inom Edge Functions tidsgräns (150 s) – planer görs med en snabbare
 * modell hos Berget. Kan bytas med secret BERGET_PLAN_MODEL. */
const PLAN_BERGET_MODEL = Deno.env.get("BERGET_PLAN_MODEL")?.trim() || "zai-org/GLM-5.3-Flash";
/** Under tidsgränsen, så att raden hinner markeras som misslyckad i stället för att bli hängande. */
const TIMEOUT_MS = 120_000;

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
- Följ personens profil: lägg pass på de veckodagar och av den typ som veckoschemat anger (vila på
  vilodagarna), och ta hänsyn till mål och skador. Anpassa intensitet och längd efter formen.
- Följ personens önskemål om de anges, men säg ifrån i texten om något är orimligt givet återhämtningen.

Formatet ska kunna läggas in direkt som pass på klockan:
- Uppvärmning och nedvarvning anges i minuter (warmup_minutes/cooldown_minutes), inte som block.
- Huvuddelen är block med steg. Ett distanspass är ett block med iterations=1 och ett work-steg.
  Intervaller är ett block med iterations=N och ett work-steg följt av ett recovery-steg.
- Styrka, HIIT, rörlighet, pilates och yoga: ett block med tidsbaserade steg och target_type "none".
  Använd activity "pilates" respektive "yoga" för de passen.
- Vilodagar tas inte med i workouts; skriv råd för dem i rest_day_notes.
All text ska vara på svenska.`;

/** Skapar en rad med status 'pending' som `generatePlan` sedan fyller i. */
export async function createPendingPlan(
  supabase: SupabaseClient,
  userId: string,
  startDate: string,
  endDate: string,
  notes: string,
): Promise<string> {
  const { data, error } = await supabase
    .from("training_plans")
    .insert({ user_id: userId, start_date: startDate, end_date: endDate, notes: notes || null, model: defaultModel(PLAN_BERGET_MODEL) })
    .select("id")
    .single();
  if (error || !data) throw new Error(`Kunde inte skapa plan: ${error?.message}`);
  return data.id;
}

/** Genererar planen och uppdaterar raden till 'ready' eller 'failed'. Kastar aldrig. */
export async function generatePlan(
  supabase: SupabaseClient,
  userId: string,
  planId: string,
  startDate: string,
  endDate: string,
  notes: string,
): Promise<void> {
  try {
    const [data, profile] = await Promise.all([
      loadAthleteData(supabase, userId, HISTORY_DAYS),
      loadProfile(supabase, userId),
    ]);
    const today = dayKey(new Date());
    const summary = `# Personens profil\n${describeProfile(profile)}\n\n# Data\n${buildSummary(data, today)}`;
    const { plan, model } = await askModel(summary, startDate, endDate, notes);

    const { error } = await supabase
      .from("training_plans")
      .update({
        status: "ready",
        plan: { ...plan, workouts: cleanWorkouts(plan.workouts, startDate, endDate) },
        model,
        updated_at: new Date().toISOString(),
      })
      .eq("id", planId)
      .eq("user_id", userId);
    if (error) throw new Error(`Kunde inte spara planen: ${error.message}`);
  } catch (err) {
    console.error("plan generation failed", err);
    await supabase
      .from("training_plans")
      .update({ status: "failed", error: errorMessage(err), updated_at: new Date().toISOString() })
      .eq("id", planId)
      .eq("user_id", userId);
  }
}

async function askModel(
  summary: string,
  startDate: string,
  endDate: string,
  notes: string,
): Promise<{ plan: Plan; model: string }> {
  const userContent = [
    `Planera träningen ${startDate} till ${endDate}.`,
    notes ? `\nPersonens önskemål för just den här perioden:\n${notes}` : "",
    `\n${summary}`,
  ].join("\n");

  const result = await chat({
    messages: [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: userContent },
    ],
    effort: "medium",
    maxTokens: MAX_TOKENS,
    responseFormat: { name: "training_plan", schema: PLAN_JSON_SCHEMA },
    bergetModel: PLAN_BERGET_MODEL,
    timeoutMs: TIMEOUT_MS,
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
