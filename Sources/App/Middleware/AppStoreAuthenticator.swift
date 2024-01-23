//
//  File.swift
//  
//
//  Created by Ronald Mannak on 1/21/24.
//

import Foundation
import FluentKit
import Hummingbird
import HummingbirdAuth
import AppStoreServerLibrary
#if os(Linux)
import FoundationNetworking
#endif

struct AppStoreAuthenticator: HBAsyncAuthenticator {
    
    let iapKey: String
    let iapIssuerId: String
    let iapKeyId: String
    let bundleId: String
    let appAppleId: Int64
    
    init() throws {
        // Fetch IAP private key, issuer ID and Key ID
        // To create a private key, see:
        //    https://developer.apple.com/documentation/appstoreserverapi/creating_api_keys_to_use_with_the_app_store_server_api
        //    and https://developer.apple.com/wwdc23/10143
        guard let iapKey = HBEnvironment().get("IAPPrivateKey")?.replacingOccurrences(of: "\\\\n", with: "\n"),
              !iapKey.isEmpty,
              let iapIssuerId = HBEnvironment().get("IAPIssuerId"),
              !iapIssuerId.isEmpty,
              let iapKeyId = HBEnvironment().get("IAPKeyId"),
              !iapKeyId.isEmpty,
              let bundleId = HBEnvironment().get("appBundleId"),
              !bundleId.isEmpty,
              let appAppleIdString = HBEnvironment().get("appAppleId"),
              let appAppleId = Int64(appAppleIdString)
        else {
            throw HBHTTPError(.internalServerError, message: "IAPPrivateKey, IAPIssuerId, IAPKeyId and/or appBundleId, appAppleId environment variable(s) not set")
        }
        self.iapKey = iapKey
        self.iapIssuerId = iapIssuerId
        self.iapKeyId = iapKeyId
        self.bundleId = bundleId
        self.appAppleId = appAppleId
    }
    
    func authenticate(request: HBRequest) async throws -> User? {
        
        // 1. The server expects an app store receipt
        //    (in the iOS and macOS client app: Bundle.main.appStoreReceiptURL)
        //    However, the receipt is not available when testing in Xcode Sandbox,
        //    so the server accepts a transaction Id in sandbox mode as well
        guard let buffer = request.body.buffer, let body = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) else {
            request.logger.error("/appstore invoked without app store receipt or transaction id in body")
            throw HBHTTPError(.badRequest)
        }
        
        // 2. Extract transactionId from receipt
        let transactionId: String
        if let transaction = ReceiptUtility.extractTransactionId(transactionReceipt: body) {
            transactionId = transaction
        } else {
            // in case the body can't be parsed, the body might be a transaction Id
            // (when the client app is a local Xcode build)
            transactionId = body
        }
                
        // 3. Validate the transaction Id in production first.
        //    If that fails, try sandbox
        do {
            return try await validate(request, transactionId: transactionId, environment: .production)
        } catch let error as HBHTTPError where error.status == .notFound {
            return try await validate(request, transactionId: transactionId, environment: .sandbox)
        }
    }
    
    private func validate(_ request: HBRequest, transactionId: String, environment: Environment) async throws -> User? {
        
        // 1. Create App Store API client
        let appStoreClient = try AppStoreServerAPIClient(signingKey: iapKey, keyId: iapKeyId, issuerId: iapIssuerId, bundleId: bundleId, environment: environment)
        
        // 2. Set up verifier to decode and verify JWT encoded data
        let rootCertificates = try loadAppleRootCertificates(request: request)
        let verifier = try SignedDataVerifier(rootCertificates: rootCertificates, bundleId: bundleId, appAppleId: appAppleId, environment: environment, enableOnlineChecks: true)
        
        // 3. Set up variables needed to create user
        let user = User(appAccountId: nil, environment: environment.rawValue, productId: "", status: .expired)
        var signedTransactionInfo: String?
        var signedRenewalInfo: String?
        
        // 4. Use transactionId to fetch active subscriptions from App Store
        let allSubs = await appStoreClient.getAllSubscriptionStatuses(transactionId: transactionId, status: [.active, .billingGracePeriod])
        switch allSubs {
        case .success(let response):
            
            // Loop through the subscription groups
            response.data?.forEach { item in
                // Loop through the transactions in each group
                item.lastTransactions?.forEach { transaction in
                    // We're only saving one subscription, an active one if available.
                    // Update user.status. Make sure we don't overwrite it if the status is already .active
                    if user.status != Status.active.rawValue, let status = transaction.status {
                        user.status = status.rawValue
                    }
                    // Assuming the transactions are in ascending order, we're storing the most recent
                    // infos. This should fetch the appAccountId even if previous transactions didn't ahve
                    // an appAccountId set
                    signedTransactionInfo = transaction.signedTransactionInfo
                    signedRenewalInfo = transaction.signedRenewalInfo
                }
            }
        case .failure(let statusCode, let rawApiError, let apiError, let errorMessage, let causedBy):
            if statusCode == 404 && environment == .production {
                // No transaction wasn't found. Try sandbox
                throw HBHTTPError(.notFound)
            } else {
                // Other error occured
                request.logger.error("get all subscriptions failed. Error: \(statusCode ?? -1): \(errorMessage ?? "Unknown error"), \(String(describing: rawApiError)) \(String(describing: apiError)), \(String(describing: causedBy))")
                throw HBHTTPError(HTTPResponseStatus(statusCode: statusCode ?? 500, reasonPhrase: errorMessage ?? "Unknown error"))
            }
        }
        
        // 5. Parse signed transaction
        if let signedTransaction = signedTransactionInfo {
            let verifyResponse = await verifier.verifyAndDecodeTransaction(signedTransaction: signedTransaction)
            
            switch verifyResponse {
            case .valid(let payload):
                // Fetches app account token set by client app.
                // Note: Token is nil when client app doesn't set appAccountToken during the purchase
                // See https://developer.apple.com/documentation/storekit/product/3791971-purchase
                user.appAccountId = payload.appAccountToken
                if let productId = payload.productId {
                    user.productId = productId
                }
            case .invalid(let error):
                request.logger.error("Verifying transaction failed. Error: \(error)")
                throw HBHTTPError(.unauthorized)
            }
        }
        
        // 6. Parse renewal info
        if let signedRenewalInfo = signedRenewalInfo {
            let verifyResponse = await verifier.verifyAndDecodeRenewalInfo(signedRenewalInfo: signedRenewalInfo)
            
            switch verifyResponse {
            case .valid(let payload):
                if let productId = payload.productId {
                    user.productId = productId
                }
            case .invalid(let error):
                request.logger.error("Verifying transaction failed. Error: \(error)")
                throw HBHTTPError(.unauthorized)
            }
        }
        
        // 7. return user
        return user
    }
    
    private func loadAppleRootCertificates(request: HBRequest) throws -> [Foundation.Data] {
        #if os(Linux)
        // Linux doesn't have app bundles, so we're copying the certificates in the Dockerfile to /app/Resources and load them manually
        return [
            try loadData(url: URL(string: "/app/Resources/AppleComputerRootCertificate.cer"), request: request),
            try loadData(url: URL(string: "/app/Resources/AppleIncRootCertificate.cer"), request: request),
            try loadData(url: URL(string: "/app/Resources/AppleRootCA-G2.cer"), request: request),
            try loadData(url: URL(string: "/app/Resources/AppleRootCA-G3.cer"), request: request),
        ].compactMap { $0 }
        #else
        return [
            try loadData(url: Bundle.module.url(forResource: "AppleComputerRootCertificate", withExtension: "cer"), request: request),
            try loadData(url: Bundle.module.url(forResource: "AppleIncRootCertificate", withExtension: "cer"), request: request),
            try loadData(url: Bundle.module.url(forResource: "AppleRootCA-G2", withExtension: "cer"), request: request),
            try loadData(url: Bundle.module.url(forResource: "AppleRootCA-G3", withExtension: "cer"), request: request),
        ].compactMap { $0 }
        #endif
    }
    
    private func loadData(url: URL?, request: HBRequest) throws -> Foundation.Data? {
        let fs = FileManager()
        guard let url = url, fs.fileExists(atPath: url.path) else {
            request.logger.error("File missing: \(url?.absoluteString ?? "invalid url")")
            throw HBHTTPError(.internalServerError)
        }
                
        guard let data = fs.contents(atPath: url.path) else {
            request.logger.error("Can't read data from \(url.absoluteString)")
            return nil
        }
        return data
    }
}
