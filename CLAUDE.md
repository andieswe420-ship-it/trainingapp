# TrainingApp – personlig träningsapp (iOS 17+, SwiftUI)

## Arkitektur (målbild)

```
HealthKit  ──►  Supabase  ──►  AI-planerare  ──►  WorkoutKit  ──►  Apple Watch
 (läsa pass,     (lagring,       (genererar          (schemalägger    (passen dyker
  vilopuls,       historik,       veckoplan utifrån   pass med         upp i Träning-
  HRV, VO2max)    planer)         belastning/återh.)  WorkoutScheduler) appen)
```

1. **HealthKit** – källan för all rådata. `HealthKitManager` är det enda stället som pratar
   med `HKHealthStore`. Data mappas direkt till appens egna värdetyper
   (`WorkoutSummary`, `HealthSample`, `DailyMetrics`, `HealthMetrics`) så att resten av appen
   aldrig ser `HK*`-objekt (förutom aktivitetstypen). Per pass: snitt-/maxpuls, pulsfördelning
   i 10-bpm-intervall, pulsåterhämtning och löpdynamik. Per dag: sömn (faser, räknas till
   dagen man vaknar, en källa per natt), steg, aktiv energi, träningsminuter, ståtimmar,
   andningsfrekvens och handledstemperatur. Saknad behörighet för en typ ger bara tom data.
   **Bakgrund:** `observeNewWorkouts` (HKObserverQuery + background delivery, entitlement i
   `project.yml`) registreras i `TrainingApp.init` och väcker appen när ett pass sparas →
   synk → coachens check-in → lokal notis om appen inte är öppen. När appen blir aktiv
   (scenePhase) synkas och uppdateras plan och chatt.
2. **Supabase** – projekt `trainingapp` (ref `whuleymkapsysrjxyfyx`, eu-north-1).
   `SyncService` är det enda stället som pratar med `SupabaseClient`. Synkar
   `WorkoutSummary` → `workouts`, `HealthSample` → `health_samples` (upsert på HealthKits UUID)
   och `DailyMetrics` → `daily_metrics` (upsert på `user_id,date`). Efter varje synk anropas
   coachens `checkin`. `user_id` sätts av databasen (`default auth.uid()`), RLS
   begränsar allt till egna rader. Inloggning: e-post + lösenord (Supabase Auth).
   Schemat ligger i `supabase/migrations/` – nya ändringar läggs som nya migrationsfiler.
   URL/nyckel läggs i `Config/Secrets.xcconfig` (gitignorerad), aldrig i koden.
3. **AI-planerare** – Edge Function `plan-week` (`supabase/functions/plan-week/`).
   Appen anropar den (användarens JWT) → en rad med status `pending` skapas i
   `training_plans` och id:t returneras direkt → planen genereras i bakgrunden
   (`EdgeRuntime.waitUntil`) → raden blir `ready`/`failed`. `PlanStore` pollar raden.
   Funktionen sammanfattar 90 dagars historik (`summary.ts`: daglig HRV-median, vilopuls,
   veckobelastning, passlista) och anropar Claude via **OpenRouter**
   (`anthropic/claude-opus-5.5`, reserv `anthropic/claude-opus-5`, `reasoning.effort: medium`)
   med strukturerad output (`response_format: json_schema`, strict) genererad från `schema.ts`
   (Zod). Svaret valideras med Zod innan det sparas.
   Planformatet speglar WorkoutKit: uppvärmning/nedvarvning i minuter, block med
   `iterations` och steg med mål (time/distance/open) och larm (pulszon/pulsintervall/tempo).
   Ändras schemat måste `TrainingApp/Models/TrainingPlan.swift` följa med.
   **Coach** – Edge Function `coach` (`supabase/functions/coach/`), chatt i fliken "Coach".
   Åtgärder: `send` (användarmeddelande → svar), `checkin` (fråga om senaste passet inom 48 h,
   max en gång per pass via unikt index), `decide` (godkänn/avböj förslag). Svar skapas som
   `pending` i `coach_messages` och fylls i bakgrunden; `CoachStore` pollar. Coachen ser samma
   kontext som planeraren plus aktuell plan (med genomförda pass) och konversationen, och kan
   föreslå ändringar via verktyget `propose_plan_change` (hela passlistan för idag–planens
   slut). Förslag tillämpas bara när användaren godkänner. Effort `low`, kontexten cachas.
   **Profil** – `athlete_profiles` (mål, veckoschema per veckodag, skador/begränsningar,
   övrigt). Både coach och planerare läser den (`describeProfile` i `_shared/context.ts`);
   planeraren följer veckoschemat. Coachen sparar bestående saker själv via verktyget
   `update_profile` (utan godkännande, veckodagar slås ihop) och det visas i chatten
   (`coach_messages.profile_update`). Användaren kan redigera profilen i `ProfileView`
   (knapp i Plan- och Coach-fliken).
   Delad serverkod ligger i `supabase/functions/_shared/` (kontext, schema, AI-anrop, auth).
   **AI-leverantör** (`_shared/ai.ts`, OpenAI-kompatibla chat completions) väljs med Edge Function-
   secrets: `AI_PROVIDER` = `openrouter` (standard) eller `berget` (Berget AI, Stockholm, med
   `BERGET_API_KEY` och valfri `BERGET_MODEL`, standard `moonshotai/Kimi-K3`). Med Berget används
   OpenRouter som reserv vid fel (inte vid timeout). Kolumnen `model` visar vilken modell som svarade
   (`berget/...`). `reasoning_effort` skickas till Berget – planer och trendanalys kör `low` (Kimi med fullt
   resonemang tar >100 s för en veckoplan, mot Edge Functions tidsgräns 150 s; med `low` ~30 s). Planer och
   analyser avbryts efter 120 s och markeras `failed` så att raden inte blir hängande. Berget returnerar
   CO₂ per anrop i `usage.co2_grams` – det sparas i `co2_grams` på `coach_messages`, `training_plans` och
   `trend_insights` och summeras via vyn `ai_usage` (security_invoker) i kortet "AI-användningens
   klimatavtryck" i Trender (`AIUsage`, `SyncService.fetchAIUsage`).
   **Coachens minne:** `log_workout` sparar vad ett pass faktiskt var (`workouts.athlete_note`, visas i
   chatten via `coach_messages.workout_note`) och följer med i all kontext. Verktygsresultat läggs i
   historiken som "Notis från appen" – aldrig i coachens text, annars härmar modellen formatet.
   Nycklarna (`OPENROUTER_API_KEY`, `BERGET_API_KEY`) är secrets i Supabase – aldrig i appen eller repot.
   **Automatisk veckoplan** – Edge Function `weekly-plans` anropas av pg_cron söndagar 17:00 UTC
   och skapar måndag–söndag-planer för profiler med `auto_weekly_plan`. Den kör med service role
   och skyddas av headern `x-cron-secret` som jämförs mot Vault (`verify_cron_secret`). Därför
   filtrerar alla läsningar i `_shared/context.ts` och `_shared/planner.ts` på `user_id`.
   Appen schemalägger en lokal påminnelse söndagar 19:30 (`Notifications`).
   **Trendanalys** – Edge Function `insights`: appen räknar fram nyckeltal (`TrendSnapshot` i
   `TrainingApp/Analysis/`) och skickar dem; AI:n skriver en övergripande analys, en kommentar
   per diagram (status positive/neutral/attention) och mönster. Sparas i `trend_insights` en gång
   per dag och period (`4w`/`3m`/`6m`); `force` skapar en ny. `InsightStore` pollar.
   Deploy: `supabase functions deploy plan-week coach` och
   `supabase functions deploy weekly-plans --no-verify-jwt` (eller Supabase MCP – ange då
   `import_map_path: deno.json` och skicka med `_shared`-filerna som `../_shared/<fil>`).
4. **WorkoutKit** – (fas 4) appen hämtar planen och översätter den till
   `CustomWorkout`/`WorkoutPlan` och schemalägger med `WorkoutScheduler`.
   Användaren har en färdig `WorkoutScheduling.swift` som ska in i `TrainingApp/Scheduling/`.
   `WorkoutKitAuthorization` finns redan där och kan slås ihop med den filen.
5. **Apple Watch** – schemalagda pass synkas automatiskt till Träning-appen på klockan.
   Ingen egen watchOS-target behövs.

## Faser

- [x] **Fas 1** – Läs HealthKit (pass senaste 90 dagarna, vilopuls, HRV, VO2 max),
      visa lista med datum, typ, tid och snittpuls. HealthKit-/WorkoutKit-behörigheter.
- [x] **Fas 2** – Synk till Supabase (inloggning, synk vid start/dra-för-att-uppdatera/knapp).
- [x] **Fas 3** – AI-planering (Edge Function `plan-week`, flik "Plan" i appen).
- [x] **Fas 3b** – Löpande coach (chatt, frågor efter pass, förslag på planändringar) och
      utökad hälsodata (sömn, aktivitet, andning, temperatur, löpdynamik, pulsfördelning).
- [x] **Fas 3c** – Träningsprofil (mål, veckoschema, skador) som coach och planerare följer.
- [x] **Fas 3d** – Bakgrundssynk med notis efter pass, automatisk veckoplan på söndagar,
      pilates/yoga som passtyper och flik "Trender" (Swift Charts).
- [x] **Fas 3e** – Utökade trender: periodval och jämförelse, normalintervall (band),
      form/belastning (TRIMP, kondition/trötthet/form, belastningskvot), aerob effektivitet
      (meter per hjärtslag), AI-analys och "Fråga coachen". 180 dagars historik från HealthKit.
- [ ] **Fas 4** – Schemaläggning med WorkoutKit (`WorkoutScheduling.swift`).

## Projektstruktur

```
project.yml                 XcodeGen-spec – ENDA källan för projektinställningar
Config/                     App.xcconfig (incheckad) + Secrets.xcconfig (gitignorerad)
supabase/migrations/        Databasschema (SQL)
supabase/functions/         Edge Functions (plan-week, coach, weekly-plans, insights, _shared)
TrainingApp/
  App/                      @main-app, AppDelegate (notiser), AppRouter (flikar), Notifications
  Analysis/                 TrendAnalysis (beräkningar), TrendSnapshot (nyckeltal till AI-analysen)
  HealthKit/                HealthKitManager (läsning, behörighet)
  Models/                   WorkoutSummary, HealthSample, DailyMetrics, HealthMetrics, TrainingPlan,
                            CoachMessage, AthleteProfile, svenska namn
  Planning/                 PlanStore, CoachStore, InsightStore (beställ/skicka, polla tills klart)
  Sync/                     SyncService (Supabase-auth + upsert), DTO:er, konfiguration
  Views/                    SwiftUI-vyer
  Scheduling/               WorkoutKit (behörighet nu, schemaläggning i fas 4)
  Resources/                Assets.xcassets
```

## Regler för arbete i repot

- **Redigera aldrig `.xcodeproj` för hand.** Den är gitignorerad och genereras med
  `xcodegen generate`. Nya filer under `TrainingApp/` plockas upp automatiskt.
- `Info.plist` och `TrainingApp.entitlements` genereras också från `project.yml`
  (sektionerna `info:` och `entitlements:`) – ändra där.
- Alla användarsynliga texter och behörighetstexter är på **svenska**.
- iOS 17+: använd `@Observable`, `NavigationStack`, `ContentUnavailableView`,
  async HealthKit-API:er (`HKSampleQueryDescriptor`).
- Vyer får inte importera HealthKit-frågor direkt – gå via `HealthKitManager`.
  Samma sak för Supabase – gå via `SyncService`.
- I xcconfig startar `//` en kommentar – ange därför `SUPABASE_HOST` utan `https://`.

## Bygga och köra

```sh
brew install xcodegen          # en gång
cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig   # en gång, fyll i värden
xcodegen generate
open TrainingApp.xcodeproj     # eller bygg via XcodeBuildMCP / xcodebuild:
xcodebuild -project TrainingApp.xcodeproj -scheme TrainingApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Med XcodeBuildMCP: kör `xcodegen generate` först, sedan `build_run_sim` med
projekt `TrainingApp.xcodeproj`, scheme `TrainingApp`.

Simulatorn har ingen träningsdata – lägg till pass/puls manuellt i Hälsa-appen i
simulatorn för att testa listan. Team ID (`DEVELOPMENT_TEAM`) är satt i `project.yml` – ändra där, inte i Xcode.
