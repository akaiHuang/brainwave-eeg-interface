//
//  AuraApp.swift
//  Aura
//
//  Created by akaiHuangM1Max on 2025/10/14.
//

import SwiftUI

@main
struct AuraApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .oledOptimizedTheme() // 全局應用 OLED 優化暗色主題
        }
    }
}
