# Remote CTD/LaMa execution

This service runs the same SHA-pinned CTD and LaMa graphs and ONNX Runtime 1.24.2 used by iOS. Native resizing, masks, compositing, residue checks and text rendering stay on the phone. Little-endian float32 tensors use lossless zlib transport; there is no JPEG conversion, quantization or alternate model. CPU and hardware implementations can have floating-point differences: transport equivalence alone is not a claim of pixel-identical cross-platform output.

Deploy `Restoration/Dockerfile` from the repository root, with at least 2 GB RAM. Configure `ZEUS_OWNER_ID` (Supabase user UUID) or `ZEUS_OWNER_EMAIL` for the intended owner. Authentication verifies the existing Supabase session. Models download and verify at startup under `/models`; a volume avoids re-downloading them on every deployment. Health only becomes available after model verification. The service stores model files, never uploaded page tensors or translated images. Access logs are disabled.

After the deployment is healthy, enter its HTTPS base address in image settings and enable cloud restoration. Only then delete downloaded restoration models in application storage settings. Cloud mode does not silently fall back to downloading them locally. Accountless guests can continue using local processing; this owner-authenticated endpoint requires sign-in.

Tests: `PYTHONPATH=Cloud:Restoration python -m unittest -v test_api test_inference`. Set `ZEUS_TEST_MODELS` to a folder containing pinned models to execute the real direct-versus-transport comparison. Native tests separately verify the C zlib/Swift float-bit round trip. The real Asura workflow compares strict and unchecked rendering on all original chapter images.

Deployment is not yet claimed: the currently connected Railway account does not expose the Zeus project. Configure the intended host before selecting cloud mode in the app.
