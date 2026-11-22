import MtProtoKit
import SwiftSignalKit
import EncryptionProvider

public protocol CloudDataContext {
    func get(phoneNumber: Signal<String?, NoError>) -> Signal<MTBackupDatacenterData, NoError>
}

@available(iOS 10.0, *)
public final class CloudDataContextImpl: CloudDataContext {
    public init(encryptionProvider: EncryptionProvider) {
    }

    public func get(phoneNumber: Signal<String?, NoError>) -> Signal<MTBackupDatacenterData, NoError> {
        return .complete()
    }
}
