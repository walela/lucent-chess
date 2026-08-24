import Foundation

enum GameSortField: String, CaseIterable, Identifiable {
    case players
    case event
    case date
    case result
    case moves
    case round

    var id: Self { self }

    var label: String {
        switch self {
        case .players: return "Players"
        case .event: return "Event"
        case .date: return "Date"
        case .result: return "Result"
        case .moves: return "Moves"
        case .round: return "Round"
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .date, .moves: return false
        default: return true
        }
    }
}

enum GameResultFilter: String, CaseIterable, Identifiable {
    case all
    case whiteWin
    case draw
    case blackWin
    case unfinished

    var id: Self { self }

    var label: String {
        switch self {
        case .all: return "All results"
        case .whiteWin: return "White wins"
        case .draw: return "Draws"
        case .blackWin: return "Black wins"
        case .unfinished: return "Unfinished"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "circle.grid.2x2"
        case .whiteWin: return "circle.lefthalf.filled"
        case .draw: return "equal.circle"
        case .blackWin: return "circle.righthalf.filled"
        case .unfinished: return "ellipsis.circle"
        }
    }

    func includes(_ study: ChessStudy) -> Bool {
        switch self {
        case .all: return true
        case .whiteWin: return study.result == "1-0"
        case .draw: return study.result == "1/2-1/2"
        case .blackWin: return study.result == "0-1"
        case .unfinished: return !["1-0", "0-1", "1/2-1/2"].contains(study.result)
        }
    }
}

enum GameFileFilter: String, CaseIterable, Identifiable {
    case all
    case savedPGN
    case needsSaving
    case included
    case imported
    case autosaved

    var id: Self { self }

    var label: String {
        switch self {
        case .all: return "All files"
        case .savedPGN: return "PGN saved"
        case .needsSaving: return "Needs saving"
        case .included: return "Included archive"
        case .imported: return "Source import"
        case .autosaved: return "Autosave"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "doc.on.doc"
        case .savedPGN: return "checkmark.circle"
        case .needsSaving: return "pencil.circle"
        case .included: return "archivebox"
        case .imported: return "arrow.down.doc"
        case .autosaved: return "archivebox"
        }
    }

    func includes(_ study: ChessStudy) -> Bool {
        switch self {
        case .all: return true
        case .savedPGN: return study.filePath != nil && !study.hasUnsavedChanges
        case .needsSaving: return study.hasUnsavedChanges
        case .included: return study.starterCollectionID != nil
        case .imported: return study.sourceName != nil
        case .autosaved: return study.isAutosaved
        }
    }
}

struct GameLibraryQuery {
    var result: GameResultFilter = .all
    var file: GameFileFilter = .all
    var sort: GameSortField = .date
    var ascending = false

    var isFiltered: Bool { result != .all || file != .all }

    func apply(to studies: [ChessStudy]) -> [ChessStudy] {
        studies
            .filter { result.includes($0) && file.includes($0) }
            .sorted(by: comesBefore)
    }

    private func comesBefore(_ lhs: ChessStudy, _ rhs: ChessStudy) -> Bool {
        let comparison: ComparisonResult
        switch sort {
        case .players:
            comparison = compare(lhs.playerDescription, rhs.playerDescription)
        case .event:
            comparison = compare(lhs.event, rhs.event)
        case .date:
            comparison = lhs.date == rhs.date ? .orderedSame : (lhs.date < rhs.date ? .orderedAscending : .orderedDescending)
        case .result:
            comparison = compare(lhs.result, rhs.result)
        case .moves:
            comparison = lhs.mainLinePlyCount == rhs.mainLinePlyCount
                ? .orderedSame
                : (lhs.mainLinePlyCount < rhs.mainLinePlyCount ? .orderedAscending : .orderedDescending)
        case .round:
            comparison = (lhs.round ?? "").localizedStandardCompare(rhs.round ?? "")
        }

        if comparison == .orderedSame {
            let players = compare(lhs.playerDescription, rhs.playerDescription)
            if players != .orderedSame { return players == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    private func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.localizedCaseInsensitiveCompare(rhs)
    }
}
