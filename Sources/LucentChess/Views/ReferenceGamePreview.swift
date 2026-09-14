import SwiftUI

struct ReferenceGameSelection: Hashable, Codable {
    let gameID: UUID
    let boardFEN: String
}

// A newly decoded game is exclusively transferred from its worker to this view.
private struct LoadedReferenceGame: @unchecked Sendable { let study: ChessStudy }

struct ReferenceGamePreview: View {
    let selection: ReferenceGameSelection
    @EnvironmentObject private var library: LibraryStore
    @State private var game: ChessStudy?
    @State private var error: String?
    var body: some View {
        Group {
            if let game { ReferencePreviewContent(study:game) }
            else if let error { ContentUnavailableView("Could not open game",systemImage:"exclamationmark.triangle",description:Text(error)) }
            else { ProgressView("Opening reference game…") }
        }.frame(minWidth:800,minHeight:600)
        .task(id:selection) {
            guard let catalog=library.catalog else {return}
            do {
                let gameID=selection.gameID
                let worker=Task.detached {try LoadedReferenceGame(study:catalog.load(gameID))}
                let transfer=try await withTaskCancellationHandler {try await worker.value} onCancel: {worker.cancel()}
                let loaded=transfer.study
                try Task.checkCancellation()
                if let board=try? CatalogFilter.boardKey(selection.boardFEN) {
                    var node:MoveNode?=loaded.root
                    while let current=node {
                        if current.positionFEN.split(separator:" ").prefix(2).joined(separator:" ")==board {loaded.select(current);break}
                        node=current.children.first
                    }
                }
                game=loaded
            } catch is CancellationError { }
            catch {self.error=error.localizedDescription}
        }
    }
}

private struct ReferencePreviewContent: View {
    @ObservedObject var study: ChessStudy
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.openWindow) private var openWindow
    private var line:[MoveNode] {
        var result:[MoveNode]=[],node=study.root.children.first
        while let current=node {result.append(current);node=current.children.first}
        return result
    }
    private var startingPly: Int {
        let start=ChessPosition(fen:study.root.positionFEN) ?? .starting
        return (start.fullmoveNumber-1)*2 + (start.sideToMove == .black ? 1 : 0)
    }
    private func moveLabel(index: Int, san: String?) -> String {
        let ply = startingPly + index
        let number = ply / 2 + 1
        let separator = ply.isMultiple(of: 2) ? "." : "…"
        return "\(number)\(separator) \(san ?? "")"
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text(study.playerDescription).font(.title2.bold())
            Text("\(study.event) · \(study.result)").foregroundStyle(.secondary)
            HStack(alignment:.top,spacing:20) {
                VStack {
                    ChessBoardView(position:study.currentPosition,lastMoveUCI:study.currentNode.moveUCI,allowsInteraction:false,showsEngineArrow:false,moveHandler:{_ in}).frame(width:380,height:380)
                    HStack {
                        Button("Start") {study.goToStart();study.markSelectionChanged()}
                        Button("Previous") {study.goBack();study.markSelectionChanged()}
                        Button("Next") {study.goForward();study.markSelectionChanged()}
                        Button("End") {study.goToEnd();study.markSelectionChanged()}
                    }
                }
                ScrollView {
                    LazyVGrid(columns:[GridItem(.adaptive(minimum:90))],alignment:.leading) {
                        ForEach(Array(line.enumerated()),id:\.element.id) { index,node in
                            Button(moveLabel(index: index, san: node.moveSAN)) {study.select(node);study.markSelectionChanged()}
                                .buttonStyle(.bordered).tint(study.currentNode.id==node.id ? .accentColor : .secondary)
                        }
                    }
                    Text(study.currentNode.comment).frame(maxWidth:.infinity,alignment:.leading).padding(.top)
                }
            }
            Spacer()
            HStack {
                Text("Reference preview · your working game is unchanged").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open for analysis") { library.select(study);openWindow(id:AppWindowID.game) }
            }
        }.padding(24)
    }
}
