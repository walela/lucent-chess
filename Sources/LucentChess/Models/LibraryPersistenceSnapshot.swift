import Foundation

struct LibraryPersistenceSnapshot: Codable, Sendable {
    var studies: [StudyPersistenceSnapshot]
    var selectedStudyID: UUID?
    var folders: [GameFolder]?
    var seedVersion: Int?

    init(studies: [ChessStudy], selectedStudyID: UUID?, folders: [GameFolder], seedVersion: Int) {
        self.studies = studies.map(StudyPersistenceSnapshot.init)
        self.selectedStudyID = selectedStudyID
        self.folders = folders
        self.seedVersion = seedVersion
    }

    func makeStudies() throws -> [ChessStudy] {
        try studies.map { try $0.makeStudy() }
    }
}

struct StudyPersistenceSnapshot: Codable, Sendable {
    var id: UUID
    var title: String
    var white: String
    var black: String
    var event: String
    var site: String?
    var round: String?
    var whiteElo: String?
    var blackElo: String?
    var eco: String?
    var date: Date
    var result: String
    var nodes: [MovePersistenceSnapshot]
    var lastNodeID: UUID
    var createdAt: Date
    var modifiedAt: Date
    var filePath: String?
    var lastSavedAt: Date?
    var dirtyState: Bool?
    var folderID: UUID?
    var starterCollectionID: String?

    init(_ study: ChessStudy) {
        id = study.id
        title = study.title
        white = study.white
        black = study.black
        event = study.event
        site = study.site
        round = study.round
        whiteElo = study.whiteElo
        blackElo = study.blackElo
        eco = study.eco
        date = study.date
        result = study.result
        lastNodeID = study.lastNodeID
        createdAt = study.createdAt
        modifiedAt = study.modifiedAt
        filePath = study.filePath
        lastSavedAt = study.lastSavedAt
        dirtyState = study.dirtyState
        folderID = study.folderID
        starterCollectionID = study.starterCollectionID

        var flattened: [MovePersistenceSnapshot] = []
        var stack: [(MoveNode, UUID?)] = [(study.root, nil)]
        while let (node, parentID) = stack.popLast() {
            flattened.append(MovePersistenceSnapshot(node, parentID: parentID))
            for child in node.children.reversed() { stack.append((child, node.id)) }
        }
        nodes = flattened
    }

    func makeStudy() throws -> ChessStudy {
        guard !nodes.isEmpty else { throw LibraryPersistenceError.emptyGame }
        var nodeMap: [UUID: MoveNode] = [:]
        for node in nodes {
            guard nodeMap[node.id] == nil else { throw LibraryPersistenceError.duplicateNode(node.id) }
            nodeMap[node.id] = node.makeNode()
        }

        var root: MoveNode?
        for snapshot in nodes {
            guard let node = nodeMap[snapshot.id] else { continue }
            if let parentID = snapshot.parentID {
                guard let parent = nodeMap[parentID] else { throw LibraryPersistenceError.missingParent(parentID) }
                parent.children.append(node)
            } else if root == nil {
                root = node
            } else {
                throw LibraryPersistenceError.multipleRoots
            }
        }
        guard let root else { throw LibraryPersistenceError.emptyGame }

        let study = ChessStudy(
            id: id,
            title: title,
            white: white,
            black: black,
            event: event,
            site: site,
            round: round,
            whiteElo: whiteElo,
            blackElo: blackElo,
            eco: eco,
            date: date,
            result: result,
            startFEN: root.positionFEN
        )
        study.root = root
        study.lastNodeID = nodeMap[lastNodeID] == nil ? root.id : lastNodeID
        study.createdAt = createdAt
        study.modifiedAt = modifiedAt
        study.filePath = filePath
        study.lastSavedAt = lastSavedAt
        study.dirtyState = dirtyState
        study.folderID = folderID
        study.starterCollectionID = starterCollectionID
        study.rebuildNodeIndex()
        return study
    }
}

struct MovePersistenceSnapshot: Codable, Sendable {
    var id: UUID
    var parentID: UUID?
    var moveUCI: String?
    var moveSAN: String?
    var positionFEN: String
    var comment: String
    var nags: [Int]

    init(_ node: MoveNode, parentID: UUID?) {
        id = node.id
        self.parentID = parentID
        moveUCI = node.moveUCI
        moveSAN = node.moveSAN
        positionFEN = node.positionFEN
        comment = node.comment
        nags = node.nags
    }

    func makeNode() -> MoveNode {
        MoveNode(
            id: id,
            parentID: parentID,
            moveUCI: moveUCI,
            moveSAN: moveSAN,
            positionFEN: positionFEN,
            comment: comment,
            nags: nags
        )
    }
}

enum LibraryPersistenceError: LocalizedError {
    case emptyGame
    case duplicateNode(UUID)
    case missingParent(UUID)
    case multipleRoots

    var errorDescription: String? {
        switch self {
        case .emptyGame: return "A saved game has no position nodes."
        case let .duplicateNode(id): return "A saved game contains duplicate node \(id)."
        case let .missingParent(id): return "A saved game references missing parent \(id)."
        case .multipleRoots: return "A saved game contains multiple root positions."
        }
    }
}
