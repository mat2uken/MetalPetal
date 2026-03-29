//
//  MetalPetalExamplesApp.swift
//  Shared
//
//  Created by YuAo on 2021/4/8.
//

import SwiftUI

private enum MetalPetalExamplesLaunchRoute {
    case home
    case threadSafeImageViews

    static var current: Self {
#if os(iOS)
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-mti-thread-safe-image-views") {
            return .threadSafeImageViews
        }
#endif
        return .home
    }
}

@main
struct MetalPetalExamplesApp: App {
    
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    class AppDelegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
            true
        }
    }
    #endif

    @ViewBuilder
    private var rootView: some View {
        switch MetalPetalExamplesLaunchRoute.current {
        case .home:
            HomeView()
        case .threadSafeImageViews:
#if os(iOS)
            NavigationView {
                ThreadSafeImageViewStressView()
            }
            .stackNavigationViewStyle()
#else
            HomeView()
#endif
        }
    }
    
    var body: some Scene {
        WindowGroup {
            rootView
        }.commands(content: {
            SidebarCommands()
        })
    }
}
