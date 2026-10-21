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
   (`WorkoutSummary`, `HealthMetrics`) så att resten av appen aldrig ser `HK*`-objekt
   (förutom aktivitetstypen).
2. **Supabase** – projekt `trainingapp` (ref `whuleymkapsysrjxyfyx`, eu-north-1).
   `SyncService` är det enda stället som pratar med `SupabaseClient`. Synkar
   `WorkoutSummary` → tabellen `workouts` och `HealthSample` → `health_samples`, idempotent
   upsert på HealthKits UUID. `user_id` sätts av databasen (`default auth.uid()`), RLS
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
   `OPENROUTER_API_KEY` är en Edge Function-secret i Supabase – aldrig i appen eller repot.
   Deploy: `supabase functions deploy plan-week` (eller Supabase MCP – ange då
   `import_map_path: deno.json`).
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
- [ ] **Fas 4** – Schemaläggning med WorkoutKit (`WorkoutScheduling.swift`).

## Projektstruktur

```
project.yml                 XcodeGen-spec – ENDA källan för projektinställningar
Config/                     App.xcconfig (incheckad) + Secrets.xcconfig (gitignorerad)
supabase/migrations/        Databasschema (SQL)
supabase/functions/         Edge Functions (plan-week)
TrainingApp/
  App/                      @main-app
  HealthKit/                HealthKitManager (läsning, behörighet)
  Models/                   WorkoutSummary, HealthSample, HealthMetrics, TrainingPlan, svenska namn
  Planning/                 PlanStore (beställ plan, polla tills klar)
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
