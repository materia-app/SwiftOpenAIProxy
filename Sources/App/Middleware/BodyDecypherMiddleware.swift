//
//  BodyDecypherMiddleware.swift
//
//
//  Created by Andrew Petrus on 27.02.24.
//

import Hummingbird
import NIOHTTP1
import Foundation

struct BodyDecypherMiddleware: HBMiddleware {
    func apply(to request: HBRequest, next: HBResponder) -> EventLoopFuture<HBResponse> {
        let modifiedDataFuture = accumulateAndModifyRequestBody(request)
        return modifiedDataFuture.flatMap { modifiedData in
            let headers = request.headers
            let head = HTTPRequestHead(version: request.version, method: request.method, uri: request.uri.string, headers: headers)
            
            let allocator = ByteBufferAllocator()
            var byteBuffer = allocator.buffer(capacity: modifiedData.count)
            byteBuffer.writeBytes(modifiedData)
            
            let request = HBRequest(head: head, body: HBRequestBody.byteBuffer(byteBuffer), application: request.application, context: request.context)
            
            return next.respond(to: request)
        }
    }
    
    private func accumulateAndModifyRequestBody(_ request: HBRequest) -> EventLoopFuture<Data> {
        var accumulatedBuffer = request.allocator.buffer(capacity: 0) // Prepare an empty buffer for accumulation
            
        let processChunk: (ByteBuffer) -> EventLoopFuture<Void> = { chunk in
            var mutableChunk = chunk
            return request.eventLoop.submit {
                accumulatedBuffer.writeBuffer(&mutableChunk)
            }
        }
        
        return request.body.stream?.consumeAll(on: request.eventLoop, processChunk).flatMapThrowing {
            let data = accumulatedBuffer.getData(at: 0, length: accumulatedBuffer.readableBytes) ?? Data()
            let modifiedData = modifyData(data)
            return modifiedData
        } ?? request.eventLoop.makeFailedFuture(NSError(domain: "StreamError", code: 0, userInfo: [NSLocalizedDescriptionKey: "Request body stream is nil."]))
    }
    
    private func modifyData(_ data: Data) -> Data {
        if let decodedData = Data(base64Encoded: data) {
            let decryptedData = AESHelper.decrypt(decodedData)
            return decryptedData
        }
        return Data()
    }
}
