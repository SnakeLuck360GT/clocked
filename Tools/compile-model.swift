import CoreML
import Foundation
let src = URL(fileURLWithPath: CommandLine.arguments[1])
let dst = URL(fileURLWithPath: CommandLine.arguments[2])
let compiled = try await MLModel.compileModel(at: src)
try? FileManager.default.removeItem(at: dst)
try FileManager.default.moveItem(at: compiled, to: dst)
let m = try MLModel(contentsOf: dst)
print(m.modelDescription.outputDescriptionsByName.keys, m.modelDescription.classLabels?.count ?? -1)
print((m.modelDescription.classLabels as? [String])?.filter{$0.contains("phone")} ?? [])
