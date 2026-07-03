//
//  CalibrationAssistantView.swift
//  Touch Up
//

import SwiftUI
import TouchUpCore

enum CalibrationAssistantResult {
    case completed(TouchCalibration)
    case cancelled
}

struct CalibrationAssistantView: View {
    @ObservedObject var model: TouchUp
    let screen: TUCScreen
    let completion: (CalibrationAssistantResult) -> Void

    @State private var targetIndex = 0
    @State private var samples = [TouchCalibrationSample]()
    @State private var sampleBuffer = [CGPoint]()
    @State private var holdStartDate: Date?
    @State private var waitingForLift = false
    @State private var errorMessage: String?
    @State private var learnedSourceIdentifiers = Set<Int>()

    private let holdDuration: TimeInterval = 0.75
    private let minimumSamples = 8
    private let movementTolerance: CGFloat = 0.055
    private let timer = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()

    private var targets: [CGPoint] {
        [
            CGPoint(x: 0.10, y: 0.10),
            CGPoint(x: 0.50, y: 0.10),
            CGPoint(x: 0.90, y: 0.10),
            CGPoint(x: 0.10, y: 0.50),
            CGPoint(x: 0.50, y: 0.50),
            CGPoint(x: 0.90, y: 0.50),
            CGPoint(x: 0.10, y: 0.90),
            CGPoint(x: 0.50, y: 0.90),
            CGPoint(x: 0.90, y: 0.90)
        ]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.07)
                    .ignoresSafeArea()

                calibrationGrid(in: geometry.size)

                targetMarker(at: currentTarget, in: geometry.size)

                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(screen.name)
                                .font(.title2)
                                .fontWeight(.semibold)
                            Text("Point \(targetIndex + 1) of \(targets.count)")
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Button("Cancel") {
                            completion(.cancelled)
                        }
                        .keyboardShortcut(.cancelAction)
                    }
                    .padding(28)

                    Spacer()

                    VStack(spacing: 10) {
                        if waitingForLift {
                            Text("Lift your finger")
                        } else if let errorMessage {
                            Text(errorMessage)
                        } else {
                            Text("Touch and hold the highlighted point")
                        }

                        ProgressView(value: progress)
                            .frame(maxWidth: 360)
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.bottom, 42)
                }
            }
        }
        .onReceive(timer) { _ in
            updateSampling()
        }
        .onChange(of: model.touches.count) { _ in
            updateSampling()
        }
    }

    private var currentTarget: CGPoint {
        targets[min(targetIndex, targets.count - 1)]
    }

    private var progress: Double {
        guard let holdStartDate, !waitingForLift else {
            return 0
        }

        return min(1, Date().timeIntervalSince(holdStartDate) / holdDuration)
    }

    private func calibrationGrid(in size: CGSize) -> some View {
        ZStack {
            ForEach(0..<targets.count, id: \.self) { index in
                let target = targets[index]
                Circle()
                    .stroke(index < targetIndex ? Color.green.opacity(0.75) : Color.white.opacity(0.18), lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .position(x: target.x * size.width, y: target.y * size.height)
            }
        }
    }

    private func targetMarker(at target: CGPoint, in size: CGSize) -> some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.24))
                .frame(width: 116, height: 116)

            Circle()
                .stroke(Color.accentColor, lineWidth: 5)
                .frame(width: 72, height: 72)

            Rectangle()
                .fill(Color.white)
                .frame(width: 2, height: 96)

            Rectangle()
                .fill(Color.white)
                .frame(width: 96, height: 2)

            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
        }
        .position(x: target.x * size.width, y: target.y * size.height)
    }

    private func updateSampling() {
        guard targetIndex < targets.count else {
            return
        }

        guard let touch = activeTouch() else {
            waitingForLift = false
            holdStartDate = nil
            sampleBuffer = []
            return
        }

        if !learnedSourceIdentifiers.contains(touch.sourceIdentifier) {
            model.learnTouchAssignment(from: touch, to: screen)
            learnedSourceIdentifiers.insert(touch.sourceIdentifier)
        }

        if waitingForLift {
            return
        }

        let rawLocation = touch.rawLocation
        guard rawLocation.x.isFinite, rawLocation.y.isFinite else {
            resetCurrentHold(message: "Touch data is invalid")
            return
        }

        if let first = sampleBuffer.first, distance(from: first, to: rawLocation) > movementTolerance {
            resetCurrentHold(message: "Hold still")
            return
        }

        errorMessage = nil
        if holdStartDate == nil {
            holdStartDate = Date()
        }

        sampleBuffer.append(rawLocation)

        if progress >= 1, sampleBuffer.count >= minimumSamples {
            acceptCurrentTarget()
        }
    }

    private func activeTouch() -> TUCTouch? {
        let activeTouches = model.touches.filter { $0.isActive() }

        if let screenTouch = activeTouches.first(where: { $0.screen?.calibrationKey == screen.calibrationKey }) {
            return screenTouch
        }

        return activeTouches.first
    }

    private func acceptCurrentTarget() {
        guard let rawPoint = stablePoint(from: sampleBuffer) else {
            resetCurrentHold(message: "Touch data is invalid")
            return
        }

        samples.append(TouchCalibrationSample(raw: rawPoint, target: currentTarget))
        holdStartDate = nil
        sampleBuffer = []

        if targetIndex == targets.count - 1 {
            guard let calibration = TouchCalibration.fittingAffine(for: screen, samples: samples) else {
                errorMessage = "Calibration failed"
                waitingForLift = false
                return
            }

            completion(.completed(calibration))
            return
        }

        targetIndex += 1
        waitingForLift = true
    }

    private func resetCurrentHold(message: String?) {
        holdStartDate = nil
        sampleBuffer = []
        errorMessage = message
    }

    private func stablePoint(from points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else {
            return nil
        }

        let sortedX = points.map(\.x).sorted()
        let sortedY = points.map(\.y).sorted()
        return CGPoint(x: median(sortedX), y: median(sortedY))
    }

    private func median(_ values: [CGFloat]) -> CGFloat {
        let mid = values.count / 2

        if values.count.isMultiple(of: 2) {
            return (values[mid - 1] + values[mid]) * 0.5
        }

        return values[mid]
    }

    private func distance(from a: CGPoint, to b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return sqrt(dx * dx + dy * dy)
    }
}
