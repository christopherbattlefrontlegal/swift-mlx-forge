// Copyright © 2026 Apple Inc.

import Foundation
import MLXLMCommon

/// Registers the DFlash2 drafter model type.
///
/// Call once before loading a drafter through `DFlash2DrafterModelFactory`.
/// DFlash2 checkpoints report `model_type: qwen3`; the drafter registry is
/// separate from the language-model registry, so the type does not collide,
/// and a checkpoint without a `dflash_config` object fails to decode.
public enum DFlash2Registration {
    public static func register() async {
        await DFlash2DrafterTypeRegistry.shared.registerModelType(
            "qwen3",
            creator: { data in
                guard isDFlash2Configuration(data) else {
                    throw DFlash2RegistrationError.notADrafter
                }
                let config = try JSONDecoder.json5().decode(DFlash2Configuration.self, from: data)
                return DFlash2DraftModel(config)
            }
        )
    }
}

public enum DFlash2RegistrationError: Error {
    /// The `config.json` has no `dflash_config` object.
    case notADrafter
}

private func isDFlash2Configuration(_ data: Data) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return false
    }
    return root["dflash_config"] is [String: Any]
}
