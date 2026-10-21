// Checks the hand-written network: backpropagation against finite differences, ability to learn a
// non-linear boundary, and reproducibility. Run with Tests/run.sh.
import Foundation

var failures = 0
func check(_ ok: Bool, _ message: String) {
    print((ok ? "PASS " : "FAIL ") + message)
    if !ok { failures += 1 }
}

// 1. Gradient check: analytic gradients vs. central finite differences on the loss.
do {
    var rng = SeededRandom(seed: 42)
    var net = PhoneNet(inputs: 6, seed: 3)
    let x = (0..<6).map { _ in rng.uniform(-1, 1) }
    let y: Float = 1
    var g = net.zeroGradients()
    net.accumulateGradients(x, y, weight: 1, into: &g)
    func loss(_ n: PhoneNet) -> Double {
        let p = Double(min(max(n.predict(x), 1e-6), 1 - 1e-6))
        return -(Double(y) * log(p) + (1 - Double(y)) * log(1 - p))
    }
    var worst = 0.0
    let eps: Float = 1e-2
    for l in net.layers.indices {
        for i in stride(from: 0, to: net.layers[l].weights.count, by: 7) {
            let original = net.layers[l].weights[i]
            net.layers[l].weights[i] = original + eps; let up = loss(net)
            net.layers[l].weights[i] = original - eps; let down = loss(net)
            net.layers[l].weights[i] = original
            let numeric = (up - down) / Double(2 * eps)
            let analytic = Double(g.weights[l][i])
            let relative = abs(numeric - analytic) / max(1e-4, abs(numeric) + abs(analytic))
            worst = max(worst, relative)
        }
    }
    check(worst < 0.02, String(format: "gradient check: worst relative error %.4f", worst))
}

// 2. Learns a non-linear boundary (a ring), which a single linear layer cannot.
do {
    var rng = SeededRandom(seed: 9)
    var examples: [PhoneNet.Example] = []
    for i in 0..<2000 {
        let a = rng.uniform(-1, 1), b = rng.uniform(-1, 1)
        let inside: Float = (a * a + b * b) < 0.4 ? 1 : 0
        examples.append(.init(x: [a, b], y: inside, episode: i / 20))
    }
    let (net, report) = PhoneNet.train(examples, inputs: 2)
    check(report.balancedAccuracy > 0.9, String(format: "learns a ring: balanced accuracy %.3f on held-out episodes (%d epochs, %d params)",
                                                 report.balancedAccuracy, report.epochs, net.parameterCount))

    // Cross-validation scores every example once, and stays honest when there's nothing to learn.
    let cv = PhoneNet.crossValidate(examples, inputs: 2)
    check(cv?.validationCount == examples.count && (cv?.balancedAccuracy ?? 0) > 0.9,
          String(format: "cross-validation checks all %d examples: balanced accuracy %.3f", cv?.validationCount ?? 0, cv?.balancedAccuracy ?? 0))
    let noise = (0..<600).map { i in PhoneNet.Example(x: [rng.uniform(-1, 1), rng.uniform(-1, 1)], y: Float((i / 20) % 2), episode: i / 20) }
    let noiseCV = PhoneNet.crossValidate(noise, inputs: 2)
    check((noiseCV?.balancedAccuracyLowerBound ?? 1) < 0.65,
          String(format: "random labels stay untrusted: cautious accuracy %.3f", noiseCV?.balancedAccuracyLowerBound ?? 1))
}

// 3. Reproducible: same data and seed → identical weights.
do {
    let examples = (0..<300).map { i in PhoneNet.Example(x: [Float(i % 7) / 7, Float(i % 3) / 3], y: Float(i % 2), episode: i / 10) }
    let (a, _) = PhoneNet.train(examples, inputs: 2)
    let (b, _) = PhoneNet.train(examples, inputs: 2)
    check(a.layers[0].weights == b.layers[0].weights, "training is deterministic for a given seed")
}

// 4. Attribution (Developer View): sum over inputs of d(logit)/d(standardised input) must match finite differences.
do {
    var rng = SeededRandom(seed: 11)
    let net = PhoneNet(inputs: 5, seed: 4)
    let x = (0..<5).map { _ in rng.uniform(-1, 1) }
    let a = net.attribution(x)
    func logit(_ v: [Float]) -> Double { let p = Double(net.predict(v)); return log(p / (1 - p)) }
    var worst = 0.0
    for i in 0..<5 where abs(x[i]) > 0.05 {
        var up = x, down = x
        up[i] += 1e-2; down[i] -= 1e-2
        let slope = (logit(up) - logit(down)) / 2e-2           // d(logit)/d(raw input); scale is 1 for an untrained net
        let expected = slope * Double(x[i])                    // × standardised input (mean 0, scale 1 here)
        worst = max(worst, abs(expected - Double(a[i])) / max(1e-3, abs(expected) + abs(Double(a[i]))))
    }
    check(worst < 0.02, String(format: "attribution matches finite differences: worst relative error %.4f", worst))
}

print(failures == 0 ? "All network tests passed." : "\(failures) network test(s) failed.")
exit(failures == 0 ? 0 : 1)
