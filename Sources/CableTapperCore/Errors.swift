import Foundation

public enum CableTapperError: Error, LocalizedError, Sendable {
    case bluetoothNotConnected
    case screenUnavailable(String)
    case unsupportedCharacters(String)
    case textNotFound(String)
    case invalidArgument(String)
    case notSettled
    case internalError(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothNotConnected:
            return "Not connected to the iPhone over Bluetooth Classic HID. Run `cabletapper pair`, enable AssistiveTouch, and tap this Mac's name in Settings › Bluetooth."
        case .screenUnavailable(let detail):
            return "No screen frame available (\(detail)). Plug in USB, unlock the iPhone, and Trust this Mac."
        case .unsupportedCharacters(let chars):
            return "Unsupported characters for US keyboard HID: \(chars)"
        case .textNotFound(let query):
            return "Text not found on screen: \(query)"
        case .invalidArgument(let detail):
            return "Invalid argument: \(detail)"
        case .notSettled:
            return "Screen still moving"
        case .internalError(let detail):
            return detail
        }
    }
}
