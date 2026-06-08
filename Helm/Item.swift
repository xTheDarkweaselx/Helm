//
//  Item.swift
//  Helm
//
//  Created by Adam Ibrahim on 08/06/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
