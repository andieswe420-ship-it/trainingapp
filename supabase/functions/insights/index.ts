// insights: AI-analys av trenderna i appens Trender-flik.
//
// POST { period: "4w" | "3m" | "6m", metrics: {...}, force?: boolean }
// Appen skickar nyckeltalen den räknat fram (normalintervall, form/belastning, aerob effektivitet,
// periodjämförelse). Analysen sparas per dag och period i trend_insights; finns en redan för idag
// returneras den (om inte force). Annars skapas en 'pending'-rad som fylls i bakgrunden och appen pollar.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { userClient } from "../_shared/auth.ts";
import { buildSummary, dayKey, describeProfile, loadAthleteData, loadProfile } from "../_shared/context.ts";
import { AIError, chat, errorMessage, json, MODELS } from "../_shared/openrouter.ts";

const HISTORY_DAYS = 90;
const MAX_TOKENS = 32000;
const MAX_METRICS_LENGTH = 20000;
const PERIODS = { "4w": "senaste 4 veckorna", "3m": "senaste 3 månaderna", "6m": "senaste 6 månaderna" } as const;
type Period = keyof typeof PERIODS;

const CARD_KEYS = ["volume", "vo2max", "resting_hr", "hrv", "sleep", "load", "efficiency"] as const;

const InsightSchema = z.object({
  overall: z.string().describe(
    "Övergripande analys på svenska, 3-5 meningar: vad som förändrats, vad det betyder och vad personen bör tänka på.",
  ),
  cards: z.array(z.object({
    key: z.enum(CARD_KEYS),
    headline: z.string().describe("Kort rubrik, max 50 tecken, t.ex. \"Konditionen ökar stadigt\"."),
    comment: z.string().describe("1-2 meningar som förklarar förändringen och vad den betyder."),
    status: z.enum(["positive", "neutral", "attention"]),
  })).describe("En kommentar per diagram, i ordningen volume, vo2max, resting_hr, hrv, sleep, load, efficiency."),
  patterns: z.array(z.string()).describe(
    "0-3 samband du ser i datan, t.ex. mellan sömn och HRV eller belastning och vilopuls. Tom lista om inga tydliga.",
  ),
});
const { $schema: _ignored, ...INSIGHT_JSON_SCHEMA } = z.toJSONSchema(InsightSchema, { target: "draft-7" });

const SYSTEM_PROMPT = `Du är en träningscoach som förklarar en motionärs träningstrender på ett begripligt sätt.
Du får nyckeltal som appen har räknat fram för en vald period, personens profil och en sammanfattning
av all träning, återhämtning och sömn de senaste 90 dagarna.

Så här skriver du:
- Förklara förändringar i vardagliga ord: vad har hänt, vad betyder det, och vad är rimligt att göra.
  Personen ska förstå sin utveckling utan att kunna träningsfysiologi.
- Jämför med personens eget normalintervall och föregående period, inte med andra människor.
- Använd de exakta siffrorna från nyckeltalen. Hitta aldrig på värden.
- Förklara begreppen kort första gången: "form" = kondition minus trötthet (positivt = utvilad,
  negativt = belastad), "belastningskvot" = senaste veckans belastning jämfört med snittet de
  senaste fyra veckorna (över ~1,5 = snabb ökning med högre skaderisk), "meter per hjärtslag" =
  hur långt personen springer per hjärtslag (högre = bättre aerob kondition).
- status: "positive" för en tydligt gynnsam utveckling, "attention" för något att hålla koll på
  (t.ex. vilopuls över normalintervallet, snabbt ökande belastning, kort sömn), annars "neutral".
- Saknas data för ett diagram: säg det kort och sätt status "neutral".
- Ställ inga diagnoser. Vid tecken på sjukdom eller överbelastning: rekommendera vila och att söka vård
  vid behov.
All text ska vara på svenska.`;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Använd POST." }, 405);
  const user = await userClient(req);
  if (!user) return json({ error: "Inloggning krävs." }, 401);
  const { supabase, userId } = user;

  const body = await req.json().catch(() => ({})) as { period?: unknown; metrics?: unknown; force?: unknown };
  const period = typeof body.period === "string" && body.period in PERIODS ? body.period as Period : null;
  if (!period) return json({ error: "Ogiltig period." }, 400);
  const metrics = JSON.stringify(body.metrics ?? {});
  if (metrics.length > MAX_METRICS_LENGTH) return json({ error: "För mycket data." }, 413);

  const today = dayKey(new Date());
  try {
    const { data: existing } = await supabase
      .from("trend_insights")
      .select("id, status")
      .eq("user_id", userId)
      .eq("date", today)
      .eq("period", period)
      .maybeSingle();
    if (existing && body.force !== true && existing.status !== "failed") {
      return json({ id: existing.id, status: existing.status });
    }
    if (existing) {
      await supabase.from("trend_insights").delete().eq("id", existing.id);
    }

    const { data: row, error } = await supabase
      .from("trend_insights")
      .insert({ user_id: userId, date: today, period, input: body.metrics ?? {}, model: MODELS[0] })
      .select("id")
      .single();
    if (error || !row) {
      // Ett parallellt anrop hann före – returnera den raden.
      const { data: raced } = await supabase
        .from("trend_insights")
        .select("id, status")
        .eq("user_id", userId)
        .eq("date", today)
        .eq("period", period)
        .maybeSingle();
      if (raced) return json({ id: raced.id, status: raced.status });
      throw new Error(`Kunde inte skapa analys: ${error?.message}`);
    }

    EdgeRuntime.waitUntil(generate(supabase, userId, row.id, period, metrics, today));
    return json({ id: row.id, status: "pending" }, 202);
  } catch (err) {
    console.error("insights request failed", err);
    return json({ error: errorMessage(err) }, 500);
  }
});

async function generate(
  supabase: SupabaseClient,
  userId: string,
  insightId: string,
  period: Period,
  metrics: string,
  today: string,
) {
  try {
    const [data, profile] = await Promise.all([
      loadAthleteData(supabase, userId, HISTORY_DAYS),
      loadProfile(supabase, userId),
    ]);
    const userContent = [
      `Analysera trenderna för ${PERIODS[period]} (idag är ${today}).`,
      `\n# Nyckeltal från appen (JSON)\n${metrics}`,
      `\n# Personens profil\n${describeProfile(profile)}`,
      `\n# Data\n${buildSummary(data, today)}`,
    ].join("\n");

    const result = await chat({
      messages: [
        { role: "system", content: SYSTEM_PROMPT },
        { role: "user", content: userContent },
      ],
      effort: "medium",
      maxTokens: MAX_TOKENS,
      responseFormat: { name: "trend_insight", schema: INSIGHT_JSON_SCHEMA },
    });
    if (!result.content) throw new AIError("AI-coachen returnerade ingen analys.");

    let parsedJson: unknown;
    try {
      parsedJson = JSON.parse(result.content);
    } catch {
      throw new AIError("AI-coachen returnerade ogiltig JSON. Försök igen.");
    }
    const parsed = InsightSchema.safeParse(parsedJson);
    if (!parsed.success) {
      console.error("insight schema mismatch", parsed.error.issues.slice(0, 5));
      throw new AIError("Analysen hade fel format. Försök igen.");
    }

    const { error } = await supabase
      .from("trend_insights")
      .update({ status: "ready", content: parsed.data, model: result.model, updated_at: new Date().toISOString() })
      .eq("id", insightId)
      .eq("user_id", userId);
    if (error) throw new Error(`Kunde inte spara analysen: ${error.message}`);
  } catch (err) {
    console.error("insight generation failed", err);
    await supabase
      .from("trend_insights")
      .update({ status: "failed", error: errorMessage(err), updated_at: new Date().toISOString() })
      .eq("id", insightId)
      .eq("user_id", userId);
  }
}
