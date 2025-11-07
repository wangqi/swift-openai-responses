import Foundation
import RecouseEventSource
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// wangqi 2025-11-07: Custom decoder that provides default values for missing keys.
// This allows the Response model to work with streaming events that don't include all fields,
// which is common when different API providers (OpenAI, LM Studio, etc.) send partial responses.
private class LenientJSONDecoder: JSONDecoder {
	// wangqi 2025-11-07: Default values for commonly missing fields in OpenAI Responses API
	// Using nonisolated(unsafe) because this is a constant dictionary that's never modified
	private static nonisolated(unsafe) let defaults: [String: Any] = [
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
		"logprobs": [],

		// Output item fields
		"content": [],
		"status": "completed"
	]

	override func decode<T>(_ type: T.Type, from data: Data) throws -> T where T : Decodable {
		let patchedData = try patchJSONData(data)
		return try super.decode(type, from: patchedData)
	}

	private func patchJSONData(_ data: Data) throws -> Data {
		guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			return data
		}

		patchRecursively(&json)
		return try JSONSerialization.data(withJSONObject: json)
	}

	private func patchRecursively(_ object: inout [String: Any]) {
		// wangqi 2025-11-07: Process existing nested structures first to avoid infinite loops
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

		// wangqi 2025-11-07: Apply defaults after recursion to avoid processing newly-added values
		applyDefaults(to: &object)
		normalizeSpecialFields(&object)
	}

	private func applyDefaults(to object: inout [String: Any]) {
		// wangqi 2025-11-07: Apply all defaults except 'text' which is handled specially
		for (key, defaultValue) in Self.defaults {
			if object[key] == nil {
				object[key] = defaultValue
			}
		}

		// wangqi 2025-11-07: Handle 'text' field - only add to Response objects
		let isResponseObject = object["model"] != nil || object["status"] != nil || object["output"] != nil
		if isResponseObject && object["text"] == nil {
			object["text"] = ["format": ["type": "text"]]
		}

		// wangqi 2025-11-07: Clean up metadata - remove fields that might have wrong types
		// Different providers send different metadata formats (OpenAI vs LM Studio)
		if var metadata = object["metadata"] as? [String: Any] {
			// Remove any non-string values from metadata since it should be [String: String]
			metadata = metadata.filter { _, value in value is String }
			object["metadata"] = metadata
		}
	}

	private func normalizeSpecialFields(_ object: inout [String: Any]) {
		// wangqi 2025-11-07: Ensure text.format exists if text exists
		if var text = object["text"] as? [String: Any], text["format"] == nil {
			text["format"] = ["type": "text"]
			object["text"] = text
		}

		// wangqi 2025-11-07: Normalize truncation from dict to string (some providers send {"type": "auto"})
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
				print("[APIClient.sseStream] Stream closed")
				continuation.finish()
			}

			let dataTask = eventSource.dataTask(for: request)
			defer { dataTask.cancel(urlSession: URLSession.shared) }

			print("[APIClient.sseStream] Starting event stream for \(T.self)")
			var eventCount = 0

			for await event in dataTask.events() {
				eventCount += 1

				// wangqi 2025-11-07: Handle error events from the server
				if case let .error(error) = event {
					print("[APIClient.sseStream] Event #\(eventCount): Error - \(error)")

					// wangqi 2025-11-07: Try to extract error details from connection errors
					if case let .connectionError(statusCode, responseData) = error as? RecouseEventSource.EventSourceError {
						if let errorString = String(data: responseData, encoding: .utf8) {
							print("[APIClient.sseStream] Server error (HTTP \(statusCode)): \(errorString)")
						}

						// wangqi 2025-11-07: Try to decode as OpenAI error response
						if let errorResponse = try? decoder.decode(Response.ErrorResponse.self, from: responseData) {
							continuation.finish(throwing: errorResponse.error)
							return
						}
					}

					continuation.finish(throwing: error)
					return
				}

				guard case let .event(event) = event else {
					print("[APIClient.sseStream] Event #\(eventCount): Skipped (type: \(event))")
					continue
				}

				guard let data = event.data?.data(using: .utf8) else {
					print("[APIClient.sseStream] Event #\(eventCount): No data field")
					continue
				}

				print("[APIClient.sseStream] Event #\(eventCount): Decoding \(data.count) bytes")
				continuation.yield(with: Result { try decoder.decode(T.self, from: data) })

				try Task.checkCancellation()
			}

			print("[APIClient.sseStream] Completed with \(eventCount) events")
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
