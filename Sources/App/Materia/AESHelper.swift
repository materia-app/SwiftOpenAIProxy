//
//  AESHelper.swift
//  AIAssistantPoC
//
//  Created by Andrew Petrus on 03.03.24.
//

import Foundation
//#if os(macOS)
//import CommonCrypto
//#else
import Crypto
//#endif
//import CryptoKit

class AESHelper {
    private static let symmetricKeyString = "nIMf7UcJ0xZ89ePLPS97VPMFA2WhTcM/V8sh8Ylv/14="
    private static var cryptor: AESCryptor?
    
    static func generateRandomAESKeyString() -> String {
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data(Array($0)) }
        let keyBase64String = keyData.base64EncodedString()
        return keyBase64String
    }
    
    static func encrypt(_ message: Data) -> Data {
        if cryptor == nil {
            cryptor = AESCryptor(keyBase64String: symmetricKeyString)
        }
        return cryptor?.encrypt(message) ?? Data()
    }
    
    static func decrypt(_ message: Data) -> Data {
        if cryptor == nil {
            cryptor = AESCryptor(keyBase64String: symmetricKeyString)
        }
        return cryptor?.decrypt(message) ?? Data()
    }
}

private class AESCryptor {
    private var key: SymmetricKey?
    
    init(keyBase64String: String) {
        if let keyData = Data(base64Encoded: keyBase64String) {
            key = SymmetricKey(data: keyData)
        }
    }
    
    func encrypt(_ message: Data) -> Data {
        guard let key else { return Data() }
        do {
            let sealedBox = try AES.GCM.seal(message, using: key)
            return sealedBox.combined ?? Data()
        } catch {
            print("Encryption error: \(error)")
            return Data()
        }
    }
    
    func decrypt(_ message: Data) -> Data {
        guard let key else { return Data() }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: message) else { return Data() }
        
        do {
            let decryptedData = try AES.GCM.open(sealedBox, using: key)
            return decryptedData
        } catch {
            print("Decryption error: \(error)")
            return Data()
        }
    }
}
