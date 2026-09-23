// The arithmetic the JavaScript engine does, where Swift's own differs: Math.max and Math.min
// order +0 above -0, Math.round takes halves up, Math.hypot is a scaled Kahan sum rather than
// libm's hypot, and toFixed rounds exact ties away from zero. The port is checked against the
// JavaScript to the pixel, and a difference in the last bit of any of these can move one.

@inline(__always) func jmax(_ a: Double, _ b: Double) -> Double {
    a > b ? a : b > a ? b : a == b ? (a.sign == .minus ? b : a) : .nan
}

@inline(__always) func jmin(_ a: Double, _ b: Double) -> Double {
    a < b ? a : b < a ? b : a == b ? (a.sign == .minus ? a : b) : .nan
}

@inline(__always) func jround(_ x: Double) -> Double {
    let f = x.rounded(.down), r = x - f >= 0.5 ? f + 1 : f
    return r == 0 && x < 0 ? -0.0 : r
}

@inline(__always) func jhypot(_ x: Double, _ y: Double) -> Double {
    let ax = abs(x), ay = abs(y), m = jmax(ax, ay)
    if m == 0 { return 0 }
    if m == .infinity { return .infinity }
    let a = ax / m, b = ay / m
    return (a * a + b * b).squareRoot() * m
}

@inline(__always) func jhypot(_ x: Double, _ y: Double, _ z: Double) -> Double {
    let ax = abs(x), ay = abs(y), az = abs(z), m = jmax(jmax(ax, ay), az)
    if m == 0 { return 0 }
    if m == .infinity { return .infinity }
    let a = ax / m, b = ay / m, c = az / m
    let s1 = a * a, s2 = b * b, p2 = s1 + s2, comp = (p2 - s1) - s2
    let s3 = c * c - comp
    return (p2 + s3).squareRoot() * m
}

/// `(v).toFixed(2)` as hundredths, for v in [0, 1): the nearest, and on an exact tie the larger.
func fixed2(_ v: Double) -> Int {
    // printf reads the double's exact decimal value as toFixed does, but settles an exact tie to even
    let n = Int(String(format: "%.2f", v).replacingOccurrences(of: ".", with: ""))!
    return v == 0.125 || v == 0.625 ? n + 1 : n
}

/// Math.random for a host that wants the oracle's sequence: mulberry32.
public struct Mulberry32: Sendable {
    var a: UInt32
    public init(seed: UInt32) { a = seed }
    public mutating func next() -> Double {
        a = a &+ 0x6D2B79F5
        var t = (a ^ (a >> 15)) &* (1 | a)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4294967296
    }
}
