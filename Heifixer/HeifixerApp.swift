//
//  HeifixerApp.swift
//  Heifixer
//
//  Created by 王昕 on 2026/4/20.
//

import SwiftUI

@main
struct HeifixerApp: App {
    @State private var fixer = PhotoFixer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(fixer)
        }
    }
}
