import WidgetKit
import SwiftUI

@main
struct DatBikeWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        DatBikeWidgetExtension()
        DatBikeWidgetExtensionControl()
        DatBikeLiveActivity()
    }
}
