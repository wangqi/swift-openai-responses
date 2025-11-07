// wangqi 2025-11-07: Middleware protocol for debugging/inspection support
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Protocol for intercepting HTTP requests, responses, and SSE streaming events
/// Used for debugging and logging OpenAI Responses API calls
public protocol ResponsesMiddlewareProtocol: Sendable {
    /// Intercepts outgoing HTTP requests before they are sent
    func intercept(request: URLRequest) -> URLRequest

    /// Intercepts streaming data chunks during SSE streaming
    func interceptStreamingData(request: URLRequest?, _ data: Data) -> Data

    /// Intercepts SSE event strings during streaming
    func interceptStreamingEvent(request: URLRequest?, _ eventString: String) -> String

    /// Intercepts complete HTTP responses after they are received
    func intercept(response: URLResponse?, request: URLRequest, data: Data?) -> (response: URLResponse?, data: Data?)

    /// Intercepts errors that occur during requests
    func interceptError(response: URLResponse?, request: URLRequest?, data: Data?, error: Error?)
}
