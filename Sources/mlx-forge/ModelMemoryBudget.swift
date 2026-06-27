// Forge — resident model memory slots and load admission control.

import Foundation
import MLX

enum ModelMemoryBudget {
    /// How many MLX/GGUF models Forge tracks as concurrent resident slots.
    static let slotCount = 4

    struct LoadDecision: Equatable {
        let allowed: Bool
        let message: String?
    }

    enum Pressure: String {
        case comfortable
        case tight
        case critical

        var label: String {
            switch self {
            case .comfortable: "comfortable"
            case .tight: "tight"
            case .critical: "critical"
            }
        }
    }

    struct Snapshot: Equatable {
        var physical: Int64
        var reserved: Int64
        var modelsCommitted: Int64
        var mlxActive: Int
        var slotCount: Int
        var loadedSlotCount: Int
        var budget: Int64
        var remaining: Int64
        var utilization: Double
        var pressure: Pressure
    }

    static var physicalBytes: Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    /// Headroom reserved for macOS + Forge runtime (not model weights).
    static func reservedBytes(total: Int64 = physicalBytes) -> Int64 {
        max(4 << 30, total / 6)
    }

    static func allowableModelBytes(total: Int64 = physicalBytes) -> Int64 {
        max(0, total - reservedBytes(total: total))
    }

    /// Rough on-disk → resident estimate for admission checks.
    static func estimatedResidentBytes(for model: LocalModel) -> Int64 {
        if model.isGGUF {
            return Int64(Double(model.sizeBytes) * 1.05)
        }
        return Int64(Double(model.sizeBytes) * 1.15)
    }

    static func estimatedCommittedBytes<S: Sequence>(
        modelIDs: S, models: [LocalModel]
    ) -> Int64 where S.Element == String {
        let byID = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        return modelIDs.reduce(Int64(0)) { partial, id in
            partial + (byID[id].map(estimatedResidentBytes(for:)) ?? 0)
        }
    }

    static func canLoad(
        _ model: LocalModel,
        slotAssignments: [String?],
        replacingSlot: Int? = nil,
        allModels: [LocalModel]
    ) -> LoadDecision {
        let occupied = slotAssignments.compactMap { $0 }
        var projected = occupied
        if let replacingSlot, replacingSlot >= 0, replacingSlot < slotAssignments.count,
            let existing = slotAssignments[replacingSlot]
        {
            projected.removeAll { $0 == existing }
        }
        if !projected.contains(model.id) {
            projected.append(model.id)
        }

        let budget = allowableModelBytes()
        let committed = estimatedCommittedBytes(modelIDs: projected, models: allModels)
        if committed <= budget {
            return LoadDecision(allowed: true, message: nil)
        }

        let over = committed - budget
        let name = model.shortName
        let size = Format.bytes(model.sizeBytes)
        return LoadDecision(
            allowed: false,
            message:
                "Not enough RAM for \(name) (\(size) loaded, budget \(Format.bytes(over)) over). Unload a slot or pick a smaller model."
        )
    }

    static func snapshot(
        loadedModelIDs: [String],
        models: [LocalModel],
        mlxActiveBytes: Int = Memory.activeMemory,
        loadedSlotCount: Int? = nil
    ) -> Snapshot {
        let physical = physicalBytes
        let reserved = reservedBytes(total: physical)
        let budget = allowableModelBytes(total: physical)
        let committed = estimatedCommittedBytes(modelIDs: loadedModelIDs, models: models)
        let remaining = max(0, budget - committed)
        let utilization = budget > 0 ? Double(committed) / Double(budget) : 0
        let pressure: Pressure =
            if utilization >= 0.92 { .critical }
            else if utilization >= 0.78 { .tight }
            else { .comfortable }
        return Snapshot(
            physical: physical,
            reserved: reserved,
            modelsCommitted: committed,
            mlxActive: mlxActiveBytes,
            slotCount: slotCount,
            loadedSlotCount: loadedSlotCount ?? loadedModelIDs.count,
            budget: budget,
            remaining: remaining,
            utilization: utilization,
            pressure: pressure)
    }

    static func catalogTitle(_ snapshot: Snapshot) -> String {
        "Memory · \(snapshot.loadedSlotCount)/\(snapshot.slotCount) slots"
    }

    static func catalogSubtitle(_ snapshot: Snapshot) -> String {
        "\(Format.bytes(snapshot.modelsCommitted)) / \(Format.bytes(snapshot.budget)) · \(snapshot.pressure.label)"
    }

    static func catalogMenuLabel(_ snapshot: Snapshot) -> String {
        "\(catalogTitle(snapshot)) — \(catalogSubtitle(snapshot))"
    }
}