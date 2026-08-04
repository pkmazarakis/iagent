import SwiftUI

struct MeetingRecorderView: View {
  @ObservedObject var model: MobileAppModel
  @ObservedObject private var recorder: MobileMeetingRecorder

  init(model: MobileAppModel) {
    self.model = model
    _recorder = ObservedObject(wrappedValue: model.recorder)
  }

  var body: some View {
    PanelScreen {
      VStack(spacing: 0) {
        hero
          .frame(height: 250, alignment: .top)

        JoiTimelineSheet(minHeight: 0) {
          VStack(spacing: 0) {
            transcriptHeader
            JoiDottedDivider(inset: 24)
            transcript
            JoiDottedDivider(inset: 24)
            controls
          }
        }
        .frame(maxHeight: .infinity)
      }
    }
    .preferredColorScheme(.dark)
    .interactiveDismissDisabled(recorder.isRecording)
    .task {
      guard model.lastRecordedNote == nil, !recorder.isRecording else { return }
      await model.startRecording()
    }
  }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Button { model.dismissRecorder() } label: {
          Image(systemName: "xmark")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(PanelTheme.primary)
            .frame(width: 40, height: 40)
            .background(PanelTheme.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")

        Spacer()

        Text(recorder.isRecording ? "LISTENING" : model.lastRecordedNote == nil ? "READY" : "SAVED")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(recorder.isRecording ? PanelTheme.coral : PanelTheme.secondary)
      }

      Spacer(minLength: 24)

      HStack(alignment: .lastTextBaseline, spacing: 9) {
        Text(recorder.elapsedText)
          .font(.system(size: 50, weight: .bold))
          .foregroundStyle(PanelTheme.primary)
          .monospacedDigit()
          .contentTransition(.numericText(countsDown: false))

        Circle()
          .fill(recorder.isRecording ? PanelTheme.coral : PanelTheme.tertiary)
          .frame(width: 12, height: 12)
          .padding(.bottom, 6)
      }

      Text(model.activeMeetingTitle)
        .font(.system(size: 19, weight: .semibold))
        .foregroundStyle(PanelTheme.secondary)
        .lineLimit(1)
        .padding(.top, 4)

      Spacer(minLength: 18)
    }
    .padding(.horizontal, PanelTheme.horizontalPadding)
    .padding(.top, 10)
  }

  private var transcriptHeader: some View {
    HStack {
      Text(model.lastRecordedNote == nil ? "LIVE TRANSCRIPT" : "MEETING NOTE")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(PanelTheme.tertiary)
      Spacer()
      if model.lastRecordedNote != nil {
        Label("Saved", systemImage: "checkmark")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(PanelTheme.green)
      }
    }
    .padding(.horizontal, 24)
    .frame(height: 48)
  }

  private var transcript: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          if let error = recorder.errorMessage {
            Text(error)
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(PanelTheme.coral)
              .lineSpacing(5)
          } else if let note = model.lastRecordedNote {
            Text(note.body)
              .font(.system(size: 17, weight: .medium))
              .foregroundStyle(PanelTheme.primary)
              .lineSpacing(6)
              .textSelection(.enabled)
          } else if recorder.transcript.isEmpty {
            Text("Words from the room will appear here as the conversation unfolds.")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(PanelTheme.secondary)
              .lineSpacing(6)
          } else {
            Text(recorder.transcript)
              .font(.system(size: 19, weight: .semibold))
              .foregroundStyle(PanelTheme.primary)
              .lineSpacing(7)
              .textSelection(.enabled)
          }

          Color.clear.frame(height: 1).id("latest")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .onChange(of: recorder.transcript) { _, _ in
        withAnimation(PanelTheme.quick) { proxy.scrollTo("latest", anchor: .bottom) }
      }
    }
  }

  private var controls: some View {
    VStack(spacing: 14) {
      JoiRecorderWaveform(levels: recorder.levels, isActive: recorder.isRecording)
        .frame(height: 36)

      if model.lastRecordedNote != nil {
        Button {
          model.dismissRecorder()
          model.selectedTab = .notes
        } label: {
          Text("Open note")
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(PanelTheme.primary, in: Capsule())
        }
        .buttonStyle(.plain)
      } else {
        Button {
          Task {
            if recorder.isRecording {
              await model.finishRecording()
            } else {
              await model.startRecording()
            }
          }
        } label: {
          HStack(spacing: 10) {
            ZStack {
              Circle()
                .fill(PanelTheme.coral)
                .frame(width: 32, height: 32)
              if recorder.isRecording {
                RoundedRectangle(cornerRadius: 2)
                  .fill(.white)
                  .frame(width: 10, height: 10)
              } else {
                Circle().fill(.white).frame(width: 11, height: 11)
              }
            }

            Text(recorder.isRecording ? "Stop and save" : "Start listening")
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(PanelTheme.primary)
          }
          .frame(maxWidth: .infinity)
          .frame(height: 48)
          .background(PanelTheme.sheetRaised, in: Capsule())
          .overlay { Capsule().stroke(PanelTheme.strongBorder, lineWidth: 0.5) }
        }
        .buttonStyle(.plain)
      }
    }
    .padding(.horizontal, 24)
    .padding(.top, 14)
    .padding(.bottom, 22)
  }
}

private struct JoiRecorderWaveform: View {
  let levels: [CGFloat]
  let isActive: Bool

  var body: some View {
    Canvas { context, size in
      let count = max(1, levels.count)
      let stride = size.width / CGFloat(count)
      let width = max(1.2, min(2.2, stride * 0.42))
      for (index, level) in levels.enumerated() {
        let normalized = isActive ? max(0.05, min(1, level)) : 0.05
        let height = max(2, normalized * size.height)
        let rect = CGRect(
          x: CGFloat(index) * stride + (stride - width) / 2,
          y: (size.height - height) / 2,
          width: width,
          height: height
        )
        context.fill(
          Path(roundedRect: rect, cornerRadius: width / 2),
          with: .color(isActive ? PanelTheme.coral.opacity(0.86) : PanelTheme.tertiary)
        )
      }
    }
    .accessibilityLabel(isActive ? "Live microphone level" : "Recorder idle")
  }
}
