// coach: löpande träningscoach att chatta med.
//
// Åtgärder (POST { action, ... }):
// - "send"    { text }                 – sparar användarens meddelande och skapar ett svar.
// - "checkin" {}                       – om ett nytt pass synkats (senaste 48 h) som coachen inte
//                                        frågat om än, skapas en fråga om passet. Annars inget.
// - "decide"  { message_id, accept }   – godkänn eller avböj ett förslag på planändring.
//
// Svar skapas som en rad med status 'pending' i coach_messages som fylls i bakgrunden
// (EdgeRuntime.waitUntil); appen pollar raden. Coachen kan föreslå planändringar via verktyget
// propose_plan_change – de sparas som förslag och tillämpas först när användaren godkänner.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import type { SupabaseClient } from "@supabase/supabase-js";
import { z } from "zod";
import { userClient } from "../_shared/auth.ts";
import {
  type AthleteData,
  buildSummary,
  clockTime,
  dayKey,
  describePlan,
  describePlannedWorkout,
  describeProfile,
  describeWorkout,
  loadActivePlan,
  loadAthleteData,
  loadProfile,
  type PlanRow,
  type ProfileRow,
  weekday,
  WEEKDAYS,
  type WorkoutRow,
} from "../_shared/context.ts";
import { chat, type ChatMessage, defaultModel, errorMessage, json, type ToolCall } from "../_shared/ai.ts";
import { cleanWorkouts, WorkoutSchema } from "../_shared/schema.ts";

const HISTORY_DAYS = 90;
const HISTORY_MESSAGES = 40;
const CHECKIN_WINDOW_HOURS = 48;
/** Med effort "low" reserveras ~20 % av max_tokens för resonemang. */
const MAX_TOKENS = 24000;

const ProposalInputSchema = z.object({
  reason: z.string().describe("Kort förklaring på svenska av vad som ändras och varför."),
  workouts: z.array(WorkoutSchema).describe(
    "HELA den nya listan av pass för de berörda datumen – även pass som inte ändras. Vilodagar utelämnas.",
  ),
});
const { $schema: _ignored, ...PROPOSAL_JSON_SCHEMA } = z.toJSONSchema(ProposalInputSchema, { target: "draft-7" });

const dayText = z.string().describe("Vad dagen ska innehålla, t.ex. \"Vila\" eller \"Intervaller inomhus\". Tom sträng = flexibel.");
const ProfileUpdateSchema = z.object({
  summary: z.string().describe("Kort beskrivning på svenska av vad som ändrades i profilen."),
  goals: z.string().optional().describe("Personens mål – hela den nya texten."),
  weekly_schedule: z.object(Object.fromEntries(WEEKDAYS.map(([key]) => [key, dayText.optional()])))
    .optional()
    .describe("Dagar som ändras i veckoschemat. Dagar som utelämnas behålls."),
  limitations: z.string().optional().describe("Skador och begränsningar – hela den nya texten."),
  notes: z.string().optional().describe("Övriga bestående preferenser – hela den nya texten."),
});
const { $schema: _ignored2, ...PROFILE_JSON_SCHEMA } = z.toJSONSchema(ProfileUpdateSchema, { target: "draft-7" });

const WorkoutNoteSchema = z.object({
  date: z.string().describe("Datum för passet, YYYY-MM-DD."),
  time: z.string().optional().describe("Starttid HH:MM, behövs bara om det finns flera pass samma dag."),
  note: z.string().describe(
    "Vad passet var och hur det kändes enligt personen, kort på svenska, t.ex. \"Intervaller på löpband, " +
      "ansträngning 7/10, tunga ben\". Ersätter en tidigare anteckning – ta med det som fortfarande gäller.",
  ),
});
const { $schema: _ignored3, ...WORKOUT_NOTE_JSON_SCHEMA } = z.toJSONSchema(WorkoutNoteSchema, { target: "draft-7" });

/** Rader som appen lägger in i historiken och som modellen inte ska skriva själv. */
const APP_NOTE_PATTERN = /^\s*\[(Notis från appen|Föreslagen planändring|Profil uppdaterad|Pass noterat)[^\]]*\]\s*$/gm;

interface Proposal {
  reason: string;
  window_start: string;
  window_end: string;
  workouts: z.infer<typeof WorkoutSchema>[];
}

interface MessageRow {
  id: string;
  role: "user" | "assistant";
  content: string;
  status: "pending" | "done" | "failed";
  workout_id: string | null;
  proposal: Proposal | null;
  proposal_status: "pending" | "accepted" | "rejected" | null;
  plan_id: string | null;
  profile_update: { summary: string } | null;
  workout_note: { summary: string } | null;
  created_at: string;
}

const SYSTEM_PROMPT = `Du är personens löpande träningscoach i en chatt i deras träningsapp. Du har tillgång till
all deras data från Apple Watch och iPhone (pass med puls och löpdynamik, HRV, vilopuls, VO2 max, sömn,
steg, aktivitet, andningsfrekvens och handledstemperatur) och till den aktuella träningsplanen.

Så här coachar du:
- Svara kort och personligt, som i en chatt: oftast 2-6 meningar. Använd listor bara när det verkligen
  hjälper (t.ex. kommande pass). Skriv på svenska.
- Grunda allt i datan. Hänvisa gärna till konkreta värden ("din vilopuls har legat 4 slag över det
  normala i tre dagar"), men hitta aldrig på siffror som inte finns i datan.
- Bevaka formen löpande: sömn, HRV, vilopuls och känsla. Om flera tecken pekar på trötthet eller
  begynnande sjukdom (förhöjd vilopuls, andningsfrekvens och handledstemperatur samtidigt) – säg det och
  föreslå lättare träning eller vila. Vid smärta eller skada: råd till vila och att söka vård vid behov.
- Det som faktiskt hänt går före planen. Anta aldrig att ett genomfört pass var det planerade passet –
  utgå från datan (typ, tid, puls, tempo, pulsfördelning) och det personen berättat. Ser passet annorlunda
  ut än planerat: säg det och fråga vad det blev. Nämn bara pass och värden som finns i datan eller
  samtalet; säg aldrig att något hände en dag om det inte står där.
- När personen berättar vad ett pass var eller hur det kändes (t.ex. "det blev intervaller inomhus",
  ansträngning, tunga ben): spara det på passet med verktyget log_workout, så att du och veckoplaneringen
  minns det framöver. Koppla ihop känslan med datan och använd det i bedömningen av kommande pass.
- Om kommande pass bör ändras (form, sjukdom, schema, önskemål, eller att personen redan flyttat eller
  bytt ett pass) – använd verktyget propose_plan_change. Ändringen träder i kraft först när personen
  godkänner den i appen, så beskriv kort i texten vad du föreslår. Skriv aldrig att en ändring är gjord
  eller godkänd – planen ändras bara via verktyget och personens godkännande. Föreslå bara ändringar när
  det finns en tydlig anledning.
- Rader inom hakparentes som börjar med "Notis från appen" är skrivna av appen, inte av dig. Skriv aldrig
  sådana rader själv.
- Finns ingen aktiv plan kan du inte föreslå ändringar; tipsa då om att skapa en ny veckoplan under
  fliken Plan.
- Personens profil (mål, veckoschema, skador, övrigt) är det som gäller långsiktigt och används även när
  nya veckoplaner skapas. När personen berättar något bestående – nytt veckoschema, mål, skada,
  preferens – spara det med verktyget update_profile och nämn kort att du uppdaterat profilen. Tillfälliga
  saker (t.ex. "jag är bortrest i helgen") sparas inte i profilen. Följ veckoschemat när du föreslår pass.
- Formatregler för pass i förslag: uppvärmning/nedvarvning i minuter, huvuddelen som block med steg
  (distanspass = ett block med iterations=1 och ett work-steg; intervaller = iterations=N med ett
  work-steg och ett recovery-steg; styrka/HIIT/rörlighet/pilates/yoga = tidsbaserade steg med
  target_type "none"; använd activity "pilates" respektive "yoga" för de passen).`;

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Använd POST." }, 405);
  const user = await userClient(req);
  if (!user) return json({ error: "Inloggning krävs." }, 401);
  const { supabase, userId } = user;

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  try {
    switch (body.action) {
      case "send":
        return await send(supabase, userId, typeof body.text === "string" ? body.text.trim() : "");
      case "checkin":
        return await checkin(supabase, userId);
      case "decide":
        return await decide(supabase, String(body.message_id ?? ""), body.accept === true);
      default:
        return json({ error: "Okänd åtgärd." }, 400);
    }
  } catch (err) {
    console.error("coach request failed", err);
    return json({ error: errorMessage(err) }, 500);
  }
});

// MARK: - Åtgärder

async function send(supabase: SupabaseClient, userId: string, text: string): Promise<Response> {
  if (!text) return json({ error: "Tomt meddelande." }, 400);
  const { data: userMessage, error: userError } = await supabase
    .from("coach_messages")
    .insert({ role: "user", content: text.slice(0, 4000) })
    .select("id")
    .single();
  if (userError || !userMessage) throw new Error(`Kunde inte spara meddelandet: ${userError?.message}`);

  const reply = await createPendingReply(supabase, {});
  EdgeRuntime.waitUntil(generateReply(supabase, userId, reply.id, null));
  return json({ user_message_id: userMessage.id, assistant_message_id: reply.id }, 202);
}

async function checkin(supabase: SupabaseClient, userId: string): Promise<Response> {
  const since = new Date(Date.now() - CHECKIN_WINDOW_HOURS * 3600 * 1000).toISOString();
  const { data: recent, error } = await supabase
    .from("workouts")
    .select("id")
    .gte("ended_at", since)
    .order("ended_at", { ascending: false })
    .limit(1);
  if (error) throw new Error(`Kunde inte läsa pass: ${error.message}`);
  const workoutId = recent?.[0]?.id as string | undefined;
  if (!workoutId) return json({ created: false });

  // Det unika indexet (user_id, workout_id) gör att varje pass bara får en fråga.
  const { data: existing } = await supabase.from("coach_messages").select("id").eq("workout_id", workoutId).limit(1);
  if (existing?.length) return json({ created: false });

  let reply: { id: string };
  try {
    reply = await createPendingReply(supabase, { workout_id: workoutId });
  } catch {
    return json({ created: false }); // Ett parallellt anrop hann före.
  }
  EdgeRuntime.waitUntil(generateReply(supabase, userId, reply.id, workoutId));
  return json({ created: true, assistant_message_id: reply.id }, 202);
}

async function decide(supabase: SupabaseClient, messageId: string, accept: boolean): Promise<Response> {
  const { data: message, error } = await supabase
    .from("coach_messages")
    .select("id, proposal, proposal_status, plan_id")
    .eq("id", messageId)
    .single();
  if (error || !message) return json({ error: "Förslaget hittades inte." }, 404);
  if (message.proposal_status !== "pending" || !message.proposal || !message.plan_id) {
    return json({ error: "Förslaget är redan hanterat." }, 409);
  }

  if (accept) {
    const proposal = message.proposal as Proposal;
    const { data: planRow, error: planError } = await supabase
      .from("training_plans")
      .select("id, plan")
      .eq("id", message.plan_id)
      .single();
    if (planError || !planRow?.plan) return json({ error: "Planen hittades inte." }, 404);

    // Pass utanför förslagets period behålls; inom perioden ersätts allt med förslaget.
    const kept = (planRow.plan.workouts as Proposal["workouts"]).filter(
      (w) => w.date < proposal.window_start || w.date > proposal.window_end,
    );
    const workouts = [...kept, ...proposal.workouts].sort((a, b) => a.date.localeCompare(b.date));
    const { error: updateError } = await supabase
      .from("training_plans")
      .update({ plan: { ...planRow.plan, workouts }, updated_at: new Date().toISOString() })
      .eq("id", planRow.id);
    if (updateError) throw new Error(`Kunde inte uppdatera planen: ${updateError.message}`);
  }

  const { error: statusError } = await supabase
    .from("coach_messages")
    .update({ proposal_status: accept ? "accepted" : "rejected", updated_at: new Date().toISOString() })
    .eq("id", messageId);
  if (statusError) throw new Error(`Kunde inte spara beslutet: ${statusError.message}`);
  return json({ ok: true });
}

async function createPendingReply(
  supabase: SupabaseClient,
  extra: { workout_id?: string },
): Promise<{ id: string }> {
  const { data, error } = await supabase
    .from("coach_messages")
    .insert({ role: "assistant", status: "pending", model: defaultModel(), ...extra })
    .select("id")
    .single();
  if (error || !data) throw new Error(`Kunde inte skapa svar: ${error?.message}`);
  return data;
}

// MARK: - Generering

async function generateReply(
  supabase: SupabaseClient,
  userId: string,
  replyId: string,
  checkinWorkoutId: string | null,
) {
  try {
    const today = dayKey(new Date());
    const [data, plan, history, profile] = await Promise.all([
      loadAthleteData(supabase, userId, HISTORY_DAYS),
      loadActivePlan(supabase, userId, today),
      loadHistory(supabase, replyId),
      loadProfile(supabase, userId),
    ]);

    const messages = buildMessages(data, plan, profile, history, today, checkinWorkoutId);
    const windowStart = today;
    const windowEnd = plan?.end_date ?? today;

    const result = await chat({
      messages,
      effort: "low",
      maxTokens: MAX_TOKENS,
      tools: [
        {
          name: "log_workout",
          description: "Spara vad ett genomfört pass faktiskt var och hur det kändes, enligt personen.",
          parameters: WORKOUT_NOTE_JSON_SCHEMA,
        },
        {
          name: "update_profile",
          description: "Spara bestående information i personens profil (mål, veckoschema, skador, övrigt). " +
            "Ange bara de fält som ändras.",
          parameters: PROFILE_JSON_SCHEMA,
        },
        ...(plan?.plan
          ? [{
            name: "propose_plan_change",
            description: `Föreslå ändrade pass i den aktiva planen för perioden ${windowStart} till ${windowEnd}. ` +
              "Ange hela den nya listan av pass för perioden, även oförändrade pass. " +
              "Personen måste godkänna förslaget i appen innan det gäller.",
            parameters: PROPOSAL_JSON_SCHEMA,
          }]
          : []),
      ],
    });

    const profileCall = result.toolCalls.find((c) => c.function.name === "update_profile");
    const profileUpdate = profileCall ? await applyProfileUpdate(supabase, profile, profileCall) : null;
    const noteCall = result.toolCalls.find((c) => c.function.name === "log_workout");
    const workoutNote = noteCall ? await applyWorkoutNote(supabase, userId, data.workouts, noteCall) : null;

    let proposal: Proposal | null = null;
    const call = result.toolCalls.find((c) => c.function.name === "propose_plan_change");
    if (call && plan) {
      const parsed = ProposalInputSchema.safeParse(safeJson(call.function.arguments));
      if (parsed.success) {
        proposal = {
          reason: parsed.data.reason,
          window_start: windowStart,
          window_end: windowEnd,
          workouts: cleanWorkouts(parsed.data.workouts, windowStart, windowEnd),
        };
      } else {
        console.error("invalid proposal", parsed.error.issues.slice(0, 5));
      }
    }

    const content = result.content.replace(APP_NOTE_PATTERN, "").trim() || proposal?.reason ||
      profileUpdate?.summary || workoutNote?.summary || "";
    if (!content) throw new Error("AI-coachen svarade inte. Försök igen.");

    const { error } = await supabase
      .from("coach_messages")
      .update({
        status: "done",
        content,
        model: result.model,
        proposal,
        proposal_status: proposal ? "pending" : null,
        plan_id: proposal ? plan!.id : null,
        profile_update: profileUpdate,
        workout_note: workoutNote,
        updated_at: new Date().toISOString(),
      })
      .eq("id", replyId);
    if (error) throw new Error(`Kunde inte spara svaret: ${error.message}`);
  } catch (err) {
    console.error("coach reply failed", err);
    await supabase
      .from("coach_messages")
      .update({ status: "failed", error: errorMessage(err), updated_at: new Date().toISOString() })
      .eq("id", replyId);
  }
}

async function loadHistory(supabase: SupabaseClient, excludeId: string): Promise<MessageRow[]> {
  const { data, error } = await supabase
    .from("coach_messages")
    .select("id, role, content, status, workout_id, proposal, proposal_status, plan_id, profile_update, workout_note, created_at")
    .neq("id", excludeId)
    .eq("status", "done")
    .order("created_at", { ascending: false })
    .limit(HISTORY_MESSAGES);
  if (error) throw new Error(`Kunde inte läsa konversationen: ${error.message}`);
  return (data as MessageRow[]).reverse();
}

function buildMessages(
  data: AthleteData,
  plan: PlanRow | null,
  profile: ProfileRow | null,
  history: MessageRow[],
  today: string,
  checkinWorkoutId: string | null,
): ChatMessage[] {
  const workoutsById = new Map(data.workouts.map((w) => [w.id, w]));
  const now = new Date();

  const messages: ChatMessage[] = [{
    role: "system",
    content: [
      {
        type: "text",
        text: `${SYSTEM_PROMPT}\n\n# Personens profil\n${describeProfile(profile)}\n\n# Data\n${
          buildSummary(data, today)
        }\n\n# Aktuell plan\n${describePlan(plan, data.workouts, today)}`,
        // Datan ändras sällan inom en chattsession – cachas hos Anthropic.
        cache_control: { type: "ephemeral" },
      },
      { type: "text", text: `Just nu: ${today} ${weekday(today)} kl. ${clockTime(now)}.` },
    ],
  }];

  // Konversationen. Coachens frågor efter pass föregås av en syntetisk användarrad om passet,
  // så att rollerna alternerar och modellen ser vilket pass frågan gällde.
  for (const m of history) {
    if (m.role === "assistant" && m.workout_id) {
      push(messages, "user", workoutNotice(workoutsById.get(m.workout_id)));
    }
    push(messages, m.role, m.content.replace(APP_NOTE_PATTERN, "").trim());
    // Vad verktygen gjorde läggs som en notis från appen efter svaret – inte i coachens egen text,
    // annars härmar modellen formatet i stället för att anropa verktygen.
    const notes: string[] = [];
    if (m.proposal) {
      const status = { pending: "inte svarat på", accepted: "godkänt", rejected: "avböjt" }[m.proposal_status ?? "pending"];
      notes.push(`coachen föreslog en planändring som personen har ${status}: ${m.proposal.reason}. Pass: ${
        m.proposal.workouts.map((w) => `${w.date}: ${describePlannedWorkout(w)}`).join(" / ") || "inga"
      }`);
    }
    if (m.profile_update) notes.push(`profilen uppdaterades: ${m.profile_update.summary}`);
    if (m.workout_note) notes.push(`anteckning sparad på passet: ${m.workout_note.summary}`);
    if (notes.length) push(messages, "user", `[Notis från appen: ${notes.join("; ")}]`);
  }

  if (checkinWorkoutId) {
    push(
      messages,
      "user",
      `${workoutNotice(workoutsById.get(checkinWorkoutId))}\n` +
        "[Ställ en kort, personlig fråga om hur passet kändes – t.ex. ansträngning 1-10 och hur kroppen " +
        "kändes – och kommentera gärna något konkret i datan från passet. Utgå från datan, inte från planen: " +
        "om passet ser ut att vara något annat än det planerade, säg det och fråga vad det blev. Max 3-4 " +
        "meningar. Föreslå inga planändringar förrän personen svarat, om inte datan tydligt kräver det.]",
    );
  }

  // Konversationen måste börja med ett användarmeddelande (historiken kan vara avkapad).
  if (messages[1]?.role === "assistant") {
    messages.splice(1, 0, { role: "user", content: "[Tidigare i samtalet.]" });
  }
  // Modellen måste svara på ett användarmeddelande.
  if (messages[messages.length - 1].role !== "user") {
    push(messages, "user", "[Fortsätt samtalet.]");
  }
  return messages;
}

/** Sparar coachens profiländring. Veckodagar slås ihop med befintligt schema; tom sträng tar bort dagen. */
async function applyProfileUpdate(
  supabase: SupabaseClient,
  current: ProfileRow | null,
  call: ToolCall,
): Promise<{ summary: string; fields: string[] } | null> {
  const parsed = ProfileUpdateSchema.safeParse(safeJson(call.function.arguments));
  if (!parsed.success) {
    console.error("invalid profile update", parsed.error.issues.slice(0, 5));
    return null;
  }
  const update = parsed.data;
  const patch: Record<string, unknown> = { updated_at: new Date().toISOString() };
  const fields: string[] = [];
  for (const key of ["goals", "limitations", "notes"] as const) {
    if (update[key] !== undefined) {
      patch[key] = update[key]?.trim() || null;
      fields.push(key);
    }
  }
  if (update.weekly_schedule) {
    const merged: Record<string, string> = { ...(current?.weekly_schedule ?? {}) };
    for (const [day, text] of Object.entries(update.weekly_schedule)) {
      if (text === undefined) continue;
      if (text.trim()) merged[day] = text.trim();
      else delete merged[day];
    }
    patch.weekly_schedule = merged;
    fields.push("weekly_schedule");
  }
  if (!fields.length) return null;

  const { error } = await supabase.from("athlete_profiles").upsert(patch, { onConflict: "user_id" });
  if (error) {
    console.error("profile update failed", error);
    return null;
  }
  return { summary: update.summary, fields };
}

/** Sparar personens beskrivning av ett genomfört pass på passet. */
async function applyWorkoutNote(
  supabase: SupabaseClient,
  userId: string,
  workouts: WorkoutRow[],
  call: ToolCall,
): Promise<{ summary: string } | null> {
  const parsed = WorkoutNoteSchema.safeParse(safeJson(call.function.arguments));
  if (!parsed.success || !parsed.data.note.trim()) {
    console.error("invalid workout note", parsed.success ? "empty note" : parsed.error.issues.slice(0, 5));
    return null;
  }
  const { date, time, note } = parsed.data;
  const sameDay = workouts.filter((w) => dayKey(w.started_at) === date);
  const workout = sameDay.find((w) => time && clockTime(w.started_at) === time) ?? sameDay[sameDay.length - 1];
  if (!workout) {
    console.error("workout note: no workout on", date);
    return null;
  }
  const text = note.trim().slice(0, 500);
  const { error } = await supabase
    .from("workouts")
    .update({ athlete_note: text })
    .eq("id", workout.id)
    .eq("user_id", userId);
  if (error) {
    console.error("workout note failed", error);
    return null;
  }
  return { summary: `${weekday(date)} ${clockTime(workout.started_at)} ${workout.activity_name.toLowerCase()} – ${text}` };
}

function workoutNotice(workout: WorkoutRow | undefined): string {
  return workout
    ? `[Nytt pass synkat: ${describeWorkout(workout, true)}]`
    : "[Nytt pass synkat (detaljer saknas).]";
}

/** Lägger till ett meddelande och slår ihop med föregående om rollen är densamma. */
function push(messages: ChatMessage[], role: "user" | "assistant", content: string) {
  const last = messages[messages.length - 1];
  if (last.role === role && typeof last.content === "string") {
    last.content += `\n\n${content}`;
  } else {
    messages.push({ role, content });
  }
}

function safeJson(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
