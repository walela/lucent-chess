import SwiftUI

struct DatabaseFilterView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @State private var filter: CatalogFilter
    @State private var result: String
    @State private var bounds: [String]
    @State private var error: String?
    @State private var drawingBoard = false
    let currentPositionFEN: String?
    let apply: (CatalogFilter,String) -> Void

    init(filter: CatalogFilter, result: String, currentPositionFEN: String? = nil, apply: @escaping (CatalogFilter,String) -> Void) {
        _filter = State(initialValue:filter);_result=State(initialValue:result)
        _bounds=State(initialValue:[filter.whiteMin,filter.whiteMax,filter.blackMin,filter.blackMax,filter.yearMin,filter.yearMax].map { $0.map(String.init) ?? "" })
        self.apply=apply
        self.currentPositionFEN=currentPositionFEN
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Filter games").font(.title2.bold())
            Text("Combine fields to narrow the database. Names match word prefixes; blank fields include everyone.").font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Player, either color",text:$filter.player)
                TextField("White player",text:$filter.white)
                TextField("Black player",text:$filter.black)
                TextField("Tournament",text:$filter.tournament)
                range("White Elo",offset:0)
                range("Black Elo",offset:2)
                range("Year",offset:4)
                Picker("Result",selection:$result) {
                    ForEach(GameResultFilter.allCases) { value in Text(value.label).tag(value.rawValue) }
                }
            }
            Divider()
            HStack {
                Text("Board position").font(.headline)
                Spacer()
                Button("Set up board…") { drawingBoard=true }
                Button("Use current game") { filter.boardFEN=currentPositionFEN ?? library.selectedStudy?.currentPosition.fen ?? "" }.disabled(currentPositionFEN == nil && library.selectedStudy==nil)
                if !filter.boardFEN.isEmpty { Button("Remove") {filter.boardFEN=""} }
            }
            TextField("Optional FEN — paste a position or set up a board",text:$filter.boardFEN).textFieldStyle(.roundedBorder).font(.system(.callout,design:.monospaced))
            Text("Board search matches the exact pieces and side to move anywhere in the main line, including transpositions. Castling rights, en passant and move clocks are ignored. Variations are excluded in this first pass.").font(.caption).foregroundStyle(.secondary)
            if !filter.boardFEN.isEmpty {
                Text("The first search scans moves in the filtered games; it can take time on a large database. Progress and cancellation are available, and completed results are cached.").font(.caption).foregroundStyle(.secondary)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Clear all") { filter=CatalogFilter();bounds=Array(repeating:"",count:6);result="all";error=nil }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(filter.boardFEN.isEmpty ? "Apply filters" : "Search games",action:submit).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width:620)
        .sheet(isPresented:$drawingBoard) {
            PositionSetupView(initialPosition:ChessPosition(fen:filter.boardFEN),usePosition:{ position in filter.boardFEN=position.fen })
        }
    }
    private func range(_ label:String,offset:Int) -> some View {
        HStack {
            Text(label).frame(width:110,alignment:.leading)
            TextField("Minimum",text:$bounds[offset]).frame(width:120)
            Text("to").foregroundStyle(.secondary)
            TextField("Maximum",text:$bounds[offset+1]).frame(width:120)
            Spacer()
        }
    }
    private func submit() {
        do {
            let values: [Int?] = try bounds.map {
                let text=$0.trimmingCharacters(in:.whitespaces)
                if text.isEmpty { return nil }
                guard let value=Int(text) else { throw CatalogError.message("Elo and year ranges must contain whole numbers.") }
                return value
            }
            filter.whiteMin=values[0];filter.whiteMax=values[1];filter.blackMin=values[2];filter.blackMax=values[3];filter.yearMin=values[4];filter.yearMax=values[5]
            filter.player=filter.player.trimmingCharacters(in:.whitespacesAndNewlines)
            filter.white=filter.white.trimmingCharacters(in:.whitespacesAndNewlines)
            filter.black=filter.black.trimmingCharacters(in:.whitespacesAndNewlines)
            filter.tournament=filter.tournament.trimmingCharacters(in:.whitespacesAndNewlines)
            filter.boardFEN=filter.boardFEN.trimmingCharacters(in:.whitespacesAndNewlines)
            try filter.validate();apply(filter,result);dismiss()
        } catch {self.error=error.localizedDescription}
    }
}
