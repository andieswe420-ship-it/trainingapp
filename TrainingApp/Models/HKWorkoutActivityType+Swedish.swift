import HealthKit

extension HKWorkoutActivityType {
    var swedishName: String {
        switch self {
        case .running: "Löpning"
        case .walking: "Promenad"
        case .hiking: "Vandring"
        case .cycling: "Cykling"
        case .swimming: "Simning"
        case .rowing: "Rodd"
        case .crossCountrySkiing: "Längdskidor"
        case .downhillSkiing: "Utförsåkning"
        case .elliptical: "Crosstrainer"
        case .stairClimbing, .stairs: "Trappor"
        case .traditionalStrengthTraining: "Styrketräning"
        case .functionalStrengthTraining: "Funktionell styrka"
        case .coreTraining: "Bålträning"
        case .highIntensityIntervalTraining: "HIIT"
        case .crossTraining: "Crossträning"
        case .mixedCardio: "Blandad kondition"
        case .yoga: "Yoga"
        case .pilates: "Pilates"
        case .flexibility: "Rörlighet"
        case .cooldown: "Nedvarvning"
        case .dance, .socialDance, .cardioDance: "Dans"
        case .boxing, .kickboxing: "Boxning"
        case .martialArts: "Kampsport"
        case .climbing: "Klättring"
        case .soccer: "Fotboll"
        case .tennis: "Tennis"
        case .golf: "Golf"
        case .paddleSports: "Paddling"
        case .swimBikeRun: "Triathlon"
        case .transition: "Växling"
        case .other: "Övrigt"
        default: "Träning"
        }
    }

    var symbolName: String {
        switch self {
        case .running: "figure.run"
        case .walking: "figure.walk"
        case .hiking: "figure.hiking"
        case .cycling: "figure.outdoor.cycle"
        case .swimming: "figure.pool.swim"
        case .rowing: "figure.rower"
        case .crossCountrySkiing: "figure.skiing.crosscountry"
        case .downhillSkiing: "figure.skiing.downhill"
        case .elliptical: "figure.elliptical"
        case .stairClimbing, .stairs: "figure.stair.stepper"
        case .traditionalStrengthTraining: "figure.strengthtraining.traditional"
        case .functionalStrengthTraining: "figure.strengthtraining.functional"
        case .coreTraining: "figure.core.training"
        case .highIntensityIntervalTraining: "figure.highintensity.intervaltraining"
        case .yoga: "figure.yoga"
        case .pilates: "figure.pilates"
        case .flexibility, .cooldown: "figure.flexibility"
        case .climbing: "figure.climbing"
        case .soccer: "figure.soccer"
        case .tennis: "figure.tennis"
        case .golf: "figure.golf"
        default: "figure.mixed.cardio"
        }
    }
}
