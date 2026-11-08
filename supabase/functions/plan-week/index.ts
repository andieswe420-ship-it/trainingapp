// plan-week: skapar en AI-genererad träningsplan för veckan måndag–söndag (knappen i appen):
// innevarande vecka, eller nästa vecka om det är söndag. Dagar som redan passerat får inga pass.
//
// Flöde: appen anropar funktionen (med användarens JWT) → en rad med status 'pending'
// skapas i training_plans och dess id returneras direkt → planen genereras i bakgrunden
// (EdgeRuntime.waitUntil) → raden uppdateras till 'ready' eller 'failed'. Appen pollar raden.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { userClient } from "../_shared/auth.ts";
import { addDays, dayKey, weekStart } from "../_shared/context.ts";
import { errorMessage, json } from "../_shared/ai.ts";
import { createPendingPlan, generatePlan } from "../_shared/planner.ts";

/** Veckan som planen gäller: måndag–söndag, på söndagar nästa vecka (som den automatiska planen). */
function planWeek(today: string): { startDate: string; endDate: string } {
  const monday = weekStart(today);
  const startDate = today === addDays(monday, 6) ? addDays(today, 1) : monday;
  return { startDate, endDate: addDays(startDate, 6) };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Använd POST." }, 405);
  const user = await userClient(req);
  if (!user) return json({ error: "Inloggning krävs." }, 401);

  const body = await req.json().catch(() => ({})) as { notes?: unknown };
  const notes = typeof body.notes === "string" ? body.notes.trim().slice(0, 2000) : "";

  const { startDate, endDate } = planWeek(dayKey(new Date()));

  try {
    const planId = await createPendingPlan(user.supabase, user.userId, startDate, endDate, notes);
    EdgeRuntime.waitUntil(generatePlan(user.supabase, user.userId, planId, startDate, endDate, notes));
    return json({ id: planId, status: "pending" }, 202);
  } catch (err) {
    console.error("plan request failed", err);
    return json({ error: errorMessage(err) }, 500);
  }
});
