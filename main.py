from ultralytics import YOLO
import cv2

# Load YOLOv8n pretrained on COCO
model = YOLO("yolov8n.pt")

# Allowed classes
allowed_classes = ["sports ball", "baseball bat", "baseball glove"]

# Open a video (or webcam with 0)
cap = cv2.VideoCapture("")  # video name

while True:
    ret, frame = cap.read()
    if not ret:
        break

    # Run inference
    results = model(frame)

    # Copy frame for annotations
    annotated_frame = frame.copy()

    for result in results:
        for box in result.boxes:
            cls_id = int(box.cls[0])
            cls_name = model.names[cls_id]

            if cls_name in allowed_classes:
                # Extract box coordinates
                x1, y1, x2, y2 = map(int, box.xyxy[0])

                # Draw rectangle and label
                cv2.rectangle(annotated_frame, (x1, y1), (x2, y2), (0, 255, 0), 2)
                cv2.putText(
                    annotated_frame,
                    cls_name,
                    (x1, y1 - 10),
                    cv2.FONT_HERSHEY_SIMPLEX,
                    0.6,
                    (0, 255, 0),
                    2,
                )

    # Show filtered detection
    cv2.imshow("YOLOv8 Filtered Detection", annotated_frame)

    if cv2.waitKey(1) & 0xFF == ord("q"):
        break

cap.release()
cv2.destroyAllWindows()
