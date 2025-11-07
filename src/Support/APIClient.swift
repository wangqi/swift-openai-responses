import Foundation
import RecouseEventSource
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// wangqi 2025-11-07: Custom decoder that provides default values for missing keys
// This allows the Response model to work with streaming events that don't include all fields
private class LenientJSONDecoder: JSONDecoder {
	override func decode<T>(_ type: T.Type, from data: Data) throws -> T where T : Decodable {
		// Pre-patch the JSON before any decoding attempts
		let patchedData = try patchJSONData(data)
		return try super.decode(type, from: patchedData)
	}

	private func patchJSONData(_ data: Data) throws -> Data {
		guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			// If it's not a dictionary, return as-is
			return data
		}

		// wangqi 2025-11-07: Recursively patch all nested dictionaries and arrays
		patchRecursively(&json)

		return try JSONSerialization.data(withJSONObject: json)
	}

	private func patchRecursively(_ object: inout [String: Any]) {
		// wangqi 2025-11-07: First, recursively patch existing nested structures BEFORE adding defaults
		// This prevents infinite loops from processing newly-added default values
		let originalKeys = Set(object.keys)
		for key in originalKeys {
			guard let value = object[key] else { continue }

			if var nestedDict = value as? [String: Any] {
				patchRecursively(&nestedDict)
				object[key] = nestedDict
			} else if var nestedArray = value as? [[String: Any]] {
				for i in 0..<nestedArray.count {
					patchRecursively(&nestedArray[i])
				}
				object[key] = nestedArray
			}
		}

		// wangqi 2025-11-07: Now apply defaults for missing keys (after recursion is done)
		let defaults: [String: Any] = [
			// Response-level fields
			"metadata": [:],
			"parallel_tool_calls": true,
			"temperature": 1.0,
			"top_p": 1.0,
			"store": true,
			"tool_choice": "auto",
			"tools": [],
			"truncation": "auto",

			// Text config fields
			"format": ["type": "text"],

			// Usage details
			"input_tokens_details": ["cached_tokens": 0],
			"output_tokens_details": ["reasoning_tokens": 0],

			// Content part fields
			"annotations": [],
			"logprobs": [], // Empty array, not null

			// Output item fields
			"content": [],
			"status": "completed"
		]

		// wangqi 2025-11-07: Detect if this is a Response object by checking for response-specific fields
		let isResponseObject = object["model"] != nil || object["status"] != nil || object["output"] != nil

		// Apply defaults for missing keys
		for (key, defaultValue) in defaults {
			// Skip 'text' for now - handle it specially below
			if key == "text" { continue }

			if object[key] == nil {
				object[key] = defaultValue
			}
		}

		// wangqi 2025-11-07: Special handling for text config - only add to Response objects
		if isResponseObject && object["text"] == nil {
			object["text"] = ["format": ["type": "text"]]
		} else if var text = object["text"] as? [String: Any] {
			if text["format"] == nil {
				text["format"] = ["type": "text"]
				object["text"] = text
			}
		}

		// Special handling for truncation - normalize dict to string
		if let truncationDict = object["truncation"] as? [String: Any],
		   let type = truncationDict["type"] as? String {
			object["truncation"] = type
		}
	}
}

public struct APIClient: Sendable {
	public enum Error: Swift.Error {
		/// The provided request is invalid.
		case invalidRequest(URLRequest)

		/// The response was not a 200 or 400 status
		case invalidResponse(URLResponse)
	}

	private let request: URLRequest
	private let eventSource = EventSource(mode: .default) // wangqi 2025-11-07: Changed from .dataOnly to properly parse SSE events
	private let encoder = tap(JSONEncoder()) { $0.dateEncodingStrategy = .iso8601 }
	private let decoder: JSONDecoder = {
		// wangqi 2025-11-07: Use lenient decoder that handles missing fields gracefully
		let decoder = LenientJSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		return decoder
	}()

	/// Creates a new `APIClient` instance using the provided `URLRequest`.
	///
	/// - Parameter request: The `URLRequest` to use for the API.
	init(connectingTo request: URLRequest) throws(Error) {
		guard let url = request.url else { throw Error.invalidRequest(request) }

		var request = request
		if url.lastPathComponent != "/" {
			request.url = url.appendingPathComponent("/")
		}

		self.request = request
	}

	/// Creates a new `ResponsesAPI` instance using OpenAI API credentials.
	///
	/// - Parameter authToken: The OpenAI API key to use for authentication.
	/// - Parameter organizationId: The [organization](https://platform.openai.com/docs/guides/production-best-practices#setting-up-your-organization) associated with the request.
	/// - Parameter projectId: The project associated with the request.
	init(authToken: String, organizationId: String? = nil, projectId: String? = nil) {
		var request = URLRequest(url: URL(string: "https://api.openai.com/")!)

		request.addValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
		if let projectId { request.addValue(projectId, forHTTPHeaderField: "OpenAI-Project") }
		if let organizationId { request.addValue(organizationId, forHTTPHeaderField: "OpenAI-Organization") }

		self.request = request
	}

	func send<R: Decodable>(expecting _: R.Type, configuring requestBuilder: (inout URLRequest, JSONEncoder) throws -> Void) async throws -> R {
		return try decoder.decode(R.self, from: await send(configuring: requestBuilder))
	}

	func send(configuring requestBuilder: (inout URLRequest, JSONEncoder) throws -> Void) async throws -> Data {
		var req = request
		try requestBuilder(&req, encoder)

		return try await send(request: req)
	}

	func stream<T: Decodable & Sendable>(expecting _: T.Type, configuring requestBuilder: (inout URLRequest, JSONEncoder) throws -> Void) async throws -> AsyncThrowingStream<T, Swift.Error> {
		var req = request
		try requestBuilder(&req, encoder)

		return try await sseStream(of: T.self, request: req)
	}

	/// Sends an URLRequest and returns the response data.
	///
	/// - Throws: If the request fails to send or has a non-200 status code.
	private func send(request: URLRequest) async throws -> Data {
		let (data, res) = try await URLSession.shared.data(for: request)

		guard let res = res as? HTTPURLResponse else { throw Error.invalidResponse(res) }
		guard res.statusCode != 200 else { return data }

		if let response = try? decoder.decode(Response.ErrorResponse.self, from: data) {
			throw response.error
		}

		throw Error.invalidResponse(res)
	}

	private func sseStream<T: Decodable & Sendable>(of _: T.Type, request: URLRequest) async throws -> AsyncThrowingStream<T, Swift.Error> {
		let (stream, continuation) = AsyncThrowingStream.makeStream(of: T.self)

		let task = Task {
			defer {
				print("[APIClient] sseStream: Task finishing, calling continuation.finish()")
				continuation.finish()
			}

			let dataTask = eventSource.dataTask(for: request)
			defer { dataTask.cancel(urlSession: URLSession.shared) }

			print("[APIClient] sseStream: Starting to iterate events from dataTask...")
			var eventIndex = 0
			for await event in dataTask.events() {
				eventIndex += 1
				print("[APIClient] sseStream: Received event #\(eventIndex), type=\(event)")

				guard case let .event(event) = event else {
					print("[APIClient] sseStream: Event #\(eventIndex) is not .event type, continuing...")
					continue
				}

				print("[APIClient] sseStream: Event #\(eventIndex) data field: \(event.data ?? "nil")")

				guard let data = event.data?.data(using: .utf8) else {
					print("[APIClient] sseStream: Event #\(eventIndex) has no data, continuing...")
					continue
				}

				print("[APIClient] sseStream: Event #\(eventIndex) attempting to decode \(data.count) bytes")
				continuation.yield(with: Result { try decoder.decode(T.self, from: data) })

				try Task.checkCancellation()
			}
			print("[APIClient] sseStream: Event iteration completed")
		}

		continuation.onTermination = { _ in
			task.cancel()
		}

		return stream
	}

	/// A hacky parser for Server-Sent Events lines.
	///
	/// It looks for a line that starts with `data:`, then tries to decode the message as the given type.
	private func parseSSELine<T: Decodable>(_ line: String, as _: T.Type = T.self) -> Result<T, Swift.Error>? {
		let components = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: true)
		guard components.count == 2, components[0] == "data" else { return nil }

		let message = components[1].trimmingCharacters(in: .whitespacesAndNewlines)

		return Result { try decoder.decode(T.self, from: Data(message.utf8)) }
	}
}
