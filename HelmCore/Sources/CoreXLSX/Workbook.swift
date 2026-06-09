// Copyright 2019-2020 CoreOffice contributors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
//  Created by Max Desiatov on 23/11/2018.
//
//  Modified by the Helm project (2026): expose workbookPr/date1904 (ADR-7).
//  Stock CoreXLSX does not parse the workbook date system, which is required to
//  convert serial dates correctly (1900 vs 1904). See HelmDateResolver.
//

public struct Workbook: Codable, Equatable {
  // --- Helm fork addition: workbook properties (date system) ---
  public struct Properties: Codable, Equatable {
    public let date1904: Bool?
  }

  public let workbookProperties: Properties?

  /// The workbook's date system. `false` (1900) when absent.
  public var date1904: Bool { workbookProperties?.date1904 ?? false }
  // --- end Helm fork addition ---

  public struct Views: Codable, Equatable {
    public let items: [View]

    enum CodingKeys: String, CodingKey {
      case items = "workbookView"
    }
  }

  public struct View: Codable, Equatable {
    public let xWindow: Int?
    public let yWindow: Int?
    public let windowWidth: UInt?
    public let windowHeight: UInt?
  }

  public let views: Views?

  public struct Sheets: Codable, Equatable {
    public let items: [Sheet]

    enum CodingKeys: String, CodingKey {
      case items = "sheet"
    }
  }

  public struct Sheet: Codable, Equatable {
    public let name: String?
    public let id: String
    public let relationship: String

    enum CodingKeys: String, CodingKey {
      case name
      case id = "sheetId"
      case relationship = "r:id"
    }
  }

  public let sheets: Sheets

  enum CodingKeys: String, CodingKey {
    case views = "bookViews"
    case sheets
    case workbookProperties = "workbookPr" // Helm fork addition
  }
}
