import Foundation
import Testing
@testable import Services

@Test("OTLP resource設定は全spanに共通のSDK resourceへ渡り、設定比較にも含まれる")
func otlpResourceAttributesArePreserved() {
    let endpoint = URL(string: "https://example.invalid/v1/traces")!
    let standard = OpenTelemetryConfiguration(endpoint: endpoint)
    let verification = OpenTelemetryConfiguration(
        endpoint: endpoint, resourceAttributes: ["deployment.environment.name": "verification"]
    )
    #expect(standard != verification)
    let resource = OpenTelemetryService.resource(for: verification)
    #expect(resource.attributes["service.name"]?.description == "swift-mcp-app")
    #expect(resource.attributes["deployment.environment.name"]?.description == "verification")
    #expect(OpenTelemetryService.resource(for: standard).attributes["deployment.environment.name"] == nil)
}
