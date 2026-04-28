import Foundation

enum AgentTUIStyledTextTone: Sendable, Equatable {
    case base
    case secondary
    case accent
}

struct AgentTUIStyledTextSpan: Sendable, Equatable {
    var text: String
    var isBold: Bool
    var isItalic: Bool
    var isUnderlined: Bool
    var tone: AgentTUIStyledTextTone

    init(
        _ text: String,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        tone: AgentTUIStyledTextTone = .base
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.tone = tone
    }
}

func agentTUIPlainText(_ spans: [AgentTUIStyledTextSpan]) -> String {
    spans.map(\.text).joined()
}

func agentTUIMarkdownStyledLines(_ markdown: String, width: Int) -> [[AgentTUIStyledTextSpan]] {
    let width = max(1, width)
    let rawLines = markdown
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)

    guard !rawLines.isEmpty else {
        return [[AgentTUIStyledTextSpan("")]]
    }

    var result: [[AgentTUIStyledTextSpan]] = []
    var index = 0

    while index < rawLines.count {
        if let table = parseMarkdownTable(lines: rawLines, startIndex: index, width: width) {
            result.append(contentsOf: table.lines)
            index = table.nextIndex
            continue
        }

        let spans = parseMarkdownLine(rawLines[index])
        result.append(contentsOf: wrapStyledSpans(spans, width: width))
        index += 1
    }

    return result.isEmpty ? [[AgentTUIStyledTextSpan("")]] : result
}

private struct MarkdownInlineState: Equatable {
    var isBold = false
    var isItalic = false
    var isUnderlined = false
    var tone: AgentTUIStyledTextTone = .base
}

private func parseMarkdownLine(_ line: String) -> [AgentTUIStyledTextSpan] {
    if line.isEmpty {
        return [AgentTUIStyledTextSpan("")]
    }

    let leadingSpaceCount = line.prefix { $0 == " " || $0 == "\t" }.count
    let indent = String(repeating: " ", count: leadingSpaceCount)
    let trimmed = line.dropFirst(leadingSpaceCount)

    if let unordered = unorderedListBody(String(trimmed)) {
        return [AgentTUIStyledTextSpan(indent + "• ")] + parseInlineMarkdown(unordered)
    }

    if let ordered = orderedListBody(String(trimmed)) {
        return [AgentTUIStyledTextSpan(indent + ordered.marker + " ")] + parseInlineMarkdown(ordered.body)
    }

    return parseInlineMarkdown(line)
}

private func unorderedListBody(_ text: String) -> String? {
    guard text.count >= 2 else {
        return nil
    }
    let marker = text[text.startIndex]
    guard marker == "-" || marker == "*" || marker == "+" else {
        return nil
    }
    let next = text.index(after: text.startIndex)
    guard text[next] == " " || text[next] == "\t" else {
        return nil
    }
    return String(text[text.index(after: next)...])
}

private func orderedListBody(_ text: String) -> (marker: String, body: String)? {
    var index = text.startIndex
    while index < text.endIndex, text[index].isNumber {
        index = text.index(after: index)
    }

    guard index > text.startIndex, index < text.endIndex, text[index] == "." else {
        return nil
    }

    let afterDot = text.index(after: index)
    guard afterDot < text.endIndex, text[afterDot] == " " || text[afterDot] == "\t" else {
        return nil
    }

    return (
        marker: String(text[text.startIndex...index]),
        body: String(text[text.index(after: afterDot)...])
    )
}

private func parseInlineMarkdown(
    _ text: String,
    initialState: MarkdownInlineState = MarkdownInlineState()
) -> [AgentTUIStyledTextSpan] {
    guard !text.isEmpty else {
        return [AgentTUIStyledTextSpan("")]
    }

    var spans: [AgentTUIStyledTextSpan] = []
    var state = initialState
    var index = text.startIndex

    func append(_ value: String, state: MarkdownInlineState) {
        appendSpan(
            AgentTUIStyledTextSpan(
                value,
                isBold: state.isBold,
                isItalic: state.isItalic,
                isUnderlined: state.isUnderlined,
                tone: state.tone
            ),
            to: &spans
        )
    }

    while index < text.endIndex {
        if text[index...].hasPrefix("["),
           let link = parseMarkdownLink(in: text, at: index) {
            var linkState = state
            linkState.isUnderlined = true
            linkState.tone = .accent
            parseInlineMarkdown(link.label, initialState: linkState).forEach { appendSpan($0, to: &spans) }

            if !link.url.isEmpty, link.url != link.label {
                var urlState = state
                urlState.tone = .secondary
                append(" (\(link.url))", state: urlState)
            }

            index = link.nextIndex
            continue
        }

        if text[index...].hasPrefix("<u>"),
           hasClosing("</u>", in: text, after: text.index(index, offsetBy: 3)) {
            state.isUnderlined = true
            index = text.index(index, offsetBy: 3)
            continue
        }

        if text[index...].hasPrefix("</u>") {
            state.isUnderlined = false
            index = text.index(index, offsetBy: 4)
            continue
        }

        if text[index...].hasPrefix("**"),
           state.isBold || hasClosing("**", in: text, after: text.index(index, offsetBy: 2)) {
            state.isBold.toggle()
            index = text.index(index, offsetBy: 2)
            continue
        }

        if text[index...].hasPrefix("__"),
           state.isBold || hasClosing("__", in: text, after: text.index(index, offsetBy: 2)) {
            state.isBold.toggle()
            index = text.index(index, offsetBy: 2)
            continue
        }

        if text[index] == "*",
           !text[index...].hasPrefix("**"),
           state.isItalic || hasClosing("*", in: text, after: text.index(after: index)) {
            state.isItalic.toggle()
            index = text.index(after: index)
            continue
        }

        if text[index] == "_",
           !text[index...].hasPrefix("__"),
           state.isItalic || isSafeUnderscoreEmphasis(text, at: index),
           state.isItalic || hasClosing("_", in: text, after: text.index(after: index)) {
            state.isItalic.toggle()
            index = text.index(after: index)
            continue
        }

        append(String(text[index]), state: state)
        index = text.index(after: index)
    }

    return spans.isEmpty ? [AgentTUIStyledTextSpan("")] : spans
}

private struct MarkdownLink {
    var label: String
    var url: String
    var nextIndex: String.Index
}

private func parseMarkdownLink(in text: String, at index: String.Index) -> MarkdownLink? {
    guard text[index] == "[" else {
        return nil
    }

    guard let closeBracket = text[index...].firstIndex(of: "]") else {
        return nil
    }
    let openParen = text.index(after: closeBracket)
    guard openParen < text.endIndex, text[openParen] == "(" else {
        return nil
    }
    guard let closeParen = text[openParen...].firstIndex(of: ")") else {
        return nil
    }

    let labelStart = text.index(after: index)
    let urlStart = text.index(after: openParen)
    return MarkdownLink(
        label: String(text[labelStart..<closeBracket]),
        url: String(text[urlStart..<closeParen]),
        nextIndex: text.index(after: closeParen)
    )
}

private func hasClosing(_ delimiter: String, in text: String, after index: String.Index) -> Bool {
    text[index...].range(of: delimiter) != nil
}

private func isSafeUnderscoreEmphasis(_ text: String, at index: String.Index) -> Bool {
    let previous = index > text.startIndex ? text[text.index(before: index)] : " "
    let next = text.index(after: index) < text.endIndex ? text[text.index(after: index)] : " "
    return !previous.isLetter && !previous.isNumber && !next.isWhitespace
}

private struct MarkdownTableParseResult {
    var lines: [[AgentTUIStyledTextSpan]]
    var nextIndex: Int
}

private func parseMarkdownTable(lines: [String], startIndex: Int, width: Int) -> MarkdownTableParseResult? {
    guard startIndex + 1 < lines.count else {
        return nil
    }
    guard let header = parseTableRow(lines[startIndex]),
          isTableSeparator(lines[startIndex + 1])
    else {
        return nil
    }

    var rows = [header]
    var index = startIndex + 2
    while index < lines.count, let row = parseTableRow(lines[index]) {
        rows.append(row)
        index += 1
    }

    let columnCount = rows.map(\.count).max() ?? 0
    guard columnCount > 0 else {
        return nil
    }

    let normalizedRows = rows.map { row in
        row + Array(repeating: "", count: max(0, columnCount - row.count))
    }
    let columnWidths = (0..<columnCount).map { column in
        max(3, normalizedRows.map { plainInlineText($0[column]).count }.max() ?? 3)
    }

    var rendered: [[AgentTUIStyledTextSpan]] = []
    rendered.append(renderTableRow(normalizedRows[0], columnWidths: columnWidths, header: true))
    rendered.append([AgentTUIStyledTextSpan(tableDivider(columnWidths), tone: .secondary)])
    for row in normalizedRows.dropFirst() {
        rendered.append(renderTableRow(row, columnWidths: columnWidths, header: false))
    }

    return MarkdownTableParseResult(
        lines: rendered.flatMap { wrapStyledSpans($0, width: width) },
        nextIndex: index
    )
}

private func parseTableRow(_ line: String) -> [String]? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.contains("|") else {
        return nil
    }

    var content = trimmed
    if content.first == "|" {
        content.removeFirst()
    }
    if content.last == "|" {
        content.removeLast()
    }

    return content
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

private func isTableSeparator(_ line: String) -> Bool {
    guard let cells = parseTableRow(line), !cells.isEmpty else {
        return false
    }

    return cells.allSatisfy { cell in
        let trimmed = cell.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else {
            return false
        }
        return trimmed.allSatisfy { $0 == "-" || $0 == ":" }
    }
}

private func renderTableRow(
    _ row: [String],
    columnWidths: [Int],
    header: Bool
) -> [AgentTUIStyledTextSpan] {
    var spans: [AgentTUIStyledTextSpan] = []

    for (column, cell) in row.enumerated() {
        if column > 0 {
            appendSpan(AgentTUIStyledTextSpan(" │ ", tone: .secondary), to: &spans)
        }

        let cellSpans = parseInlineMarkdown(cell)
        for span in cellSpans {
            var copy = span
            copy.isBold = copy.isBold || header
            appendSpan(copy, to: &spans)
        }

        let padding = columnWidths[column] - plainInlineText(cell).count
        if padding > 0 {
            appendSpan(AgentTUIStyledTextSpan(String(repeating: " ", count: padding)), to: &spans)
        }
    }

    return spans
}

private func tableDivider(_ widths: [Int]) -> String {
    widths
        .map { String(repeating: "─", count: $0) }
        .joined(separator: "─┼─")
}

private func plainInlineText(_ markdown: String) -> String {
    agentTUIPlainText(parseInlineMarkdown(markdown))
}

private struct StyledToken {
    var span: AgentTUIStyledTextSpan
    var isWhitespace: Bool
}

private func wrapStyledSpans(_ spans: [AgentTUIStyledTextSpan], width: Int) -> [[AgentTUIStyledTextSpan]] {
    guard width > 0 else {
        return [spans]
    }

    let tokens = tokenize(spans)
    guard !tokens.isEmpty else {
        return [[AgentTUIStyledTextSpan("")]]
    }

    var lines: [[AgentTUIStyledTextSpan]] = []
    var current: [AgentTUIStyledTextSpan] = []
    var currentWidth = 0
    var pendingWhitespace: [AgentTUIStyledTextSpan] = []
    var pendingWhitespaceWidth = 0

    func flush() {
        if current.isEmpty {
            return
        }
        lines.append(current)
        current = []
        currentWidth = 0
        pendingWhitespace = []
        pendingWhitespaceWidth = 0
    }

    for token in tokens {
        let tokenWidth = token.span.text.count

        if token.isWhitespace {
            if currentWidth > 0 {
                pendingWhitespace.append(token.span)
                pendingWhitespaceWidth += tokenWidth
            }
            continue
        }

        if tokenWidth > width {
            flush()
            var remainder = token.span.text
            while remainder.count > width {
                let end = remainder.index(remainder.startIndex, offsetBy: width)
                var piece = token.span
                piece.text = String(remainder[..<end])
                lines.append([piece])
                remainder = String(remainder[end...])
            }
            if !remainder.isEmpty {
                var piece = token.span
                piece.text = remainder
                appendSpan(piece, to: &current)
                currentWidth = piece.text.count
            }
            continue
        }

        let whitespaceWidth = currentWidth > 0 ? pendingWhitespaceWidth : 0
        if currentWidth > 0, currentWidth + whitespaceWidth + tokenWidth > width {
            flush()
        } else if currentWidth > 0 {
            for whitespace in pendingWhitespace {
                appendSpan(whitespace, to: &current)
            }
            currentWidth += whitespaceWidth
        }

        appendSpan(token.span, to: &current)
        currentWidth += tokenWidth
        pendingWhitespace = []
        pendingWhitespaceWidth = 0
    }

    flush()
    return lines.isEmpty ? [[AgentTUIStyledTextSpan("")]] : lines
}

private func tokenize(_ spans: [AgentTUIStyledTextSpan]) -> [StyledToken] {
    var tokens: [StyledToken] = []

    for span in spans {
        var current = ""
        var currentIsWhitespace: Bool?

        func flush() {
            guard let isWhitespace = currentIsWhitespace, !current.isEmpty else {
                return
            }
            var tokenSpan = span
            tokenSpan.text = current
            tokens.append(StyledToken(span: tokenSpan, isWhitespace: isWhitespace))
            current = ""
            currentIsWhitespace = nil
        }

        for character in span.text {
            let isWhitespace = character == " " || character == "\t"
            if let currentIsWhitespace, currentIsWhitespace != isWhitespace {
                flush()
            }
            currentIsWhitespace = isWhitespace
            current.append(character)
        }

        flush()
    }

    return tokens
}

private func appendSpan(_ span: AgentTUIStyledTextSpan, to spans: inout [AgentTUIStyledTextSpan]) {
    guard !span.text.isEmpty else {
        return
    }

    if var last = spans.last,
       last.isBold == span.isBold,
       last.isItalic == span.isItalic,
       last.isUnderlined == span.isUnderlined,
       last.tone == span.tone {
        last.text += span.text
        spans[spans.count - 1] = last
    } else {
        spans.append(span)
    }
}
