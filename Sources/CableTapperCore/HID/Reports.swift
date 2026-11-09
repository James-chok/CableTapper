import Foundation

enum ReportID: UInt8 {
    case mouse = 1
    case keyboard = 2
    case keyboardLEDs = 3
    case battery = 4
    case systemControl = 5
    case consumerControl = 6
}

public struct MouseReport: Sendable, Equatable {
    public var buttons: MouseButtons = []
    public var dX: Int8 = 0
    public var dY: Int8 = 0
    public var wheel: Int8 = 0

    public init(buttons: MouseButtons = [], dX: Int8 = 0, dY: Int8 = 0, wheel: Int8 = 0) {
        self.buttons = buttons
        self.dX = dX
        self.dY = dY
        self.wheel = wheel
    }

    public static let zero = MouseReport()

    public var data: Data {
        Data([
            buttons.rawValue,
            UInt8(bitPattern: dX),
            UInt8(bitPattern: dY),
            UInt8(bitPattern: wheel),
        ])
    }
}

public struct MouseButtons: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let left = MouseButtons(rawValue: 1 << 0)
    public static let right = MouseButtons(rawValue: 1 << 1)
    public static let middle = MouseButtons(rawValue: 1 << 2)
}

public struct KeyboardReport: Sendable, Equatable {
    public var modifiers: KeyboardModifiers = []
    public var keys: [Keycode] = []

    public init(modifiers: KeyboardModifiers = [], keys: [Keycode] = []) {
        self.modifiers = modifiers
        self.keys = keys
    }

    public static let zero = KeyboardReport()

    public var data: Data {
        var bytes = [UInt8](repeating: 0, count: 8)
        bytes[0] = modifiers.rawValue
        for (i, key) in keys.prefix(6).enumerated() {
            bytes[2 + i] = key.rawValue
        }
        return Data(bytes)
    }
}

public struct KeyboardModifiers: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let leftCtrl = KeyboardModifiers(rawValue: 1 << 0)
    public static let leftShift = KeyboardModifiers(rawValue: 1 << 1)
    public static let leftAlt = KeyboardModifiers(rawValue: 1 << 2)
    public static let leftGUI = KeyboardModifiers(rawValue: 1 << 3)
    public static let rightCtrl = KeyboardModifiers(rawValue: 1 << 4)
    public static let rightShift = KeyboardModifiers(rawValue: 1 << 5)
    public static let rightAlt = KeyboardModifiers(rawValue: 1 << 6)
    public static let rightGUI = KeyboardModifiers(rawValue: 1 << 7)
}

public struct KeyboardLEDs: OptionSet, Sendable, Equatable {
    public let rawValue: UInt8
    public static let numLock = KeyboardLEDs(rawValue: 1 << 0)
    public static let capsLock = KeyboardLEDs(rawValue: 1 << 1)
    public static let scrollLock = KeyboardLEDs(rawValue: 1 << 2)

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public init(byte: UInt8) {
        rawValue = byte & 0x1F
    }
}

public enum Keycode: UInt8, Sendable, Equatable, Hashable {
    case a = 0x04, b, c, d, e, f, g, h, i, j, k, l, m
    case n, o, p, q, r, s, t, u, v, w, x, y, z
    case digit1 = 0x1E, digit2, digit3, digit4, digit5, digit6, digit7, digit8, digit9, digit0
    case `return` = 0x28
    case escape = 0x29
    case backspace = 0x2A
    case tab = 0x2B
    case space = 0x2C
    case minus = 0x2D
    case equal = 0x2E
    case leftBracket = 0x2F
    case rightBracket = 0x30
    case backslash = 0x31
    case semicolon = 0x33
    case quote = 0x34
    case grave = 0x35
    case comma = 0x36
    case period = 0x37
    case slash = 0x38
    case capsLock = 0x39
    case f1 = 0x3A, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
    case rightArrow = 0x4F
    case leftArrow = 0x50
    case downArrow = 0x51
    case upArrow = 0x52
}

struct SystemControlReport: Sendable, Equatable {
    var actions: UInt8 = 0
    static let zero = SystemControlReport()
    var data: Data { Data([actions]) }
}

public struct ConsumerReport: Sendable, Equatable {
    public var key: ConsumerKey = .none
    public var acUsageA: UInt8 = 0
    public var acUsageB: UInt8 = 0
    public var sub: UInt8 = 0

    public init(key: ConsumerKey = .none, acUsageA: UInt8 = 0, acUsageB: UInt8 = 0, sub: UInt8 = 0) {
        self.key = key
        self.acUsageA = acUsageA
        self.acUsageB = acUsageB
        self.sub = sub
    }

    public static let zero = ConsumerReport()
    public static let acHome = ConsumerReport(acUsageB: 0x23)
    public static let acBack = ConsumerReport(acUsageB: 0x24)

    public var data: Data {
        let raw = key.rawValue
        return Data([
            UInt8(raw & 0xFF),
            UInt8(raw >> 8),
            acUsageA,
            acUsageB,
            sub,
        ])
    }
}

public enum ConsumerKey: UInt16, Sendable, Equatable {
    case none = 0x0000
    case playPause = 0x00CD
    case scanNext = 0x00B5
    case scanPrev = 0x00B6
    case mute = 0x00E2
    case volumeUp = 0x00E9
    case volumeDown = 0x00EA
}

enum ASCIIKeymap {
    static func map(_ character: Character) -> (Keycode, KeyboardModifiers)? {
        if let a = character.asciiValue {
            if a >= 0x61, a <= 0x7A, let key = Keycode(rawValue: 0x04 + (a - 0x61)) {
                return (key, [])
            }
            if a >= 0x41, a <= 0x5A, let key = Keycode(rawValue: 0x04 + (a - 0x41)) {
                return (key, .leftShift)
            }
        }
        return symbolKeys[character]
    }

    private static let shift: KeyboardModifiers = .leftShift
    private static let symbolKeys: [Character: (Keycode, KeyboardModifiers)] = [
        "1": (.digit1, []), "2": (.digit2, []), "3": (.digit3, []), "4": (.digit4, []), "5": (.digit5, []),
        "6": (.digit6, []), "7": (.digit7, []), "8": (.digit8, []), "9": (.digit9, []), "0": (.digit0, []),
        "!": (.digit1, shift), "@": (.digit2, shift), "#": (.digit3, shift), "$": (.digit4, shift), "%": (.digit5, shift),
        "^": (.digit6, shift), "&": (.digit7, shift), "*": (.digit8, shift), "(": (.digit9, shift), ")": (.digit0, shift),
        " ": (.space, []), "\n": (.return, []), "\r": (.return, []), "\t": (.tab, []),
        "-": (.minus, []), "_": (.minus, shift), "=": (.equal, []), "+": (.equal, shift),
        "[": (.leftBracket, []), "{": (.leftBracket, shift), "]": (.rightBracket, []), "}": (.rightBracket, shift),
        "\\": (.backslash, []), "|": (.backslash, shift), ";": (.semicolon, []), ":": (.semicolon, shift),
        "'": (.quote, []), "\"": (.quote, shift), "`": (.grave, []), "~": (.grave, shift),
        ",": (.comma, []), "<": (.comma, shift), ".": (.period, []), ">": (.period, shift),
        "/": (.slash, []), "?": (.slash, shift),
    ]
}
