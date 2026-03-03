import Foundation

enum BenchmarkBaselines {
    struct Phase2Navigation: Decodable {
        let date: String
        let commit: String
        let navigation_p95_sec: Double
    }

    struct Phase3WindowOps: Decodable {
        let date: String
        let commit: String
        let window_ops_planner_p95_sec: Double
        let window_ops_full_path_p95_sec: Double

        private enum CodingKeys: String, CodingKey {
            case date
            case commit
            case window_ops_p95_sec
            case window_ops_planner_p95_sec
            case window_ops_full_path_p95_sec
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            date = try container.decode(String.self, forKey: .date)
            commit = try container.decode(String.self, forKey: .commit)

            if let planner = try container.decodeIfPresent(Double.self, forKey: .window_ops_planner_p95_sec) {
                window_ops_planner_p95_sec = planner
            } else if let legacy = try container.decodeIfPresent(Double.self, forKey: .window_ops_p95_sec) {
                window_ops_planner_p95_sec = legacy
            } else {
                throw DecodingError.keyNotFound(
                    CodingKeys.window_ops_planner_p95_sec,
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Missing planner p95 field for phase 3 window ops baseline"
                    )
                )
            }

            guard let fullPath = try container.decodeIfPresent(Double.self, forKey: .window_ops_full_path_p95_sec) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.window_ops_full_path_p95_sec,
                    DecodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "Strict phase 3 gate requires window_ops_full_path_p95_sec"
                    )
                )
            }
            window_ops_full_path_p95_sec = fullPath
        }
    }

    private static var benchmarksDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Benchmarks")
    }

    static func loadPhase2Navigation() throws -> Phase2Navigation {
        try loadJSON(named: "phase2-navigation-baseline.json", as: Phase2Navigation.self)
    }

    static func loadPhase3WindowOps() throws -> Phase3WindowOps {
        try loadJSON(named: "phase3-window-ops-baseline.json", as: Phase3WindowOps.self)
    }

    private static func loadJSON<T: Decodable>(named name: String, as type: T.Type) throws -> T {
        let url = benchmarksDirectory.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        return try decoder.decode(T.self, from: data)
    }
}
