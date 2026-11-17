import SwiftUI

/// Lightweight markdown renderer for LLM output.
/// Handles fenced code blocks, headings, lists, blockquotes, tables, rules,
/// and inline bold/italic/code/links — no external dependencies.
/// When `streaming` is true, unterminated constructs (open code fences,
/// trailing emphasis markers) are handled so partial output renders cleanly.
struct MarkdownView: View {
    let text: String
    var streaming: Bool = false
    /// Reveals the top-level blocks one after another instead of all at once.
    var revealInChunks: Bool = false
    /// Called once the chunked reveal has fully played out.
    var onRevealFinished: (() -> Void)? = nil
    @State private var revealedCount = 0
    @State private var revealFinished = false

    var body: some View {
        let blocks = BlockParser.blocks(from: text, streaming: streaming)
        // Reveal units: one per block, except list items which count one each,
        // so long answers made of lists still reveal in many small steps.
        let counts = blocks.map(Self.unitCount)
        let totalUnits = counts.reduce(0, +)
        var starts: [Int] = []
        var running = 0
        for count in counts { starts.append(running); running += count }
        let visibleUnits = revealInChunks && !revealFinished ? revealedCount : totalUnits
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                // Every block is laid out from the start, so the height is
                // final and nothing shifts; steps only fade the opacity in.
                let start = starts[index]
                let shown = max(0, visibleUnits - start)
                Group {
                switch block {
                case .heading(let level, let content):
                    InlineText(content)
                        .font(headingFont(level))
                        .padding(.vertical, level <= 2 ? 4 : 0)
                case .paragraph(let content):
                    InlineText(content)
                        .fixedSize(horizontal: false, vertical: true)
                case .codeBlock(let language, let code):
                    CodeBlockView(language: language, code: code)
                case .bulletList(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, item in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•").foregroundStyle(.secondary)
                                InlineText(item).fixedSize(horizontal: false, vertical: true)
                            }
                            .opacity(itemIndex < shown ? 1 : 0)
                        }
                    }
                case .numberedList(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { itemIndex, item in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(itemIndex + 1).").foregroundStyle(.secondary)
                                InlineText(item).fixedSize(horizontal: false, vertical: true)
                            }
                            .opacity(itemIndex < shown ? 1 : 0)
                        }
                    }
                case .blockquote(let content):
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 3)
                        InlineText(content)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                case .rule:
                    Divider()
                case .table(let header, let rows, let alignments):
                    TableBlockView(header: header, rows: rows, alignments: alignments)
                case .image(let alt, let url):
                    MarkdownImageView(alt: alt, url: url)
                }
                }
                // Lists fade per item (above); other blocks fade as a whole.
                .opacity(Self.isList(block) || shown > 0 ? 1 : 0)
            }
        }
        // Soft overlapping fades; no offset/blur, which made the text jump.
        .animation(revealFinished || !revealInChunks ? nil : .easeInOut(duration: 0.45),
                   value: visibleUnits)
        .task {
            guard revealInChunks, !revealFinished else { return }
            // Overlapping fades at ~0.1s steps, whole reveal capped at ~2s.
            let delay = min(0.1, 2.0 / Double(max(totalUnits, 1)))
            for _ in 0..<totalUnits {
                guard !Task.isCancelled else { return }
                revealedCount += 1
                try? await Task.sleep(for: .seconds(delay))
            }
            try? await Task.sleep(for: .milliseconds(500))
            revealFinished = true
            onRevealFinished?()
        }
    }

    private static func isList(_ block: Block) -> Bool {
        switch block {
        case .bulletList, .numberedList: return true
        default: return false
        }
    }

    private static func unitCount(_ block: Block) -> Int {
        switch block {
        case .bulletList(let items), .numberedList(let items): return max(items.count, 1)
        default: return 1
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title.bold()
        case 2: return .title2.bold()
        case 3: return .title3.bold()
        default: return .headline
        }
    }
}

// MARK: - Block parsing

enum Block {
    case heading(Int, String)
    case paragraph(String)
    case codeBlock(String?, String)
    case bulletList([String])
    case numberedList([String])
    case blockquote(String)
    case rule
    case table(header: [String], rows: [[String]], alignments: [ColumnAlignment])
    case image(alt: String, url: URL)
}

enum ColumnAlignment {
    case leading, center, trailing
}

enum BlockParser {
    static func blocks(from text: String, streaming: Bool = false) -> [Block] {
        var blocks: [Block] = []
        let lines = text.components(separatedBy: "\n")
        var i = 0

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                let language = line.trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: "```", with: "").nilIfEmpty
                var codeLines: [String] = []
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }
                if i < lines.count {
                    i += 1 // skip closing fence
                }
                // When streaming, an unclosed fence still renders as a code block.
                blocks.append(.codeBlock(language, codeLines.joined(separator: "\n")))
                continue
            }

            // Heading
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let content = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(min(level, 6), content))
                i += 1
                continue
            }

            // Horizontal rule
            if line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == "-" || $0 == "*" })
                && line.trimmingCharacters(in: .whitespaces).count >= 3 {
                blocks.append(.rule)
                i += 1
                continue
            }

            // Blockquote
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                var quoteLines: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoteLines.append(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(1).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(quoteLines.joined(separator: " ")))
                continue
            }

            // Bullet list
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") || line.trimmingCharacters(in: .whitespaces).hasPrefix("* ") {
                var items: [String] = []
                while i < lines.count {
                    let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    if trimmed.hasPrefix("- ") {
                        items.append(String(trimmed.dropFirst(2)))
                    } else if trimmed.hasPrefix("* ") {
                        items.append(String(trimmed.dropFirst(2)))
                    } else {
                        break
                    }
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }

            // Numbered list
            if let match = firstNumberedPrefix(line) {
                var items: [String] = []
                while i < lines.count, let rest = firstNumberedPrefix(lines[i]) {
                    items.append(rest)
                    i += 1
                }
                blocks.append(.numberedList(items))
                continue
            }

            // Table: header row with pipes followed by a |---|---| separator row
            if line.contains("|"), i + 1 < lines.count,
               let sep = tableSeparator(lines[i + 1]) {
                var header = splitRow(line)
                var alignments = sep
                var rows: [[String]] = []
                i += 2
                while i < lines.count, lines[i].contains("|"),
                      !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    let cells = splitRow(lines[i])
                    // Skip stray separator rows inside the table body.
                    if tableSeparator(lines[i]) != nil { i += 1; continue }
                    rows.append(cells)
                    i += 1
                }
                // Normalize column counts so the grid stays rectangular.
                let columns = max(header.count,
                                  rows.map(\.count).max() ?? 0,
                                  alignments.count)
                while header.count < columns { header.append("") }
                while alignments.count < columns { alignments.append(.leading) }
                rows = rows.map { row in
                    row.count >= columns ? row
                        : row + Array(repeating: "", count: columns - row.count)
                }
                blocks.append(.table(header: header, rows: rows, alignments: alignments))
                continue
            }

            // Image on a line of its own: ![alt](url)
            if let image = imageBlock(line) {
                blocks.append(image)
                i += 1
                continue
            }

            // Blank line
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                i += 1
                continue
            }

            // Paragraph: gather consecutive non-special lines
            var paragraphLines = [line]
            i += 1
            while i < lines.count {
                let next = lines[i]
                if next.trimmingCharacters(in: .whitespaces).isEmpty
                    || next.hasPrefix("#") || next.hasPrefix("```")
                    || next.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
                    || next.trimmingCharacters(in: .whitespaces).hasPrefix(">")
                    || firstNumberedPrefix(next) != nil
                    || imageBlock(next) != nil
                    || (next.contains("|") && i + 1 < lines.count
                        && tableSeparator(lines[i + 1]) != nil) {
                    break
                }
                paragraphLines.append(next)
                i += 1
            }
            blocks.append(.paragraph(paragraphLines.joined(separator: " ")))
        }
        return blocks
    }

    /// Parses a line that is only `![alt](target)`. The target is an http(s)
    /// address or a file in the app's Documents folder (`file:///…`, an absolute
    /// path, or one relative to Documents); anything else stays ordinary text.
    static func imageBlock(_ line: String) -> Block? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("!["), trimmed.hasSuffix(")"),
              let altEnd = trimmed.range(of: "](") else { return nil }
        let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd.lowerBound])
        let inner = trimmed[altEnd.upperBound..<trimmed.index(before: trimmed.endIndex)]
        // Drop an optional title: ![alt](url "title")
        guard let target = inner.split(whereSeparator: \.isWhitespace).first.map(String.init),
              !target.contains(")") else { return nil }
        let lowered = target.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return URL(string: target).map { .image(alt: alt, url: $0) }
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let candidate: URL
        if lowered.hasPrefix("file://") {
            guard let url = URL(string: target) else { return nil }
            candidate = url
        } else if target.hasPrefix("/") {
            candidate = URL(fileURLWithPath: target)
        } else {
            let relative = target.hasPrefix("Documents/") ? String(target.dropFirst("Documents/".count)) : target
            guard !relative.contains("..") else { return nil }
            candidate = documents.appendingPathComponent(relative)
        }
        guard let saved = candidate.savedFileURL,
              FileManager.default.fileExists(atPath: saved.path) else { return nil }
        return .image(alt: alt, url: saved)
    }

    /// Recognizes a table separator row like `|---|:--:|--:|`,
    /// returning the per-column alignments.
    static func tableSeparator(_ line: String) -> [ColumnAlignment]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("-"), trimmed.contains("|") else { return nil }
        var cells = splitRow(line)
        guard !cells.isEmpty else { return nil }
        cells = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        var alignments: [ColumnAlignment] = []
        for cell in cells {
            let dashes = cell.filter { $0 == "-" }
            let others = cell.filter { $0 != "-" }
            guard !dashes.isEmpty, others.allSatisfy({ $0 == ":" } ) else { return nil }
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            if left && right { alignments.append(.center) }
            else if right { alignments.append(.trailing) }
            else { alignments.append(.leading) }
        }
        return alignments
    }

    /// Splits a pipe-delimited row into trimmed cell values,
    /// tolerating leading/trailing pipes.
    static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    /// Matches "12. " prefixes, returning the remainder.
    private static func firstNumberedPrefix(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let dotIndex = trimmed.firstIndex(of: ".") else { return nil }
        let numberPart = trimmed[trimmed.startIndex..<dotIndex]
        guard !numberPart.isEmpty, numberPart.allSatisfy(\.isNumber) else { return nil }
        let after = trimmed.index(after: dotIndex)
        guard after < trimmed.endIndex, trimmed[after] == " " else { return nil }
        return String(trimmed[after...])
    }
}

// MARK: - Inline parsing

/// Renders inline markdown: **bold**, *italic*, `code`, [text](url).
struct InlineText: View {
    let segments: [InlineSegment]

    init(_ text: String) {
        self.segments = InlineParser.parse(text)
    }

    var body: some View {
        AnyView(Self.render(segments))
    }

    /// Builds one Text so selection flows naturally. Bold and italic runs are
    /// parsed again, so a link or code span inside `**…**` still works.
    private static func render(_ segments: [InlineSegment]) -> Text {
        var result = Text("")
        for segment in segments {
            switch segment {
            case .plain(let s):
                result = Text("\(result)\(Text(s))")
            case .bold(let s):
                result = Text("\(result)\(render(InlineParser.parse(s)).bold())")
            case .italic(let s):
                result = Text("\(result)\(render(InlineParser.parse(s)).italic())")
            case .code(let s):
                let code = Text(s).font(.system(.body, design: .monospaced))
                    .foregroundColor(.accentColor)
                result = Text("\(result)\(code)")
            case .link(let title, let url):
                if url.isOpenableFromChat {
                    // An attributed run keeps the link tappable; SwiftUI opens it
                    // in the default browser and tints it with the accent color.
                    var link = AttributedString(title)
                    link.link = url.savedFileURL ?? url
                    link.underlineStyle = .single
                    result = Text("\(result)\(Text(link))")
                } else {
                    result = Text("\(result)\(Text(title))")
                }
            }
        }
        return result
    }
}

enum InlineSegment {
    case plain(String)
    case bold(String)
    case italic(String)
    case code(String)
    case link(title: String, url: URL)
}

enum InlineParser {
    static func parse(_ text: String) -> [InlineSegment] {
        var segments: [InlineSegment] = []
        var buffer = ""
        let chars = Array(text)
        var i = 0

        func flush() {
            if !buffer.isEmpty {
                segments.append(.plain(buffer))
                buffer = ""
            }
        }

        while i < chars.count {
            // Inline code: `...`
            if chars[i] == "`" {
                if let end = indexOf(`chars`, "`", from: i + 1) {
                    flush()
                    let code = String(chars[(i + 1)..<end])
                    // A code span holding an address or a saved file's path is a link in
                    // all but formatting, and models often wrap them in backticks.
                    if let url = linkTarget(forCode: code) {
                        segments.append(.link(title: code, url: url))
                    } else {
                        segments.append(.code(code))
                    }
                    i = end + 1
                    continue
                }
            }
            // Bold: **...**
            if chars[i] == "*", i + 1 < chars.count, chars[i + 1] == "*" {
                if let end = indexOfDouble(`chars`, "*", from: i + 2) {
                    flush()
                    segments.append(.bold(String(chars[(i + 2)..<end])))
                    i = end + 2
                    continue
                }
            }
            // Italic: *...*
            if chars[i] == "*" {
                if let end = indexOf(`chars`, "*", from: i + 1) {
                    flush()
                    segments.append(.italic(String(chars[(i + 1)..<end])))
                    i = end + 1
                    continue
                }
            }
            // Link: [text](url)
            if chars[i] == "[" {
                if let closeBracket = indexOf(`chars`, "]", from: i + 1),
                   closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
                   let closeParen = indexOf(`chars`, ")", from: closeBracket + 2) {
                    let title = String(chars[(i + 1)..<closeBracket])
                    let urlText = String(chars[(closeBracket + 2)..<closeParen])
                    if let url = URL(string: urlText) {
                        flush()
                        segments.append(.link(title: title, url: url))
                        i = closeParen + 1
                        continue
                    }
                }
            }
            // Bare URL: https://example.com/page
            if "hHfF".contains(chars[i]), let end = bareURLEnd(chars, from: i) {
                let urlText = String(chars[i..<end])
                if let url = URL(string: urlText) {
                    flush()
                    segments.append(.link(title: urlText, url: url))
                    i = end
                    continue
                }
            }
            buffer.append(chars[i])
            i += 1
        }
        flush()
        return segments
    }

    /// The link a code span stands for: a web or file address, or a path to a
    /// file that exists in the app's Documents folder ("diagrams/x.svg",
    /// "Documents/diagrams/x.svg" or an absolute path). Nil for ordinary code.
    private static func linkTarget(forCode code: String) -> URL? {
        let text = code.trimmingCharacters(in: .whitespaces)
        // Whitespace rules out ordinary code, except in an absolute path, which is
        // checked against the Documents folder below.
        guard !text.isEmpty, text.hasPrefix("/") || !text.contains(where: \.isWhitespace) else { return nil }
        let lowered = text.lowercased()
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") || lowered.hasPrefix("file:///") {
            return URL(string: text)
        }
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let candidate: URL
        if text.hasPrefix("/") {
            candidate = URL(fileURLWithPath: text)
        } else if text.contains("/") || text.contains(".") {
            let relative = text.hasPrefix("Documents/") ? String(text.dropFirst("Documents/".count)) : text
            candidate = documents.appendingPathComponent(relative)
        } else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard candidate.isSavedFile,
              FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return nil }
        return candidate
    }

    /// End index (exclusive) of an http(s) URL starting at `start`, or nil when
    /// there isn't one. Sentence punctuation after the URL isn't part of it.
    private static func bareURLEnd(_ chars: [Character], from start: Int) -> Int? {
        // Only at the start of a word, not in the middle of one.
        if start > 0, !(chars[start - 1].isWhitespace || "([<\"'".contains(chars[start - 1])) {
            return nil
        }
        let head = String(chars[start..<min(chars.count, start + 8)]).lowercased()
        guard head.hasPrefix("https://") || head.hasPrefix("http://") || head.hasPrefix("file:///") else { return nil }
        var end = start
        while end < chars.count, !chars[end].isWhitespace, !"<>\"'`".contains(chars[end]) {
            end += 1
        }
        while end > start, ".,;:!?)]}*_".contains(chars[end - 1]) {
            end -= 1
        }
        // Something has to follow the scheme.
        return end - start > 8 ? end : nil
    }

    private static func indexOf(_ chars: [Character], _ target: Character, from: Int) -> Int? {
        var i = from
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    private static func indexOfDouble(_ chars: [Character], _ target: Character, from: Int) -> Int? {
        var i = from
        while i + 1 < chars.count {
            if chars[i] == target && chars[i + 1] == target { return i }
            i += 1
        }
        return nil
    }
}

// MARK: - Table

/// Renders a markdown table as a bordered grid that scrolls horizontally
/// when wider than the available space.
struct TableBlockView: View {
    let header: [String]
    let rows: [[String]]
    let alignments: [ColumnAlignment]

    var body: some View {
        // No horizontal ScrollView: the grid fills the available width and
        // cells wrap, so long text is never clipped off-screen.
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                ForEach(Array(header.enumerated()), id: \.offset) { col, cell in
                    InlineText(cell)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: frameAlignment(col))
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { col, cell in
                        InlineText(cell)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: frameAlignment(col))
                    }
                }
            }
        }
        .padding(10)
        .background(Color.appTertiaryBackground, in: RoundedRectangle(cornerRadius: 10))
    }

    private func frameAlignment(_ column: Int) -> Alignment {
        guard column < alignments.count else { return .leading }
        switch alignments[column] {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Image

/// A markdown image, shown as a thumbnail that opens full screen on tap. Both
/// saved files and remote images load right away.
struct MarkdownImageView: View {
    let alt: String
    let url: URL
    @State private var showFullScreen = false

    private var caption: String { alt.isEmpty ? (url.host ?? url.lastPathComponent) : alt }

    var body: some View {
        content
            .modifier(ImagePopup(isPresented: $showFullScreen, url: url, caption: caption))
    }

    @ViewBuilder
    private var content: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let image):
                // Thumbnail; tapping opens the full-screen viewer.
                Button {
                    showFullScreen = true
                } label: {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 260, maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(caption)
                .accessibilityHint("Opens the image full screen")
            case .failure:
                fallback
            default:
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Shown when the data isn't a decodable image (an SVG, say, or a dead link).
    private var fallback: some View {
        Group {
            if url.isOpenableFromChat {
                Link(destination: url) { Label("Open \(caption)", systemImage: "photo") }
            } else {
                Label("Couldn't load \(caption)", systemImage: "photo")
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appTertiaryBackground, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Presents the full-size viewer: full screen on iOS, a sheet on macOS
/// (where `fullScreenCover` doesn't exist).
private struct ImagePopup: ViewModifier {
    @Binding var isPresented: Bool
    let url: URL
    let caption: String

    func body(content: Content) -> some View {
        #if os(macOS)
        content.sheet(isPresented: $isPresented) {
            ImageViewer(url: url, caption: caption)
                .frame(minWidth: 640, minHeight: 480)
        }
        #else
        content.fullScreenCover(isPresented: $isPresented) {
            ImageViewer(url: url, caption: caption)
        }
        #endif
    }
}

/// Full-size image on black: pinch to zoom, drag to pan while zoomed,
/// double-tap to reset, with share and close buttons.
private struct ImageViewer: View {
    let url: URL
    let caption: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { scale = max(1, baseScale * $0.magnification) }
                                .onEnded { _ in
                                    baseScale = scale
                                    if scale == 1 { offset = .zero; baseOffset = .zero }
                                }
                        )
                        .simultaneousGesture(
                            DragGesture()
                                .onChanged { drag in
                                    guard scale > 1 else { return }
                                    offset = CGSize(width: baseOffset.width + drag.translation.width,
                                                    height: baseOffset.height + drag.translation.height)
                                }
                                .onEnded { _ in baseOffset = offset }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation {
                                scale = 1; baseScale = 1
                                offset = .zero; baseOffset = .zero
                            }
                        }
                        .accessibilityLabel(caption)
                case .failure:
                    Label("Couldn't load image", systemImage: "photo")
                        .foregroundStyle(.white)
                default:
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Translucent circles keep both buttons visible over bright images,
            // with 44pt tap targets.
            HStack(spacing: 12) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                        .contentShape(Circle())
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                        .contentShape(Circle())
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .buttonStyle(.plain)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .padding()
        }
    }
}

// MARK: - Code block

struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Clipboard.string = code
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.08))

            Text(code)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension URL {
    /// Links in model output only open web pages and mail. Other schemes
    /// (file:, tel:, app-specific ones) are shown as plain text instead.
    var isOpenableFromChat: Bool {
        switch scheme?.lowercased() {
        case "http", "https", "mailto":
            return true
        case "file":
            return isSavedFile
        default:
            return false
        }
    }

    /// A file inside the app's Documents folder, where the assistant saves files.
    var isSavedFile: Bool { savedFileURL != nil }

    /// This file's location in the app's current Documents folder, or nil if it isn't one of
    /// the assistant's saved files. The app container's path changes when the app is
    /// reinstalled, so an old chat's link can name a container that no longer exists; the part
    /// after `/Documents/` is looked up in the current one instead.
    var savedFileURL: URL? {
        guard isFileURL,
              let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let docsPath = documents.standardizedFileURL.path
        let path = standardizedFileURL.path
        if path.hasPrefix(docsPath + "/") { return self }
        guard let range = path.range(of: "/Documents/", options: .backwards) else { return nil }
        let tail = String(path[range.upperBound...])
        guard !tail.isEmpty, !tail.contains("..") else { return nil }
        let relocated = documents.appendingPathComponent(tail)
        return FileManager.default.fileExists(atPath: relocated.path) ? relocated : nil
    }
}
