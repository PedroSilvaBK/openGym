import Foundation

// What the phone sends (frontend/src/lib/watch-snapshot.js). Keys the phone leaves out (it never
// sends null) decode as nil.
struct Snapshot: Codable, Equatable {
    var v: Int
    var unit: String
    var today: Today?
    var routines: [Routine]
    var active: Active?
    var rest: Rest?

    struct Today: Codable, Equatable {
        var ids: [String]
        var name: String
    }

    struct Routine: Codable, Equatable, Identifiable {
        var id: String
        var name: String
    }

    struct Active: Codable, Equatable {
        var id: String
        var name: String
        var start: Double
        var done: Int
        var total: Int
        var next: Next?

        var startDate: Date { Date(timeIntervalSince1970: start / 1000) }
    }

    struct Next: Codable, Equatable {
        // The exercise's catalogue id (absent from a phone app older than the recorder).
        var exId: String?
        var idx: Int
        var i: Int
        var exercise: String
        var set: Int
        var sets: Int
        var mode: String
        var reps: Double
        var w: Double
        var sec: Double
        var min: Double
        var warmup: Bool
        var side: String?
        var restAfter: Double
    }

    struct Rest: Codable, Equatable {
        var endsAt: Double
        var total: Double
        var paused: Bool
        var left: Double
        var kind: String

        var endDate: Date { Date(timeIntervalSince1970: endsAt / 1000) }
    }

    static func decode(_ any: Any?) -> Snapshot? {
        guard let dict = any as? [String: Any],
              JSONSerialization.isValidJSONObject(dict),
              let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

extension Snapshot.Next {
    // "8 × 60 kg", "45 s", "20 min", "8 reps" — what to do, in the phone's unit.
    func target(unit: String) -> String {
        let num: (Double) -> String = { v in v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v) }
        switch mode {
        case "time":
            let hold = "\(num(sec)) s"
            return w > 0 ? "\(hold) · \(num(w)) \(unit)" : hold
        case "cardio":
            return "\(num(min)) min"
        default:
            if w > 0 { return "\(num(reps)) × \(num(w)) \(unit)" }
            return "\(num(reps)) reps"
        }
    }
}
