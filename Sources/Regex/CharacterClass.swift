public struct CharacterClass: Hashable {
  /// The actual character class to match.
  var cc: Representation
  
  /// The level (character or Unicode scalar) at which to match.
  var matchLevel: MatchLevel

  /// Whether this character class matches against an inverse,
  /// e.g \D, \S, [^abc].
  var isInverted: Bool = false

  public enum Property : Hashable {
    public struct Key : RawRepresentable, Hashable {
      public var rawValue: String
      public init(_ rawValue: String) { self.rawValue = rawValue }
      public init(rawValue: String) { self.rawValue = rawValue }
    }
    public struct Value : RawRepresentable, Hashable {
      public var rawValue: String
      public init(_ rawValue: String) { self.rawValue = rawValue }
      public init(rawValue: String) { self.rawValue = rawValue }
    }

    case generalCategory(GeneralCategory)
    case script(Value)
    case scriptExtension(Value)
    /// Character.isLetter
    case letter
    /// Character.isUppercase
    case uppercase
    /// Character.isLowercase
    case lowercase
    /// Character.isWhitespace
    case whitespace
    case nonCharacter
    case defaultIgnorable
    case other(key: Key?, value: Value)

    public func matches(_ character: Character) -> Bool {
      switch self {
      case .generalCategory, .script, .scriptExtension, .nonCharacter,
          .defaultIgnorable, .other:
        fatalError("Not implemented")
      case .letter:
        return character.isLetter
      case .uppercase:
        return character.isUppercase
      case .lowercase:
        return character.isLowercase
      case .whitespace:
        return character.isWhitespace
      }
    }
  }

  public struct CharacterName: RawRepresentable, Hashable {
    public var rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(rawValue: String) { self.rawValue = rawValue }
  }

  public enum Representation: Hashable {
    /// Any character
    case any
    /// Any grapheme cluster
    case anyGrapheme
    /// Character.isASCII
    case ascii
    /// \p{Cc} -- C0 control characters, delete, and C1 control characters
    /// U+00...U+1F, U+7F, U+80...U+9F
    case controlChar
    /// Character.isDigit
    case digit
    /// Character.isHexDigit
    case hexDigit
    case horizontalWhitespace
    // Characters that mark the page when printed.
    case graphChar
    /// Character.isLetter or Character.isDigit
    case letterOrNumber
    /// Character.isLowercase
    case lowercase
    /// graph + whitespace - control
    case printChar
    case punctuation
    // Character is space or tab
    case spaceOrTab
    case verticalWhitespace
    /// \n
    case newline
    /// \R
    case newlineSequence
    /// Character.isLetter or Character.isDigit or Character == "_"
    case word

    /// A character property e.g \p{...}.
    case property(Property)

    /// A specific named character \N{...}.
    case named(CharacterName)

    /// One of the custom character set.
    case custom([CharacterSetComponent])
  }

  public enum SetOperator: Hashable {
    case intersection
    case subtraction
    case symmetricDifference
  }

  /// A binary set operation that forms a character class component.
  public struct SetOperation: Hashable {
    var lhs: CharacterSetComponent
    var op: SetOperator
    var rhs: CharacterSetComponent

    public func matches(_ c: Character) -> Bool {
      switch op {
      case .intersection:
        return lhs.matches(c) && rhs.matches(c)
      case .subtraction:
        return lhs.matches(c) && !rhs.matches(c)
      case .symmetricDifference:
        return lhs.matches(c) != rhs.matches(c)
      }
    }
  }

  public enum CharacterSetComponent: Hashable {
    case character(Character)
    case range(ClosedRange<Character>)

    /// A nested character class.
    case characterClass(CharacterClass)

    /// A binary set operation of character class components.
    indirect case setOperation(SetOperation)

    public static func setOperation(
      lhs: CharacterSetComponent, op: SetOperator, rhs: CharacterSetComponent
    ) -> CharacterSetComponent {
      .setOperation(.init(lhs: lhs, op: op, rhs: rhs))
    }

    public func matches(_ character: Character) -> Bool {
      switch self {
      case .character(let c): return c == character
      case .range(let range): return range.contains(character)
      case .characterClass(let custom):
        let str = String(character)
        return custom.matches(in: str, at: str.startIndex) != nil
      case .setOperation(let op): return op.matches(character)
      }
    }
  }

  public enum MatchLevel {
    /// Match at the extended grapheme cluster level.
    case graphemeCluster
    /// Match at the Unicode scalar level.
    case unicodeScalar
  }

  public var scalarSemantic: Self {
    var result = self
    result.matchLevel = .unicodeScalar
    return result
  }
  
  public var graphemeClusterSemantic: Self {
    var result = self
    result.matchLevel = .graphemeCluster
    return result
  }

  /// Returns an inverted character class if true is passed, otherwise the
  /// same character class is returned.
  public func withInversion(_ invertion: Bool) -> Self {
    var copy = self
    if invertion {
      copy.isInverted.toggle()
    }
    return copy
  }

  /// Returns the inverse character class.
  public var inverted: Self {
    return withInversion(!isInverted)
  }
  
  /// Returns the end of the match of this character class in `str`, if
  /// it matches.
  public func matches(in str: String, at i: String.Index) -> String.Index? {
    switch matchLevel {
    case .graphemeCluster:
      let c = str[i]
      var matched: Bool
      switch cc {
      case .any, .anyGrapheme: matched = true
      case .ascii: matched = c.isASCII
      case .controlChar: fatalError("Not implemented")
      case .digit: matched = c.isNumber
      case .graphChar: fatalError("Not implemented")
      case .hexDigit: matched = c.isHexDigit
      case .horizontalWhitespace: fatalError("Not implemented")
      case .letterOrNumber: matched = c.isLetter || c.isNumber
      case .lowercase: matched = c.isLowercase
      case .newline: fatalError("Not implemented")
      case .newlineSequence: fatalError("Not implemented")
      case .printChar: fatalError("Not implemented")
      case .punctuation: fatalError("Not implemented")
      case .spaceOrTab: fatalError("Not implemented")
      case .verticalWhitespace: fatalError("Not implemented")
      case .word: matched = c.isLetter || c.isNumber || c == "_"
      case .property(let p): matched = p.matches(c)
      case .named: fatalError("Not implemented")
      case .custom(let set): matched = set.any { $0.matches(c) }
      }
      if isInverted {
        matched.toggle()
      }
      return matched ? str.index(after: i) : nil
    case .unicodeScalar:
      let c = str.unicodeScalars[i]
      var matched: Bool
      switch cc {
      case .any: matched = true
      case .anyGrapheme: fatalError("Not matched in this mode")
      case .ascii: matched = c.isASCII
      case .controlChar: fatalError("Not implemented")
      case .digit: matched = c.properties.numericType != nil
      case .graphChar: fatalError("Not implemented")
      case .hexDigit: matched = Character(c).isHexDigit
      case .horizontalWhitespace: fatalError("Not implemented")
      case .letterOrNumber: fatalError("Not implemented")
      case .lowercase: matched = c.properties.isLowercase
      case .newline: fatalError("Not implemented")
      case .newlineSequence: fatalError("Not implemented")
      case .printChar: fatalError("Not implemented")
      case .punctuation: fatalError("Not implemented")
      case .spaceOrTab: fatalError("Not implemented")
      case .verticalWhitespace: fatalError("Not implemented")
      case .word: matched = c.properties.isAlphabetic || c == "_"
      case .property: fatalError("Not implemented")
      case .named: fatalError("Not implemented")
      case .custom: fatalError("Not supported")
      }
      if isInverted {
        matched.toggle()
      }
      return matched ? str.unicodeScalars.index(after: i) : nil
    }
  }
}

extension CharacterClass {
  public static var any: CharacterClass {
    .init(cc: .any, matchLevel: .graphemeCluster)
  }

  public static var anyGrapheme: CharacterClass {
    .init(cc: .anyGrapheme, matchLevel: .graphemeCluster)
  }

  public static var ascii: CharacterClass {
    .init(cc: .ascii, matchLevel: .graphemeCluster)
  }

  public static var controlChar: CharacterClass {
    .init(cc: .controlChar, matchLevel: .graphemeCluster)
  }

  public static var digit: CharacterClass {
    .init(cc: .digit, matchLevel: .graphemeCluster)
  }

  public static var graphChar: CharacterClass {
    .init(cc: .graphChar, matchLevel: .graphemeCluster)
  }

  public static var hexDigit: CharacterClass {
    .init(cc: .hexDigit, matchLevel: .graphemeCluster)
  }

  public static var horizontalWhitespace: CharacterClass {
    .init(cc: .horizontalWhitespace, matchLevel: .graphemeCluster)
  }

  public static var letter: CharacterClass {
    .property(.letter)
  }

  public static var letterOrNumber: CharacterClass {
    .init(cc: .letterOrNumber, matchLevel: .graphemeCluster)
  }

  public static var lowercase: CharacterClass {
    .property(.lowercase)
  }

  public static var newline: CharacterClass {
    .init(cc: .newline, matchLevel: .graphemeCluster)
  }

  public static var newlineSequence: CharacterClass {
    .init(cc: .newlineSequence, matchLevel: .graphemeCluster)
  }

  public static var printChar: CharacterClass {
    .init(cc: .printChar, matchLevel: .graphemeCluster)
  }

  public static var punctuation: CharacterClass {
    .init(cc: .punctuation, matchLevel: .graphemeCluster)
  }

  public static var spaceOrTab: CharacterClass {
    .init(cc: .spaceOrTab, matchLevel: .graphemeCluster)
  }

  public static var uppercase: CharacterClass {
    .property(.uppercase)
  }

  public static var verticalWhitespace: CharacterClass {
    .init(cc: .verticalWhitespace, matchLevel: .graphemeCluster)
  }

  public static var whitespace: CharacterClass {
    .property(.whitespace)
  }

  public static var word: CharacterClass {
    .init(cc: .word, matchLevel: .graphemeCluster)
  }

  public static func property(_ prop: Property) -> CharacterClass {
    .init(cc: .property(prop), matchLevel: .graphemeCluster)
  }

  public static func namedCharacter(_ name: CharacterName) -> CharacterClass {
    .init(cc: .named(name), matchLevel: .graphemeCluster)
  }

  public static func custom(
    _ components: [CharacterSetComponent]
  ) -> CharacterClass {
    .init(cc: .custom(components), matchLevel: .graphemeCluster)
  }
}

extension CharacterClass.CharacterSetComponent: CustomStringConvertible {
  public var description: String {
    switch self {
    case .range(let range): return "<range \(range)>"
    case .character(let character): return "<character \(character)>"
    case .characterClass(let custom): return "\(custom)"
    case .setOperation(let op): return "<\(op.lhs) \(op.op) \(op.rhs)>"
    }
  }
}

extension CharacterClass.Representation: CustomStringConvertible {
  public var description: String {
    switch self {
    case .any: return "<any>"
    case .anyGrapheme: return "<any grapheme>"
    case .ascii: return "<ascii>"
    case .controlChar: return "<control char>"
    case .digit: return "<digit>"
    case .graphChar: return "<graph char>"
    case .hexDigit: return "<hex digit>"
    case .horizontalWhitespace: return "<horizontal whitespace>"
    case .letterOrNumber: return "<letter or number>"
    case .newline: return "<newline>"
    case .newlineSequence: return "<newline sequence>"
    case .lowercase: return "<lowercase>"
    case .printChar: return "<printable char>"
    case .punctuation: return "<punctuation>"
    case .spaceOrTab: return "<space or tab>"
    case .verticalWhitespace: return "<vertical whitespace>"
    case .word: return "<word>"
    case .property(let prop): return "<char prop \(prop)>"
    case .named(let name): return "<char named \(name)>"
    case .custom(let set): return "<custom \(set)>"
    }
  }
}

extension CharacterClass: CustomStringConvertible {
  public var description: String {
    return "\(isInverted ? "not " : "")\(cc)"
  }
}

extension CharacterClass.Property {
  public enum GeneralCategory: String, Hashable {
    case other = "C"
    case control = "Cc"
    case format = "Cf"
    case unassigned = "Cn"
    case privateUse = "Co"
    case surrogate = "Cs"

    case letter = "L"
    case casedLetter = "Lc"
    case lowercaseLetter = "Ll"
    case modifierLetter = "Lm"
    case otherLetter = "Lo"
    case titlecaseLetter = "Lt"
    case uppercaseLetter = "Lu"

    case mark = "M"
    case spacingMark = "Mc"
    case enclosingMark = "Me"
    case nonspacingMark = "Mn"

    case number = "N"
    case decimalNumber = "Nd"
    case letterNumber = "Nl"
    case otherNumber = "No"

    case punctuation = "P"
    case connectorPunctuation = "Pc"
    case dashPunctuation = "Pd"
    case closePunctuation = "Pe"
    case finalPunctuation = "Pf"
    case initialPunctuation = "Pi"
    case otherPunctuation = "Po"
    case openPunctuation = "Ps"

    case symbol = "S"
    case currencySymbol = "Sc"
    case modifierSymbol = "Sk"
    case mathSymbol = "Sm"
    case otherSymbol = "So"

    case separator = "Z"
    case lineSeparator = "Zl"
    case paragraphSeparator = "Zp"
    case spaceSeparator = "Zs"
  }
}
