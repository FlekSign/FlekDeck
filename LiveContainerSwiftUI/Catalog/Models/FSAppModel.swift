//
//  FSAppModel.swift
//  LiveContainer
//
//  Created by Alexander Grigoryev on 30.09.2025.
//

import Foundation

struct FSAppModel: Identifiable, Codable, Equatable {
    let app_id: Int
    let app_icon: String
    let app_name: String
    let app_version: String
    let app_short_description: String
    let app_isAdult: Int
    let install_url: String

    // MARK: Custom repositories
    //
    // A custom repo's catalog is all the app page has to work from — its rows
    // have no detail endpoint behind them — so whatever
    // the catalog said about size, release date, developer and screenshots is
    // carried on the row itself. Optional, and so absent from any older
    // rows, which get these from `FSAppDetail` instead; that also keeps both
    // the API's responses and catalogs cached by an older build decodable.

    var app_developer: String? = nil
    /// Bytes.
    var app_size: Int64? = nil
    /// However the repo wrote it — see `FSCatalogFormat` for the shapes.
    var app_date: String? = nil
    var app_downloads: Int? = nil
    var app_screenshots: [String]? = nil

    var id: Int { app_id }
}
