import Foundation

struct EEGBand: Identifiable {
    let id = UUID()
    let displayName: String
    let alias: String
    let hzRange: String
    let meaning: String
}

let EEG_BANDS_REFERENCE: [EEGBand] = [
    .init(displayName: "Delta 波",    alias: "delta",     hzRange: "0.5–2.75 Hz",  meaning: "深層睡眠、無意識狀態"),
    .init(displayName: "Theta 波",    alias: "theta",     hzRange: "3.5–6.75 Hz",  meaning: "想像、冥想、放鬆"),
    .init(displayName: "Low Alpha",   alias: "lowAlpha",  hzRange: "7.5–9.25 Hz",  meaning: "平靜、放鬆、專注前狀態"),
    .init(displayName: "High Alpha",  alias: "highAlpha", hzRange: "10–11.75 Hz", meaning: "清醒放鬆、正念"),
    .init(displayName: "Low Beta",    alias: "lowBeta",   hzRange: "13–16.75 Hz", meaning: "專注、解題思考"),
    .init(displayName: "High Beta",   alias: "highBeta",  hzRange: "18–29.75 Hz", meaning: "緊張、壓力、警覺"),
    .init(displayName: "Low Gamma",   alias: "lowGamma",  hzRange: "31–39.75 Hz", meaning: "記憶處理、感知整合"),
    .init(displayName: "Mid Gamma",   alias: "midGamma",  hzRange: "41–49.75 Hz", meaning: "高階認知、覺察、意識整合"),
]
