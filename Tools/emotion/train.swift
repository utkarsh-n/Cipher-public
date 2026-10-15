// The vocal emotion model: a sound classifier trained on acted emotional speech, bundled in
// the app as VocalEmotion.mlmodel and run over a take in 1.5 s windows.
//
//   swift train.swift <folder of label folders> <VocalEmotion.mlmodel>
//
// The folder holds one subfolder per label (angry, calm, disgust, fearful, happy, neutral,
// sad, surprised) of .wav clips; prepare.py builds it from RAVDESS and CREMA-D. CreateML's
// classifier sits on Apple's audio feature print, the same embedding SoundAnalysis uses, so
// the model is a few hundred kilobytes and runs on the phone without a GPU.
import CreateML
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift train.swift <data folder> <output .mlmodel>")
    exit(1)
}
let data = MLSoundClassifier.DataSource.labeledDirectories(at: URL(fileURLWithPath: arguments[1]))
var parameters = MLSoundClassifier.ModelParameters()
parameters.overlapFactor = 0.5
parameters.maxIterations = 40
let classifier = try MLSoundClassifier(trainingData: data, parameters: parameters)
print("training accuracy: \(100 - classifier.trainingMetrics.classificationError * 100)%")
print("validation accuracy: \(100 - classifier.validationMetrics.classificationError * 100)%")
let metadata = MLModelMetadata(author: "Cipher", shortDescription: "Vocal emotion from acted emotional speech (RAVDESS, CREMA-D).", version: "1")
try classifier.write(to: URL(fileURLWithPath: arguments[2]), metadata: metadata)
print("wrote \(arguments[2])")
