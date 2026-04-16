//
//  DatBikeWidgetExtensionLiveActivity.swift
//  DatBikeWidgetExtension
//
//  Created by Nguyen Tu on 16/4/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct DatBikeWidgetExtensionAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct DatBikeWidgetExtensionLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DatBikeWidgetExtensionAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension DatBikeWidgetExtensionAttributes {
    fileprivate static var preview: DatBikeWidgetExtensionAttributes {
        DatBikeWidgetExtensionAttributes(name: "World")
    }
}

extension DatBikeWidgetExtensionAttributes.ContentState {
    fileprivate static var smiley: DatBikeWidgetExtensionAttributes.ContentState {
        DatBikeWidgetExtensionAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: DatBikeWidgetExtensionAttributes.ContentState {
         DatBikeWidgetExtensionAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: DatBikeWidgetExtensionAttributes.preview) {
   DatBikeWidgetExtensionLiveActivity()
} contentStates: {
    DatBikeWidgetExtensionAttributes.ContentState.smiley
    DatBikeWidgetExtensionAttributes.ContentState.starEyes
}
