# Two grouping strategies: capture-time and content similarity

Capture-time gap grouping is a *proxy* for what culling actually needs — near-duplicate
frames — and the proxy leaks: the right gap threshold depends on the camera's frame rate and
the photographer's habits (a 1.8s recompose pause merged two distinct sequences on a real
shoot). For a tool other people run on other cameras, the camera-agnostic signal is the
pixels. So the tool supports two selectable grouping strategies (`group.method`):

- **time** — the original capture-time gap bursts, unchanged, with a per-burst locked subject
  region. Cheapest; good when one camera/one habit and bursts are cleanly time-separated.
- **similarity** — group frames by perceptual-hash (dHash) near-duplicate distance, with a
  safety time-ceiling. Camera-agnostic; splits a pan mid-hold and merges a recompose pause,
  because it judges what the frame looks like, not when it was taken.

## Consequences

- Similarity mode measures sharpness on each frame's own subject box rather than a
  group-locked region; group members are near-duplicates, so the boxes already align.
- The resumable cache discriminates rows by a tag (the gap-seconds for time mode, "sim" for
  similarity), so both modes' measurements coexist in one cache file without colliding.
- Similarity's one knob (`sim_max_distance`, a perceptual-hash distance) ports across cameras
  far better than a seconds-gap.
- Known limit: whole-frame hashing can over-group when a fixed background dominates and only
  the subject changes; the fix, if it bites, is to hash the subject region.
