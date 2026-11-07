// run-brief: röstcoachens personliga repliker inför ett löppass.
//
// POST { title: string, date: "YYYY-MM-DD", steps: string[] }
// Appen skickar passets steg i den ordning röstcoachen leder dem (index = plats i listan).
// Coachen skriver en öppningsreplik, några repliker knutna till särskilda steg och en avslutning,
// utifrån personens data (sömn, HRV, vilopuls, senaste passen och anteckningar) och profil.
// Svaret kommer direkt (inte pending/poll) – det är kort, och appen kör passet utan repliker om
// det dröjer eller misslyckas. Raden sparas i run_briefs för historik och CO₂.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { z } from "zod";
import { userClient } from "../_shared/auth.ts";
import { buildSummary, dayKey, describeProfile, loadAthleteData, loadProfile } from "../_shared/context.ts";
import { AIError, chat, errorMessage, json } from "../_shared/ai.ts";

const HISTORY_DAYS = 90;
const MAX_TOKENS = 8000;
/** Kortare än appens väntan, så att ett svar hinner fram före passet. */
const TIMEOUT_MS = 60_000;
const MAX_STEPS = 60;

const BriefSchema = z.object({
  opening: z.string().describe(
    "Sägs när passet startar: 1-2 korta meningar om dagens form och fokus, grundat i datan.",
  ),
  steps: z.array(z.object({
    index: z.number().describe("Stegets nummer i listan (0 = första steget)."),
    text: z.string().describe("En kort mening som sägs direkt efter stegets instruktion."),
  })).describe("1-4 repliker på steg där de gör mest nytta, t.ex. första arbetssteget, sista intervallen, nedvarvningen."),
  finish: z.string().describe("Sägs när passet är klart: 1-2 korta meningar, gärna kopplat till målet."),
});
type Brief = z.infer<typeof BriefSchema>;
const { $schema: _ignored, ...BRIEF_JSON_SCHEMA } = z.toJSONSchema(BriefSchema, { target: "draft-7" });

const RequestSchema = z.object({
  title: z.string().min(1).max(200),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/),
  steps: z.array(z.string().max(400)).min(1).max(MAX_STEPS),
});

const SYSTEM_PROMPT = `Du är personens träningscoach och pratar i deras hörlurar under ett löppass. Appen läser
upp passets steg själv (tider, tempo, puls). Du skriver några korta, personliga repliker som gör passet till
deras eget: varför passet ser ut som det gör idag, och lite pepp vid rätt tillfälle.

Så här skriver du:
- Allt läses upp av en talsyntes medan personen springer: korta meningar, högst cirka 20 ord per replik,
  vardaglig svenska. Inga listor, emojis, förkortningar eller markdown.
- Grunda replikerna i datan: nattens sömn, HRV och vilopuls jämfört med baslinjen, senaste passen och vad
  personen berättat om dem (anteckningar), samt profilens mål och begränsningar. Hitta aldrig på värden.
- Upprepa inte stegets instruktion (appen säger redan "Intervall 2 av 4, fyra minuter …"), utan lägg till
  något: fokus, teknik, en påminnelse om varför, eller pepp inför sista biten.
- Pekar datan på trötthet eller att personen varit sjuk: uppmana till försiktighet och att hellre ta det lugnt.
- steps.index måste vara ett nummer från stegslistan. Välj 1-4 steg där en replik gör mest nytta.`;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Använd POST." }, 405);
  const user = await userClient(req);
  if (!user) return json({ error: "Inloggning krävs." }, 401);
  const { supabase, userId } = user;

  const parsed = RequestSchema.safeParse(await req.json().catch(() => null));
  if (!parsed.success) return json({ error: "Ogiltig förfrågan." }, 400);
  const { title, date, steps } = parsed.data;

  try {
    const today = dayKey(new Date());
    const [data, profile] = await Promise.all([
      loadAthleteData(supabase, userId, HISTORY_DAYS),
      loadProfile(supabase, userId),
    ]);

    const stepList = steps.map((step, index) => `${index}: ${step}`).join("\n");
    const result = await chat({
      messages: [
        {
          role: "system",
          content: `${SYSTEM_PROMPT}\n\n# Personens profil\n${describeProfile(profile)}\n\n# Data\n${
            buildSummary(data, today)
          }`,
        },
        {
          role: "user",
          content: `Idag: ${today}. Passet (planerat ${date}): ${title}\n\nSteg i ordning:\n${stepList}`,
        },
      ],
      effort: "low",
      maxTokens: MAX_TOKENS,
      responseFormat: { name: "run_brief", schema: BRIEF_JSON_SCHEMA },
      timeoutMs: TIMEOUT_MS,
    });

    const brief = parseBrief(result.content, steps.length);
    const { error } = await supabase.from("run_briefs").insert({
      workout_title: title,
      content: brief,
      model: result.model,
      co2_grams: result.co2Grams,
    });
    if (error) console.error("run brief not saved", error);
    console.log(`run-brief: ${result.model}, ${brief.steps.length} stegrepliker, co2=${result.co2Grams}`);
    return json(brief);
  } catch (err) {
    console.error("run brief failed", err);
    return json({ error: errorMessage(err) }, 500);
  }
});

/** Validerar svaret och tar bort repliker på steg som inte finns. */
function parseBrief(text: string, stepCount: number): Brief {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch {
    throw new AIError("Coachen svarade inte med repliker. Passet körs utan.");
  }
  const result = BriefSchema.safeParse(raw);
  if (!result.success) {
    console.error("invalid brief", result.error.issues.slice(0, 5));
    throw new AIError("Coachens repliker kunde inte läsas. Passet körs utan.");
  }
  const seen = new Set<number>();
  const steps = result.data.steps
    .map((step) => ({ index: Math.round(step.index), text: step.text.trim() }))
    .filter((step) => step.index >= 0 && step.index < stepCount && step.text && !seen.has(step.index) && seen.add(step.index))
    .slice(0, 4);
  return { opening: result.data.opening.trim(), steps, finish: result.data.finish.trim() };
}
