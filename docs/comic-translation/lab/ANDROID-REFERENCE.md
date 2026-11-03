# Android reference and limits

Reference: private `Andriod`, branch `rea/ascent-decompile-20261101`, Ascent 1.0.25.
The full-smali workflow artifact 13066224457 contains the actual obfuscated code;
`rea-smali-app` omits these classes. Do not substitute report prose for execution.

| Component | Directly observed behavior | Current implementation status |
| --- | --- | --- |
| `vcb.l` | Insets source boxes using max(2, height * 0.12) when its boolean is set, otherwise height * 0.30; translates strip coordinates before cleanup | Source-height padding is implemented; boolean semantics need independent reference outputs before asserting equivalence |
| `vcb.r` | Nine binary-search passes bounded by source-provided min/max size and available rectangle height; checks layout width and height | CoreText uses nine passes and a source-glyph height cap |
| `vcb.B` | Deferred bitmap cleanup and lettering operate on the same source bitmap | All cleanup finishes before lettering; native code reads an immutable source copy |
| `ncb.invoke` / `dub` | Pixel arrays, connected components and region clipping; more than uniform rectangle filling | Shared native masks protect edge-connected art; this is not a byte-for-byte port |
| `n3h` | Strip context and orchestration reference | Adjacent-image context exists; layout and grouping require real-case regression |

The added native test validates real crop rendering, not exact Android output.
Neither the local gallery nor a successful IPA build establishes complete Android
quality equivalence. A comparison against actual Android output remains a separate
acceptance item, especially for rotated SFX and textured artwork.
