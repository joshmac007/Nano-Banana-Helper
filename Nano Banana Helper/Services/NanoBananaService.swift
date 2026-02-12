import Foundation

/// Request structure for image editing
struct ImageEditRequest: Sendable {
    let inputImageURLs: [URL] // Changed to array
    let prompt: String
    let aspectRatio: String
    let imageSize: String
    let useBatchTier: Bool
}

/// Response structure from Gemini API
struct ImageEditResponse: Sendable {
    let imageData: Data
    let mimeType: String
}

/// Internal struct to hold batch job creation info
struct BatchJobInfo: Sendable {
    let jobName: String
    let requestKey: String
}

/// Simple config storage
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
    // private let modelName = "gemini-3-pro-image-preview" // Removed hardcoded
    private let session: URLSession
    
    private var modelName: String {
        get async {
            await AppConfig.load().modelName ?? "gemini-3-pro-image-preview"
        }
    }
    
    private var baseURL: String {
        get async {
            "https://generativelanguage.googleapis.com/v1beta/models/\(await modelName)"
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
        await AppConfig.load().apiKey
    }
    
    func setAPIKey(_ key: String) async {
        var config = await AppConfig.load()
        config.apiKey = key.isEmpty ? nil : key
        await config.save()
    }
    
    func hasAPIKey() async -> Bool {
        await getAPIKey() != nil
    }
    
    // MARK: - Image Editing
    
    /// Maximum payload size for inline batch requests (20MB per documentation)
    private let maxBatchPayloadSize = 20 * 1024 * 1024
    
    func editImage(_ request: ImageEditRequest, onJobCreated: (@Sendable (String) -> Void)? = nil, onPollUpdate: (@Sendable (Int) -> Void)? = nil) async throws -> ImageEditResponse {
        guard let apiKey = await getAPIKey(), !apiKey.isEmpty else {
            throw NanoBananaError.missingAPIKey
        }
        
        if request.useBatchTier {
            // Use split workflow to allow ID capture
            let jobInfo = try await startBatchJob(request: request)
            onJobCreated?(jobInfo.jobName)
            return try await pollBatchJob(jobName: jobInfo.jobName, requestKey: jobInfo.requestKey, onPollUpdate: onPollUpdate)
        } else {
            let requestPayload = try await buildRequestPayload(request: request)
            return try await processStandardRequest(requestPayload, apiKey: apiKey)
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
    
    private func buildRequestPayload(request: ImageEditRequest) async throws -> [String: Any] {
        // Build multimodal parts
        var parts: [[String: Any]] = []
        parts.append(["text": request.prompt])
        
        var totalDataSize = 0
        for url in request.inputImageURLs {
            let imageData = try Data(contentsOf: url)
            totalDataSize += imageData.count
            let base64Image = imageData.base64EncodedString()
            let mimeTypeString = mimeType(for: url)
            
            parts.append([
                "inlineData": [
                    "mimeType": mimeTypeString,
                    "data": base64Image
                ]
            ])
        }
        
        // Validate size for batch requests (20MB limit for inline requests)
        if request.useBatchTier && totalDataSize > maxBatchPayloadSize {
            throw NanoBananaError.batchError(message: "Total image data (\(totalDataSize / 1024 / 1024)MB) exceeds 20MB limit for batch inline requests. Use smaller images or fewer images per batch.")
        }
        
        return [
            "contents": [["parts": parts]],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"],
                "imageConfig": [
                    "aspectRatio": AspectRatio.from(string: request.aspectRatio).apiValue, // Send "auto" or specific ratio
                    "imageSize": request.imageSize
                ]
            ]
        ]
    }
    
    // MARK: - Standard API
    
    private func processStandardRequest(_ payload: [String: Any], apiKey: String) async throws -> ImageEditResponse {
        var urlRequest = URLRequest(url: URL(string: "\(await baseURL):generateContent?key=\(apiKey)")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let httpBody = try JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted)
        urlRequest.httpBody = httpBody
        
        // Log request
        if let jsonString = String(data: httpBody, encoding: .utf8) {
            await LogManager.shared.log(.request, payload: jsonString)
        }
        
        // Execute with retry
        let (data, response) = try await executeWithRetry(urlRequest)
        
        // Log response
        if let jsonString = String(data: data, encoding: .utf8) {
            await LogManager.shared.log(.response, payload: jsonString)
        }
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NanoBananaError.invalidResponse
        }
        
        guard httpResponse.statusCode == 200 else {
            await LogManager.shared.log(.error, payload: "HTTP \(httpResponse.statusCode): \(String(data: data, encoding: .utf8) ?? "Unknown error")")
            throw NanoBananaError.apiError(statusCode: httpResponse.statusCode, data: data)
        }
        
        return try parseResponse(data)
    }
    
    // MARK: - Batch Job Resume
    
    /// Resume polling for an interrupted batch job
    func resumePolling(jobName: String, onPollUpdate: (@Sendable (Int) -> Void)? = nil) async throws -> ImageEditResponse {
        guard let apiKey = await getAPIKey(), !apiKey.isEmpty else {
            throw NanoBananaError.missingAPIKey
        }
        
        await LogManager.shared.log(.request, payload: "Resuming polling for job: \(jobName)")
        
        // Use empty requestKey since we're resuming - we'll take whatever result comes back
        return try await pollBatchJob(jobName: jobName, requestKey: "", apiKey: apiKey, onPollUpdate: onPollUpdate)
    }
    
    // MARK: - Batch API (Async Job-Based)
    
    private func createBatchJobRecord(_ payload: [String: Any], apiKey: String) async throws -> BatchJobInfo {
        let requestKey = UUID().uuidString
        let batchPayload: [String: Any] = [
            "batch": [
                "display_name": "NanoBananaPro-\(Int(Date().timeIntervalSince1970))",
                "input_config": [
                    "requests": [
                        "requests": [
                            [
                                "request": payload,
                                "metadata": ["key": requestKey]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        
        // POST to :batchGenerateContent endpoint
        let url = URL(string: "\(await baseURL):batchGenerateContent?key=\(apiKey)")!
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let httpBody = try JSONSerialization.data(withJSONObject: batchPayload)
        urlRequest.httpBody = httpBody
        
        let (data, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NanoBananaError.invalidResponse
        }
        
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
    func pollBatchJob(jobName: String, requestKey: String, onPollUpdate: (@Sendable (Int) -> Void)? = nil) async throws -> ImageEditResponse {
        guard let apiKey = await getAPIKey(), !apiKey.isEmpty else {
            throw NanoBananaError.missingAPIKey
        }
        return try await pollBatchJob(jobName: jobName, requestKey: requestKey, apiKey: apiKey, onPollUpdate: onPollUpdate)
    }

    private func pollBatchJob(jobName: String, requestKey: String, apiKey: String, onPollUpdate: (@Sendable (Int) -> Void)?) async throws -> ImageEditResponse {
        let pollInterval: UInt64 = 10 * 1_000_000_000 // 10 seconds (docs show this interval)
        let completedStates = Set(["JOB_STATE_SUCCEEDED", "JOB_STATE_FAILED", "JOB_STATE_CANCELLED", "JOB_STATE_EXPIRED"])
        var pollCount = 0
        let jobName = jobName.trimmingCharacters(in: .whitespacesAndNewlines)
        var consecutiveErrors = 0
        
        while true {
            pollCount += 1
            onPollUpdate?(pollCount)
            // Poll using the operation name
            let urlString = "https://generativelanguage.googleapis.com/v1beta/\(jobName)?key=\(apiKey)"
            
            await LogManager.shared.log(.request, payload: "Polling batch job: \(jobName) (Attempt \(pollCount))")
            
            do {
                var pollRequest = URLRequest(url: URL(string: urlString)!)
                pollRequest.httpMethod = "GET"
                
                let (data, response) = try await session.data(for: pollRequest)
                
                // Reset error count on success
                consecutiveErrors = 0
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NanoBananaError.invalidResponse
                }
                
                if httpResponse.statusCode != 200 {
                    // Handle temporary 5xx errors or 429s by retrying
                    if (500...599).contains(httpResponse.statusCode) || httpResponse.statusCode == 429 {
                        let delay = min(60, pow(2.0, Double(consecutiveErrors))) // Exponential backoff capped at 60s
                        await LogManager.shared.log(.error, payload: "Poll HTTP \(httpResponse.statusCode). Retrying in \(delay)s...")
                        try await Task.sleep(for: .seconds(delay))
                        consecutiveErrors += 1
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
                let state = metadata?["state"] as? String ?? (done ? "JOB_STATE_SUCCEEDED" : "JOB_STATE_PENDING")
                
                await LogManager.shared.log(.response, payload: "Job state: \(state), done: \(done)")
                
                if done || completedStates.contains(state) {
                    if state == "JOB_STATE_SUCCEEDED" || done {
                        // Check for inlined responses in the response field
                        if let responseObj = json["response"] as? [String: Any] {
                            return try extractResultFromResponse(responseObj, requestKey: requestKey, apiKey: apiKey)
                        }
                        // Some batch jobs may have results in metadata.dest
                        if let dest = metadata?["dest"] as? [String: Any] {
                            return try await extractResultFromDest(dest, requestKey: requestKey, apiKey: apiKey)
                        }
                        throw NanoBananaError.noImageInResponse
                    } else if state == "JOB_STATE_FAILED" {
                        let error = json["error"] as? [String: Any] ?? metadata?["error"] as? [String: Any]
                        let message = error?["message"] as? String ?? "Unknown batch error"
                        throw NanoBananaError.batchError(message: message)
                    } else {
                        throw NanoBananaError.batchError(message: "Job \(state.lowercased().replacingOccurrences(of: "job_state_", with: ""))")
                    }
                }
                
                // Still running or pending - wait and retry
                try await Task.sleep(nanoseconds: pollInterval)
                
            } catch {
                // Network error handling
                let nsError = error as NSError
                // Retry on network loss or timeout
                if nsError.domain == NSURLErrorDomain {
                    consecutiveErrors += 1
                    let delay = min(60, pow(2.0, Double(consecutiveErrors)))
                    await LogManager.shared.log(.error, payload: "Network error during poll: \(error.localizedDescription). Retrying in \(delay)s...")
                     try await Task.sleep(for: .seconds(delay))
                    continue
                }
                
                // Rethrow other errors
                throw error
            }
        }
    }
    
    private func extractResultFromResponse(_ response: [String: Any], requestKey: String, apiKey: String) throws -> ImageEditResponse {
        // Log the response structure for debugging
        if let responseData = try? JSONSerialization.data(withJSONObject: response, options: .prettyPrinted),
           let jsonString = String(data: responseData, encoding: .utf8) {
            let truncatedJson = String(jsonString.prefix(2000))
            Task { @MainActor in
                LogManager.shared.log(.response, payload: "Extracting result from response structure:\n\(truncatedJson)...")
            }
        }
        
        // Check for inlined responses
        if let inlinedResponses = extractInlinedResponses(from: response) {
            let count = inlinedResponses.count
            Task { @MainActor in
                LogManager.shared.log(.response, payload: "Found \(count) inlined response(s)")
            }
            for item in inlinedResponses {
                // Try to match by key, or just use first response
                if let innerResponse = item["response"] as? [String: Any] {
                    let responseData = try JSONSerialization.data(withJSONObject: innerResponse)
                    return try parseResponse(responseData)
                }
            }
        }
        
        // Check if response itself has candidates directly (some batch formats)
        if response["candidates"] != nil {
            Task { @MainActor in
                LogManager.shared.log(.response, payload: "Found candidates directly in response, parsing directly")
            }
            let responseData = try JSONSerialization.data(withJSONObject: response)
            return try parseResponse(responseData)
        }
        
        // Direct response parse attempt
        let responseData = try JSONSerialization.data(withJSONObject: response)
        return try parseResponse(responseData)
    }
    
    private func extractResultFromDest(_ dest: [String: Any], requestKey: String, apiKey: String) async throws -> ImageEditResponse {
        // Check for inlined responses first
        if let inlinedResponses = extractInlinedResponses(from: dest) {
            for item in inlinedResponses {
                if let response = item["response"] as? [String: Any] {
                    let responseData = try JSONSerialization.data(withJSONObject: response)
                    return try parseResponse(responseData)
                }
            }
        }
        
        // If results are in a file, download it
        if let fileName = dest["fileName"] as? String ?? dest["file_name"] as? String ?? dest["responsesFile"] as? String {
            await LogManager.shared.log(.request, payload: "Downloading results from: \(fileName)")
            
            let downloadURL = "https://generativelanguage.googleapis.com/download/v1beta/\(fileName):download?alt=media&key=\(apiKey)"
            var downloadRequest = URLRequest(url: URL(string: downloadURL)!)
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
                        return try parseResponse(responseData)
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
        let urlString = "https://generativelanguage.googleapis.com/v1beta/\(jobName):cancel?key=\(apiKey)"
        var urlRequest = URLRequest(url: URL(string: urlString)!)
        urlRequest.httpMethod = "POST"
        
        await LogManager.shared.log(.request, payload: "Cancelling batch job: \(jobName)")
        
        let (data, response) = try await session.data(for: urlRequest)
        
        if let jsonString = String(data: data, encoding: .utf8) {
            await LogManager.shared.log(.response, payload: "Cancel response: \(jsonString)")
        }
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NanoBananaError.invalidResponse
        }
    }
    
    
    // MARK: - Private Helpers
    
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
    
    private func parseResponse(_ data: Data) throws -> ImageEditResponse {
        guard let rawJson = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Task { @MainActor in
                LogManager.shared.log(.error, payload: "parseResponse: Could not parse as JSON dictionary")
            }
            throw NanoBananaError.invalidResponseFormat
        }
        
        // Log raw keys for debugging (capture before async)
        let keysString = rawJson.keys.sorted().joined(separator: ", ")
        Task { @MainActor in
            LogManager.shared.log(.response, payload: "parseResponse keys: \(keysString)")
        }
        
        // Handle batch API wrapper
        let json: [String: Any]
        if let responses = rawJson["responses"] as? [[String: Any]], let first = responses.first {
            json = first
        } else {
            json = rawJson
        }
        
        guard let candidates = json["candidates"] as? [[String: Any]],
              let firstCandidate = candidates.first,
              let content = firstCandidate["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else {
            // Log detailed failure info (capture values before async)
            let hasCandidates = json["candidates"] != nil
            let candidatesTypeStr = String(describing: type(of: json["candidates"] as Any))
            let jsonKeysString = json.keys.sorted().joined(separator: ", ")
            Task { @MainActor in
                LogManager.shared.log(.error, payload: "parseResponse structure issue - hasCandidates: \(hasCandidates), type: \(candidatesTypeStr), keys: \(jsonKeysString)")
            }
            throw NanoBananaError.invalidResponseFormat
        }
        
        for part in parts {
            // Handle both snake_case and camelCase response formats
            let inlineData = part["inline_data"] as? [String: Any] ?? part["inlineData"] as? [String: Any]
            if let inlineData = inlineData,
               let mimeType = (inlineData["mime_type"] ?? inlineData["mimeType"]) as? String,
               let base64Data = inlineData["data"] as? String,
               let imageData = Data(base64Encoded: base64Data) {
                return ImageEditResponse(imageData: imageData, mimeType: mimeType)
            }
            // Also handle file_data format
            let fileData = part["file_data"] as? [String: Any] ?? part["fileData"] as? [String: Any]
            if let fileData = fileData,
               let mimeType = (fileData["mime_type"] ?? fileData["mimeType"]) as? String,
               let base64Data = fileData["data"] as? String,
               let imageData = Data(base64Encoded: base64Data) {
                return ImageEditResponse(imageData: imageData, mimeType: mimeType)
            }
        }
        
        throw NanoBananaError.noImageInResponse
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
}

/// Errors
enum NanoBananaError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case invalidResponseFormat
    case noImageInResponse
    case apiError(statusCode: Int, data: Data)
    case batchError(message: String)
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
        case .apiError(let code, let data):
            let msg = String(data: data, encoding: .utf8) ?? "Unknown"
            return "API error (\(code)): \(msg)"
        case .batchError(let message):
            return "Batch error: \(message)"
        case .timeout:
            return "The request timed out. Try again or reduce image size."
        case .unknownError:
            return "Unknown error occurred."
        }
    }
}
