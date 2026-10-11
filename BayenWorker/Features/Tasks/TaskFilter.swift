import Foundation

/// Status filter of "My tasks": the states selected in the summary bar. Nothing selected shows everything.
enum TaskFilter {
    /// Tasks whose section is in `selected`, in their original order. An empty selection keeps every task.
    /// - Parameter status: the status to judge a task by (the list uses the one including work queued on the device).
    static func apply(_ tasks: [WorkerTask], selected: Set<TaskSection>,
                      status: (WorkerTask) -> TaskStatus = { $0.status }) -> [WorkerTask] {
        guard !selected.isEmpty else { return tasks }
        return tasks.filter { task in
            guard let section = TaskSection.of(status(task)) else { return false }
            return selected.contains(section)
        }
    }

    /// Number of tasks per section over *all* tasks — the figures in the bar do not follow the filter.
    static func counts(_ tasks: [WorkerTask], status: (WorkerTask) -> TaskStatus = { $0.status }) -> [TaskSection: Int] {
        tasks.reduce(into: [:]) { counts, task in
            if let section = TaskSection.of(status(task)) { counts[section, default: 0] += 1 }
        }
    }

    static func toggling(_ section: TaskSection, in selected: Set<TaskSection>) -> Set<TaskSection> {
        var result = selected
        if result.remove(section) == nil { result.insert(section) }
        return result
    }
}
