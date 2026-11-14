import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @ObservedObject var model: SamplerModel

    var body: some View {
        ZStack {
            // Extend the current theme color through the device's safe areas,
            // while keeping the interactive drawing surface inside its safe bounds.
            Color(argb: model.backgroundARGB).ignoresSafeArea()
            SamplerSurface(model: model)
        }
        .background(AudioFilePicker(model: model).allowsHitTesting(false))
        .alert("无法导入音频", isPresented: $model.showingImportError) {
            Button("好", role: .cancel) {}
        } message: {
            Text(model.importErrorMessage)
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}


private struct AudioFilePicker: UIViewControllerRepresentable {
    let model: SamplerModel

    func makeUIViewController(context: Context) -> Presenter {
        let presenter = Presenter()
        presenter.model = model
        model.openFilePicker = { [weak presenter] in presenter?.open() ?? false }
        return presenter
    }

    func updateUIViewController(_ presenter: Presenter, context: Context) {}

    final class Presenter: UIViewController, UIDocumentPickerDelegate {
        weak var model: SamplerModel?

        func open() -> Bool {
            guard let root = viewIfLoaded?.window?.rootViewController,
                  root.viewIfLoaded?.window != nil,
                  root.presentedViewController == nil,
                  root.transitionCoordinator == nil else { return false }
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.mp3, .audio], asCopy: true)
            picker.delegate = self
            root.present(picker, animated: true)
            return true
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            model?.importSample(.success(url))
        }
    }
}
