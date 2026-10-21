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
2. **Supabase** – (fas 2) synkar `WorkoutSummary` + `HealthMetrics` till Postgres.
   Idempotent upsert på `HKWorkout.uuid`. Nycklar läggs i `Secrets.xcconfig` (gitignorerad),
   aldrig i koden.
3. **AI-planerare** – (fas 3) körs server-side (Supabase Edge Function) och anropar
   Claude med historik + återhämtningsmått, returnerar en strukturerad veckoplan (JSON).
   API-nycklar ligger aldrig i appen.
4. **WorkoutKit** – (fas 4) appen hämtar planen och översätter den till
   `CustomWorkout`/`WorkoutPlan` och schemalägger med `WorkoutScheduler`.
   Användaren har en färdig `WorkoutScheduling.swift` som ska in i `TrainingApp/Scheduling/`.
   `WorkoutKitAuthorization` finns redan där och kan slås ihop med den filen.
5. **Apple Watch** – schemalagda pass synkas automatiskt till Träning-appen på klockan.
   Ingen egen watchOS-target behövs.

## Faser

- [x] **Fas 1** – Läs HealthKit (pass senaste 90 dagarna, vilopuls, HRV, VO2 max),
      visa lista med datum, typ, tid och snittpuls. HealthKit-/WorkoutKit-behörigheter.
- [ ] **Fas 2** – Synk till Supabase.
- [ ] **Fas 3** – AI-planering.
- [ ] **Fas 4** – Schemaläggning med WorkoutKit (`WorkoutScheduling.swift`).

## Projektstruktur

```
project.yml                 XcodeGen-spec – ENDA källan för projektinställningar
TrainingApp/
  App/                      @main-app
  HealthKit/                HealthKitManager (läsning, behörighet)
  Models/                   WorkoutSummary, HealthMetrics, svenska aktivitetsnamn
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

## Bygga och köra

```sh
brew install xcodegen          # en gång
xcodegen generate
open TrainingApp.xcodeproj     # eller bygg via XcodeBuildMCP / xcodebuild:
xcodebuild -project TrainingApp.xcodeproj -scheme TrainingApp \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Med XcodeBuildMCP: kör `xcodegen generate` först, sedan `build_run_sim` med
projekt `TrainingApp.xcodeproj`, scheme `TrainingApp`.

Simulatorn har ingen träningsdata – lägg till pass/puls manuellt i Hälsa-appen i
simulatorn för att testa listan. Team ID (`DEVELOPMENT_TEAM`) är satt i `project.yml` – ändra där, inte i Xcode.
