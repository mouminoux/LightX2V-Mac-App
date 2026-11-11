import Foundation

/// Arguments of the MCP `generate_image` tool. Every call produces exactly one image.
public struct MCPImageArguments {
    public static let toolName = "generate_image"
    public static let aspectRatios = ["adaptive"] + ImageAspectRatio.allCases.map(\.rawValue)
    public static let resolutions = ImageResolution.allCases.map(\.rawValue)
    private static let keys: Set<String> = ["prompt", "aspect_ratio", "resolution", "seed", "prompt_enhancement", "input_images"]

    public var prompt: String
    public var size: GenerationSize
    public var seed: Int64?
    public var promptEnhancement: Bool
    public var inputImages: [String]

    public init(prompt: String, size: GenerationSize = GenerationSize(), seed: Int64? = nil,
                promptEnhancement: Bool = false, inputImages: [String] = []) {
        self.prompt = prompt; self.size = size; self.seed = seed
        self.promptEnhancement = promptEnhancement; self.inputImages = inputImages
    }

    public static func parse(_ arguments: [String: Any]) throws -> MCPImageArguments {
        if let unknown = arguments.keys.filter({ !keys.contains($0) }).sorted().first {
            throw AppError.message("Unknown argument \"\(unknown)\". This tool generates exactly one image per call.")
        }
        guard let prompt = arguments["prompt"] as? String,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 20000 else {
            throw AppError.message("\"prompt\" must be a string between 1 and 20000 characters.")
        }
        var size = GenerationSize()
        if let value = arguments["resolution"] {
            guard let text = value as? String, let resolution = ImageResolution(rawValue: text) else {
                throw AppError.message("\"resolution\" must be one of: \(resolutions.joined(separator: ", ")).")
            }
            size.selectResolution(resolution)
        }
        if let value = arguments["aspect_ratio"] {
            guard let text = value as? String, aspectRatios.contains(text) else {
                throw AppError.message("\"aspect_ratio\" must be one of: \(aspectRatios.joined(separator: ", ")).")
            }
            size.selectAspectRatio(ImageAspectRatio(rawValue: text))
        }
        var seed: Int64?
        if let value = arguments["seed"], !(value is NSNull) {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue == number.doubleValue.rounded(), (0...4294967295).contains(number.doubleValue) else {
                throw AppError.message("\"seed\" must be an integer between 0 and 4294967295.")
            }
            seed = number.int64Value
        }
        var enhancement = false
        if let value = arguments["prompt_enhancement"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw AppError.message("\"prompt_enhancement\" must be a boolean.")
            }
            enhancement = number.boolValue
        }
        var images: [String] = []
        if let value = arguments["input_images"] {
            guard let paths = value as? [String], paths.allSatisfy({ $0.hasPrefix("/") }) else {
                throw AppError.message("\"input_images\" must be an array of absolute file paths.")
            }
            guard paths.count <= InputImages.maximumCount else {
                throw AppError.message("\"input_images\" accepts up to \(InputImages.maximumCount) images.")
            }
            images = paths
        }
        return MCPImageArguments(prompt: prompt, size: size, seed: seed, promptEnhancement: enhancement, inputImages: images)
    }

    public static var tool: [String: Any] {
        [
            "name": toolName,
            "title": "Generate image",
            "description": "Generate one image locally with Qwen-Image-2.1-Turbo in LightX2V APP. "
                + "Each call produces exactly one PNG image, returned inline together with its file path. "
                + "Provide input_images to edit or combine reference images (image-to-image). "
                + "Generation takes from several seconds to a few minutes; the APP runs one generation at a time.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "prompt": ["type": "string", "minLength": 1, "maxLength": 20000,
                               "description": "Description of the image to generate, or the edit to apply to the input images."],
                    "aspect_ratio": ["type": "string", "enum": aspectRatios, "default": "adaptive",
                                     "description": "Output aspect ratio (width:height). \"adaptive\" lets the model choose the dimensions."],
                    "resolution": ["type": "string", "enum": resolutions, "default": ImageResolution.oneK.rawValue,
                                   "description": "Output size tier: 512 (fast preview), 1K (about 1 megapixel) or 2K (about 4 megapixels)."],
                    "seed": ["type": "integer", "minimum": 0, "maximum": 4294967295,
                             "description": "Random seed for reproducible results. Omit for a random seed."],
                    "prompt_enhancement": ["type": "boolean", "default": false,
                                           "description": "Rewrite the prompt with the local enhancement model first. Requires the enhancement models to be prepared in the APP."],
                    "input_images": ["type": "array", "items": ["type": "string"], "maxItems": InputImages.maximumCount,
                                     "description": "Absolute paths of local reference images for image-to-image generation (1 to 3 recommended)."]
                ] as [String: Any],
                "required": ["prompt"],
                "additionalProperties": false
            ] as [String: Any],
            "annotations": ["readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false]
        ]
    }
}

public enum MCPPort {
    public static let range = 1024...65535
    public static let defaultValue = 7788

    public static func parse(_ text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespaces)), range.contains(value) else { return nil }
        return value
    }
}
