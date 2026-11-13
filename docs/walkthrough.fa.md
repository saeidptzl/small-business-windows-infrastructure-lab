# راهنمای کوتاه: بازسازی دمو و توضیح آن در مصاحبه

این لب یک **لب شخصی** است: یک دامنه‌ی ویندوزی کوچک برای یک دفتر ۱۰ تا ۲۰ نفره، با دو ماشین مجازی روی یک شبکه‌ی کاملاً ایزوله.

| ماشین | نقش | IP |
|---|---|---|
| DC01 | Windows Server 2025 (Server Core): Active Directory، DNS، پوشه‌های اشتراکی، Windows Server Backup | 10.10.50.10 |
| CL01 | Windows 11 Enterprise LTSC 2024، عضو دامنه | 10.10.50.21 |

## ۱) روشن کردن لب (روی لینوکس)

```bash
cd small-business-windows-infrastructure-lab
host/vm.sh start dc01        # اول سرور
host/vm.sh start cl01        # بعد کلاینت
host/vm.sh status
host/vm.sh console cl01      # آدرس VNC روی 127.0.0.1 (یا اجرا با LAB_DISPLAY=gtk برای پنجره)
```

پسوردهای لب در فایل `lab-runtime/secrets/lab-secrets.env` هستند (بیرون از مخزن، فقط روی لپ‌تاپ خودتان).

## ۲) تیکت ۱: ورود کارمند جدید (Onboarding)

**روی DC01**: در کنسول `Ctrl+Alt+Del` بزنید، با `SMALLBIZ\Administrator` (پسورد `DC01_ADMIN_PASSWORD`) وارد شوید و در منوی SConfig گزینه‌ی `15` را انتخاب کنید تا PowerShell باز شود. بعد:

```powershell
C:\LabSetup\server\10-New-OnboardingUser.ps1 -GivenName Anna -Surname Galli -Department Finance -TicketId LAB-2001
```

اسکریپت پسورد موقت را می‌پرسد، حساب را در OU مربوط به Finance می‌سازد، فقط به گروه `GG_Finance` اضافه می‌کند و تیک «تغییر پسورد در اولین ورود» را می‌زند.

**روی CL01** (کنسول):

1. `Ctrl+Alt+Del` و ورود با `SMALLBIZ\anna.galli` و پسورد موقت.
2. ویندوز می‌گوید پسورد باید عوض شود: پسورد جدید را دو بار وارد کنید.
3. در یک `cmd` معمولی (نه Run as administrator) بزنید:

```cmd
whoami
net use
dir \\DC01.corp.smallbiz.test\Finance
dir \\DC01.corp.smallbiz.test\Operations
```

نتیجه‌ی درست: درایو `F:` وصل است، پوشه‌ی Finance باز می‌شود، و برای Operations پیام **Access is denied** می‌آید. نسخه‌ی کامل تست:

```powershell
powershell -ExecutionPolicy Bypass -File C:\LabSetup\client\10-Test-DepartmentAccess.ps1
```

## ۳) تیکت ۲: «درایو اشتراکی‌ام غیب شده» (DNS)

**روی CL01** (PowerShell با دسترسی ادمین). ویندوز ۱۱ به‌طور پیش‌فرض اجرای اسکریپت را می‌بندد، پس خط اول را در هر پنجره‌ی PowerShell بزنید (فقط روی همان پنجره اثر دارد):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
C:\LabSetup\client\20-Set-DnsFault.ps1      # خراب کردن عمدی: DNS = 8.8.8.8
Restart-Computer
```

بعد از ری‌استارت، با همان کاربر وارد شوید: درایو `F:` نیست و `dir \\DC01.corp.smallbiz.test\Finance` پیام *The network path was not found* می‌دهد.

**عیب‌یابی** (روی CL01، هر کاربری):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
C:\LabSetup\client\21-Get-DnsDiagnostics.ps1
```

منطق عیب‌یابی را این‌طور توضیح دهید: «با IP به DC می‌رسم (ping موفق)، ولی اسم resolve نمی‌شود. وقتی مستقیم از DNS خود دامنه (10.10.50.10) سؤال می‌کنم جواب درست می‌گیرم. پس شبکه و سرور سالم‌اند و مشکل از تنظیم DNS روی کارت شبکه‌ی کلاینت است.»

**رفع مشکل** (روی CL01، ادمین):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
C:\LabSetup\client\22-Repair-ClientDns.ps1
```

بعد کاربر یک بار sign out/sign in کند یا `gpupdate /target:user /force` بزند. اگر درایو بلافاصله برنگشت، یک دقیقه بعد دوباره امتحان کنید (در تست واقعی همین اتفاق افتاد). در آخر تست دسترسی را دوباره اجرا کنید.

## ۴) بازیابی فایل (روی DC01)

```powershell
C:\LabSetup\server\06-Invoke-FileRecoveryDemo.ps1
```

بکاپ یک فایل، خراب کردن عمدی، بازیابی در مسیر جایگزین، و مقایسه‌ی hash با فایل اصلی. **محدوده را صادقانه بگویید:** فقط یک فایل، روی دیسک دوم همان سرور؛ این یک تمرین بازیابی است، نه استراتژی بکاپ (3-2-1 ندارد).

## ۵) توضیح در مصاحبه (حدود ۲ دقیقه)

> «یک لب شخصی ساختم که محیط یک دفتر کوچک را شبیه‌سازی می‌کند: یک Windows Server 2025 با Active Directory و DNS و پوشه‌های اشتراکی، و یک کلاینت Windows 11 عضو دامنه، روی شبکه‌ی ایزوله. دسترسی‌ها را با مدل AGDLP و ترکیب permissionهای Share و NTFS پیاده کردم و با یک GPO درایوها را map کردم. بعد دو تیکت واقعی را اجرا و مستند کردم: ورود کارمند جدید، و یک مشکل DNS که روی کلاینت بازسازی، از پایین به بالا عیب‌یابی و رفع شد. همه‌ی نتایج، چه موفق و چه ناموفق، با خروجی واقعی در گیت‌هاب ثبت شده است.»

> (به ایتالیایی، کوتاه:) «Ho realizzato un laboratorio personale con un dominio Active Directory su Windows Server 2025 e un client Windows 11, su una rete virtuale isolata. Ho gestito permessi di condivisione e NTFS con il modello AGDLP, una GPO per le unità di rete, e ho documentato due ticket: onboarding di un nuovo utente e un guasto DNS diagnosticato e risolto.»

### سؤال‌های محتمل و جواب کوتاه

| سؤال | جواب کوتاه |
|---|---|
| چرا AGDLP؟ | گروه Global می‌گوید «کیست» (واحد)، گروه Domain Local می‌گوید «به چه چیزی دسترسی دارد». جابه‌جایی کارمند فقط یک تغییر عضویت گروه است و به ACLها دست نمی‌زنیم. |
| Share یا NTFS؟ | هر دو. دسترسی مؤثر، محدودترینِ این دو است. اینجا هر دو فقط به گروه DL همان واحد اجازه می‌دهند. |
| چرا با UNC تست کردی؟ | چون درایو `F:` فقط نشان می‌دهد GPO اجرا شده؛ اجازه‌ی دسترسی را ثابت نمی‌کند. |
| *Network path not found* با *Access denied* چه فرقی دارد؟ | اولی یعنی مشکل اسم یا شبکه (DNS)، دومی یعنی مشکل permission. |
| چرا کلاینت دامنه نباید 8.8.8.8 داشته باشد؟ | DNS عمومی zone داخلی و رکوردهای SRV مربوط به DC را نمی‌شناسد، پس ورود، GPO و دسترسی به فایل‌ها خراب می‌شوند. |
| بعد از درست کردن DNS چه چیزی غافلگیرت کرد؟ | secure channel کامپیوتر هنوز قطع بود (`ERROR_NO_LOGON_SERVERS`)، چون سیستم بدون DC بوت شده بود. با `nltest /sc_reset` درست شد و اسکریپت را اصلاح کردم. |
| همه‌ی نقش‌ها روی یک سرور؟ | برای لب و دفتر خیلی کوچک قابل قبول است، ولی نقطه‌ی شکست واحد است. در محیط واقعی دو DC و یک فایل‌سرور جدا با DFS پیشنهاد می‌کنم. |

## ۶) نکته‌های صداقت

* این لب شخصی است، نه تجربه‌ی کاری در شرکت.
* لایسنس ارزیابی Windows 11 در حالت آفلاین از همان ابتدا «expired» نشان داد. لب کار کرد، ولی این محدودیت را بدانید.
* قبل از مصاحبه، **خودتان** تیکت‌ها را یک بار از اول تا آخر اجرا کنید تا بتوانید با اطمینان درباره‌شان حرف بزنید.
