//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2021-2022 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
//
//===----------------------------------------------------------------------===//

/*

Syntactic structure of a regular expression

 Regex           -> '' | Alternation
 Alternation     -> Concatenation ('|' Concatenation)*
 Concatenation   -> (!'|' !')' ConcatComponent)*
 ConcatComponent -> Trivia | Quote | Quantification
 Quantification  -> QuantOperand Quantifier?
 QuantOperand    -> Group | CustomCharClass | Atom
 Group           -> GroupStart Regex ')'

Custom character classes are a mini-language to their own. We
support UTS#18 set operators and nested character classes. The
meaning of some atoms, such as `\b` changes inside a custom
chararacter class. Below, we have a grammar "scope", that is we say
"SetOp" to mean "CustomCharactetClass.SetOp", so we don't have to
abbreviate/obfuscate/disambiguate with ugly names like "CCCSetOp".

Also, PCRE lets you end in `&&`, but not Oniguruma as it's a set
operator. We probably want a rule similar to how you can end in `-`
and that's just the character. Perhaps we also have syntax options
in case we need a compatibilty mode (it's easy to add here and now)

 CustomCharClass -> Start Set (SetOp Set)* ']'
 Set             -> Member+
 Member          -> CustomCharClass | !']' !SetOp (Range | Atom)
 Range           -> Atom `-` Atom

Lexical analysis provides the following:

 Atom       -> `lexAtom`
 Trivia     -> `lexComment` | `lexNonSemanticWhitespace`
 Quote      -> `lexQuote`
 Quantifier -> `lexQuantifier`
 GroupStart -> `lexGroupStart`

 CustomCharacterClass.Start -> `lexCustomCCStart`
 CustomCharacterClass.SetOp -> `lexCustomCCBinOp`

*/

struct ParsingContext {
  /// Whether we're currently parsing in a custom character class.
  var isInCustomCharacterClass = false

  /// Tracks the number of group openings we've seen, to disambiguate the '\n'
  /// syntax as a backreference or an octal sequence.
  fileprivate var priorGroupCount = 0

  /// A set of used group names.
  fileprivate var usedGroupNames = Set<String>()

  fileprivate mutating func recordGroup(_ g: AST.Group.Kind) {
    // TODO: Needs to track group number resets (?|...).
    priorGroupCount += 1
    if let name = g.name {
      usedGroupNames.insert(name)
    }
  }

  private init() {}
  static var none: ParsingContext { .init() }

  /// Check whether a given reference refers to a prior group.
  func isPriorGroupRef(_ ref: AST.Reference.Kind) -> Bool {
    switch ref {
    case .absolute(let i):
      return i <= priorGroupCount
    case .relative(let i):
      return i < 0
    case .named(let str):
      return usedGroupNames.contains(str)
    }
  }
}

private struct Parser {
  var source: Source
  var context: ParsingContext = .none

  init(_ source: Source) {
    self.source = source
  }
}

// Diagnostics
extension Parser {
  mutating func report(
    _ str: String, _ function: String = #function, _ line: Int = #line
  ) throws -> Never {
    throw """
        ERROR: \(str)
        (error detected in parser at \(function):\(line))
        """
  }

  fileprivate func loc(
    _ start: Source.Position
  ) -> SourceLocation {
    SourceLocation(start ..< source.currentPosition)
  }
}

extension Parser {
  /// Parse a regular expression
  ///
  ///     Regex        -> GlobalMatchingOption* RecursiveRegex
  ///
  mutating func parse() throws -> AST {
    var opts = [AST.GlobalMatchingOption]()
    while let opt = try source.lexGlobalMatchingOption() {
      opts.append(opt)
    }
    let ast = try parseRecursive()
    if !opts.isEmpty {
      return .globalMatchingOptions(.init(ast, options: opts))
    }
    guard source.isEmpty else {
      if let loc = source.tryEatWithLoc(")") {
        throw Source.LocatedError(ParseError.unbalancedEndOfGroup, loc)
      }
      fatalError("Unhandled termination condition")
    }
    return ast
  }

  /// Parse a recursive regular expression. Unlike a top-level parse, this
  /// does not include matching directives that may only appear at the start.
  ///
  ///     RecursiveRegex        -> '' | Alternation
  ///     Alternation  -> Concatenation ('|' Concatenation)*
  ///
  mutating func parseRecursive() throws -> AST {
    let _start = source.currentPosition

    if source.isEmpty { return .empty(.init(loc(_start))) }

    var result = [try parseConcatenation()]
    var pipes: [SourceLocation] = []
    while true {
      let pipeStart = source.currentPosition
      guard source.tryEat("|") else { break }
      pipes.append(loc(pipeStart))
      result.append(try parseConcatenation())
    }

    if result.count == 1 {
      return result[0]
    }

    return .alternation(.init(result, pipes: pipes))
  }

  /// Parse a term, potentially separated from others by `|`
  ///
  ///     Concatenation   -> (!'|' !')' ConcatComponent)*
  ///     ConcatComponent -> Trivia | Quote | Quantification
  ///     Quantification  -> QuantOperand Quantifier?
  ///
  mutating func parseConcatenation() throws -> AST {
    var result = Array<AST>()
    let _start = source.currentPosition

    while true {
      // Check for termination, e.g. of recursion or bin ops
      if source.isEmpty { break }
      if source.peek() == "|" || source.peek() == ")" { break }

      // TODO: refactor loop body into function
      let _start = source.currentPosition

      //     Trivia -> `lexComment` | `lexNonSemanticWhitespace`
      if let triv = try source.lexComment() {
        result.append(.trivia(triv))
        continue
      }
      if let triv = try source.lexNonSemanticWhitespace() {
        result.append(.trivia(triv))
        continue
      }

      //     Quote      -> `lexQuote`
      if let quote = try source.lexQuote() {
        result.append(.quote(quote))
        continue
      }
      //     Quantification  -> QuantOperand Quantifier?
      if let operand = try parseQuantifierOperand() {
        if let (amt, kind) = try source.lexQuantifier() {
          let location = loc(_start)
          guard operand.isQuantifiable else {
            throw Source.LocatedError(ParseError.notQuantifiable, location)
          }
          result.append(.quantification(.init(amt, kind, operand, location)))
        } else {
          result.append(operand)
        }
        continue
      }

      fatalError("unreachable?")
    }
    guard !result.isEmpty else {
      return .empty(.init(loc(_start)))
    }
    if result.count == 1 {
      return result[0]
    }

    return .concatenation(.init(result, loc(_start)))
  }

  /// Perform a recursive parse for the branches of a conditional.
  mutating func parseConditionalBranches(
    start: Source.Position, _ cond: AST.Conditional.Condition
  ) throws -> AST {
    let child = try parseRecursive()
    let trueBranch: AST, falseBranch: AST, pipe: SourceLocation?
    switch child {
    case .alternation(let a):
      // If we have an alternation child, we only accept 2 branches.
      let numBranches = a.children.count
      guard numBranches == 2 else {
        // TODO: Better API for the parser to throw located errors.
        throw Source.LocatedError(
          ParseError.tooManyBranchesInConditional(numBranches), child.location
        )
      }
      trueBranch = a.children[0]
      falseBranch = a.children[1]
      pipe = a.pipes[0]
    default:
      // If there's no alternation, the child is assumed to be the true
      // branch, with the false branch matching anything.
      trueBranch = child
      falseBranch = .empty(.init(loc(source.currentPosition)))
      pipe = nil
    }
    try source.expect(")")
    return .conditional(.init(
      cond, trueBranch: trueBranch, pipe: pipe, falseBranch: falseBranch,
      loc(start)))
  }

  /// Perform a recursive parse for the body of a group.
  mutating func parseGroupBody(
    start: Source.Position, _ kind: AST.Located<AST.Group.Kind>
  ) throws -> AST.Group {
    context.recordGroup(kind.value)

    let child = try parseRecursive()
    // An implicit scoped group has already consumed its closing paren.
    if !kind.value.hasImplicitScope {
      try source.expect(")")
    }
    return .init(kind, child, loc(start))
  }

  /// Consume the body of an absent function.
  ///
  ///     AbsentFunction -> '(?~' RecursiveRegex ')'
  ///                     | '(?~|' Concatenation '|' Concatenation ')'
  ///                     | '(?~|' Concatenation ')'
  ///                     | '(?~|)'
  ///
  mutating func parseAbsentFunctionBody(
    _ start: AST.Located<AST.AbsentFunction.Start>
  ) throws -> AST.AbsentFunction {
    let startLoc = start.location

    // TODO: Diagnose on nested absent functions, which Oniguruma states is
    // undefined behavior.
    let kind: AST.AbsentFunction.Kind
    switch start.value {
    case .withoutPipe:
      // Must be a repeater.
      kind = .repeater(try parseRecursive())
    case .withPipe where source.peek() == ")":
      kind = .clearer
    case .withPipe:
      // Can either be an expression or stopper depending on whether we have a
      // any additional '|'s.
      let child = try parseRecursive()
      switch child {
      case .alternation(let alt):
        // A pipe, so an expression.
        let numChildren = alt.children.count
        guard numChildren == 2 else {
          throw Source.LocatedError(
            ParseError.tooManyAbsentExpressionChildren(numChildren),
            child.location
          )
        }
        kind = .expression(
          absentee: alt.children[0], pipe: alt.pipes[0], expr: alt.children[1])
      default:
        // No pipes, so a stopper.
        kind = .stopper(child)
      }
    }
    try source.expect(")")
    return .init(kind, start: startLoc, location: loc(startLoc.start))
  }

  /// Parse a (potentially quantified) component
  ///
  ///     QuantOperand     -> Conditional | Group | CustomCharClass | Atom
  ///                       | AbsentFunction
  ///     Group            -> GroupStart RecursiveRegex ')'
  ///     Conditional      -> ConditionalStart Concatenation ('|' Concatenation)? ')'
  ///     ConditionalStart -> KnownConditionalStart | GroupConditionalStart
  ///
  mutating func parseQuantifierOperand() throws -> AST? {
    assert(!source.isEmpty)

    let _start = source.currentPosition

    // Check if we have the start of a conditional '(?(cond)', which can either
    // be a known condition, or an arbitrary group condition.
    if let cond = try source.lexKnownConditionalStart(context: context) {
      return try parseConditionalBranches(start: _start, cond)
    }
    if let kind = try source.lexGroupConditionalStart() {
      let groupStart = kind.location.start
      let group = try parseGroupBody(start: groupStart, kind)
      return try parseConditionalBranches(
        start: _start, .init(.group(group), group.location))
    }

    // Check if we have an Oniguruma absent function.
    if let start = source.lexAbsentFunctionStart() {
      return .absentFunction(try parseAbsentFunctionBody(start))
    }

    // Check if we have the start of a group '('.
    if let kind = try source.lexGroupStart() {
      return .group(try parseGroupBody(start: _start, kind))
    }

    // Check if we have the start of a custom character class '['.
    if let cccStart = try source.lexCustomCCStart() {
      return .customCharacterClass(
        try parseCustomCharacterClass(cccStart))
    }

    if let atom = try source.lexAtom(context: context) {
      // TODO: track source locations
      return .atom(atom)
    }

    return nil
  }
}

// MARK: - Custom character classes

/// `AST.CustomCharacterClass.Start` is a mouthful
internal typealias CustomCC = AST.CustomCharacterClass

extension Parser {
  /// Parse a custom character class
  ///
  ///     CustomCharClass -> Start Set (SetOp Set)* ']'
  ///     Set             -> Member+
  ///     Member          -> CustomCharClass | !']' !SetOp (Range | Atom)
  ///     Range           -> Atom `-` Atom
  ///
  mutating func parseCustomCharacterClass(
    _ start: Source.Located<CustomCC.Start>
  ) throws -> CustomCC {
    let alreadyInCCC = context.isInCustomCharacterClass
    context.isInCustomCharacterClass = true
    defer { context.isInCustomCharacterClass = alreadyInCCC }

    typealias Member = CustomCC.Member
    try source.expectNonEmpty()

    var members: Array<Member> = []
    try parseCCCMembers(into: &members)

    // If we have a binary set operator, parse it and the next members. Note
    // that this means we left associate for a chain of operators.
    // TODO: We may want to diagnose and require users to disambiguate, at least
    // for chains of separate operators.
    // TODO: What about precedence?
    while let binOp = try source.lexCustomCCBinOp() {
      var rhs: Array<Member> = []
      try parseCCCMembers(into: &rhs)

      if members.isEmpty || rhs.isEmpty {
        throw ParseError.expectedCustomCharacterClassMembers
      }

      // If we're done, bail early
      let setOp = Member.setOperation(members, binOp, rhs)
      if source.tryEat("]") {
        return CustomCC(
          start, [setOp], loc(start.location.start))
      }

      // Otherwise it's just another member to accumulate
      members = [setOp]
    }
    if members.isEmpty {
      throw ParseError.expectedCustomCharacterClassMembers
    }
    try source.expect("]")
    return CustomCC(start, members, loc(start.location.start))
  }

  mutating func parseCCCMembers(
    into members: inout Array<CustomCC.Member>
  ) throws {
    // Parse members until we see the end of the custom char class or an
    // operator.
    while source.peek() != "]" && source.peekCCBinOp() == nil {

      // Nested custom character class.
      if let cccStart = try source.lexCustomCCStart() {
        members.append(.custom(try parseCustomCharacterClass(cccStart)))
        continue
      }

      // Quoted sequence.
      if let quote = try source.lexQuote() {
        members.append(.quote(quote))
        continue
      }

      guard let atom = try source.lexAtom(context: context) else { break }

      // Range between atoms.
      if let (dashLoc, rhs) =
          try source.lexCustomCharClassRangeEnd(context: context) {
        guard atom.literalCharacterValue != nil &&
              rhs.literalCharacterValue != nil else {
          throw ParseError.invalidCharacterClassRangeOperand
        }
        members.append(.range(.init(atom, dashLoc, rhs)))
        continue
      }

      members.append(.atom(atom))
      continue
    }
  }
}

public func parse<S: StringProtocol>(
  _ regex: S, _ syntax: SyntaxOptions
) throws -> AST where S.SubSequence == Substring
{
  let source = Source(String(regex), syntax)
  var parser = Parser(source)
  return try parser.parse()
}

/// Parse a given regex string with delimiters, inferring the syntax options
/// from the delimiter used.
public func parseWithDelimiters<S: StringProtocol>(
  _ regex: S
) throws -> AST where S.SubSequence == Substring {
  let (contents, delim) = droppingRegexDelimiters(String(regex))
  return try parse(contents, delim.defaultSyntaxOptions)
}

extension String: Error {}
