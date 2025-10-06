from ultralytics import YOLO

# Load the YOLOv8n pretrained on COCO (80 classes)
model = YOLO("yolov8n.pt")

# Export to CoreML (all classes included)
model.export(
    format="coreml",
    nms=True,        # built-in non-max suppression
    dynamic=False,   # fixed input size
    half=False       # use full precision (works well with Neural Engine)
)
