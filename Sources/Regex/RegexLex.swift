/// TODO: describe real lexical structure of regex
struct Lexer {
  var source: Source // TODO: fileprivate after diags
  fileprivate var nextToken: Token? = nil

  /// The number of parent custom character classes we're lexing within.
  fileprivate var customCharacterClassDepth = 0

  init(_ source: Source) { self.source = source }
}

// MARK: - Intramodule Programming Interface (IPI?)

extension Lexer {
  /// Whether we're done
  var isEmpty: Bool {
    nextToken == nil && source.isEmpty
  }

  /// Grab the next token without consuming it, if there is one
  mutating func peek() throws -> Token? {
    if let tok = nextToken { return tok }
    guard !source.isEmpty else { return nil }
    try advance()
    return nextToken.unsafelyUnwrapped
  }

  /// Eat a token, returning it (unless we're at the end)
  @discardableResult
  mutating func eat() throws -> Token? {
    let tok = try peek()
    try advance()
    return tok
  }

  /// Eat the specified token if there is one. Returns whether anything happened
  mutating func tryEat(_ tok: Token.Kind) throws -> Bool {
    guard try peek()?.kind == tok else { return false }
    try advance()
    return true
  }

  /// Try to eat a token, throwing if we don't see what we're expecting.
  mutating func eat(expecting tok: Token.Kind) throws {
    guard try tryEat(tok) else { throw "Expected \(tok)" }
  }

  /// Try to eat a token, asserting we saw what we expected
  mutating func eat(asserting tok: Token.Kind) throws {
    let expected = try tryEat(tok)
    assert(expected)
  }

  /// TODO: Consider a variant that will produce the requested token, but also
  /// produce diagnostics/fixit if that's not what's really there.
}

// MARK: - Implementation

extension Lexer {

  /// Whether the lexer is currently lexing within a custom character class.
  private var isInCustomCharacterClass: Bool { customCharacterClassDepth > 0 }

  private mutating func consumeUnicodeScalar(
    firstDigit: Character? = nil,
    digits digitCount: Int
  ) throws -> UnicodeScalar {
    var digits = firstDigit.map(String.init) ?? ""
    for _ in digits.count ..< digitCount {
      guard !source.isEmpty else {
        throw "Exactly \(digitCount) hex digits required"
      }
      digits.append(source.eat())
    }

    guard let value = UInt32(digits, radix: 16),
          let scalar = UnicodeScalar(value)
    else { throw "Invalid unicode sequence" }
    
    return scalar
  }
  
  private mutating func consumeUnicodeScalar() throws -> UnicodeScalar {
    var digits = ""
    // Eat a maximum of 9 characters, the last of which must be the terminator
    for _ in 0..<9 {
      guard !source.isEmpty else { throw "Unterminated unicode value" }
      let next = source.eat()
      if next == "}" { break }
      digits.append(next)
      guard digits.count <= 8 else { throw "Maximum 8 hex values required" }
    }
    
    guard let value = UInt32(digits, radix: 16),
          let scalar = UnicodeScalar(value)
    else { throw "Invalid unicode sequence" }
    
    return scalar
  }

  private func normalizeForCharacterPropertyMatching(_ str: String) -> String {
    // This follows the rules provided by UAX44-LM3, except the dropping
    // of an "is" prefix, which UTS#18 RL1.2 states isn't a requirement.
    return str.filter { !$0.isWhitespace && $0 != "_" && $0 != "-" }
              .lowercased()
  }

  private func getGeneralCategory(
    _ str: String
  ) -> CharacterClass.Property.GeneralCategory? {
    switch normalizeForCharacterPropertyMatching(str) {
    case "c", "other":
      return .other
    case "cc", "control", "cntrl":
      return .control
    case "cf", "format":
      return .format
    case "cn", "unassigned":
      return .unassigned
    case "co", "privateuse":
      return .privateUse
    case "cs", "surrogate":
      return .surrogate
    case "l", "letter":
      return .letter
    case "lc", "casedletter":
      return .casedLetter
    case "ll", "lowercaseletter":
      return .lowercaseLetter
    case "lm", "modifierletter":
      return .modifierLetter
    case "lo", "otherletter":
      return .otherLetter
    case "lt", "titlecaseletter":
      return .titlecaseLetter
    case "lu", "uppercaseletter":
      return .uppercaseLetter
    case "m", "mark", "combiningmark":
      return .mark
    case "mc", "spacingmark":
      return .spacingMark
    case "me", "enclosingmark":
      return .enclosingMark
    case "mn", "nonspacingmark":
      return .nonspacingMark
    case "n", "number":
      return .number
    case "nd", "decimalnumber", "digit":
      return .decimalNumber
    case "nl", "letternumber":
      return .letterNumber
    case "no", "othernumber":
      return .otherNumber
    case "p", "punctuation", "punct":
      return .punctuation
    case "pc", "connectorpunctuation":
      return .connectorPunctuation
    case "pd", "dashpunctuation":
      return .dashPunctuation
    case "pe", "closepunctuation":
      return .closePunctuation
    case "pf", "finalpunctuation":
      return .finalPunctuation
    case "pi", "initialpunctuation":
      return .initialPunctuation
    case "po", "otherpunctuation":
      return .otherPunctuation
    case "ps", "openpunctuation":
      return .openPunctuation
    case "s", "symbol":
      return .symbol
    case "sc", "currencysymbol":
      return .currencySymbol
    case "sk", "modifiersymbol":
      return .modifierSymbol
    case "sm", "mathsymbol":
      return .mathSymbol
    case "so", "othersymbol":
      return .otherSymbol
    case "z", "separator":
      return .separator
    case "zl", "lineseparator":
      return .lineSeparator
    case "zp", "paragraphseparator":
      return .paragraphSeparator
    case "zs", "spaceseparator":
      return .spaceSeparator
    default:
      return nil
    }
  }

  private func classifyBoolProperty(_ str: String) throws -> CharacterClass.Property? {
    switch normalizeForCharacterPropertyMatching(str) {
    case "alpha", "alphabetic":
      return .letter
    case "upper", "uppercase":
      return .uppercase
    case "lower", "lowercase":
      return .lowercase
    case "wspace", "whitespace":
      return .whitespace
    case "nchar", "noncharactercodepoint":
      return .nonCharacter
    case "di", "defaultignorablecodepoint":
      return .defaultIgnorable
    default:
      return nil
    }
  }

  private func classifyCharacterPropertyBoolValue(_ str: String) throws -> Bool {
    switch normalizeForCharacterPropertyMatching(str) {
    case "t", "true", "y", "yes":
      return true
    case "f", "false", "n", "no":
      return false
    default:
      throw "Unexpected bool value \(str)"
    }
  }

  private func classifyCharacterProperty(value: String) throws -> CharacterClass {
    if let prop = try classifyBoolProperty(value) {
      return .property(prop)
    }
    if let cat = getGeneralCategory(value) {
      return .property(.generalCategory(cat))
    }
    return .property(.other(key: nil, value: .init(value)))
  }

  private func classifyCharacterProperty(key: String) throws -> (String) throws -> CharacterClass {
    if let prop = try classifyBoolProperty(key) {
      return {
        let isTrue = try classifyCharacterPropertyBoolValue($0)
        return .property(prop).withInversion(!isTrue)
      }
    }
    switch normalizeForCharacterPropertyMatching(key) {
    case "script", "sc":
      return { .property(.script(.init($0))) }
    case "scriptextensions", "scx":
      return { .property(.scriptExtension(.init($0))) }
    case "gc", "generalcategory":
      return { value in
        guard let cat = getGeneralCategory(value) else {
          throw "Unknown general category '\(value)'"
        }
        return .property(.generalCategory(cat))
      }
    default:
      return { .property(.other(key: .init(key), value: .init($0))) }
    }
  }

  private mutating func consumeCharacterProperty() throws -> CharacterClass {
    var lhs = ""
    while !source.isEmpty && source.peek() != "}" && source.peek() != "=" {
      lhs.append(source.eat())
    }
    if source.eat("}") {
      return try classifyCharacterProperty(value: lhs)
    }
    guard source.eat("=") else {
      throw "Expected } ending"
    }
    var rhs = ""
    while !source.isEmpty && source.peek() != "}" {
      rhs.append(source.eat())
    }
    guard source.eat("}") else {
      throw "Expected } ending"
    }
    return try classifyCharacterProperty(key: lhs)(rhs)
  }

  private mutating func consumeNamedCharacter() throws -> CharacterClass.CharacterName {
    var name = ""
    while !source.isEmpty && source.peek() != "}" {
      name.append(source.eat())
    }
    guard source.eat("}") else {
      throw "Expected } ending"
    }
    return .init(name)
  }

  private mutating func consumeEscapedCharacterClass(
    _ c: Character
  ) throws -> CharacterClass? {
    switch c {
    case "s": return .property(.whitespace)
    case "d": return .digit
    case "w": return .word
    case "h": return .horizontalWhitespace
    case "v": return .verticalWhitespace
    case "n": return .newline
    case "S", "D", "W", "H", "V", "P", "N":
      let lower = Character(c.lowercased())
      return try consumeEscapedCharacterClass(lower)!.inverted
    case "X":
      return .anyGrapheme
    case "R":
      return .newlineSequence
    case "p":
      guard source.eat() == "{" else { throw "Expected '{'" }
      let inverted = source.eat("^")
      return try consumeCharacterProperty().withInversion(inverted)
    case let c where c.isLetter && c.isASCII:
      // To be consistent with PCRE, escaping unknown [a-zA-Z] characters is
      // forbidden, but escaping other characters is a no-op.
      throw "unexpected escape sequence \\\(c)"
    default:
      return nil
    }
  }


  private mutating func consumeEscapedCharacter() throws -> Token.Kind {
    assert(!source.isEmpty, "Escape at end of input string")
    let nextCharacter = source.eat()

    switch nextCharacter {
    // Escaped metacharacters are just regular characters
    case let x where Token.MetaCharacter(rawValue: x) != nil:
      fallthrough
    case Token.escape:
      return .character(nextCharacter, isEscaped: false)

    // Explicit Unicode scalar values have one of these forms:
    // - \u{h...}   (1+ hex digits)
    // - \uhhhh     (exactly 4 hex digits)
    // - \x{h...}   (1+ hex digits)
    // - \xhh       (exactly 2 hex digits)
    // - \Uhhhhhhhh (exactly 8 hex digits)
    case "u":
      let firstDigit = source.eat()
      if firstDigit == "{" {
        return .unicodeScalar(try consumeUnicodeScalar())
      } else {
        return .unicodeScalar(try consumeUnicodeScalar(
          firstDigit: firstDigit, digits: 4))
      }
    case "x":
      let firstDigit = source.eat()
      if firstDigit == "{" {
        return .unicodeScalar(try consumeUnicodeScalar())
      } else {
        return .unicodeScalar(try consumeUnicodeScalar(
          firstDigit: firstDigit, digits: 2))
      }

    case "U":
      return .unicodeScalar(try consumeUnicodeScalar(digits: 8))

    case "N" where source.peek() == "{":
      _ = source.eat()
      if source.eat("U") && source.eat("+") {
        return .unicodeScalar(try consumeUnicodeScalar())
      }
      return .characterClass(.namedCharacter(try consumeNamedCharacter()))
    default:
      break
    }
    if let cc = try consumeEscapedCharacterClass(nextCharacter) {
      return .characterClass(cc)
    }
    return .character(nextCharacter, isEscaped: true)
  }

  private mutating func consumeIfSetOperator(_ ch: Character) -> Token.Kind? {
    // Can only occur in a custom character class. Otherwise, the operator
    // characters are treated literally.
    guard isInCustomCharacterClass else { return nil }
    switch ch {
    case "-" where source.peek() == "-":
      _ = source.eat()
      return .setOperator(.doubleDash)
    case "~" where source.peek() == "~":
      _ = source.eat()
      return .setOperator(.doubleTilda)
    case "&" where source.peek() == "&":
      _ = source.eat()
      return .setOperator(.doubleAmpersand)
    default:
      return nil
    }
  }

  private mutating func consumeIfMetaCharacter(_ ch: Character) -> Token.Kind? {
    guard let meta = Token.MetaCharacter(rawValue: ch) else { return nil }
    // Track the custom character class depth. We can increment it every time
    // we see a `[`, and decrement every time we see a `]`, though we don't
    // decrement if we see `]` outside of a custom character class, as that
    // should be treated as a literal character.
    if meta == .lsquare {
      customCharacterClassDepth += 1
    }
    if meta == .rsquare && isInCustomCharacterClass {
      customCharacterClassDepth -= 1
    }
    return .meta(meta)
  }

  private mutating func consumeNextToken() throws -> Token? {
    guard !source.isEmpty else { return nil }

    let startLoc = source.currentLoc
    func tok(_ kind: Token.Kind) -> Token {
      Token(kind: kind, loc: startLoc..<source.currentLoc)
    }

    let current = source.eat()
    if let op = consumeIfSetOperator(current) {
      return tok(op)
    }
    if let meta = consumeIfMetaCharacter(current) {
      return tok(meta)
    }
    if current == Token.escape {
      return tok(try consumeEscapedCharacter())
    }
    return tok(.character(current, isEscaped: false))
  }
  
  private mutating func advance() throws {
    nextToken = try consumeNextToken()
  }
}
