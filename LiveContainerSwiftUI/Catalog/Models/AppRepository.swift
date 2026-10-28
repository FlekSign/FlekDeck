//
//  AppRepository.swift
//  LiveContainerSwiftUI
//
//  Created by Alexander Grigoryev on 27.01.2026.
//

import Foundation


struct AppRepository: Codable, Equatable, Identifiable {
    let id = UUID()
    let name: String
    let iconUrl: String
    let sourceURL: String
    var isSelected: Bool
}
