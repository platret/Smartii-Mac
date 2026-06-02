import Foundation

// MARK: - Provider registry model

/// Static metadata describing a single AI provider and the models it exposes.
struct ProviderInfo {
    let id: String
    let label: String
    let tier: String
    let defaultModel: String
    let models: [String]
    let keyURL: String
    let instructions: String
}

/// A user-facing error carrying a human-readable message.
enum SmartiiError: Error, LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}

// MARK: - Providers

enum Providers {

    /// The full provider registry, in display order:
    /// gemini, groq, openrouter, huggingface, anthropic, openai, perplexity.
    static let all: [ProviderInfo] = [
        ProviderInfo(
            id: "gemini",
            label: "Google Gemini",
            tier: "free",
            defaultModel: "gemini-2.0-flash",
            models: [
                "gemini-2.0-flash",
                "gemini-2.5-flash",
                "gemini-2.5-pro",
                "gemini-1.5-flash",
                "gemini-1.5-pro",
            ],
            keyURL: "https://aistudio.google.com/app/apikey",
            instructions: "Free API key from Google AI Studio. Every Gemini model can read screenshots."
        ),
        ProviderInfo(
            id: "groq",
            label: "Groq",
            tier: "free",
            defaultModel: "llama-3.3-70b-versatile",
            models: [
                "llama-3.3-70b-versatile",
                "llama-3.1-8b-instant",
                "meta-llama/llama-4-scout-17b-16e-instruct",
            ],
            keyURL: "https://console.groq.com/keys",
            instructions: "Fast, free inference. Screenshots are routed to Llama 4 Scout (the vision model)."
        ),
        ProviderInfo(
            id: "openrouter",
            label: "OpenRouter",
            tier: "mixed",
            defaultModel: "meta-llama/llama-3.3-70b-instruct:free",
            models: [
                "meta-llama/llama-3.3-70b-instruct:free",
                "google/gemini-2.0-flash-exp:free",
                "qwen/qwen-2.5-vl-72b-instruct:free",
                "anthropic/claude-3.5-sonnet",
                "openai/gpt-4o",
            ],
            keyURL: "https://openrouter.ai/keys",
            instructions: "One key for many models, including free tiers. Screenshots use a free Gemini vision model."
        ),
        ProviderInfo(
            id: "huggingface",
            label: "Hugging Face",
            tier: "free",
            defaultModel: "meta-llama/Llama-3.3-70B-Instruct",
            models: [
                "meta-llama/Llama-3.3-70B-Instruct",
                "Qwen/Qwen2.5-72B-Instruct",
            ],
            keyURL: "https://huggingface.co/settings/tokens",
            instructions: "Free inference API. Text only — these models cannot read screenshots."
        ),
        ProviderInfo(
            id: "anthropic",
            label: "Anthropic Claude",
            tier: "paid",
            defaultModel: "claude-sonnet-4-6",
            models: [
                "claude-opus-4-7",
                "claude-sonnet-4-6",
                "claude-haiku-4-5-20251001",
            ],
            keyURL: "https://console.anthropic.com/settings/keys",
            instructions: "Paid API key. Every Claude model can read screenshots."
        ),
        ProviderInfo(
            id: "openai",
            label: "OpenAI",
            tier: "paid",
            defaultModel: "gpt-4o",
            models: [
                "gpt-4o",
                "gpt-4o-mini",
                "gpt-4-turbo",
                "o1-mini",
            ],
            keyURL: "https://platform.openai.com/api-keys",
            instructions: "Paid API key. Screenshots are routed to a GPT-4o vision model."
        ),
        ProviderInfo(
            id: "perplexity",
            label: "Perplexity",
            tier: "paid",
            defaultModel: "sonar",
            models: [
                "sonar",
                "sonar-pro",
                "sonar-reasoning",
            ],
            keyURL: "https://www.perplexity.ai/settings/api",
            instructions: "Paid API key with live web search. Text only — cannot read screenshots."
        ),
    ]

    /// Look up provider metadata by id.
    static func info(_ id: String) -> ProviderInfo? {
        all.first { $0.id == id }
    }

    // MARK: - Data URL helper

    /// Splits a data URL of the form "data:<mime>;base64,<payload>" into its
    /// MIME type and the raw base64 payload (without the "data:" prefix).
    /// Returns nil if the string is not a well-formed data URL.
    private static func splitDataURL(_ dataURL: String) -> (mime: String, base64: String)? {
        // mime is the substring between "data:" and the first ";".
        guard dataURL.hasPrefix("data:") else { return nil }
        guard let semicolon = dataURL.firstIndex(of: ";") else { return nil }
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let mimeStart = dataURL.index(dataURL.startIndex, offsetBy: 5) // after "data:"
        guard mimeStart <= semicolon else { return nil }
        let mime = String(dataURL[mimeStart..<semicolon])
        // base64 is everything after the comma.
        let base64 = String(dataURL[dataURL.index(after: comma)...])
        if mime.isEmpty || base64.isEmpty { return nil }
        return (mime, base64)
    }

    // MARK: - Networking helper

    /// Performs the request and returns the response body. Throws
    /// SmartiiError.message on transport failure or non-2xx status (using the
    /// server's error text when parseable, otherwise "HTTP <code>").
    private static func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SmartiiError.message(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw SmartiiError.message("No HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "HTTP \(http.statusCode)")
        }
        return data
    }

    /// Best-effort extraction of a human-readable error message from a server
    /// error body. Handles the common shapes used by the supported providers.
    private static func serverErrorText(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            // Some providers return a bare string body.
            let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (raw?.isEmpty == false) ? raw : nil
        }
        if let obj = json as? [String: Any] {
            // {"error": {"message": "..."}} (OpenAI / Groq / OpenRouter / Gemini)
            if let err = obj["error"] as? [String: Any], let msg = err["message"] as? String {
                return msg
            }
            // {"error": "..."} (Hugging Face, some others)
            if let msg = obj["error"] as? String {
                return msg
            }
            // {"message": "..."} (Anthropic-style top-level message)
            if let msg = obj["message"] as? String {
                return msg
            }
            // {"detail": "..."} (Perplexity / FastAPI-style)
            if let msg = obj["detail"] as? String {
                return msg
            }
        }
        return nil
    }

    /// Serializes a JSON body, wrapping failures as SmartiiError.
    private static func serialize(_ body: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw SmartiiError.message("Failed to encode request: \(error.localizedDescription)")
        }
    }

    /// Parses a JSON response into a dictionary, throwing on malformed bodies.
    private static func parseObject(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SmartiiError.message("Unexpected response from provider")
        }
        return obj
    }

    // MARK: - Dispatch

    /// Calls the given provider with the prompt and (optionally) an attached
    /// screenshot as a data URL. Performs vision auto-routing per provider and
    /// returns the model's text answer.
    static func call(
        providerId: String,
        apiKey: String,
        prompt: String,
        imageDataURL: String?,
        model: String?
    ) async throws -> String {
        guard let info = info(providerId) else {
            throw SmartiiError.message("Unknown provider \"\(providerId)\".")
        }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw SmartiiError.message("No API key set for \(info.label). Add one in Smartii settings.")
        }

        // Resolve the model: caller-supplied (non-empty) else the provider default.
        let requested = (model?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let chosenModel = requested ?? info.defaultModel

        // Decode the screenshot once if present.
        var image: (mime: String, base64: String)?
        if let dataURL = imageDataURL {
            guard let parts = splitDataURL(dataURL) else {
                throw SmartiiError.message("Invalid screenshot data.")
            }
            image = parts
        }

        switch providerId {
        case "gemini":
            return try await callGemini(apiKey: trimmedKey, prompt: prompt, image: image, model: chosenModel)
        case "groq":
            // Vision: only Llama 4 Scout supports images on Groq.
            let model = image == nil ? chosenModel : "meta-llama/llama-4-scout-17b-16e-instruct"
            return try await callOpenAIChat(
                endpoint: "https://api.groq.com/openai/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: model, extraHeaders: [:]
            )
        case "openrouter":
            // Vision fallback to a free Gemini vision model.
            let model = image == nil ? chosenModel : "google/gemini-2.0-flash-exp:free"
            return try await callOpenAIChat(
                endpoint: "https://openrouter.ai/api/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: model,
                extraHeaders: [
                    "HTTP-Referer": "https://github.com/platret/Smartii-Mac",
                    "X-Title": "Smartii",
                ]
            )
        case "openai":
            // Vision: route to a GPT-4o vision model when the chosen one can't see.
            let visionModels: Set<String> = ["gpt-4o", "gpt-4o-mini", "gpt-4-turbo"]
            let model = (image == nil || visionModels.contains(chosenModel)) ? chosenModel : "gpt-4o-mini"
            return try await callOpenAIChat(
                endpoint: "https://api.openai.com/v1/chat/completions",
                apiKey: trimmedKey, prompt: prompt, image: image, model: model, extraHeaders: [:]
            )
        case "anthropic":
            return try await callAnthropic(apiKey: trimmedKey, prompt: prompt, image: image, model: chosenModel)
        case "perplexity":
            if image != nil {
                throw SmartiiError.message("\(info.label) can't read images. Switch to Gemini or Groq in Smartii settings.")
            }
            return try await callPerplexity(apiKey: trimmedKey, prompt: prompt, model: chosenModel)
        case "huggingface":
            if image != nil {
                throw SmartiiError.message("\(info.label) can't read images. Switch to Gemini or Groq in Smartii settings.")
            }
            return try await callHuggingFace(apiKey: trimmedKey, prompt: prompt, model: chosenModel)
        default:
            throw SmartiiError.message("Unsupported provider \"\(providerId)\".")
        }
    }

    // MARK: - Gemini

    private static func callGemini(
        apiKey: String, prompt: String, image: (mime: String, base64: String)?, model: String
    ) async throws -> String {
        // Key is passed as a query parameter on the generateContent endpoint.
        guard let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(encodedKey)")
        else {
            throw SmartiiError.message("Invalid Gemini request URL.")
        }

        var parts: [[String: Any]] = [["text": prompt]]
        if let image = image {
            parts.append(["inline_data": ["mime_type": image.mime, "data": image.base64]])
        }
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": parts]]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try serialize(body)

        let data = try await send(request)
        let obj = try parseObject(data)

        // candidates[0].content.parts[].text joined.
        guard let candidates = obj["candidates"] as? [[String: Any]],
              let first = candidates.first,
              let content = first["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]]
        else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "Gemini returned no answer.")
        }
        let text = parts.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw SmartiiError.message("Gemini returned an empty answer.")
        }
        return text
    }

    // MARK: - OpenAI-compatible chat (groq / openrouter / openai)

    private static func callOpenAIChat(
        endpoint: String, apiKey: String, prompt: String,
        image: (mime: String, base64: String)?, model: String, extraHeaders: [String: String]
    ) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw SmartiiError.message("Invalid request URL.")
        }

        // content is the plain prompt, or a multimodal array when an image is present.
        let content: Any
        if let image = image {
            content = [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:\(image.mime);base64,\(image.base64)"]],
            ] as [[String: Any]]
        } else {
            content = prompt
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": [["role": "user", "content": content]],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }
        request.httpBody = try serialize(body)

        let data = try await send(request)
        let obj = try parseObject(data)

        // choices[0].message.content
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty
        else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "Provider returned no answer.")
        }
        return text
    }

    // MARK: - Anthropic

    private static func callAnthropic(
        apiKey: String, prompt: String, image: (mime: String, base64: String)?, model: String
    ) async throws -> String {
        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw SmartiiError.message("Invalid Anthropic request URL.")
        }

        // content is a typed-block array; image block precedes the text block.
        let content: [[String: Any]]
        if let image = image {
            content = [
                ["type": "image", "source": ["type": "base64", "media_type": image.mime, "data": image.base64]],
                ["type": "text", "text": prompt],
            ]
        } else {
            content = [["type": "text", "text": prompt]]
        }

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": [["role": "user", "content": content]],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        request.httpBody = try serialize(body)

        let data = try await send(request)
        let obj = try parseObject(data)

        // content[].text joined.
        guard let blocks = obj["content"] as? [[String: Any]] else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "Claude returned no answer.")
        }
        let text = blocks.compactMap { $0["text"] as? String }.joined()
        guard !text.isEmpty else {
            throw SmartiiError.message("Claude returned an empty answer.")
        }
        return text
    }

    // MARK: - Perplexity

    private static func callPerplexity(apiKey: String, prompt: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api.perplexity.ai/chat/completions") else {
            throw SmartiiError.message("Invalid Perplexity request URL.")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try serialize(body)

        let data = try await send(request)
        let obj = try parseObject(data)

        // choices[0].message.content
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let text = message["content"] as? String, !text.isEmpty
        else {
            throw SmartiiError.message(serverErrorText(from: data) ?? "Perplexity returned no answer.")
        }
        return text
    }

    // MARK: - Hugging Face

    private static func callHuggingFace(apiKey: String, prompt: String, model: String) async throws -> String {
        guard let url = URL(string: "https://api-inference.huggingface.co/models/\(model)") else {
            throw SmartiiError.message("Invalid Hugging Face request URL.")
        }

        let body: [String: Any] = [
            "inputs": prompt,
            "parameters": ["max_new_tokens": 1024, "return_full_text": false],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try serialize(body)

        let data = try await send(request)

        // Response is either an array of objects or a single object.
        let json = try? JSONSerialization.jsonObject(with: data)
        if let arr = json as? [[String: Any]], let text = arr.first?["generated_text"] as? String, !text.isEmpty {
            return text
        }
        if let obj = json as? [String: Any], let text = obj["generated_text"] as? String, !text.isEmpty {
            return text
        }
        throw SmartiiError.message(serverErrorText(from: data) ?? "Hugging Face returned no answer.")
    }
}
