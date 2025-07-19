//
//  InkMicApp.swift
//  InkMic
//
//  Created by Huaihao on 6/23/25.
//

import SwiftUI

@main
struct InkMicApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 600, minHeight: 400)
        }
        .windowResizability(.contentSize)
    }
}
