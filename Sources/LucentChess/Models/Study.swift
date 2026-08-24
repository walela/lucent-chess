import Combine
import Foundation

final class MoveNode: Codable, Identifiable, Equatable {
    var id: UUID
    var parentID: UUID?
    var moveUCI: String?
    var moveSAN: String?
    var positionFEN: String
    var comment: String
    var nags: [Int]
    var children: [MoveNode]

    init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        moveUCI: String? = nil,
        moveSAN: String? = nil,
        positionFEN: String,
        comment: String = "",
        nags: [Int] = [],
        children: [MoveNode] = []
    ) {
        self.id = id
        self.parentID = parentID
        self.moveUCI = moveUCI
        self.moveSAN = moveSAN
        self.positionFEN = positionFEN
        self.comment = comment
        self.nags = nags
        self.children = children
    }

    static func == (lhs: MoveNode, rhs: MoveNode) -> Bool { lhs.id == rhs.id }

    func find(_ searchID: UUID) -> MoveNode? {
        if id == searchID { return self }
        for child in children {
            if let found = child.find(searchID) { return found }
        }
        return nil
    }

    func parent(of searchID: UUID) -> MoveNode? {
        if children.contains(where: { $0.id == searchID }) { return self }
        for child in children {
            if let found = child.parent(of: searchID) { return found }
        }
        return nil
    }

    func remove(_ searchID: UUID) -> Bool {
        if let index = children.firstIndex(where: { $0.id == searchID }) {
            children.remove(at: index)
            return true
        }
        return children.contains { $0.remove(searchID) }
    }
}

final class ChessStudy: Codable, Identifiable, ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
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
    var root: MoveNode
    var lastNodeID: UUID {
        didSet {
            guard lastNodeID != oldValue else { return }
            cachedPositionNodeID = nil
            cachedPosition = nil
        }
    }
    var createdAt: Date
    var modifiedAt: Date
    var filePath: String?
    var lastSavedAt: Date?
    var dirtyState: Bool?
    var folderID: UUID?
    var starterCollectionID: String?
    var sourceName: String?
    var sourceURL: String?

    private var nodeIndex: [UUID: MoveNode] = [:]
    private var cachedPositionNodeID: UUID?
    private var cachedPosition: ChessPosition?
    private var cachedMainLinePlyCount: Int?
    private(set) var viewRevision = 0
    private(set) var notationRevision = 0

    init(
        id: UUID = UUID(),
        title: String = "Untitled study",
        white: String = "",
        black: String = "",
        event: String = "",
        site: String? = nil,
        round: String? = nil,
        whiteElo: String? = nil,
        blackElo: String? = nil,
        eco: String? = nil,
        date: Date = Date(),
        result: String = "*",
        startFEN: String = ChessPosition.startFEN
    ) {
        self.id = id
        self.title = title
        self.white = white
        self.black = black
        self.event = event
        self.site = site
        self.round = round
        self.whiteElo = whiteElo
        self.blackElo = blackElo
        self.eco = eco
        self.date = date
        self.result = result
        self.root = MoveNode(positionFEN: startFEN)
        self.lastNodeID = root.id
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.filePath = nil
        self.lastSavedAt = nil
        self.dirtyState = nil
        self.folderID = nil
        self.starterCollectionID = nil
        self.sourceName = nil
        self.sourceURL = nil
        rebuildNodeIndex()
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        white = try container.decode(String.self, forKey: .white)
        black = try container.decode(String.self, forKey: .black)
        event = try container.decode(String.self, forKey: .event)
        site = try container.decodeIfPresent(String.self, forKey: .site)
        round = try container.decodeIfPresent(String.self, forKey: .round)
        whiteElo = try container.decodeIfPresent(String.self, forKey: .whiteElo)
        blackElo = try container.decodeIfPresent(String.self, forKey: .blackElo)
        eco = try container.decodeIfPresent(String.self, forKey: .eco)
        date = try container.decode(Date.self, forKey: .date)
        result = try container.decode(String.self, forKey: .result)
        lastNodeID = try container.decode(UUID.self, forKey: .lastNodeID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        filePath = try container.decodeIfPresent(String.self, forKey: .filePath)
        lastSavedAt = try container.decodeIfPresent(Date.self, forKey: .lastSavedAt)
        dirtyState = try container.decodeIfPresent(Bool.self, forKey: .dirtyState)
        folderID = try container.decodeIfPresent(UUID.self, forKey: .folderID)
        starterCollectionID = try container.decodeIfPresent(String.self, forKey: .starterCollectionID)
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)

        if let nodes = try container.decodeIfPresent([FlatMoveNode].self, forKey: .nodes) {
            root = try Self.rebuildTree(from: nodes, decoder: decoder)
        } else {
            root = try container.decode(MoveNode.self, forKey: .root)
        }
        rebuildNodeIndex()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(white, forKey: .white)
        try container.encode(black, forKey: .black)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(site, forKey: .site)
        try container.encodeIfPresent(round, forKey: .round)
        try container.encodeIfPresent(whiteElo, forKey: .whiteElo)
        try container.encodeIfPresent(blackElo, forKey: .blackElo)
        try container.encodeIfPresent(eco, forKey: .eco)
        try container.encode(date, forKey: .date)
        try container.encode(result, forKey: .result)
        try container.encode(flattenedNodes(), forKey: .nodes)
        try container.encode(lastNodeID, forKey: .lastNodeID)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encodeIfPresent(filePath, forKey: .filePath)
        try container.encodeIfPresent(lastSavedAt, forKey: .lastSavedAt)
        try container.encodeIfPresent(dirtyState, forKey: .dirtyState)
        try container.encodeIfPresent(folderID, forKey: .folderID)
        try container.encodeIfPresent(starterCollectionID, forKey: .starterCollectionID)
        try container.encodeIfPresent(sourceName, forKey: .sourceName)
        try container.encodeIfPresent(sourceURL, forKey: .sourceURL)
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, white, black, event, site, round, whiteElo, blackElo, eco, date, result
        case root, nodes, lastNodeID, createdAt, modifiedAt, filePath, lastSavedAt, dirtyState
        case folderID, starterCollectionID, sourceName, sourceURL
    }

    private func flattenedNodes() -> [FlatMoveNode] {
        var result: [FlatMoveNode] = []
        var stack: [(MoveNode, UUID?)] = [(root, nil)]
        while let (node, parentID) = stack.popLast() {
            result.append(FlatMoveNode(node: node, parentID: parentID))
            for child in node.children.reversed() { stack.append((child, node.id)) }
        }
        return result
    }

    private static func rebuildTree(from flatNodes: [FlatMoveNode], decoder: Decoder) throws -> MoveNode {
        guard !flatNodes.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A game has no position nodes."))
        }
        var nodeMap: [UUID: MoveNode] = [:]
        for flat in flatNodes { nodeMap[flat.id] = flat.makeNode() }
        var root: MoveNode?
        for flat in flatNodes {
            guard let node = nodeMap[flat.id] else { continue }
            if let parentID = flat.parentID {
                guard let parent = nodeMap[parentID] else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A move references a missing parent."))
                }
                parent.children.append(node)
            } else if root == nil {
                root = node
            }
        }
        guard let root else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "A game has no root position."))
        }
        return root
    }

    func rebuildNodeIndex() {
        nodeIndex.removeAll(keepingCapacity: true)
        root.parentID = nil
        var stack: [MoveNode] = [root]
        while let node = stack.popLast() {
            nodeIndex[node.id] = node
            for child in node.children.reversed() {
                child.parentID = node.id
                stack.append(child)
            }
        }
        if nodeIndex[lastNodeID] == nil { lastNodeID = root.id }
        cachedPositionNodeID = nil
        cachedPosition = nil
        cachedMainLinePlyCount = nil
    }

    func node(withID id: UUID) -> MoveNode? { nodeIndex[id] }

    func parent(of nodeID: UUID) -> MoveNode? {
        guard let parentID = nodeIndex[nodeID]?.parentID else { return nil }
        return nodeIndex[parentID]
    }

    func markChanged(notation: Bool) {
        viewRevision &+= 1
        if notation { notationRevision &+= 1 }
        objectWillChange.send()
    }

    func markSelectionChanged() {
        viewRevision &+= 1
        objectWillChange.send()
    }

    var currentNode: MoveNode { nodeIndex[lastNodeID] ?? root }
    var currentPosition: ChessPosition {
        if cachedPositionNodeID == lastNodeID, let cachedPosition { return cachedPosition }
        let position = ChessPosition(fen: currentNode.positionFEN) ?? .starting
        cachedPositionNodeID = lastNodeID
        cachedPosition = position
        return position
    }
    var fileURL: URL? { filePath.map { URL(fileURLWithPath: $0) } }
    var isAutosaved: Bool { starterCollectionID == nil && sourceName == nil && filePath == nil }
    var hasUnsavedChanges: Bool {
        if let dirtyState { return dirtyState }
        guard let lastSavedAt else { return true }
        return modifiedAt > lastSavedAt
    }
    var playerDescription: String {
        let names = [white, black].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return names.allSatisfy(\.isEmpty) ? "Unspecified players" : "\(names[0].isEmpty ? "?" : names[0]) – \(names[1].isEmpty ? "?" : names[1])"
    }
    var mainLinePlyCount: Int {
        if let cachedMainLinePlyCount { return cachedMainLinePlyCount }
        var count = 0
        var node = root
        while let next = node.children.first { count += 1; node = next }
        cachedMainLinePlyCount = count
        return count
    }
    var currentPly: Int { path().count }
    var suggestedFileName: String {
        let base: String
        if !white.isEmpty || !black.isEmpty { base = playerDescription }
        else if !event.isEmpty { base = event }
        else { base = title }
        let forbidden = CharacterSet(charactersIn: "/:\\")
        let safe = base.components(separatedBy: forbidden).joined(separator: "-")
        return (safe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Chess Game" : safe) + ".pgn"
    }

    @discardableResult
    func play(_ move: ChessMove) -> MoveNode? {
        let node = currentNode
        let position = ChessPosition(fen: node.positionFEN) ?? .starting
        guard let legalMove = position.legalMoves(from: move.from).first(where: {
            $0.to == move.to && ($0.promotion ?? .queen) == (move.promotion ?? .queen)
        }) else { return nil }
        if let existing = node.children.first(where: { $0.moveUCI == legalMove.uci }) {
            lastNodeID = existing.id
            return existing
        }
        let next = position.applyingUnchecked(legalMove)
        let child = MoveNode(
            parentID: node.id,
            moveUCI: legalMove.uci,
            moveSAN: position.san(for: legalMove),
            positionFEN: next.fen
        )
        node.children.append(child)
        nodeIndex[child.id] = child
        cachedMainLinePlyCount = nil
        lastNodeID = child.id
        modifiedAt = Date()
        return child
    }

    func goBack() {
        if let parent = parent(of: lastNodeID) { lastNodeID = parent.id }
    }

    func goForward() {
        if let child = currentNode.children.first { lastNodeID = child.id }
    }

    func goToStart() { lastNodeID = root.id }

    func goToEnd() {
        var node = currentNode
        while let next = node.children.first { node = next }
        lastNodeID = node.id
    }

    func select(_ node: MoveNode) { lastNodeID = node.id }

    func deleteCurrentVariation() {
        guard lastNodeID != root.id,
              let selected = nodeIndex[lastNodeID],
              let parent = parent(of: lastNodeID),
              let index = parent.children.firstIndex(where: { $0.id == lastNodeID }) else { return }
        parent.children.remove(at: index)
        unindex(selected)
        cachedMainLinePlyCount = nil
        lastNodeID = parent.id
        modifiedAt = Date()
    }

    func promoteCurrentVariation() {
        guard let parent = parent(of: lastNodeID),
              let index = parent.children.firstIndex(where: { $0.id == lastNodeID }), index > 0 else { return }
        let selected = parent.children.remove(at: index)
        parent.children.insert(selected, at: 0)
        cachedMainLinePlyCount = nil
        modifiedAt = Date()
    }

    func path(to node: MoveNode? = nil) -> [MoveNode] {
        let target = node ?? currentNode
        var result: [MoveNode] = []
        var cursor: MoveNode? = target
        while let current = cursor, current.id != root.id {
            result.append(current)
            cursor = parent(of: current.id)
        }
        return result.reversed()
    }

    private func unindex(_ subtree: MoveNode) {
        var stack: [MoveNode] = [subtree]
        while let node = stack.popLast() {
            nodeIndex.removeValue(forKey: node.id)
            stack.append(contentsOf: node.children)
        }
    }
}

private struct FlatMoveNode: Codable {
    var id: UUID
    var parentID: UUID?
    var moveUCI: String?
    var moveSAN: String?
    var positionFEN: String
    var comment: String
    var nags: [Int]

    init(node: MoveNode, parentID: UUID?) {
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

struct GameFolder: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

struct LibraryArchive: Codable {
    var studies: [ChessStudy]
    var selectedStudyID: UUID?
    var folders: [GameFolder]?
    var seedVersion: Int?
}
