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
    .interactiveDismissDisabled(
      recorder.isRecording
        || recorder.isStarting
        || recorder.isStopping
        || recorder.hasRecoverableRecording
        || model.isFinalizingRecording
    )
    .task {
      guard model.shouldAutoStartRecorder,
            !recorder.isRecording,
            !recorder.hasRecoverableRecording,
            !model.isFinalizingRecording
      else { return }
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
        .disabled(
          recorder.isRecording
            || recorder.isStarting
            || recorder.isStopping
            || recorder.hasRecoverableRecording
            || model.isFinalizingRecording
        )
        .accessibilityLabel("Close")

        Spacer()

        Text(recorderStatus)
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(
            recorder.isRecording || recorder.errorMessage != nil
              ? PanelTheme.coral
              : PanelTheme.secondary
          )
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
      Text("LIVE TRANSCRIPT")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(PanelTheme.tertiary)
      Spacer()
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
          }

          if !recorder.transcript.isEmpty {
            Text(recorder.transcript)
              .font(.system(size: 19, weight: .semibold))
              .foregroundStyle(PanelTheme.primary)
              .lineSpacing(7)
              .textSelection(.enabled)
          } else if recorder.errorMessage == nil {
            Text("Words from the room will appear here as the conversation unfolds.")
              .font(.system(size: 18, weight: .semibold))
              .foregroundStyle(PanelTheme.secondary)
              .lineSpacing(6)
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
      JoiAudioWaveform(
        levels: recorder.levels,
        color: PanelTheme.coral,
        isActive: recorder.isRecording
      )
        .frame(height: 36)

      Button {
        Task {
          if recorder.isRecording || recorder.hasRecoverableRecording {
            await model.finishRecording()
          } else {
            await model.startRecording()
          }
        }
      } label: {
        HStack(spacing: 10) {
          if recorder.isStarting || recorder.isStopping || model.isFinalizingRecording {
            ProgressView()
              .tint(PanelTheme.primary)
              .frame(width: 32, height: 32)
          } else {
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
          }

          Text(
            model.isFinalizingRecording
              ? "Saving meeting note"
              : recorder.isStarting
                ? "Preparing recorder"
                : recorder.isStopping
                  ? "Finishing transcript"
                  : recorder.isRecording
                    ? "Stop and save"
                    : recorder.hasRecoverableRecording
                      ? "Save partial meeting"
                      : "Start listening"
          )
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(PanelTheme.primary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(PanelTheme.sheetRaised, in: Capsule())
        .overlay { Capsule().stroke(PanelTheme.strongBorder, lineWidth: 0.5) }
      }
      .buttonStyle(.plain)
      .disabled(recorder.isStarting || recorder.isStopping || model.isFinalizingRecording)
      .accessibilityIdentifier("meeting-recorder-primary-action")
      .accessibilityLabel(
        model.isFinalizingRecording
          ? "Saving meeting note"
          : recorder.isRecording || recorder.hasRecoverableRecording
            ? "Save meeting"
            : "Start meeting recording"
      )
    }
    .padding(.horizontal, 24)
    .padding(.top, 14)
    .padding(.bottom, 22)
  }

  private var recorderStatus: String {
    if model.isFinalizingRecording { return "SAVING" }
    if recorder.isStarting { return "PREPARING" }
    if recorder.isStopping { return "FINISHING" }
    if recorder.isRecording { return "LISTENING" }
    if recorder.errorMessage != nil { return "UNAVAILABLE" }
    return "READY"
  }
}
