

// MARK: - JSON.Parser

extension JSON {
  
  public struct Parser {
    
    public struct Option: OptionSetType {
      public init(rawValue: UInt8) { self.rawValue = rawValue }
      public let rawValue: UInt8
      
      /// Do not remove null values from the resulting JSON value. Instead store `JSON.null`
      public static let noSkipNull = Option(rawValue: 1 << 1)
    }
    
    let skipNull: Bool
    var pointer: UnsafeMutablePointer<UTF8.CodeUnit>
    var bufferPointer: UnsafeMutableBufferPointer<UTF8.CodeUnit>
    
    var stringBuffer: [UTF8.CodeUnit] = []
  }
}


// MARK: - Initializers

extension JSON.Parser {
  
  // assumes data is null terminated.
  // and that the buffer will not be de-allocated before completion (handled by JSON.Parser.parse(_:,options:)
  internal init(bufferPointer: UnsafeMutableBufferPointer<UTF8.CodeUnit>, options: [Option]) {
    
    self.bufferPointer = bufferPointer
    self.pointer = bufferPointer.baseAddress
    self.skipNull = !options.contains(.noSkipNull)
    
    self.skipWhitespace()
  }
}


// MARK: - Public API

extension JSON.Parser {
  
  public static func parse(inout data: [UTF8.CodeUnit], options: [Option] = []) throws -> JSON {
    
    data.append(0)
    
    return try data.withUnsafeMutableBufferPointer { bufferPointer in
      var parser = self.init(bufferPointer: bufferPointer, options: options)
      return try parser.parseValue()
    }
  }
  
  public static func parse(data: [UTF8.CodeUnit], options: [Option] = []) throws -> JSON {
    
    var data = data
    data.append(0)
    
    return try data.withUnsafeMutableBufferPointer { bufferPointer in
      var parser = JSON.Parser(bufferPointer: bufferPointer, options: options)
      return try parser.parseValue()
    }
  }
  
  public static func parse(string: String, options: [Option] = []) throws -> JSON {
    
    var data = string.nulTerminatedUTF8
    
    return try data.withUnsafeMutableBufferPointer { bufferPointer in
      var parser = JSON.Parser(bufferPointer: bufferPointer, options: options)
      return try parser.parseValue()
    }
  }
  
}


extension JSON.Parser {
  
  // TODO: Make this work, or DEPRECATE it.
  // Screw handling errors (that requires a parser instance, we plan on reiterating the parser anyway)
  // instead we should have a validate function, which validates that JSON follows the correct form.
  private mutating func handleError(error: ErrorType) throws {
    guard let code = error as? ErrorCode else {
      throw error
    }
    
    let offset = pointer.distanceTo(bufferPointer.baseAddress)
    print("Parsed up to: \n\(bufferPointer[0..<offset].map({ String($0) }).joinWithSeparator(""))")
    var line: UInt = 0
    var char: UInt = 0
    for ch in bufferPointer.prefix(offset) {
      switch ch {
      case newline:
        
        line += 1
        char  = 0
        
      default:
        char += 1
      }
    }
    
    throw Error(char: char, line: line, code: code)
  }
}


// MARK: - Internals

extension JSON.Parser {
  
  func peek() -> UTF8.CodeUnit {
    return pointer.memory
  }
  
  mutating func pop() throws -> UTF8.CodeUnit {
    guard pointer.memory != 0 else { throw ErrorCode.endOfStream }
    defer { pointer = pointer.advancedBy(1) }
    return pointer.memory
  }
  
  /// Skips null pointer check. Use should occur only after checking the result of peek()
  mutating func unsafePop() -> UTF8.CodeUnit {
    defer { pointer = pointer.advancedBy(1) }
    return pointer.memory
  }
}

extension JSON.Parser {
  
  mutating func skipWhitespace() {
    repeat {
      switch peek() {
      case space, tab, cr, newline: unsafePop()
      default: return
      }
    } while true
  }
}

extension JSON.Parser {
  
  /**
   - precondition: `pointer` is at the beginning of a literal
   - postcondition: `pointer` will be in the next non-`whiteSpace` position
   */
  mutating func parseValue() throws -> JSON {
    
    assert(![space, tab, cr, newline, 0].contains(pointer.memory))
    
    defer { skipWhitespace() }
    switch peek() {
    case objectOpen:
      
      let o = try parseObject()
      return o
      
    case arrayOpen:
      
      let a = try parseArray()
      return a
      
    case quote:
      
      let s = try parseString()
      return .string(s)
      
    case minus, numbers:
      
      let num = try parseNumber()
      return num
      
    case f:
      
      unsafePop()
      try assertFollowedBy(alse)
      return .bool(false)
      
    case t:
      
      unsafePop()
      try assertFollowedBy(rue)
      return .bool(true)
      
    case n:
      
      unsafePop()
      try assertFollowedBy(ull)
      return .null
      
    default:
      // NOTE: This could occur if we failed to skipWhitespace somewhere
      throw ErrorCode.invalidSyntax
    }
  }
  
  mutating func parseArray() throws -> JSON {
    
    assert(peek() == arrayOpen)
    unsafePop()
    
    skipWhitespace()
    
    guard peek() != arrayClose else {
      unsafePop()
      return .array([])
    }
    
    var tempArray: [JSON] = []
    tempArray.reserveCapacity(6)
    
    repeat {
      
      switch peek() {
      case comma:
        
        unsafePop()
        skipWhitespace()
        
      case arrayClose:
        
        unsafePop()
        return .array(tempArray)
        
      default:
        let value = try parseValue()
        switch value {
        case .null where skipNull: break
        default: tempArray.append(value)
        }
      }
    } while true
  }
  
  mutating func parseObject() throws -> JSON {
    
    assert(peek() == objectOpen)
    unsafePop()
    
    skipWhitespace()
    
    guard peek() != objectClose else {
      unsafePop()
      return .object([])
    }
    
    var tempDict: [(String, JSON)] = []
    tempDict.reserveCapacity(6)
    
    repeat {
      switch peek() {
      case quote:
        
        let key = try parseString()
        try skipColon()
        let value = try parseValue()
        
        switch value {
        case .null where skipNull: break
          
        default: tempDict.append( (key, value) )
        }
        
      case comma:
        
        unsafePop()
        skipWhitespace()
        
      case objectClose:
        
        unsafePop()
        return .object(tempDict)
        
      default:
        throw ErrorCode.invalidSyntax
      }
    } while true
  }
  
  mutating func assertFollowedBy(chars: [UTF8.CodeUnit]) throws {
    
    for scalar in chars {
      guard try scalar == pop() else { throw ErrorCode.invalidLiteral }
    }
  }
  
  mutating func parseNumber() throws -> JSON {
    
    assert(numbers ~= peek() || minus == peek())
    
    var seenExponent = false
    var seenDecimal = false
    
    let negative: Bool = {
      guard minus == peek() else { return false }
      unsafePop()
      return true
    }()
    
    var significand: UInt64 = 0
    var mantisa: UInt64 = 0
    var divisor: Double = 10
    var exponent: UInt64 = 0
    var negativeExponent = false
    var overflow: Bool
    
    repeat {
      switch peek() {
      case numbers where !seenExponent && !seenDecimal:
        
        (significand, overflow) = UInt64.multiplyWithOverflow(significand, 10)
        guard !overflow else { throw JSON.Parser.ErrorCode.numberOverflow }
        
        (significand, overflow) = UInt64.addWithOverflow(significand, UInt64(unsafePop() - zero))
        guard !overflow else { throw JSON.Parser.ErrorCode.numberOverflow }
        
      case numbers where seenDecimal && !seenExponent: // decimals must come before exponents
        
        divisor *= 10
        
        (mantisa, overflow) = UInt64.multiplyWithOverflow(mantisa, 10)
        guard !overflow else { throw JSON.Parser.ErrorCode.numberOverflow }
        
        (mantisa, overflow) = UInt64.addWithOverflow(mantisa, UInt64(unsafePop() - zero))
        guard !overflow else { throw JSON.Parser.ErrorCode.numberOverflow }
        
      case numbers where seenExponent:
        
        (exponent, overflow) = UInt64.multiplyWithOverflow(exponent, 10)
        guard !overflow else { throw JSON.Parser.ErrorCode.numberOverflow }
        
        (exponent, overflow) = UInt64.addWithOverflow(exponent, UInt64(unsafePop() - zero))
        guard !overflow else { throw JSON.Parser.ErrorCode.numberOverflow }
        
      case decimal where !seenExponent && !seenDecimal:
        
        unsafePop() // remove the decimal
        seenDecimal = true
        
      case E, e where !seenExponent:
        
        unsafePop() // remove the 'e' || 'E'
        seenExponent = true
        if peek() == minus {
          negativeExponent = true
          unsafePop() // remove the '-'
        }
        
      // is end of number
      case arrayClose, objectClose, comma, space, tab, cr, newline, 0:
        
        switch (seenDecimal, seenExponent) {
        case (false, false):
          
          if negative && significand == UInt64(Int64.max) + 1 {
            return .integer(Int64.min)
          } else if significand > UInt64(Int64.max) {
            throw JSON.Parser.ErrorCode.numberOverflow
          }
          
          return .integer(negative ? -Int64(significand) : Int64(significand))
          
        case (true, false):
          
          let n = Double(significand) + Double(mantisa) / (divisor / 10)
          return .double(negative ? -n : n)
          
        case (false, true):
          
          let n = Double(significand)
            .power(10, exponent: exponent, isNegative: negativeExponent)
          
          return .double(negative ? -n : n)
          
        case (true, true):
          
          let n = (Double(significand) + Double(mantisa) / (divisor / 10))
            .power(10, exponent: exponent, isNegative: negativeExponent)
          
          return .double(negative ? -n : n)
          
        }
        
      default: throw JSON.Parser.ErrorCode.invalidNumber
      }
    } while true
  }
  
  // TODO (vdka): refactor
  // TODO (vdka): option to _repair_ Unicode
  mutating func parseString() throws -> String {
    
    assert(peek() == quote)
    unsafePop()
    
    var escaped = false
    stringBuffer.removeAll(keepCapacity: true)
    
    repeat {
      
      let codeUnit = try pop()
      if codeUnit == backslash && !escaped {
        
        escaped = true
      } else if codeUnit == quote && !escaped {
        
        stringBuffer.append(0)
        guard let string = stringBuffer.withUnsafeBufferPointer({ bufferPointer in
          return String.fromCString(unsafeBitCast(bufferPointer.baseAddress, UnsafePointer<CChar>.self))
        }) else { throw ErrorCode.invalidUnicode }
        
        return string
      } else if escaped {
        
        switch codeUnit {
        case r:
          stringBuffer.append(cr)
          
        case t:
          stringBuffer.append(tab)
          
        case n:
          stringBuffer.append(newline)
          
        case b:
          stringBuffer.append(backspace)
          
        case quote:
          stringBuffer.append(quote)
          
        case slash:
          stringBuffer.append(slash)
          
        case backslash:
          stringBuffer.append(backslash)
          
        case u:
          let codeUnit = try parseFourHex()
          let scalar = UnicodeScalar(codeUnit)
          var bytes: [UTF8.CodeUnit] = []
          UTF8.encode(scalar, output: { bytes.append($0) })
          stringBuffer.appendContentsOf(bytes)
          
        default:
          throw ErrorCode.invalidEscape
        }
        
        escaped = false
        
      } else {
        
        stringBuffer.append(codeUnit)
      }
    } while true
  }
}

extension JSON.Parser {
  
  private mutating func parseFourHex() throws -> UInt32 {
    var codeUnit: UInt32 = 0
    for _ in 0..<4 {
      let c = try pop()
      codeUnit <<= 4
      switch c {
      case numbers:
        codeUnit += UInt32(c - 48)
      case alphaNumericLower:
        codeUnit += UInt32(c - 87)
      case alphaNumericUpper:
        codeUnit += UInt32(c - 55)
      default:
        throw ErrorCode.invalidEscape
      }
    }
    return codeUnit
  }
  
  mutating func skipColon() throws {
    skipWhitespace()
    guard case colon = try pop() else {
      throw ErrorCode.missingColon
    }
    skipWhitespace()
  }
}

extension JSON.Parser {
  
  public struct Error: ErrorType {
    let char: UInt
    let line: UInt
    let code: ErrorCode
  }
  
  public enum ErrorCode: String, ErrorType {
    case missingColon
    case trailingComma
    case expectedColon
    case invalidSyntax
    case invalidNumber
    case loneLeading
    case numberOverflow
    case invalidLiteral
    case invalidUnicode
    case invalidEscape
    case endOfStream
  }
}

extension JSON.Parser.Error: CustomStringConvertible {
  
  public var description: String {
    return "\(code) @ ln: \(line), col: \(char)"
  }
}

extension Double {
  
  internal func power<I: UnsignedIntegerType>(base: Double, exponent: I, isNegative: Bool) -> Double {
    var a: Double = self
    if isNegative {
      for _ in 0..<exponent { a /= base }
    } else {
      for _ in 0..<exponent { a *= base }
    }
    return a
  }
}
