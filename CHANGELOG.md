# SDK for Swift Clients CHANGELOG

## [unreleased]
*Compatible with Lightstreamer Server since 7.4.0.*<br>
*Based on [Swift Client SDK 6.2.1](https://github.com/Lightstreamer/Lightstreamer-lib-client-swift/tree/6.2.1).*<br>

Removed dependencies on third-party libraries Starscream, Alamofire and JSONPatch.

Reimplemented Websocket connection layer using the standard class URLSessionWebSocketTask instead of the library Starscream.

Removed HTTP connection layer. If the `connectionOptions.forcedTransport` property is set to anything other than `WS-STREAMING`, the library will trigger a fatal error if WebSocket connection fails.

Dropped support for JSON patch delivery. If the server sends updates in JSON Patch format, the library will throw a fatal error.

Removed network interface status detection. In poor network conditions, this may affect the library's readiness to react to connectivity issues.

Increased the minimum compatibility requirements of the following platforms: iOS from 12 to 13, macOS from 10.13 to 10.15, tvOS from 12 to 13, watchOS from 5 to 6. 
