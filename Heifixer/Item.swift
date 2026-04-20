//
//  Item.swift
//  Heifixer
//
//  Created by 王昕 on 2026/4/20.
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
