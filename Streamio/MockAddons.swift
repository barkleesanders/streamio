import Foundation

// MOCK — replaced by real addon URLs in Phase 2
let MOCK_ADDONS: [AddonDescriptor] = [
    AddonDescriptor( // MOCK — replaced by real addon URLs in Phase 2
        transportUrl: "https://example-addon-one.invalid/manifest.json", // MOCK — replaced by real addon URLs in Phase 2
        manifest: AddonManifest(id: "mock.addon.one", name: "Mock Addon One (placeholder)", version: "0.0.0", types: ["movie", "series"], resources: nil)),
    AddonDescriptor( // MOCK — replaced by real addon URLs in Phase 2
        transportUrl: "https://example-addon-two.invalid/manifest.json", // MOCK — replaced by real addon URLs in Phase 2
        manifest: AddonManifest(id: "mock.addon.two", name: "Mock Addon Two (placeholder)", version: "0.0.0", types: ["movie", "series"], resources: nil)),
]
