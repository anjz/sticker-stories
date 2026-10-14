import Foundation

/// Paths on the ground plane around what a walker cannot cross — water it
/// does not belong in, the planes' footprints (a tree's roots): A* on a
/// grid of the ground, then pulled straight, so a walk is a few clean
/// segments rather than a staircase.
public enum GroundPaths {
    /// The way from `a` to `b` for a walker: `[a, …, b]`. `walkable` says
    /// where it may go; `a` and `b` themselves always count as walkable (a
    /// child's sticker standing somewhere odd can still walk out). When no
    /// way exists it goes straight. `crosses`, when given, says exactly
    /// whether a straight stretch goes through what it cannot cross, which
    /// samples along it can step over (a pond's sharp corner).
    public static func path(
        from a: Vec2, to b: Vec2, walkable: @escaping (Vec2) -> Bool, crosses: ((Vec2, Vec2) -> Bool)? = nil,
        bounds: (min: Vec2, max: Vec2)
    ) -> [Vec2] {
        let span = max(bounds.max.x - bounds.min.x, bounds.max.z - bounds.min.z, 0.1)
        let cell = max(0.03, span / 140)
        let clear = { (p: Vec2, q: Vec2) -> Bool in
            let steps = max(1, Int((q - p).length / (cell * 0.5)))
            return (1..<steps).allSatisfy { i in walkable(p + (q - p) * (Double(i) / Double(steps))) }
                && crosses?(p, q) != true
        }
        if clear(a, b) { return [a, b] }

        let minX = min(bounds.min.x, a.x, b.x) - cell * 2, minZ = min(bounds.min.z, a.z, b.z) - cell * 2
        let maxX = max(bounds.max.x, a.x, b.x) + cell * 2, maxZ = max(bounds.max.z, a.z, b.z) + cell * 2
        let columns = Int(((maxX - minX) / cell).rounded(.up)) + 1
        let rows = Int(((maxZ - minZ) / cell).rounded(.up)) + 1
        let at = { (c: Int, r: Int) in Vec2(minX + Double(c) * cell, minZ + Double(r) * cell) }
        let cellOf = { (p: Vec2) in (min(max(Int(((p.x - minX) / cell).rounded()), 0), columns - 1),
                                     min(max(Int(((p.z - minZ) / cell).rounded()), 0), rows - 1)) }
        let start = cellOf(a), goal = cellOf(b)
        var open = OpenSet()
        var cost = [Double](repeating: .infinity, count: columns * rows)
        var came = [Int](repeating: -1, count: columns * rows)
        var free = [Int8](repeating: -1, count: columns * rows)  // unknown, 0 blocked, 1 walkable
        let index = { (c: Int, r: Int) in r * columns + c }
        let isFree = { (c: Int, r: Int) -> Bool in
            let i = index(c, r)
            if free[i] < 0 { free[i] = walkable(at(c, r)) ? 1 : 0 }
            return free[i] == 1
        }
        let h = { (c: Int, r: Int) in Double(abs(c - goal.0) + abs(r - goal.1)) * cell * 0.75 }
        cost[index(start.0, start.1)] = 0
        open.push(index(start.0, start.1), h(start.0, start.1))
        var found = false
        while let current = open.pop() {
            let c = current % columns, r = current / columns
            if c == goal.0 && r == goal.1 {
                found = true
                break
            }
            for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1), (1, 1), (1, -1), (-1, 1), (-1, -1)] {
                let nc = c + dc, nr = r + dr
                guard nc >= 0, nr >= 0, nc < columns, nr < rows else { continue }
                let isGoal = nc == goal.0 && nr == goal.1
                guard isGoal || isFree(nc, nr) else { continue }
                // No cutting a blocked corner diagonally.
                if dc != 0 && dr != 0, !isFree(c + dc, r) || !isFree(c, r + dr) { continue }
                let step = (dc != 0 && dr != 0 ? 1.4142 : 1) * cell
                let n = index(nc, nr)
                if cost[current] + step < cost[n] {
                    cost[n] = cost[current] + step
                    came[n] = current
                    open.push(n, cost[n] + h(nc, nr))
                }
            }
        }
        guard found else { return [a, b] }
        var cells: [Vec2] = []
        var i = index(goal.0, goal.1)
        while i >= 0 {
            cells.append(at(i % columns, i / columns))
            i = came[i]
        }
        cells.reverse()
        // Its own start and end, not the cells' centres; then pulled
        // straight: from each point, on to the furthest one in sight.
        var points = [a] + cells.dropFirst().dropLast() + [b]
        var pulled = [a]
        var from = 0
        while from < points.count - 1 {
            var to = points.count - 1
            while to > from + 1, !clear(points[from], points[to]) { to -= 1 }
            pulled.append(points[to])
            from = to
        }
        points = pulled
        return points
    }

    /// The length of a path.
    public static func length(_ path: [Vec2]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }

    /// A binary heap of grid cells by priority, smallest first.
    struct OpenSet {
        private var items: [(index: Int, priority: Double)] = []

        mutating func push(_ index: Int, _ priority: Double) {
            items.append((index, priority))
            var i = items.count - 1
            while i > 0 {
                let parent = (i - 1) / 2
                guard items[i].priority < items[parent].priority else { break }
                items.swapAt(i, parent)
                i = parent
            }
        }

        mutating func pop() -> Int? {
            guard !items.isEmpty else { return nil }
            let top = items[0].index
            let last = items.removeLast()
            if !items.isEmpty {
                items[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < items.count, items[l].priority < items[m].priority { m = l }
                    if r < items.count, items[r].priority < items[m].priority { m = r }
                    guard m != i else { break }
                    items.swapAt(i, m)
                    i = m
                }
            }
            return top
        }
    }
}
