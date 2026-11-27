@_exported import AetherEngine
@_exported import SwiftLibass

/// The optional components this build has, as the engine reports them at run time.
public let enabledOptionalComponents = AetherEngine.OptionalComponent.allCases.filter(\.isBuiltIn)
