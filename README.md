# M700 — آلة حاسبة بلغة Assembly

تطبيق أندرويد مكتوب **بالكامل بلغة ARM64 Assembly**، بدون Java أو Kotlin أو C.

## كيف بيشتغل

- أندرويد فيه نشاط جاهز اسمه `NativeActivity` بيحمّل المكتبة `libcalc.so` وبيستدعي `ANativeActivity_onCreate`.
- كل إشي تاني مكتوب بإيدي بملف واحد: [`src/calc.S`](src/calc.S)
  - الرسم: كتابة البكسلات مباشرة بذاكرة الشاشة (`ANativeWindow_lock`)
  - الأزرار الدائرية والخط (5×7 بكسل لكل حرف)
  - اللمس: قراءة إحداثيات الإصبع ومعرفة أي زر انضغط
  - الحسابات: جمع، طرح، ضرب، قسمة، فاصلة عشرية، ± ، مسح، ورجوع ⌫

## تنزيل التطبيق

كل ما تتعدّل الملفات، GitHub Actions بيبني الـ APK تلقائياً وبينشره بقسم **Releases**:

https://github.com/Musabgpt/M700/releases/latest

(بيشتغل على الجوالات اللي معالجها 64-bit، يعني تقريباً كل الجوالات الحديثة.)

## الملفات

| الملف | الوظيفة |
|---|---|
| `src/calc.S` | كود التطبيق كامل (Assembly) |
| `AndroidManifest.xml` | تعريف التطبيق لأندرويد |
| `res/drawable/ic_launcher.xml` | الأيقونة |
| `.github/workflows/build-apk.yml` | خطوات بناء الـ APK |
| `keystore/debug.keystore.b64` | مفتاح توقيع تجريبي (عشان التحديثات تنزل فوق النسخة القديمة) |
