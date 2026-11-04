# ZEUS Browser — Ascent Edition 🎌➡📱

إصلاح صور المواقع وتصميم أدوات القراءة: [التغييرات وأدلة التحقق](docs/comic-translation/RELIABILITY-20261102.ar.md). نجاح بناء IPA لا يعني اكتمال اختبارات ترجمة الصور أو إثبات التكافؤ مع Android.


مستودع التعديلات المستمر على ميزة **ترجمة صور المانجا/المانهوا** في متصفح ZEUS (iOS)،
مبني على أحدث عمل موثق: فرع `ascent/parity-20261101` في `Zeus-Browser-Ascent`
(وهو نفسه امتداد لفرع `feature/zeus-manhwa-translation-20261101` في `Zeus-Browser`).

> المرجع المعتمد: تحليل REA الكامل لتطبيق **Ascent : Translator Browser** 1.0.25
> (`com.rlmobile.ascent`) في مستودع `Andriod` — فرع `rea/ascent-decompile-20261101`.

## ما الذي أضافته هذه النسخة (فوق أساس 6edbc6b)

| # | الإضافة | التفاصيل | الاختبار |
|---|---|---|---|
| 1 | **إصلاح عطل CI القاتل** | `zeus-ipa-download.yml` كان YAML مكسوراً فعلياً (قائمة branches محشورة في سطر واحد بعد `[`) — فشل parse حقيقي جعل workflow الـ IPA يفشل منذ إنشائه. أُصلح السطر وتحقق من صحة YAML للملفات الـ 11 كلها برمجياً | فحص pyyaml في CI نفسه |
| 2 | **أنماط حبر** (عادي/محدّد/مظلّل) | `ComicInkStyle` جديد: «محدّد» يرسم حداً بلون معاكس (kCTStrokeWidth 12%) حول الحروف للخلفيات المزدحمة/المتدرجة، و«مظلّل» يرسم نسخة ظل ناعمة تحت الحروف. كل التمريرات على مسار إطار واحد فتبقى متطابقة التسجيل على أي خط ودوران | `testOutlineInkAddsOppositeStrokeOverNoisyBackground` — يقيس البكسلات المعاكسة المضافة فعلياً على خلفية SFX مخططة |
| 3 | **نص مائل (ذيول التفكير/SFX)** | `ComicGeometry.estimateAngle` يستنتج ميل الذيل من انحراف مراكز الأسطر (يقبل 2°–35° فقط — الضوضاء لا تُدير الفقاعات العادية)، و`place()` يقلّص المستطيل ثنائياً حتى يبقى الصندوق المدوّر داخل حدود الكلام، والرسم يُدار حول المركز | `testDiagonalTailEstimatesAngleAndRotatedLetteringStaysInsideBounds` — زاوية دقيقة + صفر بكسل خارج الحدود |
| 4 | **خط عربي افتراضي حقيقي** | `layout()` يستخدم GeezaPro تلقائياً للأهداف العربية (كانت الجملة موثقة في تقرير سابق دون تنفيذ في مسار الصور) + منتقي الخطوط يعرض خطوط النظام العربية: GeezaPro/Damascus/Baghdad/AlBayan/Sana/Nadeem | تغطية بـ `testArabicCoreTextFitsAndColorIsValidated` الموجود |
| 5 | **بوابة أدلة أقوى** | الاختباران الجديدان (الميل + الحبر) أصبحا اختباري إثبات أساسيين في `sim_probe.py` — الـ workflow يفشل صراحة إن غابا أو فشلا | `sim_probe.py` |
| 6 | **قائمة تكافؤ محدثة بصدق** | فصل «مائل» (محقق جزئياً 0.5) عن «منظور/SFX مركبة» (فجوة معلنة)، وبند «أنماط حبر» جديد | `parity_selftest.py` يمر |

## تشغيل كل شيء

```bash
# 1) الموازنة الكاملة: جسر + مفكك C++ + محاكي حقيقي + تقرير تكافؤ
Actions → "ZEUS-Ascent parity — tests, simulator and gap report" → Run workflow (edition/ascent-parity-20261101)

# 2) اختبارات الترجمة المتخصصة
Actions → "ZEUS comic image translation" → Run workflow

# 3) اختبارات التكامل الكاملة للمتصفح
Actions → "ZEUS native browser integration tests" → Run workflow

# 4) بناء IPA للجهاز (بدون توقيع)
Actions → "ZEUS integrated IPA - build and publish (no tests)" → Run workflow
```

كل الـ workflows الأربعة مشتركة في التشغيل التلقائي على `main` و`edition/ascent-parity-20261101`.

## حالة التكافؤ مع Ascent (ملخص)

- **محقق ومثبت باختبارات**: الاستكشاف probe، النوافذ الطويلة، OCR ثلاثي (Vision/ML Kit/Paddle-ONNX)، تنظيف الفقاعات، تلوين WCAG من داخل الفقاعة، خطوط + حجم تلقائي، Bidi عربي، تبديل المصدر مع أصل قابل للاسترجاع، ذاكرة طبقات، أمان SSRF، محركات مجانية + BYOK + نموذج محلي، أنماط حبر، نص مائل.
- **فجوات معلنة بصدق** (تبقى في تقرير CI): منظور حقيقي/نص مقوّس/SFX مركبة، وعزل فك الصور في عملية منفصلة (هنا C++ داخل التطبيق).
- **خارج النطاق عمداً**: القارئ المستقل (سيأتي في تطبيق Tachiyomi منفصل بقرار صاحب المشروع).

الدرجة الحية تظهر في artifacts كل تشغيل: `PARITY-CI.ar.md`.


## سجل إصلاحات CI المجمعة (حتى آخر تحديث)

| العطل | السبب الجذري | الإصلاح | الدليل |
|---|---|---|---|
| workflow الـ IPA يفشل فوراً | YAML مكسور (قائمة branches محشورة) | إصلاح السطر + تحقق pyyaml لكل الـ 11 | تشغيلة IPA بدأت فعلياً |
| parity يفشل عند إقلاع المحاكي | قراءة GITHUB_ENV في نفس خطوة كتابته + بلا إعادة محاولة | فصل الخطوتين + إعادة محاولة (3 أجهزة × 2 محاولة + erase) | parity #4 و #7 أخضران |
| بوابة الأدلة ترفض سجلاً ناجحاً | صيغة أسماء اختبارات Xcode 26 مختلفة | regex جديد مع fallback قديم — تحقق من السجل الحقيقي | 20/20 من artifact فعلي |
| ربط الجهاز: `ish_emu not found` | استبدال LIBRARY_SEARCH_PATHS أفقد مسار deps/libs الأصلي | إلحاق بدل الاستبدال | IPA #7 أخضر (677de8) |
| ربط الجهاز: رموز Auth مكررة | حزمة Auth ترتبط مرتين (مستقلة + داخل libZEUSBrowser.a) | حصر حزمة Auth بهدف المتصفح | Auth link check أخضر |
| ربط الجهاز: ONNX مكرر | XCFramework + غلاف ObjC مرتبطان معاً | ربط الإطار عند المضيف دون تكرار الغلاف | IPA #7 أخضر (677de8) |

## مصادر المرجع

- تحليل Ascent: `cobrapk8ggggggg-tech/Andriod` @ `rea/ascent-decompile-20261101`
  (`analysis/ascent/rea/REA-REPORT.ar.md`, `MANGA-TRANSLATION.ar.md`, `DEVELOPER-KEYS.ar.md`, `API-INDEX.ar.md`)
- عمل المتصفح السابق: `Zeus-Browser` @ `feature/zeus-manhwa-translation-20261101` و `Zeus-Browser-Ascent`
