import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Pattern")
                TextField("\\d+", text: $model.pattern)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.refresh() }
                Button("Refresh") { model.refresh() }
                    .disabled(!model.ready || model.busy)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.ready ? Color.secondary : Color.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Test text").font(.headline)
                    TextEditor(text: $model.sample)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(minHeight: 110)
                        .border(Color.secondary.opacity(0.3))
                    Text("Matches").font(.headline)
                    ScrollView {
                        Text(model.matches)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 140)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Explanation").font(.headline)
                    ScrollView {
                        Text(model.explanation)
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 140)
                    Text("Railroad diagram").font(.headline)
                    if let image = model.diagram {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                    } else {
                        Text("(unavailable)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 20)

            Spacer()
        }
    }
}
