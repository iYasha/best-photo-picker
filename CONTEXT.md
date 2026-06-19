# Best Photo Picker

A tool that sorts a large dump of JPEGs from continuous-shooting ("burst") photography:
it groups near-identical frames and surfaces the keepers so a human doesn't cull thousands
of photos by hand. Non-destructive — it copies/sorts, never deletes.

## Language

**Keeper**:
A photo worth keeping — clears the picker's quality bar (sharp subject, eyes open, sane
exposure). The output the user actually wants.
_Avoid_: good photo, winner, best shot

**Burst**:
A run of frames shot in rapid succession in continuous ("click") mode, capturing
essentially the same moment. The unit within which keepers are chosen. Boundaries are
detected automatically from the time gap between consecutive frames; length varies (two to
many frames), it is never a fixed count.
_Avoid_: sequence, series, batch, set

**Single**:
A frame with no burst neighbours — the only shot of its moment. Judged on absolute quality
thresholds, since it has no peers to rank against.
_Avoid_: orphan, lone shot, one-off

**Subject**:
The thing the photo is about and should be in focus — for people, the face. Located before
scoring; falls back to image centre, then whole frame, when no face is found.
_Avoid_: object, target, foreground

**Sharpness**:
How crisp the [[Subject]] region is. Low sharpness means misfocus or motion blur. Measured
on the subject region, not the whole frame — and in a region held *fixed across the whole
[[Burst]]* so every frame is scored on the same pixels and stays comparable (a frame is
never silently re-measured on the whole image just because face detection failed on it). The
single axis frames are ranked on within a burst.
_Avoid_: focus, blur, clarity (as the measured quantity)

**Exposure**:
Tonal correctness of a frame — flagged when highlights are blown or shadows crushed. A flag,
not a hard reject; some frames are dark or bright by intent.
_Avoid_: brightness, lighting

**Eyes-open**:
Whether the [[Subject]]'s eyes are open. With one face it acts as a [[Gate]]; with several
it becomes a face-size-weighted score across all faces (big foreground faces count, tiny
background ones effectively don't), so the frame where the people who matter have their eyes
open ranks highest. Only meaningful when a face is found.
_Avoid_: blink, gaze

**Manifest**:
The one source of truth the tool produces — a row per photo recording its [[Burst]], whether
a [[Subject]] was found, [[Sharpness]], the eyes [[Gate]] result, the [[Exposure]] [[Flag]],
the assigned bin, and the reason. Written once by scoring; everything downstream reads it.
Originals are never moved.
_Avoid_: report, output, results, index

**Gate**:
A pass/fail check that disqualifies a frame outright, no matter how sharp it is. Eyes-closed
is the gate (only when a face is found). A gated frame cannot be a [[Keeper]].
_Avoid_: filter, reject rule

**Flag**:
A non-disqualifying warning attached to a frame. Bad [[Exposure]] is a flag — it surfaces
the issue without rejecting the frame.
_Avoid_: warning, mark

**Maybe**:
A frame that is neither a clear [[Keeper]] nor clearly [[Rejected]] — a [[Burst]] runner-up
or an [[Exposure]]-flagged frame. Surfaced for the human to make the final call. Also the
default whenever the tool is uncertain: it would rather surface a frame than bury it.
_Avoid_: review (as a bin name), borderline, runner-up

**Rejected**:
A frame that failed a [[Gate]] or is clearly blurry. Reserved for high-confidence trash;
when the tool is unsure it routes to [[Maybe]], never here. Sorted aside so it is out of the
way, but always kept on disk — the tool never deletes.
_Avoid_: trash, discard, deleted

**Review**:
The on-demand phase that reads the [[Manifest]] and stages photos for human inspection — by
symlink or copy — into a folder the user keeps. A verb/phase, distinct from the [[Maybe]]
bin. Never moves or alters originals.
_Avoid_: apply, stage, export
