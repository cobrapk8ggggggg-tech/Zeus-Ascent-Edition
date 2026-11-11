# تشغيل خارج الهاتف دون اشتراك استضافة

ملف `compose.free.yaml` يشغّل نموذجَي CTD وLaMa المثبتين ببصماتهما، ويعرض الخدمة عبر Cloudflare Quick Tunnel المجاني. الحاسوب الذي يشغّل Docker يوفّر المعالج والذاكرة؛ Cloudflare يوفّر الاتصال الآمن. لا يوجد تشغيل أو تنزيل لنموذجَي الترميم على الهاتف عند اختيار هذا الخادم في التطبيق.

يلزم حاسوب يعمل أثناء القراءة، وDocker، وذاكرة متاحة مناسبة. جرى اختبار الخدمة محليًا بحد 2 غيغابايت ومعالجين؛ اجتازت الاختبارات السبعة وبلغت الذروة نحو 1.16 غيغابايت. هذه ليست خدمة سحابية مجانية دائمة؛ إنها استخدام لحاسوب موجود دون اشتراك استضافة. لم يُنشأ نفق عام في جلسة الاختبار.

من جذر المستودع، عيّن `ZEUS_OWNER_EMAIL` إلى بريد حساب Zeus المستخدم، ثم شغّل:

```sh
docker compose -f Restoration/compose.free.yaml up -d --build
docker compose -f Restoration/compose.free.yaml logs tunnel
```

انسخ عنوان `https://…trycloudflare.com` الظاهر في سجل النفق إلى إعداد خادم الترميم داخل التطبيق. الخدمة تتحقق من جلسة Supabase؛ لا تعطّل التوثيق. يُخزّن مجلد Docker للنماذج ملفات الأوزان على الحاسوب فقط، ولا يحفظ قصّات الصور المرسلة. بعد التأكد من عمل الخادم، يمكن حذف نموذجَي الترميم من إعدادات مساحة التطبيق.

عنوان Quick Tunnel يتغير عند إعادة إنشائه، ولا توجد له ضمانات توافر. يمكن استخدام نفق مسمى وعنوان ثابت مع نطاق متاح في Cloudflare لاحقًا. عند تحديث صورة cloudflared، يُفضّل تثبيتها إلى digest بعد اختبارها.

## البدائل التي فُحصت في 11 نوفمبر 2026

- Workers المجاني: حد الذاكرة 128 ميغابايت، أقل من احتياج النموذجين المقاس. R2 يخزن الأوزان ولا ينفذ الاستدلال.
- Workers AI: بحث الكتالوج لم يجد CTD أو LaMa. جُرّب `stable-diffusion-v1-5-inpainting` بسعر معلن صفر لكل خطوة على قصّة أصلية من Asura؛ نجح الطلب لكنه اخترع كتابة وزخارف، فرفضناه كبديل للجودة. النموذج معلن إيقافه في 20 نوفمبر 2026.
- خدمات LaMa العامة في Hugging Face: بعض النسخ متوقفة أو تحمل خطأ بناء/تشغيل؛ نسختان تعلنان RUNNING لكن نقاط الوصول المفحوصة أعادت 404. لم تُعتمد أي منها كخادم يعمل للتطبيق.
- توثيق Hugging Face الحالي يشترط خطة مدفوعة لإنشاء Docker/Gradio Spaces عادية، رغم أن CPU Basic بلا سعر ساعي. توجد أهلية مجانية لاستضافة حتى اثنتين من ZeroGPU Gradio Spaces لحساب شخصي موثق أقدم من 30 يومًا وفي وضع سليم، مع قيود الحصص والتوافر. لم يُختبر نشر خدمة Zeus عليه ولم نثبت تطابق خرج GPU مع المسار الحالي.

المراجع:
- https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/do-more-with-tunnels/trycloudflare/
- https://developers.cloudflare.com/workers/platform/limits/
- https://developers.cloudflare.com/workers-ai/models/stable-diffusion-v1-5-inpainting/
- https://huggingface.co/docs/hub/spaces-overview
- https://huggingface.co/docs/hub/spaces-zerogpu
