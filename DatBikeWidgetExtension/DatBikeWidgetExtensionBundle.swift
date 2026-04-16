//
//  DatBikeWidgetExtensionBundle.swift
//  DatBikeWidgetExtension
//
//  Created by Nguyen Tu on 16/4/26.
//

import WidgetKit
import SwiftUI

@main
struct DatBikeWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        DatBikeWidgetExtension()
        DatBikeWidgetExtensionControl()
        DatBikeWidgetExtensionLiveActivity()
    }
}
