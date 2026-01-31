import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let url: URL
    @State private var player: AVPlayer = AVPlayer()
    @Environment(\.presentationMode) var presentationMode

    var body: some View {
        VStack(spacing: 0) {
            VideoPlayer(player: player)
                .onAppear {
                    player = AVPlayer(url: url)
                    player.play()
                }
                .edgesIgnoringSafeArea(.all)

            Button(action: {
                presentationMode.wrappedValue.dismiss()
            }) {
                Text("Close")
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(25)
                    .padding()
            }
        }
    }
}

#Preview {
    VideoPlayerView(url: URL(fileURLWithPath: "/path/to/video.mp4"))
}
