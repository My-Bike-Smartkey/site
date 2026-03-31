// BikeWidgetBundle.swift — Widget Extension entry point

import WidgetKit
import SwiftUI

@main
struct BikeWidgetBundle: WidgetBundle {
    var body: some Widget {
        BikeSmallWidget()
        BikeMediumWidget()
        BikeLockScreenWidget()
    }
}
