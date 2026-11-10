import CoreBluetooth

extension CBManagerState {
    public var description: String {
        switch self {
        case .unknown:
            "Unknown"
        case .resetting:
            "Resetting"
        case .unsupported:
            "Unsupported"
        case .unauthorized:
            "Unauthorized"
        case .poweredOff:
            "PoweredOff"
        case .poweredOn:
            "PoweredOn"
        @unknown default:
            "Unknown(\(rawValue))"
        }
    }
}
