import Foundation

/// A small fully connected neural network that estimates the probability you're on your phone from one
/// second of features (see `LearningFeatures`). Inputs → 16 tanh → 8 tanh → 1 sigmoid, about 600 weights.
///
/// Written out by hand (no frameworks) so every step is inspectable: standardised inputs, Xavier
/// initialisation, class-weighted binary cross-entropy, Adam, L2 weight decay, early stopping on a
/// held-out set of whole episodes.
struct PhoneNet: Codable {
    struct Layer: Codable {
        var inputs: Int
        var outputs: Int
        var weights: [Float]   // outputs × inputs, row-major
        var biases: [Float]

        init(inputs: Int, outputs: Int, rng: inout SeededRandom) {
            self.inputs = inputs
            self.outputs = outputs
            let limit = (6 / Float(inputs + outputs)).squareRoot() // Xavier/Glorot uniform
            weights = (0..<(inputs * outputs)).map { _ in rng.uniform(-limit, limit) }
            biases = Array(repeating: 0, count: outputs)
        }

        func forward(_ x: [Float]) -> [Float] {
            var out = biases
            for o in 0..<outputs {
                let row = o * inputs
                var sum = out[o]
                for i in 0..<inputs { sum += weights[row + i] * x[i] }
                out[o] = sum
            }
            return out
        }
    }

    var layers: [Layer]
    /// Per-feature standardisation learned from the training data.
    var mean: [Float]
    var scale: [Float]

    init(inputs: Int, hidden: [Int] = [16, 8], seed: UInt64 = 1) {
        var rng = SeededRandom(seed: seed)
        let sizes = [inputs] + hidden + [1]
        layers = []
        for i in 0..<(sizes.count - 1) {
            layers.append(Layer(inputs: sizes[i], outputs: sizes[i + 1], rng: &rng))
        }
        mean = Array(repeating: 0, count: inputs)
        scale = Array(repeating: 1, count: inputs)
    }

    var parameterCount: Int { layers.reduce(0) { $0 + $1.weights.count + $1.biases.count } }

    // MARK: Inference

    func predict(_ raw: [Float]) -> Float {
        var a = standardise(raw)
        for (index, layer) in layers.enumerated() {
            let z = layer.forward(a)
            a = index == layers.count - 1 ? z.map(sigmoid) : z.map(tanhf)
        }
        return a[0]
    }

    /// How much each input pushed this prediction, in log-odds: d(logit)/d(input) × standardised input.
    /// Positive = towards "on phone". Used by the Developer View.
    func attribution(_ raw: [Float]) -> [Float] {
        let x = standardise(raw)
        var activations = [x]
        for (index, layer) in layers.enumerated() where index < layers.count - 1 {
            activations.append(layer.forward(activations.last!).map(tanhf))
        }
        var delta: [Float] = [1] // d(logit)/d(logit)
        for l in stride(from: layers.count - 1, through: 0, by: -1) {
            let layer = layers[l]
            var previous = Array(repeating: Float(0), count: layer.inputs)
            for i in 0..<layer.inputs {
                var sum: Float = 0
                for o in 0..<layer.outputs { sum += layer.weights[o * layer.inputs + i] * delta[o] }
                previous[i] = l > 0 ? sum * (1 - activations[l][i] * activations[l][i]) : sum
            }
            delta = previous
        }
        return zip(delta, x).map { $0 * $1 }
    }

    private func standardise(_ x: [Float]) -> [Float] {
        zip(zip(x, mean), scale).map { ($0.0 - $0.1) / $1 }
    }

    // MARK: Training

    struct Example {
        var x: [Float]
        var y: Float
        /// Samples from the same episode are kept together when splitting train/validation,
        /// since neighbouring seconds are near-duplicates and would make validation look better than it is.
        var episode: Int
    }

    struct Options {
        var learningRate: Float = 0.01
        var weightDecay: Float = 1e-4
        var batchSize = 32
        var maxEpochs = 80
        var patience = 10
        var validationShare = 0.2
        var seed: UInt64 = 7
        var hidden = [16, 8]
    }

    struct Report: Codable, Equatable {
        var trainCount = 0
        var validationCount = 0
        var positives = 0
        var negatives = 0
        var epochs = 0
        var trainLoss: Float = 0
        var validationLoss: Float = 0
        /// Mean of the true-positive and true-negative rates at a 0.5 threshold (robust to class imbalance).
        var balancedAccuracy: Float = 0
        var precision: Float = 0
        var recall: Float = 0
        var validationPositives = 0
        var validationNegatives = 0
        var trainPositives = 0
        var trainNegatives = 0
        /// Balanced accuracy minus one standard error per class: a pessimistic estimate, so a small lucky
        /// validation set can't give the network more say than it has earned.
        var balancedAccuracyLowerBound: Float = 0
        var date = Date()
        /// Set when the accuracy figures come from cross-validation: every example predicted by a network
        /// trained without its episode (nil in reports saved by older versions).
        var folds: Int?
    }

    /// Splits whole episodes into `folds` groups (both classes spread across them), trains one network per
    /// group without it, and scores every example with the network that never saw its episode. Much steadier
    /// than one small held-out set. Nil if there aren't at least two episodes of each class.
    static func crossValidate(_ examples: [Example], inputs: Int, options: Options = Options(), folds k: Int = 5) -> Report? {
        var episodeLabel: [Int: Float] = [:]
        for e in examples { episodeLabel[e.episode, default: 0] += e.y > 0.5 ? 1 : -1 }
        var positive = episodeLabel.filter { $0.value > 0 }.map(\.key).sorted()
        var negative = episodeLabel.filter { $0.value <= 0 }.map(\.key).sorted()
        guard positive.count >= 2, negative.count >= 2 else { return nil }
        var rng = SeededRandom(seed: options.seed &+ 99)
        rng.shuffle(&positive); rng.shuffle(&negative)
        let k = min(k, max(positive.count, negative.count))
        var fold: [Int: Int] = [:]
        for (i, e) in positive.enumerated() { fold[e] = i % k }
        for (i, e) in negative.enumerated() { fold[e] = (i + 1) % k }

        var tp = 0, tn = 0, fp = 0, fn = 0
        for f in 0..<k {
            let train = examples.filter { fold[$0.episode] != f }
            let test = examples.filter { fold[$0.episode] == f }
            guard !test.isEmpty, train.contains(where: { $0.y > 0.5 }), train.contains(where: { $0.y <= 0.5 }) else { continue }
            let (net, _) = PhoneNet.train(train, inputs: inputs, options: options)
            for e in test {
                switch (net.predict(e.x) >= 0.5, e.y > 0.5) {
                case (true, true): tp += 1
                case (false, false): tn += 1
                case (true, false): fp += 1
                case (false, true): fn += 1
                }
            }
        }
        guard tp + fn > 0, tn + fp > 0 else { return nil }
        var report = Report(tp: tp, tn: tn, fp: fp, fn: fn)
        report.validationCount = tp + tn + fp + fn
        report.folds = k
        return report
    }

    /// Trains from scratch on `examples` and returns the best weights seen on the validation episodes.
    static func train(_ examples: [Example], inputs: Int, options: Options = Options()) -> (PhoneNet, Report) {
        var rng = SeededRandom(seed: options.seed)

        // Split by episode, separately for "phone" and "not phone" episodes so both classes are always validated.
        var episodeLabel: [Int: Float] = [:]
        for e in examples { episodeLabel[e.episode, default: 0] += e.y > 0.5 ? 1 : -1 }
        var validationEpisodes = Set<Int>()
        for positive in [true, false] {
            var group = episodeLabel.filter { ($0.value > 0) == positive }.map(\.key).sorted()
            // A class with a single episode stays in training; there's nothing to spare for validation.
            guard group.count >= 2 else { continue }
            rng.shuffle(&group)
            validationEpisodes.formUnion(group.prefix(max(1, Int(Double(group.count) * options.validationShare))))
        }
        var train = examples.filter { !validationEpisodes.contains($0.episode) }
        var validation = examples.filter { validationEpisodes.contains($0.episode) }
        if train.isEmpty || validation.isEmpty { // too few episodes: fall back to a random split
            var all = examples
            rng.shuffle(&all)
            let cut = Int(Double(all.count) * (1 - options.validationShare))
            train = Array(all[..<cut])
            validation = Array(all[cut...])
        }

        var net = PhoneNet(inputs: inputs, hidden: options.hidden, seed: options.seed)
        net.fitStandardisation(train.map(\.x))

        // Class weights so the rarer class (usually "on phone") counts as much as the common one.
        let positives = Float(train.filter { $0.y > 0.5 }.count)
        let negatives = Float(train.count) - positives
        let positiveWeight = positives > 0 ? min(max(negatives / positives, 0.2), 5) : 1

        var adam = Adam(for: net, learningRate: options.learningRate)
        var best = net
        var bestLoss = Float.infinity
        var sinceBest = 0
        var epochs = 0
        var trainLoss: Float = 0
        var bestEpoch = 0, bestTrainLoss: Float = 0

        for epoch in 0..<options.maxEpochs {
            epochs = epoch + 1
            rng.shuffle(&train)
            trainLoss = 0
            var start = 0
            while start < train.count {
                let batch = train[start..<min(start + options.batchSize, train.count)]
                start += options.batchSize
                var gradients = net.zeroGradients()
                for example in batch {
                    let weight = example.y > 0.5 ? positiveWeight : 1
                    trainLoss += net.accumulateGradients(example.x, example.y, weight: weight, into: &gradients)
                }
                adam.step(&net, gradients: gradients, batchSize: batch.count, weightDecay: options.weightDecay)
            }
            trainLoss /= Float(max(train.count, 1))

            let loss = net.loss(on: validation, positiveWeight: positiveWeight)
            if loss < bestLoss - 1e-4 {
                bestLoss = loss
                best = net
                bestEpoch = epoch + 1
                bestTrainLoss = trainLoss
                sinceBest = 0
            } else {
                sinceBest += 1
                if sinceBest >= options.patience { break }
            }
        }

        var report = best.evaluate(validation)
        report.trainCount = train.count
        report.validationCount = validation.count
        report.positives = examples.filter { $0.y > 0.5 }.count
        report.negatives = examples.count - report.positives
        report.trainPositives = train.filter { $0.y > 0.5 }.count
        report.trainNegatives = train.count - report.trainPositives
        report.epochs = epochs > 0 ? bestEpoch : 0  // the epoch whose weights were kept
        report.trainLoss = bestTrainLoss
        report.validationLoss = bestLoss
        _ = trainLoss
        return (best, report)
    }

    private mutating func fitStandardisation(_ xs: [[Float]]) {
        guard let width = xs.first?.count else { return }
        for i in 0..<width {
            let column = xs.map { $0[i] }
            let m = column.reduce(0, +) / Float(column.count)
            let variance = column.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(column.count)
            mean[i] = m
            scale[i] = max(variance.squareRoot(), 1e-3)
        }
    }

    func loss(on examples: [Example], positiveWeight: Float) -> Float {
        guard !examples.isEmpty else { return .infinity }
        var total: Float = 0
        for e in examples {
            let p = min(max(predict(e.x), 1e-6), 1 - 1e-6)
            let w = e.y > 0.5 ? positiveWeight : 1
            total += -w * (e.y * logf(p) + (1 - e.y) * logf(1 - p))
        }
        return total / Float(examples.count)
    }

    func evaluate(_ examples: [Example]) -> Report {
        var tp = 0, tn = 0, fp = 0, fn = 0
        for e in examples {
            let predicted = predict(e.x) >= 0.5
            switch (predicted, e.y > 0.5) {
            case (true, true): tp += 1
            case (false, false): tn += 1
            case (true, false): fp += 1
            case (false, true): fn += 1
            }
        }
        return Report(tp: tp, tn: tn, fp: fp, fn: fn)
    }
}

extension PhoneNet.Report {
    /// Accuracy figures from a confusion matrix at a 0.5 threshold.
    init(tp: Int, tn: Int, fp: Int, fn: Int) {
        var r = PhoneNet.Report()
        let tpr = tp + fn > 0 ? Float(tp) / Float(tp + fn) : 0
        let tnr = tn + fp > 0 ? Float(tn) / Float(tn + fp) : 0
        r.balancedAccuracy = (tpr + tnr) / 2
        r.validationPositives = tp + fn
        r.validationNegatives = tn + fp
        func standardError(_ rate: Float, _ n: Int) -> Float { n > 0 ? (rate * (1 - rate) / Float(n)).squareRoot() + 1 / Float(n) : 1 }
        r.balancedAccuracyLowerBound = ((tpr - standardError(tpr, tp + fn)) + (tnr - standardError(tnr, tn + fp))) / 2
        r.recall = tpr
        r.precision = tp + fp > 0 ? Float(tp) / Float(tp + fp) : 0
        self = r
    }
}

extension PhoneNet {

    // MARK: Backpropagation

    struct Gradients {
        var weights: [[Float]]
        var biases: [[Float]]
    }

    func zeroGradients() -> Gradients {
        Gradients(weights: layers.map { Array(repeating: 0, count: $0.weights.count) },
                  biases: layers.map { Array(repeating: 0, count: $0.biases.count) })
    }

    /// Forward + backward pass for one example. Adds dLoss/dParameter into `g` and returns the (weighted) loss.
    @discardableResult
    func accumulateGradients(_ raw: [Float], _ y: Float, weight: Float, into g: inout Gradients) -> Float {
        // Forward, keeping every layer's input and output.
        var activations = [standardise(raw)]
        for (index, layer) in layers.enumerated() {
            let z = layer.forward(activations.last!)
            activations.append(index == layers.count - 1 ? z.map(sigmoid) : z.map(tanhf))
        }
        let p = min(max(activations.last![0], 1e-6), 1 - 1e-6)
        let loss = -weight * (y * logf(p) + (1 - y) * logf(1 - p))

        // Sigmoid + cross-entropy: dL/dz = weight · (p − y).
        var delta: [Float] = [weight * (p - y)]
        for l in stride(from: layers.count - 1, through: 0, by: -1) {
            let layer = layers[l]
            let input = activations[l]
            for o in 0..<layer.outputs {
                g.biases[l][o] += delta[o]
                let row = o * layer.inputs
                for i in 0..<layer.inputs { g.weights[l][row + i] += delta[o] * input[i] }
            }
            guard l > 0 else { break }
            // Back through the weights, then through tanh (d tanh = 1 − a²).
            var previous = Array(repeating: Float(0), count: layer.inputs)
            for i in 0..<layer.inputs {
                var sum: Float = 0
                for o in 0..<layer.outputs { sum += layer.weights[o * layer.inputs + i] * delta[o] }
                let a = input[i]
                previous[i] = sum * (1 - a * a)
            }
            delta = previous
        }
        return loss
    }
}

/// Adam optimiser state (first and second moment estimates per parameter).
struct Adam {
    var learningRate: Float
    var beta1: Float = 0.9
    var beta2: Float = 0.999
    var epsilon: Float = 1e-8
    private var t: Float = 0
    private var mW: [[Float]], vW: [[Float]], mB: [[Float]], vB: [[Float]]

    init(for net: PhoneNet, learningRate: Float) {
        self.learningRate = learningRate
        let zeros = net.zeroGradients()
        mW = zeros.weights; vW = zeros.weights
        mB = zeros.biases; vB = zeros.biases
    }

    mutating func step(_ net: inout PhoneNet, gradients g: PhoneNet.Gradients, batchSize: Int, weightDecay: Float) {
        t += 1
        let n = Float(batchSize)
        let correction1 = 1 - powf(beta1, t), correction2 = 1 - powf(beta2, t)
        for l in net.layers.indices {
            for i in net.layers[l].weights.indices {
                let grad = g.weights[l][i] / n + weightDecay * net.layers[l].weights[i]
                mW[l][i] = beta1 * mW[l][i] + (1 - beta1) * grad
                vW[l][i] = beta2 * vW[l][i] + (1 - beta2) * grad * grad
                net.layers[l].weights[i] -= learningRate * (mW[l][i] / correction1) / ((vW[l][i] / correction2).squareRoot() + epsilon)
            }
            for i in net.layers[l].biases.indices {
                let grad = g.biases[l][i] / n
                mB[l][i] = beta1 * mB[l][i] + (1 - beta1) * grad
                vB[l][i] = beta2 * vB[l][i] + (1 - beta2) * grad * grad
                net.layers[l].biases[i] -= learningRate * (mB[l][i] / correction1) / ((vB[l][i] / correction2).squareRoot() + epsilon)
            }
        }
    }
}

/// Small deterministic PRNG (SplitMix64) so training runs are reproducible.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ low: Float, _ high: Float) -> Float {
        low + (high - low) * Float(next() >> 40) / Float(1 << 24)
    }

    mutating func shuffle<T>(_ array: inout [T]) {
        guard array.count > 1 else { return }
        for i in stride(from: array.count - 1, to: 0, by: -1) {
            let j = Int(next() % UInt64(i + 1))
            array.swapAt(i, j)
        }
    }
}

@inline(__always) func sigmoid(_ x: Float) -> Float { 1 / (1 + expf(-x)) }
