# Score on the Mac against the NAS; stage results as symlinks

Originals live on a Synology NAS whose CPU is weak; face detection over 2K full-resolution
JPEGs on the NAS would take hours, while the Mac (Apple Silicon) does it in minutes. So
scoring runs on the Mac with the NAS mounted over the network (accepting a one-time ~40GB
read), and the `review` phase stages keepers/maybe/rejected as **symlinks** into a
keep-folder rather than copying — the user explicitly prefers not to copy 40GB before
reviewing.

## Consequences

- Symlinks store the live mount path, so they **dangle if the NAS share is unmounted or
  renamed**. Accepted trade-off.
- The manifest stores NAS-relative paths so it stays portable across machines and mounts;
  `review` resolves them to the current mount path at link-creation time.
- Keep-folder should sit on the Mac's local APFS disk, where symlinks are stored natively.
