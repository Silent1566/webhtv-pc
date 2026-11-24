# Offscreen Android Graphics Implementation Plan

> For agentic workers: use test-driven-development within the assigned JVM module; the dispatcher owns independent acceptance. This is execution in the current session, not a plan-mode approval request.

**Goal:** Support the image-producing android.graphics calls reached by PanConfig.categoryContent(settings), without Android windows or login interaction.

**Architecture:** One implementation owner keeps the tightly coupled Bitmap/Canvas/Paint/Path/font/gradient state consistent. Use the installed JDK java.desktop raster APIs (BufferedImage, Graphics2D, ImageIO), keeping the public Android binary descriptors and honest failures for unsupported operations. Lead owns task boundaries, decisions, documentation, and final replay/review; no parallel edits in the graphics boundary.

**Tech Stack:** Java17 bytecode target, JDK21 local verification, bundled ASM/dex2jar dependencies, Java2D/ImageIO; no downloaded graphics libraries.

**Spec:** Accepted scope below; runtime evidence in managed Document 8e5ca122-e4c1-4bb9-b8be-0fcecd47f258 and .probe/lead-shell-new-acceptance/ui-support/settings-replay.log.

## Accepted scope and immutable constraints
- User selected offscreen drawing first, after read-only diagnosis.
- Proven entry: PanConfigGuard -> PanConfig.categoryContent@62 -> n@41 -> createBitmap(128,128,ARGB_8888).
- Canvas(Bitmap) is absent; later drawing/Typeface/PNG operations also need real implementation.
- Android widgets, Drawable/View/window emulation, WebView, login/scan interaction, and cloud/account changes are excluded.
- No transparent placeholder images, silent no-op drawing, dropped settings cards, Gson workaround, or arbitrary global Object replacement.
- Preserve all existing uncommitted changes, DexRepair.VERSION6 and its cache semantics.
- Paint.setShader(Shader) returns the supplied Shader; Color.parseColor hex formats are #RRGGBB and #AARRGGBB, not CSS shorthand.

## Task 1: Complete JVM offscreen graphics module (android-graphics-offscreen, run1/3)

**Files:**
- Implement only referenced members in sidecars/spider-host-jvm/src-android-shim/src/android/graphics/**: Bitmap.java, Canvas.java, Paint.java, Path.java, Typeface.java, Shader.java; Color.java and LinearGradient.java as proven needed, Rect.java/Matrix.java only on a referenced signature.
- New contract: sidecars/spider-host-jvm/test/AndroidGraphicsContractTest.java.
- Existing build output: sidecars/spider-host-jvm/host.jar via build.ps1.
- Optional production headless flag only at apps/desktop-flutter/lib/services/spider_registry.dart:jvmHeapFlags if required and verified; no other service/UI edits.

**Public contracts:**
- Bitmap.createBitmap(int,int,Bitmap$Config):Bitmap, Canvas(Bitmap), pixel read/write and ImageIO PNG/JPEG encoding.
- Canvas shape/path/text methods use live Paint state and mutate the backing pixels; font and gradient states are real, not holders.
- Preserve default Canvas() type linking; drawing with no valid target must fail honestly.
- Validate dimensions/array bounds/row stride, recycled access, compression format and resource bounds before allocation/drawing.
- Unsupported UI operations continue to name class#member in their failure; no broad class-inventory API expansion.

**Execution checklist:**
- [ ] Capture the exact referenced public member list from PanConfig and its drawing helpers (not the entire jar repeated).
- [ ] Write a standalone contract and run against the original host to capture RED. Test output is based on pixels and decoded images, not just method presence.
- [ ] Implement the smallest coherent raster/state adapter. Do not extend Drawable or widgets when replay reaches them; hand back the boundary with evidence.
- [ ] Verify image dimensions, ARGB round trip, non-background shape/text pixels, gradient-axis variation, malformed inputs, resource guards, recycle behavior, and unsupported operations.
- [ ] Run all seven existing JVM contracts; no fixture/class files outside scoped transient output trees.
- [ ] Build host.jar, verify javap-visible descriptors and hash; replay settings on isolated byte-identical copied artifacts with network denied.

**Example independently derived contract signal:**

```java
Bitmap bitmap = Bitmap.createBitmap(128, 128, Bitmap$Config.ARGB_8888);
Canvas canvas = new Canvas(bitmap);
Paint paint = new Paint();
paint.setColor(0xff00ff00);
canvas.drawCircle(64, 64, 16, paint);
ByteArrayOutputStream bytes = new ByteArrayOutputStream();
if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes)) throw new AssertionError("PNG encoding failed");
BufferedImage decoded = ImageIO.read(new ByteArrayInputStream(bytes.toByteArray()));
if (decoded == null || decoded.getWidth() != 128 || decoded.getRGB(64, 64) != 0xff00ff00) throw new AssertionError("real raster output missing");
```

**Limits:**
- Implementation attempts: max3 runs total accumulating.
- Production files edited: max14 files total accumulating, including host.jar and the new test.
- Persistent scratch: max20 files total accumulating under .probe/android-graphics-offscreen; deletion does not restore quota.
- Transient generated build/test fixtures: unlimited, only .probe/android-graphics-offscreen/tmp and the existing JVM .build output; remove owned transient output after verification.
- Commands/read/search/compile/contract test runs: unlimited inside boundary.
- Host builds: max2 total accumulating.
- Real settings replay: max3 launches total accumulating, each at most120seconds, kill+concurrent drains; copied site/userhome/tmp only.
- No commits, installed-user-data edits, network/account actions, or edits to another agent's boundary.

## Task 2: Lead acceptance (run0/3)
- Read final diff and every changed Android descriptor; check unsupported members, bounds, ownership and alpha/font/stroke/gradient behavior.
- Independently compile/run the raster contract plus existing range/use/alignment/interface/linkage/Toast/proxy gates against the final host, not a stale overlay.
- Independently replay original settings. Verify actual category result and PNG payloads, not merely absence of Bitmap exception.
- Read representative 128x128 rendered icons. No reliable Before image exists because baseline throws; require After images plus that note.
- Any later unsupported widget member returns to scope decision, never silently ships as full UI support.
- Delivery distinguishes offscreen drawing, settings-list availability, and login interaction; report new host hash and whether an exe was built (not implied).
