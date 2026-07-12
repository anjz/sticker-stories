import SwiftUI

/// Guideline 5.1.4 parental gate, presented every time (no persistence) and
/// not passable by random tapping. Gates everything commerce-related; nothing
/// else in the app leads out of the child experience. Challenge strength is a
/// deliberate product decision — see docs/compliance.md before changing it.
struct ParentalGateView: View {
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @State private var left = Int.random(in: 2...9)
    @State private var right = Int.random(in: 2...9)
    @State private var entry = ""
    @State private var wrongAttempt = false

    private var answer: String { String(left + right) }

    var body: some View {
        // Two columns so the whole gate fits a landscape sheet without
        // scrolling or resizing, even on iPhone.
        HStack(spacing: 44) {
            VStack(alignment: .leading, spacing: 16) {
                Text("For grown-ups")
                    .font(.title.weight(.bold))
                Text("To continue, solve:")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("\(left) + \(right) = \(entry.isEmpty ? "?" : entry)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(wrongAttempt ? .red : .primary)
                    .animation(.default, value: wrongAttempt)

                Spacer(minLength: 0)

                Button("Not now", action: onCancel)
                    .font(.body.weight(.medium))
            }
            .frame(maxHeight: 300)

            digitPad
        }
        .padding(30)
        .frame(maxWidth: 640)
    }

    private var digitPad: some View {
        VStack(spacing: 10) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9]], id: \.self) { row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self, content: digitButton)
                }
            }
            HStack(spacing: 10) {
                keypadButton(systemImage: "delete.left") {
                    entry = String(entry.dropLast())
                    wrongAttempt = false
                }
                digitButton(0)
                // Layout spacer matching a key's footprint.
                Color.clear.frame(width: 72, height: 56)
            }
        }
    }

    private func digitButton(_ digit: Int) -> some View {
        keypadButton(label: "\(digit)") {
            guard entry.count < 4 else { return }
            wrongAttempt = false
            entry.append("\(digit)")
            if entry.count >= answer.count {
                checkAnswer()
            }
        }
    }

    private func keypadButton(
        label: String? = nil, systemImage: String? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if let label {
                    Text(label).font(.title2.weight(.semibold))
                } else if let systemImage {
                    Image(systemName: systemImage).font(.title3.weight(.semibold))
                }
            }
            .frame(width: 72, height: 56)
            .background(RoundedRectangle(cornerRadius: 12).fill(.quaternary))
        }
        .buttonStyle(.plain)
    }

    private func checkAnswer() {
        if entry == answer {
            onSuccess()
        } else {
            // Wrong: flag it and pose a fresh question so the numbers can't
            // be brute-forced by cycling digits.
            wrongAttempt = true
            entry = ""
            left = Int.random(in: 2...9)
            right = Int.random(in: 2...9)
        }
    }
}

#Preview {
    ParentalGateView(onSuccess: {}, onCancel: {})
}
