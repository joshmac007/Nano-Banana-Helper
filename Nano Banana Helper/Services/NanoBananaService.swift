import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Request structure for image editing
struct ImageEditRequest: Sendable {
    let inputImageURLs: [URL] // Empty array for text-to-image generation
    let prompt: String
    let systemInstruction: String?
    let aspectRatio: String
    let imageSize: String
    let useBatchTier: Bool
    
    /// Convenience initializer for text-to-image generation (no input images)
    static func textOnly(
        prompt: String,
        systemInstruction: String? = nil,
        aspectRatio: String,
        imageSize: String,
        useBatchTier: Bool
    ) -> ImageEditRequest {
        ImageEditRequest(
            inputImageURLs: [],
            prompt: prompt,
            systemInstruction: systemInstruction,
            aspectRatio: aspectRatio,
            imageSize: imageSize,
            useBatchTier: useBatchTier
        )
    }
}

/// Response structure from Gemini API
struct ImageEditResponse: Sendable {
    let imageData: Data
    let mimeType: String
    let tokenUsage: TokenUsage?
}

/// Internal struct to hold batch job creation info
struct BatchJobInfo: Sendable {
    let jobName: String
    let requestKey: String
}

struct PollRetryState: Sendable {
    private(set) var consecutiveErrors = 0

    mutating func registerRetryableError() -> TimeInterval {
        consecutiveErrors += 1
        return min(60, pow(2.0, Double(consecutiveErrors)))
    }

    mutating func reset() {
        consecutiveErrors = 0
    }
}

struct PollStatusUpdate: Sendable {
    let attempt: Int
    let state: String
    let updatedAt: Date
}

struct PreparedInlineImage: Sendable {
    let filename: String
    let sourceMimeType: String
    let payloadMimeType: String
    let originalByteCount: Int
    let payloadByteCount: Int
    let data: Data

    var logDescription: String {
        let normalization = sourceMimeType == payloadMimeType ? "native" : "normalized"
        return "\(filename) \(sourceMimeType)->\(payloadMimeType) \(originalByteCount)B->\(payloadByteCount)B \(normalization)"
    }
}

struct RequestBuildDiagnostics: Sendable {
    let promptCharacterCount: Int
    let inputCount: Int
    let totalInlineBytes: Int
    let preflightDuration: TimeInterval
    let preparedInputs: [PreparedInlineImage]
}

private struct RequestBuildArtifacts {
    let payload: [String: Any]
    let diagnostics: RequestBuildDiagnostics
}

/// Simple config storage — @MainActor ensures all reads/writes are serialized
@MainActor
struct AppConfig: Codable {
    var apiKey: String?
    var modelName: String?
    
    static let fileURL: URL = AppPaths.configURL
    
    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            return AppConfig()
        }
        return config
    }
    
    func save() {
        try? JSONEncoder().encode(self).write(to: Self.fileURL)
    }
}

/// Service for communicating with the Gemini API
actor NanoBananaService {
    enum BatchTerminalResolution {
        case response([String: Any])
        case dest([String: Any])
    }

    // private let modelName = "gemini-3-pro-image-preview" // Removed hardcoded
    private let session: URLSession
    
    private var modelName: String {
        get async {
            await MainActor.run { AppConfig.load().modelName } ?? "gemini-3.1-flash-image-preview"
        }
    }
    
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 480 // Increased for multi-image processing
        config.timeoutIntervalForResource = 900
        self.session = URLSession(configuration: config)
    }
    
    // MARK: - API Key Management
    
    func getAPIKey() async -> String? {
        await MainActor.run { AppConfig.load().apiKey }
    }
    
    func setAPIKey(_ key: String) async {
        await MainActor.run {
            var config = AppConfig.load()
            config.apiKey = key.isEmpty ? nil : key
            config.save()
        }
    }
    
    func hasAPIKey() async -> Bool {
        await getAPIKey() != nil
    }
    
    // MARK: - Model Name Management
    
    func setModelName(_ name: String) async {
        await MainActor.run {
            var config = AppConfig.load()
            config.modelName = name.isEmpty ? nil : name
            config.save()
        }
    }
    
    func getModelName() async -> String {
        await MainActor.run { AppConfig.load().modelName } ?? "gemini-3.1-flash-image-preview"
    }

    func fetchAvailableModels(selectedModelID: String? = nil) async throws -> [ModelCatalogEntry] {
        guard let apiKey = await getAPIKey(), !apiKey.isEmpty else {
            return CuratedModelCatalog.fallbackEntries(selectedModelID: selectedModelID)
        }

        var request = URLRequest(url: try Self.listModelsURL(apiKey: apiKey, pageSize: 100))
        request.httpMethod = "GET"
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NanoBananaError.invalidResponse
        }

        let entries = try CuratedModelCatalog.entries(from: data, selectedModelID: selectedModelID)
        if entries.isEmpty {
            return CuratedModelCatalog.fallbackEntries(selectedModelID: selectedModelID)
        }
        return entries
    }
    
    // MARK: - Image Editing
    
    /// Maximum payload size for inline batch requests (20MB per documentation)
    private static let maxBatchPayloadSize = 20 * 1024 * 1024
    
    func editImage(_ request: ImageEditRequest, onJobCreated: (@Sendable (String) -> Void)? = nil, onPollUpdate: (@Sendable (PollStatusUpdate) -> Void)? = nil) async throws -> ImageEditResponse {
        guard let apiKey = await getAPIKey(), !apiKey.isEmpty else {
            throw NanoBananaError.missingAPIKey
        }

        let requestBuild = try await buildRequestPayload(request: request)
        
        if request.useBatchTier {
            // Use split workflow to allow ID capture
            let jobInfo = try await createBatchJobRecord(requestBuild, apiKey: apiKey)
            onJobCreated?(jobInfo.jobName)
            return try await pollBatchJob(jobName: jobInfo.jobName, requestKey: jobInfo.requestKey, onPollUpdate: onPollUpdate)
        } else {
            return try await processStandardRequest(requestBuild, apiKey: apiKey)
        }
    }
    
    /// Starts a batch job and returns the job name and request key immediately
    func startBatchJob(request: ImageEditRequest) async throws -> BatchJobInfo {
        guard let apiKey = await getAPIKey(), !apiKey.isEmpty else {
            throw NanoBananaError.missingAPIKey
        }
        
        let payload = try await buildRequestPayload(request: request)
        return try await createBatchJobRecord(payload, apiKey: apiKey)
    }
    
    private func buildRequestPayload(request: ImageEditRequest) async throws -> RequestBuildArtifacts {
        // Build multimodal parts
        var parts: [[String: Any]] = []
        parts.append(["text": request.prompt])

        let diagnostics = try buildRequestDiagnostics(for: request)

        for preparedInput in diagnostics.preparedInputs {
            parts.append([
                "inlineData": [
                    "mimeType": preparedInput.payloadMimeType,
                    "data": preparedInput.data.base64EncodedString()
                ]
            ])
        }
        
        // Build imageConfig — omit aspectRatio entirely when Auto is selected,
        // because the Gemini API only accepts explicit ratio strings (1:1, 16:9, etc.)
        // and will return HTTP 400 for any other value.
        let aspectRatioEntry = AspectRatio.from(string: request.aspectRatio)
        var imageConfig: [String: Any] = ["imageSize": request.imageSize]
        if aspectRatioEntry.id != "Auto" {
            imageConfig["aspectRatio"] = aspectRatioEntry.id
        }
        
        var payload: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"],
                "imageConfig": imageConfig
            ]
        ]
        
        // Add system instruction if present
        if let systemInstruction = request.systemInstruction, !systemInstruction.isEmpty {
            payload["system_instruction"] = [
                "parts": [
                    ["text": systemInstruction]
                ]
            ]
        }

        return RequestBuildArtifacts(
            payload: payload,
            diagnostics: diagnostics
        )
    }
    
    // MARK: - Standard API
    
    private func processStandardRequest(_ buildArtifacts: RequestBuildArtifacts, apiKey: String) async throws -> ImageEditResponse {
        let currentModelName = await modelName
        var urlRequest = URLRequest(
            url: try Self.generateContentURL(apiKey: apiKey, modelName: currentModelName)
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let serializationStart = Date()
        let httpBody = try JSONSerialization.data(withJSONObject: buildArtifacts.payload)
        let serializationDuration = Date().timeIntervalSince(serializationStart)
        urlRequest.httpBody = httpBody
        
        await LogManager.shared.log(
            .request,
            payload: Self.requestLogSummary(
                endpoint: "generateContent",
                modelName: currentModelName,
                diagnostics: buildArtifacts.diagnostics,
                bodyByteCount: httpBody.count,
                serializationDuration: serializationDuration
            )
        )
        
        // Execute with retry
        let requestStart = Date()
        let (data, response) = try await executeWithRetry(urlRequest)
        let requestDuration = Date().timeIntervalSince(requestStart)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NanoBananaError.invalidResponse
        }

        await LogManager.shared.log(
            .response,
            payload: Self.responseLogSummary(
                data: data,
                httpResponse: httpResponse,
                requestDuration: requestDuration
            )
        )
        
        guard httpResponse.statusCode == 200 else {
            await LogManager.shared.log(.error, payload: Self.httpErrorLogSummary(statusCode: httpResponse.statusCode, data: data))
            throw NanoBananaError.apiError(statusCode: httpResponse.statusCode, data: data)
        }
        
        return try await parseResponse(data)
    }
    
    // MARK: - Batch Job Resume
    
    /// Resume polling for an interrupted batch job
    func resumePolling(
        jobName: String,
        onPollUpdate: (@Sendable (PollStatusUpdate) -> Void)? = nil,
        softTimeout: TimeInterval? = nil,
        shouldContinue: (@Sendable () async -> Bool)? = nil
    ) async throws -> ImageEditResponse {
        guard let apiKey = await getAPIKey(), !apiKey.isEmpty else {
            throw NanoBananaError.missingAPIKey
        }
        
        await LogManager.shared.log(.request, payload: "Resuming polling for job: \(jobName)")
        
        // Use empty requestKey since we're resuming - we'll take whatever result comes back
        return try await pollBatchJob(
            jobName: jobName,
            requestKey: "",
            apiKey: apiKey,
            onPollUpdate: onPollUpdate,
            softTimeout: softTimeout,
            shouldContinue: shouldContinue
        )
    }
    
    // MARK: - Batch API (Async Job-Based)
    
    private func createBatchJobRecord(_ buildArtifacts: RequestBuildArtifacts, apiKey: String) async throws -> BatchJobInfo {
        let requestKey = UUID().uuidString
        let batchPayload: [String: Any] = [
            "batch": [
                "display_name": "NanoBananaPro-\(Int(Date().timeIntervalSince1970))",
                "input_config": [
                    "requests": [
                        "requests": [
                            [
                                "request": buildArtifacts.payload,
                                "metadata": ["key": requestKey]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        
        // POST to :batchGenerateContent endpoint
        let currentModelName = await modelName
        let url = try Self.batchGenerateContentURL(apiKey: apiKey, modelName: currentModelName)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let serializationStart = Date()
        let httpBody = try JSONSerialization.data(withJSONObject: batchPayload)
        let serializationDuration = Date().timeIntervalSince(serializationStart)
        urlRequest.httpBody = httpBody

        await LogManager.shared.log(
            .request,
            payload: Self.requestLogSummary(
                endpoint: "batchGenerateContent",
                modelName: currentModelName,
                diagnostics: buildArtifacts.diagnostics,
                bodyByteCount: httpBody.count,
                serializationDuration: serializationDuration
            )
        )
        
        let requestStart = Date()
        let (data, response) = try await session.data(for: urlRequest)
        let requestDuration = Date().timeIntervalSince(requestStart)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NanoBananaError.invalidResponse
        }

        await LogManager.shared.log(
            .response,
            payload: Self.responseLogSummary(
                data: data,
                httpResponse: httpResponse,
                requestDuration: requestDuration
            )
        )
        
        guard httpResponse.statusCode == 200 else {
            throw NanoBananaError.apiError(statusCode: httpResponse.statusCode, data: data)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobName = json["name"] as? String else {
            throw NanoBananaError.invalidResponseFormat
        }
        
        return BatchJobInfo(jobName: jobName, requestKey: requestKey)
    }
    
    /// Convenience wrapper for polling a known batch job
    func pollBatchJob(
        jobName: String,
        requestKey: String,
        onPollUpdate: (@Sendable (PollStatusUpdate) -> Void)? = nil,
        softTimeout: TimeInterval? = nil,
        shouldContinue: (@Sendable () async -> Bool)? = nil
    ) async throws -> ImageEditResponse {
        guard let apiKey = await getAPIKey(), !apiKey.isEmpty else {
            throw NanoBananaError.missingAPIKey
        }
        return try await pollBatchJob(
            jobName: jobName,
            requestKey: requestKey,
            apiKey: apiKey,
            onPollUpdate: onPollUpdate,
            softTimeout: softTimeout,
            shouldContinue: shouldContinue
        )
    }

    private func pollBatchJob(
        jobName: String,
        requestKey: String,
        apiKey: String,
        onPollUpdate: (@Sendable (PollStatusUpdate) -> Void)?,
        softTimeout: TimeInterval?,
        shouldContinue: (@Sendable () async -> Bool)?
    ) async throws -> ImageEditResponse {
        let pollInterval: UInt64 = 10 * 1_000_000_000 // 10 seconds (docs show this interval)
        let completedStates = Set(["JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED", "JOB_STATE_CANCELLED", "JOB_STATE_EXPIRED"])
        let maxPollCount = 360 // 360 × 10s = 1 hour max; prevents infinite loop on stuck API state
        var pollCount = 0
        let jobName = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        var retryState = PollRetryState()
        let pollStart = Date()
        var latestState = "JOB_STATE_PENDING"
        
        while pollCount <= maxPollCount {
            if let shouldContinue, await shouldContinue() == false {
                throw NanoBananaError.pollingStopped(state: latestState)
            }
            pollCount += 1
            
            await LogManager.shared.log(.request, payload: "Polling batch job: \(jobName) (Attempt \(pollCount))")
            
            do {
                var pollRequest = URLRequest(url: try Self.batchOperationURL(jobName: jobName, apiKey: apiKey))
                pollRequest.httpMethod = "GET"
                
                let (data, response) = try await session.data(for: pollRequest)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NanoBananaError.invalidResponse
                }
                
                if httpResponse.statusCode != 200 {
                    // Handle temporary 5xx errors or 429s by retrying
                    if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                        let delay = retryState.registerRetryableError()
                        await LogManager.shared.log(.error, payload: "Poll HTTP \(httpResponse.statusCode). Retrying in \(delay)s...")
                        try await Task.sleep(for: .seconds(delay))
                        continue
                    }
                    
                    // Fatal errors
                    if let errorStr = String(data: data, encoding: .utf8) {
                        await LogManager.shared.log(.error, payload: "Poll failed: \(errorStr)")
                    }
                    throw NanoBananaError.apiError(statusCode: httpResponse.statusCode, data: data)
                }
                
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw NanoBananaError.invalidResponseFormat
                }
                
                // Check if operation is done
                let done = json["done"] as? Bool ?? false
                
                // Get state from metadata
                let metadata = json["metadata"] as? [String: Any]
                let error = json["error"] as? [String: Any] ?? metadata?["error"] as? [String: Any]
                let state = Self.inferBatchJobState(
                    done: done,
                    metadataState: metadata?["state"] as? String,
                    error: error
                )
                latestState = state
                let update = PollStatusUpdate(attempt: pollCount, state: state, updatedAt: Date())
                onPollUpdate?(update)
                
                await LogManager.shared.log(.response, payload: "Job state: \(state), done: \(done)")
                retryState.reset()
                
                if done || completedStates.contains(state) {
                    let resolution = try Self.resolveTerminalBatchResolution(
                        done: done,
                        metadataState: metadata?["state"] as? String,
                        response: json["response"] as? [String: Any],
                        dest: metadata?["dest"] as? [String: Any],
                        error: error
                    )

                    switch resolution {
                    case .response(let responseObj):
                        return try await extractResultFromResponse(responseObj, requestKey: requestKey, apiKey: apiKey)
                    case .dest(let dest):
                        return try await extractResultFromDest(dest, requestKey: requestKey, apiKey: apiKey)
                    }
                }

                if let softTimeout, Date().timeIntervalSince(pollStart) >= softTimeout {
                    throw NanoBananaError.softTimeout(state: state)
                }
                if let shouldContinue, await shouldContinue() == false {
                    throw NanoBananaError.pollingStopped(state: state)
                }
                
                // Still running or pending - wait and retry
                try await Task.sleep(nanoseconds: pollInterval)
                
            } catch {
                // Network error handling
                let nsError = error as NSError
                // Retry on network loss or timeout
                if nsError.domain == NSURLErrorDomain {
                    let delay = retryState.registerRetryableError()
                    await LogManager.shared.log(.error, payload: "Network error during poll: \(error.localizedDescription). Retrying in \(delay)s...")
                     try await Task.sleep(for: .seconds(delay))
                    continue
                }
                
                // Rethrow other errors
                throw error
            }
        }

        // Exceeded maximum poll attempts — the API job is stuck in a non-terminal state
        await LogManager.shared.log(.error, payload: "Poll timeout after \(maxPollCount) attempts for job: \(jobName)")
        throw NanoBananaError.timeout
    }
    
    private func extractResultFromResponse(_ response: [String: Any], requestKey: String, apiKey: String) async throws -> ImageEditResponse {
        await LogManager.shared.log(.response, payload: Self.batchResultSummary(response))
        
        // Check for inlined responses
        if let inlinedResponses = extractInlinedResponses(from: response) {
            await LogManager.shared.log(.response, payload: "Found \(inlinedResponses.count) inlined response(s)")
            for item in inlinedResponses {
                // Try to match by key, or just use first response
                if let innerResponse = item["response"] as? [String: Any] {
                    let responseData = try JSONSerialization.data(withJSONObject: innerResponse)
                    return try await parseResponse(responseData)
                }
            }
        }
        
        // Check if response itself has candidates directly (some batch formats)
        if response["candidates"] != nil {
            await LogManager.shared.log(.response, payload: "Found candidates directly in response, parsing directly")
            let responseData = try JSONSerialization.data(withJSONObject: response)
            return try await parseResponse(responseData)
        }
        
        // Direct response parse attempt
        let responseData = try JSONSerialization.data(withJSONObject: response)
        return try await parseResponse(responseData)
    }
    
    private func extractResultFromDest(_ dest: [String: Any], requestKey: String, apiKey: String) async throws -> ImageEditResponse {
        // Check for inlined responses first
        if let inlinedResponses = extractInlinedResponses(from: dest) {
            for item in inlinedResponses {
                if let response = item["response"] as? [String: Any] {
                    let responseData = try JSONSerialization.data(withJSONObject: response)
                    return try await parseResponse(responseData)
                }
            }
        }
        
        // If results are in a file, download it
        if let fileName = dest["fileName"] as? String ?? dest["file_name"] as? String ?? dest["responsesFile"] as? String {
            await LogManager.shared.log(.request, payload: "Downloading results from: \(fileName)")
            
            var downloadRequest = URLRequest(
                url: try Self.downloadResultsURL(fileName: fileName, apiKey: apiKey)
            )
            downloadRequest.httpMethod = "GET"
            
            let (data, response) = try await session.data(for: downloadRequest)
            
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw NanoBananaError.batchError(message: "Failed to download batch results")
            }
            
            // Parse JSONL results
            guard let content = String(data: data, encoding: .utf8) else {
                throw NanoBananaError.invalidResponseFormat
            }
            
            for line in content.split(separator: "\n") {
                if let lineData = line.data(using: .utf8),
                   let lineJson = try JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    if let response = lineJson["response"] as? [String: Any] {
                        let responseData = try JSONSerialization.data(withJSONObject: response)
                        return try await parseResponse(responseData)
                    }
                }
            }
        }
        
        throw NanoBananaError.noImageInResponse
    }
    
    /// Helper to handle both direct and nested inlinedResponses structures
    private func extractInlinedResponses(from container: [String: Any]) -> [[String: Any]]? {
        // Try direct array: { "inlinedResponses": [...] }
        if let directArray = container["inlinedResponses"] as? [[String: Any]] ?? container["inlined_responses"] as? [[String: Any]] {
            return directArray
        }
        
        // Try nested object: { "inlinedResponses": { "inlinedResponses": [...] } }
        if let nestedObj = container["inlinedResponses"] as? [String: Any] ?? container["inlined_responses"] as? [String: Any],
           let nestedArray = nestedObj["inlinedResponses"] as? [[String: Any]] ?? nestedObj["inlined_responses"] as? [[String: Any]] {
            return nestedArray
        }
        
        return nil
    }
    
    // MARK: - Batch Management
    
    func cancelBatchJob(jobName: String) async throws {
        guard let apiKey = await getAPIKey(), !apiKey.isEmpty else {
            throw NanoBananaError.missingAPIKey
        }
        
        let jobName = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        var urlRequest = URLRequest(url: try Self.cancelBatchJobURL(jobName: jobName, apiKey: apiKey))
        urlRequest.httpMethod = "POST"
        
        await LogManager.shared.log(.request, payload: "Cancelling batch job: \(jobName)")
        
        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NanoBananaError.invalidResponse
        }

        await LogManager.shared.log(
            .response,
            payload: Self.responseLogSummary(
                data: data,
                httpResponse: httpResponse,
                requestDuration: 0
            )
        )

        guard httpResponse.statusCode == 200 else {
            throw NanoBananaError.invalidResponse
        }
    }
    
    
    // MARK: - Private Helpers

    func buildRequestDiagnostics(for request: ImageEditRequest) throws -> RequestBuildDiagnostics {
        let preflightStart = Date()
        let preparedInputs = try prepareInlineImages(for: request.inputImageURLs)
        let preflightDuration = Date().timeIntervalSince(preflightStart)
        let totalDataSize = preparedInputs.reduce(0) { partialResult, input in
            partialResult + input.payloadByteCount
        }

        try Self.validateBatchPayloadSize(
            totalDataSize: totalDataSize,
            hasInputImages: !preparedInputs.isEmpty,
            useBatchTier: request.useBatchTier
        )

        return RequestBuildDiagnostics(
            promptCharacterCount: request.prompt.count,
            inputCount: preparedInputs.count,
            totalInlineBytes: totalDataSize,
            preflightDuration: preflightDuration,
            preparedInputs: preparedInputs
        )
    }

    func prepareInlineImages(for urls: [URL]) throws -> [PreparedInlineImage] {
        try urls.map { url in
            let originalData = try Data(contentsOf: url)
            let sourceMimeType = mimeType(for: url)

            if sourceMimeType == "image/png" {
                let normalizedData = try normalizePNGToJPEG(data: originalData, filename: url.lastPathComponent)
                return PreparedInlineImage(
                    filename: url.lastPathComponent,
                    sourceMimeType: sourceMimeType,
                    payloadMimeType: "image/jpeg",
                    originalByteCount: originalData.count,
                    payloadByteCount: normalizedData.count,
                    data: normalizedData
                )
            }

            return PreparedInlineImage(
                filename: url.lastPathComponent,
                sourceMimeType: sourceMimeType,
                payloadMimeType: sourceMimeType,
                originalByteCount: originalData.count,
                payloadByteCount: originalData.count,
                data: originalData
            )
        }
    }

    static func validateBatchPayloadSize(totalDataSize: Int, hasInputImages: Bool, useBatchTier: Bool) throws {
        guard hasInputImages, useBatchTier, totalDataSize > Self.maxBatchPayloadSize else {
            return
        }

        throw NanoBananaError.batchError(
            message: "Total image data (\(totalDataSize / 1024 / 1024)MB) exceeds 20MB limit for batch inline requests. Use smaller images or fewer images per batch."
        )
    }

    private func normalizePNGToJPEG(data: Data, filename: String) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NanoBananaError.inputPreparationFailed(message: "Could not decode PNG input \(filename).")
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

        guard let context = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NanoBananaError.inputPreparationFailed(message: "Could not prepare PNG input \(filename) for JPEG conversion.")
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        guard let flattenedImage = context.makeImage() else {
            throw NanoBananaError.inputPreparationFailed(message: "Could not flatten PNG input \(filename) before upload.")
        }

        let destinationData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            destinationData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw NanoBananaError.inputPreparationFailed(message: "Could not encode JPEG payload for \(filename).")
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary
        CGImageDestinationAddImage(destination, flattenedImage, options)

        guard CGImageDestinationFinalize(destination) else {
            throw NanoBananaError.inputPreparationFailed(message: "JPEG conversion failed for \(filename).")
        }

        return destinationData as Data
    }

    private func executeWithRetry(_ request: URLRequest, maxRetries: Int = 3) async throws -> (Data, URLResponse) {
        var lastError: Error?
        
        for attempt in 0..<maxRetries {
            do {
                let (data, response) = try await session.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 429 {
                    let delay = pow(2.0, Double(attempt))
                    try await Task.sleep(for: .seconds(delay))
                    continue
                }
                
                return (data, response)
            } catch {
                lastError = error
                if attempt < maxRetries - 1 {
                    try await Task.sleep(for: .seconds(pow(2.0, Double(attempt)) * 0.5))
                }
            }
        }
        
        throw lastError ?? NanoBananaError.unknownError
    }
    
    func parseResponse(_ data: Data) async throws -> ImageEditResponse {
        let parseStart = Date()

        guard let rawJson = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            await LogManager.shared.log(.error, payload: "parseResponse: Could not parse as JSON dictionary")
            throw NanoBananaError.invalidResponseFormat
        }
        
        // Log raw keys for debugging
        await LogManager.shared.log(.response, payload: "parseResponse keys: \(rawJson.keys.sorted().joined(separator: ", "))")

        var tokenUsage: TokenUsage? = nil
        if let um = rawJson["usageMetadata"] as? [String: Any],
           let pt = um["promptTokenCount"] as? Int,
           let ct = um["candidatesTokenCount"] as? Int,
           let tt = um["totalTokenCount"] as? Int {
            tokenUsage = TokenUsage(promptTokenCount: pt, candidatesTokenCount: ct, totalTokenCount: tt)
        }

        // Handle batch API wrapper
        let json: [String: Any]
        if let responses = rawJson["responses"] as? [[String: Any]], let first = responses.first {
            json = first
        } else {
            json = rawJson
        }
        
        guard let candidates = json["candidates"] as? [[String: Any]],
              !candidates.isEmpty else {
            let hasCandidates = json["candidates"] != nil
            let candidatesTypeStr = String(describing: type(of: json["candidates"] as Any))
            let jsonKeysString = json.keys.sorted().joined(separator: ", ")
            await LogManager.shared.log(.error, payload: "parseResponse structure issue - hasCandidates: \(hasCandidates), type: \(candidatesTypeStr), keys: \(jsonKeysString)")
            throw NanoBananaError.invalidResponseFormat
        }

        for candidate in candidates {
            let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            for part in parts {
                // Handle both snake_case and camelCase response formats
                let inlineData = part["inline_data"] as? [String: Any] ?? part["inlineData"] as? [String: Any]
                if let inlineData = inlineData,
                   let mimeType = (inlineData["mime_type"] ?? inlineData["mimeType"]) as? String,
                   let base64Data = inlineData["data"] as? String,
                   let imageData = Data(base64Encoded: base64Data) {
                    await LogManager.shared.log(
                        .response,
                        payload: Self.cappedLogPayload(
                            "Response parse completed in \(Self.formatDuration(Date().timeIntervalSince(parseStart))) | mimeType=\(mimeType) imageBytes=\(imageData.count)"
                        )
                    )
                    return ImageEditResponse(imageData: imageData, mimeType: mimeType, tokenUsage: tokenUsage)
                }
                // Also handle file_data format
                let fileData = part["file_data"] as? [String: Any] ?? part["fileData"] as? [String: Any]
                if let fileData = fileData,
                   let mimeType = (fileData["mime_type"] ?? fileData["mimeType"]) as? String,
                   let base64Data = fileData["data"] as? String,
                   let imageData = Data(base64Encoded: base64Data) {
                    await LogManager.shared.log(
                        .response,
                        payload: Self.cappedLogPayload(
                            "Response parse completed in \(Self.formatDuration(Date().timeIntervalSince(parseStart))) | mimeType=\(mimeType) imageBytes=\(imageData.count)"
                        )
                    )
                    return ImageEditResponse(imageData: imageData, mimeType: mimeType, tokenUsage: tokenUsage)
                }
            }
        }

        if let finishError = Self.modelFinishError(from: candidates) {
            await LogManager.shared.log(
                .error,
                payload: Self.cappedLogPayload(
                    "Response parse failed after \(Self.formatDuration(Date().timeIntervalSince(parseStart))) | \(finishError.localizedDescription)"
                )
            )
            throw finishError
        }
        
        throw NanoBananaError.noImageInResponse
    }

    static func modelFinishError(from candidates: [[String: Any]]) -> NanoBananaError? {
        for candidate in candidates {
            let finishReason = (candidate["finishReason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let finishMessage = (candidate["finishMessage"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let finishReason, !finishReason.isEmpty {
                return .modelFinishedWithoutImage(finishReason: finishReason, message: finishMessage)
            }
            if let finishMessage, !finishMessage.isEmpty {
                return .modelFinishedWithoutImage(finishReason: "UNKNOWN", message: finishMessage)
            }
        }
        return nil
    }

    static func cappedLogPayload(_ payload: String, limit: Int = 1600) -> String {
        guard payload.count > limit else { return payload }
        let clipped = payload.prefix(limit)
        return "\(clipped)… [truncated \(payload.count - limit) chars]"
    }

    static func requestLogSummary(
        endpoint: String,
        modelName: String,
        diagnostics: RequestBuildDiagnostics,
        bodyByteCount: Int,
        serializationDuration: TimeInterval
    ) -> String {
        let inputSummary = diagnostics.preparedInputs.isEmpty
            ? "none"
            : diagnostics.preparedInputs.map(\.logDescription).joined(separator: "; ")
        return cappedLogPayload(
            "Request \(endpoint) | model=\(modelName) promptChars=\(diagnostics.promptCharacterCount) inputs=\(diagnostics.inputCount) inlineBytes=\(diagnostics.totalInlineBytes) bodyBytes=\(bodyByteCount) preflight=\(formatDuration(diagnostics.preflightDuration)) serialize=\(formatDuration(serializationDuration)) | images=[\(inputSummary)]"
        )
    }

    static func responseLogSummary(data: Data, httpResponse: HTTPURLResponse, requestDuration: TimeInterval) -> String {
        if let rawJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return cappedLogPayload(
                "Response HTTP \(httpResponse.statusCode) in \(formatDuration(requestDuration)) | \(responseJSONSummary(rawJson))"
            )
        }
        return cappedLogPayload(
            "Response HTTP \(httpResponse.statusCode) in \(formatDuration(requestDuration)) | non-JSON body (\(data.count) bytes)"
        )
    }

    static func httpErrorLogSummary(statusCode: Int, data: Data) -> String {
        let body = String(data: data, encoding: .utf8) ?? "Non-text body (\(data.count) bytes)"
        return cappedLogPayload("HTTP \(statusCode): \(body)", limit: 1200)
    }

    private static func responseJSONSummary(_ json: [String: Any]) -> String {
        let effectiveJSON: [String: Any]
        if let responses = json["responses"] as? [[String: Any]], let first = responses.first {
            effectiveJSON = first
        } else {
            effectiveJSON = json
        }

        let keys = effectiveJSON.keys.sorted().joined(separator: ",")
        let candidates = effectiveJSON["candidates"] as? [[String: Any]] ?? []
        let finishSummary: String
        if let finishError = modelFinishError(from: candidates) {
            finishSummary = finishError.localizedDescription
        } else {
            finishSummary = "finish=IMAGE"
        }

        let usageSummary: String
        if let usageMetadata = json["usageMetadata"] as? [String: Any],
           let totalTokens = usageMetadata["totalTokenCount"] {
            usageSummary = " totalTokens=\(totalTokens)"
        } else {
            usageSummary = ""
        }

        return "jsonKeys=[\(keys)] candidates=\(candidates.count) \(finishSummary)\(usageSummary)"
    }

    private static func batchResultSummary(_ response: [String: Any]) -> String {
        let keys = response.keys.sorted().joined(separator: ",")
        let inlinedCount = extractInlinedResponseCount(from: response)
        let candidateCount = (response["candidates"] as? [[String: Any]])?.count ?? 0
        return cappedLogPayload(
            "Batch terminal payload | keys=[\(keys)] inlinedResponses=\(inlinedCount) candidates=\(candidateCount)"
        )
    }

    private static func extractInlinedResponseCount(from container: [String: Any]) -> Int {
        if let directArray = container["inlinedResponses"] as? [[String: Any]] ?? container["inlined_responses"] as? [[String: Any]] {
            return directArray.count
        }

        if let nestedObj = container["inlinedResponses"] as? [String: Any] ?? container["inlined_responses"] as? [String: Any],
           let nestedArray = nestedObj["inlinedResponses"] as? [[String: Any]] ?? nestedObj["inlined_responses"] as? [[String: Any]] {
            return nestedArray.count
        }

        return 0
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3fs", duration)
    }
    
    static func inferBatchJobState(done: Bool, metadataState: String?, error: [String: Any]?) -> String {
        if let metadataState {
            let trimmed = canonicalBatchState(metadataState)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        guard done else {
            return "JOB_STATE_PENDING"
        }

        if isCancellationError(error) {
            return "JOB_STATE_CANCELLED"
        }

        if error != nil {
            return "JOB_STATE_FAILED"
        }

        return "JOB_STATE_SUCCEEDED"
    }

    static func batchErrorMessage(from error: [String: Any]?) -> String? {
        guard let error else { return nil }
        if let message = error["message"] as? String, !message.isEmpty {
            return message
        }
        if let status = error["status"] as? String, !status.isEmpty {
            return status
        }
        return nil
    }

    static func resolveTerminalBatchResolution(
        done: Bool,
        metadataState: String?,
        response: [String: Any]?,
        dest: [String: Any]?,
        error: [String: Any]?
    ) throws -> BatchTerminalResolution {
        let state = inferBatchJobState(done: done, metadataState: metadataState, error: error)

        switch state {
        case "JOB_STATE_SUCCEEDED":
            if let response {
                return .response(response)
            }
            if let dest {
                return .dest(dest)
            }
            throw NanoBananaError.noImageInResponse
        case "JOB_STATE_FAILED":
            throw NanoBananaError.batchError(message: batchErrorMessage(from: error) ?? "Unknown batch error")
        case "JOB_STATE_CANCELLED":
            throw NanoBananaError.jobCancelled
        case "JOB_STATE_EXPIRED":
            throw NanoBananaError.jobExpired
        default:
            throw NanoBananaError.batchError(
                message: "Job \(displayBatchState(state))"
            )
        }
    }

    private static func isCancellationError(_ error: [String: Any]?) -> Bool {
        guard let error else { return false }

        let status = (error["status"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if status == "CANCELLED" || status == "CANCELED" {
            return true
        }

        let message = (error["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return message.contains("cancelled") || message.contains("canceled")
    }

    static func canonicalBatchState(_ state: String) -> String {
        state
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
            .replacingOccurrences(of: "BATCH_STATE_", with: "JOB_STATE_")
    }

    static func displayBatchState(_ state: String) -> String {
        canonicalBatchState(state)
            .replacingOccurrences(of: "JOB_STATE_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "heif": return "image/heif"
        default: return "image/jpeg"
        }
    }

    static func generateContentURL(apiKey: String, modelName: String) throws -> URL {
        try apiURL(
            path: "/v1beta/models/\(modelName):generateContent",
            queryItems: [URLQueryItem(name: "key", value: apiKey)]
        )
    }

    static func batchGenerateContentURL(apiKey: String, modelName: String) throws -> URL {
        try apiURL(
            path: "/v1beta/models/\(modelName):batchGenerateContent",
            queryItems: [URLQueryItem(name: "key", value: apiKey)]
        )
    }

    static func batchOperationURL(jobName: String, apiKey: String) throws -> URL {
        try apiURL(
            path: "/v1beta/\(jobName.trimmingCharacters(in: .whitespacesAndNewlines))",
            queryItems: [URLQueryItem(name: "key", value: apiKey)]
        )
    }

    static func downloadResultsURL(fileName: String, apiKey: String) throws -> URL {
        try apiURL(
            path: "/download/v1beta/\(fileName):download",
            queryItems: [
                URLQueryItem(name: "alt", value: "media"),
                URLQueryItem(name: "key", value: apiKey)
            ]
        )
    }

    static func cancelBatchJobURL(jobName: String, apiKey: String) throws -> URL {
        try apiURL(
            path: "/v1beta/\(jobName.trimmingCharacters(in: .whitespacesAndNewlines)):cancel",
            queryItems: [URLQueryItem(name: "key", value: apiKey)]
        )
    }

    static func listModelsURL(apiKey: String, pageSize: Int) throws -> URL {
        try apiURL(
            path: "/v1beta/models",
            queryItems: [
                URLQueryItem(name: "key", value: apiKey),
                URLQueryItem(name: "pageSize", value: String(pageSize))
            ]
        )
    }

    private static func apiURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "generativelanguage.googleapis.com"
        components.path = path
        components.queryItems = queryItems

        guard let url = components.url else {
            throw NanoBananaError.invalidRequestURL(path: path)
        }

        return url
    }
}

/// Errors
enum NanoBananaError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case invalidResponseFormat
    case noImageInResponse
    case inputPreparationFailed(message: String)
    case modelFinishedWithoutImage(finishReason: String, message: String?)
    case invalidRequestURL(path: String)
    case apiError(statusCode: Int, data: Data)
    case batchError(message: String)
    case jobCancelled
    case jobExpired
    case softTimeout(state: String)
    case pollingStopped(state: String)
    case timeout
    case unknownError
    
    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No API key configured. Add your Gemini API key in Settings."
        case .invalidResponse:
            return "Invalid response from API. If this is a batch job recovery, double check that the Job ID is correct (no extra spaces, l vs 1, etc)."
        case .invalidResponseFormat:
            return "Could not parse API response."
        case .noImageInResponse:
            return "No image in API response."
        case .inputPreparationFailed(let message):
            return message
        case .modelFinishedWithoutImage(let finishReason, let message):
            if let message, !message.isEmpty {
                return "Model finished without image (\(finishReason)): \(message)"
            }
            return "Model finished without image (\(finishReason))."
        case .invalidRequestURL(let path):
            return "Could not build a valid API request URL for path: \(path)"
        case .apiError(let code, let data):
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            return "API error (\(code)): \(msg)"
        case .batchError(let message):
            return "Batch error: \(message)"
        case .jobCancelled:
            return "Cancelled by user."
        case .jobExpired:
            return "Remote batch expired before completion."
        case .softTimeout(let state):
            return "Polling paused after the local timeout while the remote job was still \(NanoBananaService.displayBatchState(state))."
        case .pollingStopped(let state):
            return "Polling stopped locally while the remote job was still \(NanoBananaService.displayBatchState(state))."
        case .timeout:
            return "The request timed out. Try again or reduce image size."
        case .unknownError:
            return "Unknown error occurred."
        }
    }
}
