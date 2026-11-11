import Foundation

/// The last edited state of a creation, independent of immutable run snapshots.
public struct CreationSettings: Codable, Equatable {
    public var modelName: String
    public var parameters: Parameters
    public var promptEnhancement: Enhancement
    public var updatedAt: String
    public static let imageCountRange = 1...8
    public struct Parameters: Codable, Equatable {
        public var resolution: Int
        public var aspectRatio: String
        /// Number of images queued per submission; older workspaces default to one.
        public var imageCount: Int
        init(resolution: Int, aspectRatio: String, imageCount: Int) {
            self.resolution = resolution; self.aspectRatio = aspectRatio; self.imageCount = imageCount
        }
        private enum CodingKeys: String, CodingKey { case resolution, aspectRatio, imageCount }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            resolution = try values.decode(Int.self, forKey: .resolution)
            aspectRatio = try values.decode(String.self, forKey: .aspectRatio)
            imageCount = try values.decodeIfPresent(Int.self, forKey: .imageCount) ?? 1
        }
    }
    public struct Enhancement: Codable, Equatable { public var enabled: Bool }
    public init(modelName: String = QwenImage21Turbo.title, size: GenerationSize = GenerationSize(), enhancementEnabled: Bool = true, imageCount: Int = 1) {
        self.modelName = modelName
        parameters = Parameters(resolution: size.resolution.baseDimension, aspectRatio: size.aspectRatio?.rawValue ?? "adaptive",
                                imageCount: min(max(imageCount, Self.imageCountRange.lowerBound), Self.imageCountRange.upperBound))
        promptEnhancement = Enhancement(enabled: enhancementEnabled)
        updatedAt = Date().ISO8601Format()
    }
    private enum CodingKeys: String, CodingKey { case modelName, parameters, promptEnhancement, updatedAt }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        modelName = try values.decode(String.self, forKey: .modelName)
        parameters = try values.decode(Parameters.self, forKey: .parameters)
        promptEnhancement = try values.decode(Enhancement.self, forKey: .promptEnhancement)
        updatedAt = try values.decode(String.self, forKey: .updatedAt)
        guard modelName == QwenImage21Turbo.title,
              ImageResolution.allCases.contains(where: { $0.baseDimension == parameters.resolution }),
              parameters.aspectRatio == "adaptive" || ImageAspectRatio(rawValue: parameters.aspectRatio) != nil,
              Self.imageCountRange.contains(parameters.imageCount),
              ISO8601DateFormatter().date(from: updatedAt) != nil else {
            throw AppError.message("Invalid creation settings")
        }
    }
    public var size: GenerationSize {
        var result = GenerationSize()
        result.selectResolution(ImageResolution.allCases.first { $0.baseDimension == parameters.resolution }!)
        result.selectAspectRatio(ImageAspectRatio(rawValue: parameters.aspectRatio))
        return result
    }
}
