# Native chapter probe

This separate CI workflow exercises the unchanged production image pipeline from
`3b1e5d8` on frozen real chapter images. Five language shards download and verify
the original bytes, execute Vision/Paddle, call the actual Google batch adapter,
and run cleanup, adaptive CTD/LaMa and CoreText. The corpus host replaces only the
unit-test entry point; it does not change application source or the IPA.

Each shard exports original/clean/rendered crops, full OCR window readings, source
hashes/coordinates, provider results and reasons for retaining originals. The
simulator's memory guard is bypassed to measure inference; physical iPhone
eligibility and memory remain unproven. A provider failure is explicitly recorded
as a fixed layout probe, not counted as a successful real translation.

The results are review proposals. Neither the workflow's success nor an accepted
mask establishes annotated recall, semantic translation accuracy, blind visual
acceptance, or Android output equivalence.
