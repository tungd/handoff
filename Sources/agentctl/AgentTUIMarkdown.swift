import AgentCore
import Foundation

enum AgentTUIStyledTextTone: Sendable, Equatable {
    case base
    case secondary
    case accent
    case success
    case failure
    case quote
}

enum AgentTUIToolStatus: Sendable, Equatable {
    case running
    case succeeded
    case failed
}

struct AgentTUIStyledTextSpan: Sendable, Equatable {
    var text: String
    var isBold: Bool
    var isItalic: Bool
    var isUnderlined: Bool
    var tone: AgentTUIStyledTextTone
    var preservesLayout: Bool

    init(
        _ text: String,
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        tone: AgentTUIStyledTextTone = .base,
        preservesLayout: Bool = false
    ) {
        self.text = text
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.tone = tone
        self.preservesLayout = preservesLayout
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

func agentTUIQuoteStyledLines(_ markdown: String, width: Int) -> [[AgentTUIStyledTextSpan]] {
    agentTUIMarkdownStyledLines(markdown, width: max(1, width - 2)).map { line in
        let text = agentTUIPlainText(line)
        let quoted = text.isEmpty ? "┃" : "┃ \(text)"
        return [AgentTUIStyledTextSpan(quoted, isItalic: true, tone: .quote, preservesLayout: true)]
    }
}

func agentTUIToolCallKey(from payload: [String: JSONValue]) -> String {
    agentTUICommandText(from: payload) ?? agentTUIToolCallText(from: payload)
}

func agentTUIToolCallText(from payload: [String: JSONValue]) -> String {
    if let title = payload["title"]?.stringValue {
        return title
    }

    if let name = payload["name"]?.stringValue {
        if let detail = payload["detail"]?.stringValue, !detail.isEmpty {
            return "\(name) \(detail)"
        }
        return name
    }

    guard let command = agentTUICommandText(from: payload), !command.isEmpty else {
        return "Tool"
    }

    let script = agentTUIShellScript(command)
    return "Bash \(script)"
}

func agentTUIToolCallStyledLine(
    _ text: String,
    status: AgentTUIToolStatus
) -> [AgentTUIStyledTextSpan] {
    let symbol: String
    let tone: AgentTUIStyledTextTone
    switch status {
    case .running:
        symbol = "⋯"
        tone = .secondary
    case .succeeded:
        symbol = "✓"
        tone = .success
    case .failed:
        symbol = "×"
        tone = .failure
    }

    return [AgentTUIStyledTextSpan("\(symbol) \(text)", isBold: true, tone: tone, preservesLayout: true)]
}

func agentTUIToolOutputText(
    from payload: [String: JSONValue],
    maxLines: Int = 12,
    maxLineLength: Int = 140
) -> String? {
    guard let output = payload["output"]?.stringValue?.trimmingCharacters(in: .newlines),
          !output.isEmpty,
          !agentTUIIsDiffLikeOutput(output)
    else {
        return nil
    }

    let command = agentTUICommandText(from: payload).map(agentTUIShellScript) ?? "tool"
    var outputLines = output
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .map { truncateLine($0, maxLength: maxLineLength) }

    if outputLines.count > maxLines {
        let hidden = outputLines.count - maxLines
        outputLines = ["[... \(hidden) lines truncated ...]"] + outputLines.suffix(maxLines)
    }

    return (["$ \(command)"] + outputLines).joined(separator: "\n")
}

func agentTUIToolOutputStyledLines(_ text: String, width: Int) -> [[AgentTUIStyledTextSpan]] {
    let lines = text
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)

    return lines.enumerated().flatMap { index, line -> [[AgentTUIStyledTextSpan]] in
        if index == 0, line.hasPrefix("$ ") {
            return [[AgentTUIStyledTextSpan(line, isBold: true, preservesLayout: true)]]
        }

        return wrapStyledSpans([
            AgentTUIStyledTextSpan(line, tone: .secondary)
        ], width: width)
    }
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
    let naturalColumnWidths = (0..<columnCount).map { column in
        max(3, normalizedRows.map { plainInlineText($0[column]).count }.max() ?? 3)
    }
    let columnWidths = constrainedTableColumnWidths(
        naturalColumnWidths,
        availableWidth: width,
        decorationWidth: tableDecorationWidth(columnCount: columnCount)
    )

    var rendered: [[AgentTUIStyledTextSpan]] = []
    rendered.append([AgentTUIStyledTextSpan(
        tableBorder(columnWidths, left: "┌", separator: "┬", right: "┐"),
        preservesLayout: true
    )])
    rendered.append(contentsOf: renderTableRow(normalizedRows[0], columnWidths: columnWidths))
    rendered.append([AgentTUIStyledTextSpan(
        tableBorder(columnWidths, left: "├", separator: "┼", right: "┤"),
        preservesLayout: true
    )])
    for row in normalizedRows.dropFirst() {
        rendered.append(contentsOf: renderTableRow(row, columnWidths: columnWidths))
    }
    rendered.append([AgentTUIStyledTextSpan(
        tableBorder(columnWidths, left: "└", separator: "┴", right: "┘"),
        preservesLayout: true
    )])

    return MarkdownTableParseResult(
        lines: rendered,
        nextIndex: index
    )
}

private func constrainedTableColumnWidths(
    _ naturalWidths: [Int],
    availableWidth: Int,
    decorationWidth: Int
) -> [Int] {
    guard !naturalWidths.isEmpty else {
        return []
    }

    let minimumWidth = 3
    let availableCellWidth = max(
        naturalWidths.count * minimumWidth,
        availableWidth - decorationWidth
    )
    var widths = naturalWidths.map { max(minimumWidth, $0) }

    while widths.reduce(0, +) > availableCellWidth {
        guard let shrinkIndex = widths.indices.max(by: { widths[$0] < widths[$1] }),
              widths[shrinkIndex] > minimumWidth
        else {
            break
        }
        widths[shrinkIndex] -= 1
    }

    return widths
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
    columnWidths: [Int]
) -> [[AgentTUIStyledTextSpan]] {
    let cells = row.enumerated().map { column, cell in
        wrapStyledSpans(tableCellSpans(cell), width: columnWidths[column])
    }
    let rowHeight = cells.map(\.count).max() ?? 1

    return (0..<rowHeight).map { rowIndex in
        var text = ""

        for column in row.indices {
            text += "│ "

            let cellLine = rowIndex < cells[column].count
                ? cells[column][rowIndex]
                : [AgentTUIStyledTextSpan("")]
            text += agentTUIPlainText(cellLine)

            let padding = columnWidths[column] - agentTUIPlainText(cellLine).count
            if padding > 0 {
                text += String(repeating: " ", count: padding)
            }
            text += " "
        }
        text += "│"

        return [AgentTUIStyledTextSpan(text, preservesLayout: true)]
    }
}

private func tableCellSpans(_ cell: String) -> [AgentTUIStyledTextSpan] {
    parseInlineMarkdown(cell)
}

private func tableDecorationWidth(columnCount: Int) -> Int {
    // Left/right borders + per-column padding + inner separators.
    max(0, (columnCount * 2) + columnCount + 1)
}

private func tableBorder(_ widths: [Int], left: String, separator: String, right: String) -> String {
    left + widths
        .map { String(repeating: "─", count: $0 + 2) }
        .joined(separator: separator) + right
}

private func plainInlineText(_ markdown: String) -> String {
    agentTUIPlainText(parseInlineMarkdown(markdown))
}

private func agentTUICommandText(from payload: [String: JSONValue]) -> String? {
    payload["command"]?.stringValue
        ?? payload["cmd"]?.stringValue
        ?? payload["script"]?.stringValue
}

private func agentTUIShellScript(_ command: String) -> String {
    let prefixes = [
        "/bin/zsh -lc ",
        "/usr/bin/zsh -lc ",
        "zsh -lc ",
        "/bin/bash -lc ",
        "/usr/bin/bash -lc ",
        "bash -lc "
    ]

    for prefix in prefixes where command.hasPrefix(prefix) {
        return unquoteShellArgument(String(command.dropFirst(prefix.count)))
    }

    return command
}

private func unquoteShellArgument(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2,
          let first = trimmed.first,
          let last = trimmed.last,
          (first == "'" && last == "'") || (first == "\"" && last == "\"")
    else {
        return trimmed
    }

    return String(trimmed.dropFirst().dropLast())
}

private func agentTUIIsDiffLikeOutput(_ output: String) -> Bool {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).prefix(12)
    return lines.contains { line in
        line.hasPrefix("diff --git")
            || line.hasPrefix("@@")
            || line.hasPrefix("+++ ")
            || line.hasPrefix("--- ")
    }
}

private func truncateLine(_ line: String, maxLength: Int) -> String {
    guard maxLength > 0, line.count > maxLength else {
        return line
    }

    let end = line.index(line.startIndex, offsetBy: max(0, maxLength - 1))
    return String(line[..<end]) + "…"
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
       last.tone == span.tone,
       last.preservesLayout == span.preservesLayout {
        last.text += span.text
        spans[spans.count - 1] = last
    } else {
        spans.append(span)
    }
}
