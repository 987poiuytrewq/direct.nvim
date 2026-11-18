# v0.3.0 format inventory

These files are hand-pinned from the persisted layouts and serializers in tag
`v0.3.0`; the fixture spec reads the checked-in bytes, not output from current
writers.

- `stacks/` contains the tagged JSONL history header and action records.
- `journals/` contains valid transaction snapshots for the write-ahead recovery
  states represented by the v0.3.0 transaction codec.
- `trash/` contains the version-1 file and directory sidecars.
- `register/content` is the old one-line register pointer to the accompanying
  digest-named copied-entry directory. The v0.3.0 register copied entries into
  that directory and did not write a manifest.
- `lock/.direct-history.lock` is intentionally zero bytes. v0.3.0 used the
  operating system's advisory lock on this persistent file; it had no serialized
  lock payload or version marker.

The register-manifest portion of A47 is intentionally represented by the
actual v0.3.0 pointer and copied-entry tree instead; manifests did not exist in
this release. Do not add a fabricated v0.3.0 manifest or lock marker.
