import Foundation

public enum TimecodeFormatter {
    public static func srt(_ seconds: TimeInterval) -> String {
        format(seconds, millisecondSeparator: ",")
    }

    public static func vtt(_ seconds: TimeInterval) -> String {
        format(seconds, millisecondSeparator: ".")
    }

    public static func appleMusicTTML(_ seconds: TimeInterval) -> String {
        let clampedMilliseconds = max(0, Int((seconds * 1000).rounded()))
        let milliseconds = clampedMilliseconds % 1000
        let totalSeconds = clampedMilliseconds / 1000
        let secs = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, secs, milliseconds)
        }

        return String(format: "%02d:%02d.%03d", totalMinutes, secs, milliseconds)
    }

    public static func compact(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        let totalSeconds = Int(clamped)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }

        return String(format: "%d:%02d", minutes, secs)
    }

    private static func format(_ seconds: TimeInterval, millisecondSeparator: String) -> String {
        let clampedMilliseconds = max(0, Int((seconds * 1000).rounded()))
        let milliseconds = clampedMilliseconds % 1000
        let totalSeconds = clampedMilliseconds / 1000
        let secs = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minutes = totalMinutes % 60
        let hours = totalMinutes / 60

        return String(
            format: "%02d:%02d:%02d%@%03d",
            hours,
            minutes,
            secs,
            millisecondSeparator,
            milliseconds
        )
    }
}
