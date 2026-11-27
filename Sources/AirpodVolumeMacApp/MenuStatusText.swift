import Foundation

/// The two lines at the top of the menu: which AirPods, and in plain words what
/// happens to their volume.
enum MenuStatusText {
    static func lines(for status: VolumeMemoryStatus, muted: Bool) -> (title: String, detail: String) {
        guard let name = status.currentDeviceName else {
            return (
                status.primaryText.trimmingCharacters(in: CharacterSet(charactersIn: "。.")),
                status.fixedRestoreEnabled ? "连接 AirPods 后会恢复到固定音量" : "连接 AirPods 后会自动记住和恢复音量"
            )
        }
        let detail: String
        if let problem = status.problem {
            detail = problem
        } else if muted {
            detail = "已静音"
        } else if status.restoresPaused {
            detail = "自动恢复已暂停" + (status.pauseDescription.map { "，\($0)" } ?? "")
        } else if !status.automaticRestoreEnabled {
            detail = "自动恢复已关闭"
        } else if !status.deviceAutomaticRestoreEnabled {
            detail = "这副耳机未开启自动恢复"
        } else if status.isSettling {
            // Only a restore can be in progress once pause and off are ruled out.
            detail = "正在恢复音量…"
        } else if let remembered = status.rememberedVolume {
            let prefix = status.fixedRestoreEnabled ? "下次连接固定恢复到" : "下次连接时恢复到"
            detail = "\(prefix) \(Int((min(max(remembered, 0), 1) * 100).rounded()))%"
        } else {
            detail = "调整音量后会自动记住"
        }
        return (name, detail)
    }
}
