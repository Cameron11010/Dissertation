import SwiftUI
import PhotosUI
import AVFoundation

struct PickedVideo: Identifiable {
    let id = UUID()
    let url: URL
}

struct ContentView: View {
    @State private var selectedItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var lastVideoURL: URL?
    @State private var lastVideoThumbnail: UIImage?
    @State private var showingLastVideo = false
    @State private var currentVideoURL: URL? // Video to send to CameraView
    @State private var isRecordingLive = false // Track live recording
    @State private var pickedVideo: PickedVideo?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                VStack(spacing: geo.size.height * 0.02) {
                    // Take live video
                    Button("Take Video") {
                        currentVideoURL = nil
                        showingCamera = true
                    }
                    .font(.headline)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(geo.size.height * 0.03)
                    
                    // Select video from library
                    PhotosPicker(selection: $selectedItem,
                                 matching: .videos,
                                 photoLibrary: .shared()) {
                        Text("Select Video")
                            .font(.headline)
                            .padding()
                            .frame(maxWidth: .infinity)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .cornerRadius(geo.size.height * 0.03)
                    }
                    
                    Spacer()
                }
                .padding()
                
                // Floating thumbnail for last video
                if let thumbnail = lastVideoThumbnail {
                    VStack {
                        HStack {
                            Spacer()
                            ZStack(alignment: .topTrailing) {
                                Button(action: { showingLastVideo = true }) {
                                    Image(uiImage: thumbnail)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: geo.size.width * 0.18, height: geo.size.width * 0.18)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white, lineWidth: 2))
                                }
                                
                                // Dynamic recording indicator
                                if isRecordingLive {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: geo.size.width * 0.05, height: geo.size.width * 0.05)
                                        .offset(x: geo.size.width * 0.02, y: -geo.size.width * 0.02)
                                        .shadow(radius: 2)
                                }
                            }
                            .padding(.trailing, geo.safeAreaInsets.trailing + 10)
                            .padding(.top, geo.safeAreaInsets.top + 10)
                        }
                        Spacer()
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $showingCamera, onDismiss: {
            print("showingCamera fullScreenCover dismissed")
        }) {
            CameraView(
                onVideoSaved: { url in
                    lastVideoURL = url
                    Task {
                        let thumb = await generateThumbnail(url: url)
                        await MainActor.run { lastVideoThumbnail = thumb }
                    }
                },
                videoURL: currentVideoURL,
                isRecordingLive: $isRecordingLive
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(item: $pickedVideo, onDismiss: {
            print("PickedVideo fullScreenCover dismissed")
        }) { item in
            CameraView(
                onVideoSaved: nil,
                videoURL: item.url,
                isRecordingLive: .constant(false)
            )
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showingLastVideo, onDismiss: {
            print("showingLastVideo fullScreenCover dismissed")
        }) {
            if let url = lastVideoURL {
                CameraView(
                    onVideoSaved: nil,
                    videoURL: url,
                    isRecordingLive: .constant(false)
                )
                .ignoresSafeArea()
            }
        }
        .onChange(of: selectedItem) { oldItem, newItem in
            print("onChange(selectedItem): \(String(describing: newItem))")
            Task { await loadSelectedVideo(newItem) }
        }
        .onAppear {
            print("ContentView appeared")
        }
    }
    
    // MARK: - Load selected video from PhotosPicker
    private func loadSelectedVideo(_ item: PhotosPickerItem?) async {
        print("loadSelectedVideo: selection changed -> \(String(describing: item))")
        guard let item = item else { return }

        func copyToStableTemp(from sourceURL: URL) throws -> URL {
            let ext = sourceURL.pathExtension.isEmpty ? "mp4" : sourceURL.pathExtension
            let destURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: destURL.path) {
                try FileManager.default.removeItem(at: destURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return destURL
        }

        do {
            var finalURL: URL?

            // Preferred: SwiftUI Transferable URL
            if let url = try await item.loadTransferable(type: URL.self) {
                print("loadSelectedVideo: got URL via Transferable -> \(url)")
                do {
                    finalURL = try copyToStableTemp(from: url)
                } catch {
                    print("Copy to temp failed (Transferable URL): \(error). Using original URL.")
                    finalURL = url
                }
            }

            // Fallback: Load raw Data and write to a temp file
            if finalURL == nil {
                if let data = try await item.loadTransferable(type: Data.self) {
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "mov"
                    let tempURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(ext)
                    do {
                        try data.write(to: tempURL, options: .atomic)
                        finalURL = tempURL
                        print("loadSelectedVideo: wrote Data fallback to temp -> \(tempURL)")
                    } catch {
                        print("Failed writing Data fallback to temp: \(error)")
                    }
                } else {
                    print("loadSelectedVideo: Data fallback returned nil")
                }
            }

            guard let resolvedURL = finalURL else {
                print("loadSelectedVideo: failed to resolve a URL for picked video")
                return
            }

            await MainActor.run {
                currentVideoURL = resolvedURL // compatibility
                pickedVideo = PickedVideo(url: resolvedURL) // triggers fullScreenCover(item:)
                selectedItem = nil
                print("loadSelectedVideo: presenting CameraView with URL -> \(resolvedURL)")
            }
        } catch {
            print("Error loading selected video: \(error)")
        }
    }
    
    // MARK: - Generate thumbnail
    private func generateThumbnail(url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 300, height: 300)
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        
        if #available(iOS 18.0, *) {
            return await withCheckedContinuation { continuation in
                generator.generateCGImageAsynchronously(for: time) { cgImage, _, _ in
                    if let cgImage = cgImage { continuation.resume(returning: UIImage(cgImage: cgImage)) }
                    else { continuation.resume(returning: nil) }
                }
            }
        } else {
            return await withCheckedContinuation { continuation in
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, cgImage, _, _, _ in
                    if let cgImage = cgImage { continuation.resume(returning: UIImage(cgImage: cgImage)) }
                    else { continuation.resume(returning: nil) }
                }
            }
        }
    }
}

