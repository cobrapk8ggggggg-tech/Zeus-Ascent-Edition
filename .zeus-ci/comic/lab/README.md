# Comic image quality lab

This harness runs real chapter pixels locally, without launching the iOS app.
It uses the **same C++ cleanup implementation** that the app links, pinned Paddle
ONNX weights, and fixed text for independent lettering probes. Linux uses
FreeType/HarfBuzz through Pillow RAQM; production CoreText is checked separately
by `testRealComicCropsRenderThroughProductionCoreText` on the same retained crops.

```sh
python3 -m venv /tmp/zeus-comic-lab
. /tmp/zeus-comic-lab/bin/activate
pip install -r .zeus-ci/comic/lab/requirements.txt
python .zeus-ci/comic/lab/models.py .zeus-ci/comic/lab/models
python .zeus-ci/comic/lab/acquire.py .zeus-ci/comic/lab/data
python .zeus-ci/comic/lab/test_masks.py
python .zeus-ci/comic/lab/run.py --corpus .zeus-ci/comic/lab/data --models .zeus-ci/comic/lab/models --output .zeus-ci/comic/lab/output/review --regions 400 --ocr
```

Use a fontconfig installation including `NotoNaskhArabic-Regular.ttf` (Ubuntu:
`fonts-noto-core`) for the Linux layout probe. Run `python -m http.server` in the
output directory and open `index.html`; export reviews with the button. Proposals
are explicitly **unreviewed**, not hand-labelled truth. `report.json` cannot claim
95% recall or visual success from model output. Holdout chapters are separate from
calibration chapters. Review thumbnails are triage; inspect full-resolution crops
before accepting a case. Fixed Arabic strings do not evaluate translation quality.

`docs/comic-translation/lab/corpus.json` records the downloaded 11 chapters, 251
original images, source URLs and SHA-256 hashes. Full chapters and model weights
stay outside git; six small real crops are retained for native regression tests.
The acquisition command selects two different works per language and records the
selection once. To reproduce the frozen set, download each manifest page URL and
verify its hash, rather than selecting new chapters. CDN URLs may expire; resolve
the recorded MangaDex chapter through its at-home API in that case and check hashes.

Optional model comparison (not enabled in the app):

```sh
python .zeus-ci/comic/lab/models.py .zeus-ci/comic/lab/models --comparison
python .zeus-ci/comic/lab/compare_models.py --models .zeus-ci/comic/lab/models --cases .zeus-ci/comic/lab/output/review --count 8
```

LaMa inputs are RGB float32 [0,1] plus a binary mask, letterboxed to 512x512;
output is RGB float32 [0,255]. Composite only the original-resolution mask pixels.
CTD segmentation is intersected with text ownership, not applied to an entire page.
The lock file records exact revisions, sizes and digests. These are experimental
comparators: no new deep restoration model is enabled in the shipped app merely
because it downloaded or produced an image.

The gallery can be augmented with a pixel annotation editor:

```sh
python .zeus-ci/comic/lab/annotate.py .zeus-ci/comic/lab/output/review/index.html
python .zeus-ci/comic/lab/refresh.py --models .zeus-ci/comic/lab/models --cases .zeus-ci/comic/lab/output/review
```

Ink/protection brush strokes are exported in original pixel coordinates along
with source transcription. Annotation requires independent human review. Samples
use deterministic page/group shuffling with a per-page cap, to avoid filling a
language's quota with only the cover and contents pages. Layout-fit and cleanup-
coverage counters are diagnostics, not recall or visual-acceptance percentages.

For the frozen 11-chapter corpus and the full sequence, use one command (Python,
g++, FreeType/RAQM and the fonts above must be installed):

```sh
bash .zeus-ci/comic/lab/verify.sh /tmp/zeus-comic-review
```

This verifies all retained source hashes, installs an isolated Python environment,
runs independent mask tests, downloads pinned OCR models and emits the review
artifacts. If a frozen CDN URL has expired it fails rather than silently accepting
different images; refresh it through the recorded chapter endpoint and retain the
same SHA-256 before retrying.
