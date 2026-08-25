# Baseball Image Classifier

An earlier iteration of the baseball-tracking pipeline: instead of a custom-trained model, this version runs stock YOLOv8n (pretrained on COCO) over a video feed and filters its output down to the three baseball-relevant classes — `sports ball`, `baseball bat`, `baseball glove`.

## Files

```
main.py            Runs YOLOv8n over a video/webcam feed, draws boxes only for the allowed classes
export.py           Exports YOLOv8n to CoreML for use on iOS
classes.txt         The 80 COCO classes the base model recognises
yolov4.cfg           Darknet config, kept from an earlier experiment with YOLOv4

Baseball_TrackerApp.swift, ContentView.swift, CameraView.swift, VideoPlayerView.swift
                    SwiftUI app shell for running detection on iOS
Baseball Tracker.xcodeproj.zip
yolov8n.mlpackage.zip   Exported CoreML model
```

## How it works

`main.py` loads `yolov8n.pt`, runs inference frame by frame on an OpenCV video capture, and only draws/annotates detections whose class is in `allowed_classes`. This is a filtering approach rather than a custom-trained one — accuracy is bounded by how well COCO's general-purpose classes cover a baseball scene, which is why the project moved on to a purpose-trained model (see [Baseball-Tracker](https://github.com/Cameron11010/Baseball-Tracker)).

## Setup

```bash
pip install ultralytics opencv-python
```

Edit the empty string in `main.py`'s `cv2.VideoCapture("")` to a video file path, or pass `0` for a live webcam feed, then:

```bash
python main.py
```

Press `q` to quit the preview window.

To export the base model to CoreML for the iOS app:
```bash
python export.py
```

## Related

Superseded by [Baseball-Tracker](https://github.com/Cameron11010/Baseball-Tracker), which trains a dedicated baseball detector instead of filtering COCO's classes, and by [Dissertation](https://github.com/Cameron11010/Dissertation), the full two-phone stereo system.

---

Built by [Cameron Millar](https://github.com/Cameron11010).
