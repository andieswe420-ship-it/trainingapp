// weekly-plans: skapar nästa veckas plan (måndag–söndag) för alla som har automatisk veckoplan
// påslagen i profilen. Anropas av pg_cron på söndagskvällen.
//
// Funktionen deployas utan JWT-krav och skyddas istället av en hemlighet i headern
// x-cron-secret, som jämförs med Vault via databasfunktionen verify_cron_secret.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { serviceClient } from "../_shared/auth.ts";
import { addDays, dayKey } from "../_shared/context.ts";
import { errorMessage, json } from "../_shared/ai.ts";
import { createPendingPlan, generatePlan } from "../_shared/planner.ts";

const NOTES = "Automatisk veckoplan för kommande vecka (måndag–söndag).";

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ error: "Använd POST." }, 405);
  const supabase = serviceClient();

  const { data: authorized, error: secretError } = await supabase.rpc("verify_cron_secret", {
    secret: req.headers.get("x-cron-secret") ?? "",
  });
  if (secretError || authorized !== true) return json({ error: "Obehörig." }, 401);

  // Körs på söndagen – planen gäller måndag till söndag.
  const startDate = addDays(dayKey(new Date()), 1);
  const endDate = addDays(startDate, 6);

  try {
    const { data: profiles, error } = await supabase
      .from("athlete_profiles")
      .select("user_id")
      .eq("auto_weekly_plan", true);
    if (error) throw new Error(`Kunde inte läsa profiler: ${error.message}`);

    const jobs: { userId: string; planId: string }[] = [];
    for (const { user_id: userId } of profiles ?? []) {
      // Kör inte två gånger för samma vecka (t.ex. om jobbet startas om).
      const { data: existing } = await supabase
        .from("training_plans")
        .select("id")
        .eq("user_id", userId)
        .eq("start_date", startDate)
        .in("status", ["pending", "ready"])
        .limit(1);
      if (existing?.length) continue;
      jobs.push({ userId, planId: await createPendingPlan(supabase, userId, startDate, endDate, NOTES) });
    }

    EdgeRuntime.waitUntil((async () => {
      for (const job of jobs) {
        await generatePlan(supabase, job.userId, job.planId, startDate, endDate, NOTES);
      }
    })());
    return json({ created: jobs.length, start_date: startDate }, 202);
  } catch (err) {
    console.error("weekly plans failed", err);
    return json({ error: errorMessage(err) }, 500);
  }
});
