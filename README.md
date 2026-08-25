# Baseball Tracker

An automated ball-strike (ABS) system that runs on two iPhones.

Professional pitch adjudication uses Hawk-Eye: a dozen or more synchronised high-speed cameras, fixed mounts, a dedicated network, and specialist engineers to keep it calibrated. A stadium installation costs in the region of hundreds of thousands of pounds, which is why nothing like it exists below the professional tier — precisely where officiating accuracy is weakest and least measured.

The underlying mathematics isn't proprietary, though. A modern phone captures at 240fps and runs neural network inference on a dedicated Neural Engine. Two of them, positioned at different angles around home plate, are a stereoscopic rig. This project is the engineering work needed to get from that principle to a system that actually calls pitches.

<!-- TODO: screenshot of the live detection overlay goes here — this is the single most useful image in the README -->

## Results

Evaluated on a labelled 150-pitch dataset captured under varied lighting conditions.

| Metric | Result |
|---|---|
| Ball/strike classification accuracy | 91.3% |
| MLB human umpire benchmark | 92.8% |
| Capture rate | 240fps |

The 1.5 percentage point gap against professional human umpires is the headline number. The system is not as good as an MLB umpire, but it is close, and it costs the price of two phones you probably already own.

<!-- TODO: add the plate-crossing scatter plot and the triangulation error chart from the dissertation -->

## How it works

**1. Detection.** A YOLOv8 model, trained on a custom dataset of baseballs across varied lighting, distances and backgrounds, converted to CoreML and run through Vision. A baseball at range occupies a tiny fraction of the frame, which is the hard case for object detection — YOLOv8's anchor-free design has noticeably better recall on small objects than earlier versions.

Inference is constrained to a region of interest around the last known ball position rather than the full frame. At 240fps the ball moves little between frames, so the ROI stays reliable and the cost per frame drops enough to keep detection real-time. If the ball is lost for several frames the ROI expands and the system falls back to full-frame detection.

**2. Calibration.** Home plate is a fixed, known shape defined by the rulebook, so it doubles as a free calibration target. A five-point calibration against the plate produces a homography mapping image coordinates to the ground plane, with no checkerboard or specialist rig needed.

**3. Synchronisation.** Two devices pair over Multipeer Connectivity. One acts as coordinator and broadcasts the capture trigger; frames are aligned by timestamp.

**4. Triangulation.** A single camera cannot recover depth — every world point along a ray through a pixel projects to that same pixel, leaving one degree of freedom unresolved. The second calibrated view supplies the missing constraint, and the trajectory is reconstructed by ground-plane triangulation across the two devices.

**5. Zone classification.** The strike zone is batter-specific by rule, and across a lineup spanning 5'9" to 6'5" the lower boundary alone varies by several inches. Boundaries are set per batter from roster heights using the anthropometric ratios MLB's own ABS deployment uses, rather than estimated live from pose — pose estimation isn't precise enough for that without systematic bias.

**6. Everything else.** Least-squares parabolic trajectory fitting, human pose estimation, check-swing classification, a SceneKit 3D view of the reconstructed pitch, roster and at-bat management, and annotated video export.

## Requirements

- Two iPhones capable of 240fps capture <!-- TODO: confirm minimum model -->
- iOS <!-- TODO: deployment target -->
- Xcode <!-- TODO: version -->
- Good light. The system needs a shutter around 1/600s to avoid motion blur smearing the ball beyond what the detector can find, and that costs you exposure.

## Setup

<!-- TODO: fill this in. At minimum:
     1. clone / open in Xcode
     2. where the .mlmodel lives, or how to obtain it (LFS? release asset? not committed?)
     3. signing / provisioning notes
     4. anything that needs configuring before first run
     A reader should be able to go from clone to a running app without guessing. -->

## Calibrating in the field

<!-- TODO: this is the part a new user will get wrong, so it's worth a short walkthrough:
     - where to stand the two devices relative to the plate
     - the five-point calibration sequence, with a screenshot of the calibration screen
     - how to tell a good calibration from a bad one -->

## Limitations

Worth being upfront about these:

- **Ground-plane triangulation, not full epipolar reconstruction.** The two-device setup averages across the ground plane rather than solving the full stereo geometry. Full epipolar reconstruction is the natural extension and would be more accurate.
- **Lighting sensitivity.** The shutter speed needed to freeze a 95mph fastball is unforgiving. Overcast days and evening games are considerably harder than bright afternoons.
- **Detection is the bottleneck.** Most classification errors trace back to missed or late detections rather than to the geometry.
- **Two devices.** Three would over-determine the reconstruction and let outlier views be rejected rather than averaged in.
- **Amateur use only.** This is a research prototype, not a certified officiating system.

## Roadmap

- Full epipolar reconstruction in place of ground-plane averaging
- Three-device configuration
- Pitch velocity and movement classification
- Season-long stats and per-pitcher analytics

## Paper

This project was my undergraduate dissertation at Liverpool Hope University (BSc Artificial Intelligence). A manuscript, *Consumer-Grade Stereo Vision for Automated Baseball Pitch Adjudication*, is in preparation for publication.

<!-- TODO: add the link once it's out -->

## Licence

<!-- TODO: pick one. MIT is the usual choice if you want people to be able to use it. -->

---

Built by [Cameron Millar](https://github.com/Cameron11010).
