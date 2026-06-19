# YuNet detects faces; FaceLandmarker reads eyes

MediaPipe FaceLandmarker is tuned for close, frontal, few-face (selfie/portrait) images and
silently drops faces that are small relative to a full scene — on a real event frame with two
large foreground faces it returned zero. So face *detection* moves to **YuNet**
(`cv2.FaceDetectorYN`), which is robust across scales and poses (it found 6 faces on the same
frame), while MediaPipe FaceLandmarker is kept only to read **eye-open** from blendshapes,
run per detected face crop.

## Consequences

- Two model assets are auto-fetched to `~/.cache/best-photo-picker/`: the YuNet ONNX (~227KB)
  and the FaceLandmarker task (~4MB). Override paths via `BPP_FACE_DETECTOR` / `BPP_FACE_MODEL`.
- Detection costs one YuNet pass plus one landmarker pass **per detected face** — slower than a
  single full-frame pass, but detection is correct.
- A `min_face_frac` knob drops faces smaller than a fraction of the frame, so incidental
  background people don't flip a portrait into a "group" or sway keep/reject decisions.
- If YuNet is unavailable, there are no faces at all (sharpness + exposure only); if only the
  landmarker is unavailable, faces are still detected but the eye gate is disabled.
