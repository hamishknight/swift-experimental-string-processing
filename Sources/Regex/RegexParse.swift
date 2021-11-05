private let regexLanguageDescription = """
Brief:
    Just a simple, vanilla regular expression languague.
    Supports *, +, ?, |, and non-capturing grouping
    TBD: character classes, ...
"""

extension String: Error {}

/// A parser reads off a lexer and produces an AST
///
/// Syntactic structure of a regular expression:
///
///     RE -> '' | Alternation
///     Alternation -> Concatenation ('|' Concatenation)*
///     Concatenation -> Quantification Quantification*
///     Quantification -> (Group | Atom) <token: qualifier>?
///     Atom -> <token: .character> | <any> | ... character classes ...
///     CaptureGroup -> '(' RE ')'
///     Group -> '(' '?' ':' RE ')'
///
public enum AST: Hashable {
  indirect case alternation([AST]) // alternation(AST, AST?)
  indirect case concatenation([AST])
  indirect case group(AST)
  indirect case capturingGroup(AST, transform: CaptureTransform? = nil)

  // Post-fix modifiers
  indirect case many(AST)
  indirect case zeroOrOne(AST)
  indirect case oneOrMore(AST)

  // Lazy versions of quantifiers
  indirect case lazyMany(AST)
  indirect case lazyZeroOrOne(AST)
  indirect case lazyOneOrMore(AST)

  case character(Character)
  case unicodeScalar(UnicodeScalar)
  case characterClass(CharacterClass)
  case any
  case empty
}

extension AST: CustomStringConvertible {
  public var description: String {
    switch self {
    case .alternation(let rest): return ".alt(\(rest))"
    case .concatenation(let rest): return ".concat(\(rest))"
    case .group(let rest): return ".group(\(rest))"
    case .capturingGroup(let rest, let transform):
      return """
          .capturingGroup(\(rest), transform: \(transform.map(String.init(describing:)) ?? "nil")
          """
    case .many(let rest): return ".many(\(rest))"
    case .zeroOrOne(let rest): return ".zeroOrOne(\(rest))"
    case .oneOrMore(let rest): return ".oneOrMore(\(rest))"
    case .lazyMany(let rest): return ".lazyMany(\(rest))"
    case .lazyZeroOrOne(let rest): return ".lazyZeroOrOne(\(rest))"
    case .lazyOneOrMore(let rest): return ".lazyOneOrMore(\(rest))"
    case .character(let c): return c.halfWidthCornerQuoted
    case .unicodeScalar(let u): return u.halfWidthCornerQuoted
    case .characterClass(let cc): return ".characterClass(\(cc))"
    case .any: return ".any"
    case .empty: return "".halfWidthCornerQuoted
    }
  }
}

private struct Parser {
  var lexer: Lexer
  init(_ lexer: Lexer) {
    self.lexer = lexer
  }
}

// Diagnostics
extension Parser {
  mutating func report(
    _ str: String, _ function: String = #function, _ line: Int = #line
  ) throws -> Never {
    throw """
        ERROR: \(str)
        (error in user string evaluating \(
            String(describing: try lexer.peek())) prior to: "\(lexer.source)")
        (error detected in parser at \(function):\(line))
        """
  }
}

extension Parser {
  //     RE -> '' | Alternation
  mutating func parse() throws -> AST {
    if lexer.isEmpty { return .empty }
    return try parseAlternation()
  }
  
  //     Alternation -> Concatenation ('|' Concatenation)*
  mutating func parseAlternation() throws -> AST {
    assert(!lexer.isEmpty)
    var result = Array<AST>(singleElement: try parseConcatenation())
    while try lexer.tryEat(.pipe) {
      result.append(try parseConcatenation())
    }
    return result.count == 1 ? result[0] : .alternation(result)
  }
  
  //     Concatenation -> Quantification Quantification*
  mutating func parseConcatenation() throws -> AST {
    var result = Array<AST>()
    while let operand = try parseQuantifierOperand() {
      result.append(try parseQuantification(of: operand))
    }
    guard !result.isEmpty else {
      // Happens in `abc|`
      try report("empty concatenation")
    }
    return result.count == 1 ? result[0] : .concatenation(result)
  }
  
  //     Quantification -> QuantifierOperand <token: Quantifier>?
  mutating func parseQuantification(of operand: AST) throws -> AST {
    switch try lexer.peek()?.kind {
    case .star?:
      try lexer.eat()
      return try lexer.tryEat(.question)
        ? .lazyMany(operand)
        : .many(operand)
    case .plus?:
      try lexer.eat()
      return try lexer.tryEat(.question)
        ? .lazyOneOrMore(operand)
        : .oneOrMore(operand)
    case .question?:
      try lexer.eat()
      return try lexer.tryEat(.question)
        ? .lazyZeroOrOne(operand)
        : .zeroOrOne(operand)
    default:
      return operand
    }
  }

  //     QuantifierOperand -> (Group | <token: Character>)
  mutating func parseQuantifierOperand() throws -> AST? {
    switch try lexer.peek()?.kind {
    case .leftParen?:
      try lexer.eat()
      var isCapturing = true
      if try lexer.tryEat(.question) {
        try lexer.eat(expecting: .colon)
        isCapturing = false
      }
      let child = try parse()
      try lexer.eat(expecting: .rightParen)
      return isCapturing ? .capturingGroup(child) : .group(child)

    case .character(let c, isEscaped: _):
      try lexer.eat()
      return .character(c)

    case .characterClass(let cc):
      try lexer.eat()
      return .characterClass(cc)

    case .unicodeScalar(let u):
      try lexer.eat()
      return .unicodeScalar(u)

    case .minus?, .colon?, .rightSquareBracket?:
      // Outside of custom character classes, these are not considered to be
      // metacharacters.
      guard case .meta(let meta) = try lexer.eat()?.kind else {
        fatalError("Not a metachar?")
      }
      return .character(meta.rawValue)

    case .leftSquareBracket?:
      return .characterClass(try parseCustomCharacterClass())

    case .dot?:
      try lexer.eat()
      return .characterClass(.any)

    // Correct terminations
    case .rightParen?: fallthrough
    case .pipe?: fallthrough
    case nil:
      return nil

    default:
      try report("expected a character or group")
    }
  }

  typealias CharacterSetComponent = CharacterClass.CharacterSetComponent

  /// Parse a literal character in a custom character class.
  mutating func parseCharacterSetComponentCharacter() throws -> Character {
    // Most metacharacters can be interpreted as literal characters in a
    // custom character class. This even includes the '-' character if it
    // appears in a position where it cannot be treated as a range
    // (per PCRE#SEC9). We may want to warn on this and require the user to
    // escape it though.
    switch try lexer.eat()?.kind {
    case .meta(.rsquare):
      try report("unexpected end of character class")
    case .meta(let meta):
      return meta.rawValue
    case .character(let c, isEscaped: _):
      return c
    case .unicodeScalar(let scalar):
      return Character(scalar)
    default:
      try report("expected a character or a ']'")
    }
  }

  mutating func tryParsePOSIXCharacterClass() throws -> CharacterClass? {
    let priorLexerState = lexer
    try! lexer.eat(expecting: .leftSquareBracket)

    guard try lexer.tryEat(.colon) else {
      lexer = priorLexerState
      return nil
    }

    var name = ""
    while case .character(let ch, isEscaped: false) = try lexer.eat()?.kind {
      name.append(ch)
    }
    guard try lexer.tryEat(.colon), try lexer.tryEat(.rightSquareBracket) else {
      lexer = priorLexerState
      return nil
    }
    switch name {
    case "alnum":
      return .letterOrNumber
    case "alpha":
      return .property(.letter)
    case "ascii":
      return .ascii
    case "blank":
      return .spaceOrTab
    case "cntrl":
      return .controlChar
    case "digit":
      return .digit
    case "graph":
      return .graphChar
    case "lower":
      return .property(.lowercase)
    case "print":
      return .printChar
    case "punct":
      return .punctuation
    case "space":
      return .property(.whitespace)
    case "upper":
      return .property(.uppercase)
    case "word":
      return .word
    case "xdigit":
      return .hexDigit
    default:
      try report("Unknown POSIX char class \(name)")
    }
  }

  mutating func parseCharacterSetComponent() throws -> CharacterSetComponent {
    if try lexer.peek()?.kind == .leftSquareBracket {
      // If the next token is a ':', we may have a POSIX character class.
      if let posixClass = try tryParsePOSIXCharacterClass() {
        return .characterClass(posixClass)
      }
      // Otherwise we have a nested custom character class.
      return .characterClass(try parseCustomCharacterClass())
    }
    // Escaped character class.
    // TODO: Not all character classes can be used here.
    if case .characterClass(let cc) = try lexer.peek()?.kind {
      try lexer.eat()
      return .characterClass(cc)
    }
    // A character that can optionally form a range with another character.
    // TODO: Ranges between scalars
    let c1 = try parseCharacterSetComponentCharacter()
    if try lexer.tryEat(.minus) {
      let c2 = try parseCharacterSetComponentCharacter()
      return .range(c1...c2)
    }
    return .character(c1)
  }

  /// Attempt to parse a set operator, returning nil if the next token is not
  /// for a set operator.
  mutating func tryParseSetOperator() throws -> CharacterClass.SetOperator? {
    guard case .setOperator(let opTok) = try lexer.peek()?.kind else {
      return nil
    }
    try lexer.eat()
    switch opTok {
    case .doubleAmpersand:
      return .intersection
    case .doubleDash:
      return .subtraction
    case .doubleTilda:
      return .symmetricDifference
    }
  }

  ///     CharacterClass -> '[' CharacterSetComponent+ ']'
  ///
  ///     CharacterSetComponent -> CharacterSetComponent SetOp CharacterSetComponent
  ///     CharacterSetComponent -> CharacterClass
  ///     CharacterSetComponent -> <token: Character>
  ///     CharacterSetComponent -> <token: Character> '-' <token: Character>
  ///
  mutating func parseCustomCharacterClass() throws -> CharacterClass {
    try lexer.eat(expecting: .leftSquareBracket)
    let isInverted = try lexer.tryEat(.caret)
    var components: [CharacterSetComponent] = []
    while try !lexer.tryEat(.rightSquareBracket) {
      // If we have a binary set operator, parse it and the next component. Note
      // that this means we left associate for a chain of operators.
      // TODO: We may want to diagnose and require users to disambiguate,
      // at least for chains of separate operators.
      if let op = try tryParseSetOperator() {
        guard let lhs = components.popLast() else {
          try report("Binary set operator requires operand")
        }
        let rhs = try parseCharacterSetComponent()
        components.append(.setOperation(lhs: lhs, op: op, rhs: rhs))
        continue
      }
      components.append(try parseCharacterSetComponent())
    }
    return .custom(components).withInversion(isInverted)
  }
}

public func parse(_ regex: String) throws -> AST {
  let lexer = Lexer(Source(regex))
  var parser = Parser(lexer)
  return try parser.parse()
}
