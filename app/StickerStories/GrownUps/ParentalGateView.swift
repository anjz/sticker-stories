import SwiftUI

/// Guideline 1.3 (Kids Category) parental gate, not passable by random
/// tapping and never remembered on disk; the only shortcut is RootView's
/// one-minute grace after a parent leaves a grown-ups section. Gates
/// everything commerce-related and the parent settings; nothing else in the
/// app leads out of the child experience. Challenge strength is a deliberate product decision — see
/// docs/compliance.md before changing it.
///
/// The challenge is three digits spelled out as words ("seven · two ·
/// four") to type on the keypad: quick for a reading adult, out of reach for
/// a pre-reader, and a random tap sequence passes one time in a thousand.
/// Three wrong answers in a row pause the gate for 20 seconds: nothing a
/// parent notices, but it stops a child button-mashing their way through.
struct ParentalGateView: View {
    let onSuccess: () -> Void
    let onCancel: () -> Void

    @Environment(\.locale) private var locale
    @State private var digits = Self.challenge()
    @State private var entry = ""
    @State private var wrongAttempt = false
    /// Mirrors `GateLockout` so the view redraws when a pause starts.
    @State private var lockedUntil = GateLockout.lockedUntil

    private var answer: String { digits.map(String.init).joined() }

    var body: some View {
        // Two columns so the whole gate fits a landscape sheet without
        // scrolling or resizing, even on iPhone.
        HStack(spacing: 44) {
            VStack(alignment: .leading, spacing: 16) {
                Text("For grown-ups")
                    .font(.title.weight(.bold))

                // Re-evaluated every second while a pause runs, so the
                // countdown ticks and the keypad comes back on its own.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    if let until = lockedUntil, until > context.date {
                        pauseMessage(remaining: until.timeIntervalSince(context.date))
                    } else {
                        challenge
                    }
                }

                Spacer(minLength: 0)

                Button("Not now", action: onCancel)
                    .font(.body.weight(.medium))
            }
            .frame(width: 300, alignment: .leading)
            .frame(maxHeight: 340)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let paused = (lockedUntil ?? .distantPast) > context.date
                digitPad
                    .disabled(paused)
                    .opacity(paused ? 0.35 : 1)
            }
        }
        .padding(30)
        .frame(maxWidth: 640)
    }

    private var challenge: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Type these numbers:")
                .font(.title3)
                .foregroundStyle(.secondary)

            // The dot keeps to the word before it, so a wrapped line never
            // starts with one.
            Text(verbatim: digits.map(spelledOut).joined(separator: "\u{00A0}· "))
                .font(.system(size: 32, weight: .bold, design: .rounded))
                // Long words ("nueve · seis · cuatro") wrap rather than shrink.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // One slot per digit: what has been typed so far.
            HStack(spacing: 10) {
                ForEach(0..<digits.count, id: \.self) { index in
                    let typed = Array(entry)
                    Text(verbatim: index < typed.count ? String(typed[index]) : " ")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 44, height: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(wrongAttempt ? Color.red : Color.secondary.opacity(0.5), lineWidth: 2))
                }
            }
            .foregroundStyle(wrongAttempt ? .red : .primary)
            .animation(.default, value: wrongAttempt)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: entry))
        }
    }

    private func pauseMessage(remaining: TimeInterval) -> some View {
        let seconds = Int(remaining.rounded(.up))
        let clock = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Too many tries.")
                .font(.title3.weight(.semibold))
            Text("Try again in \(clock)")
                .font(.title3)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
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
            guard entry.count < answer.count else { return }
            wrongAttempt = false
            entry.append("\(digit)")
            if entry.count == answer.count {
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
            GateLockout.misses = 0
            onSuccess()
            return
        }
        // Wrong: flag it and pose a fresh challenge so the digits can't be
        // brute-forced by cycling through them.
        wrongAttempt = true
        entry = ""
        digits = Self.challenge()
        GateLockout.misses += 1
        if GateLockout.misses >= GateLockout.allowedMisses {
            GateLockout.misses = 0
            GateLockout.lockedUntil = .now.addingTimeInterval(GateLockout.pause)
            lockedUntil = GateLockout.lockedUntil
            wrongAttempt = false  // the challenge after the pause starts clean
        }
    }

    /// The digit as a word in the gate's language ("seven", "siete"); the
    /// system spells it, so there is nothing to translate.
    private func spelledOut(_ digit: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .spellOut
        return formatter.string(from: digit as NSNumber) ?? String(digit)
    }

    /// Three different digits from 2–9: no 0 or 1, the easiest to guess
    /// (and "one" the easiest word to recognise).
    private static func challenge() -> [Int] {
        Array((2...9).shuffled().prefix(3))
    }
}

/// Wrong answers and the pause they earn, shared by every presentation of
/// the gate so closing and reopening it doesn't reset them. In memory only:
/// nothing about failed attempts is ever written to disk.
@MainActor
enum GateLockout {
    static let allowedMisses = 3
    static let pause: TimeInterval = 20
    static var misses = 0
    static var lockedUntil: Date?
}

#Preview {
    ParentalGateView(onSuccess: {}, onCancel: {})
}
