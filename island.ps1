# Mini Island untuk notifikasi Windows
# Pil hitam di tengah atas layar. Notifikasi baru -> pil membesar dan menampilkan isinya.
# Hover -> daftar notifikasi terbaru. Klik -> buka aplikasinya. Klik kanan -> Keluar.

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$logFile = Join-Path $here 'island.log'
# Log tidak dibiarkan membesar terus
try { if ((Get-Item $logFile -ErrorAction Stop).Length -gt 512KB) { Remove-Item $logFile -Force } } catch {}
function Log($msg) { try { Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg) } catch {} }

# Versi ini dibandingkan dengan file VERSION di GitHub untuk cek update
$APP_VERSION = '1.3.2'
$REPO_URL = 'https://github.com/nkzwsn/mini-island-windows'

# Pengaturan yang diingat antar-restart (diatur lewat menu klik kanan)
$settingsFile = Join-Path $here 'settings.json'
# LyricDelay: lirik ditampilkan sekian detik setelah waktu di file lirik. Posisi yang dilaporkan pemutar
# sedikit mendahului suara yang terdengar (buffer audio, headset Bluetooth), jadi bawaannya sedikit ditunda.
# Monitor: nama perangkat layar (kosong = layar utama). Language: 'id' / 'en'.
# AppVolume: slider volume kartu musik mengatur volume aplikasi pemutarnya saja, bukan volume utama Windows.
$script:settings = [PSCustomObject]@{
    Lyrics = $true; Romaji = $true; Furigana = $true; LyricDelay = 0.15; Language = ''; Monitor = ''
    VolumeOsd = $true; Charging = $true; MicCam = $true; Headset = $true; Glow = $true; CheckUpdates = $true; SkipVersion = ''; NotifiedVersion = ''
    AppVolume = $true
}
try {
    if (Test-Path $settingsFile) {
        $j = Get-Content $settingsFile -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            $cur = $script:settings.PSObject.Properties[$p.Name]
            if (-not $cur -or $null -eq $p.Value) { continue }
            if ($cur.Value -is [bool]) { $cur.Value = [bool]$p.Value }
            elseif ($cur.Value -is [double]) { $cur.Value = [double]$p.Value }
            else { $cur.Value = [string]$p.Value }
        }
        $script:settings.LyricDelay = [Math]::Max(-3.0, [Math]::Min(3.0, $script:settings.LyricDelay))
        # Pengguna lama (sebelum ada pilihan bahasa) sudah terbiasa dengan bahasa Indonesia
        if (-not $script:settings.Language) { $script:settings.Language = 'id' }
    }
} catch { Log "settings load: $_" }
if ($script:settings.Language -ne 'id' -and $script:settings.Language -ne 'en') {
    $script:settings.Language = if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq 'id') { 'id' } else { 'en' }
}
function Save-Settings {
    try { $script:settings | ConvertTo-Json | Set-Content -Path $settingsFile -Encoding UTF8 } catch { Log "settings save: $_" }
}
# Teks antarmuka sesuai bahasa yang dipilih: T 'Indonesia' 'English'
function T($id, $en) { if ($script:settings.Language -eq 'en') { $en } else { $id } }
# Angka desimal mengikuti bahasa antarmuka (0,1 untuk Indonesia, 0.1 untuk Inggris), bukan pengaturan regional Windows
$CULTURE_ID = [Globalization.CultureInfo]::GetCultureInfo('id-ID')
function Fmt($fmt, $v) { [string]::Format($(if ($script:settings.Language -eq 'en') { [Globalization.CultureInfo]::InvariantCulture } else { $CULTURE_ID }), $fmt, $v) }

# Nama mutex dari nama lama (Dynamic Island) sengaja dipertahankan: versi lama dan baru tidak bisa jalan bersamaan
$mutex = New-Object System.Threading.Mutex($false, 'Local\DynamicIslandNotif')
if (-not $mutex.WaitOne(0)) { exit }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Runtime.WindowsRuntime

# Kode C# dikompilasi sekali lalu disimpan sebagai DLL di folder cache; start berikutnya tinggal dimuat
# (kompilasi tiap start memakan beberapa detik). Nama file = hash kode + referensinya, jadi kode yang
# berubah otomatis dikompilasi ulang dan DLL lama dibersihkan.
$cacheDir = Join-Path $here 'cache'
$script:usedDlls = @()
function Add-IslandType([string]$Source, [string[]]$Refs = @()) {
    $sha = New-Object System.Security.Cryptography.SHA1Managed
    $bytes = [Text.Encoding]::UTF8.GetBytes($Source + '|' + ($Refs -join '|') + '|' + [Environment]::Version)
    $key = ([BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').Substring(0, 16)
    $dll = Join-Path $cacheDir "island-$key.dll"
    $script:usedDlls += $dll
    $refArgs = @{}
    if ($Refs.Count) { $refArgs.ReferencedAssemblies = $Refs }
    if (Test-Path $dll) {
        try { Add-Type -Path $dll; return } catch { Log "cache load: $_" }
    }
    try {
        if (-not (Test-Path $cacheDir)) { [void](New-Item -ItemType Directory -Path $cacheDir) }
        Add-Type -TypeDefinition $Source @refArgs -OutputAssembly $dll -OutputType Library
        Add-Type -Path $dll
    } catch {
        Log "cache build: $_"
        Add-Type -TypeDefinition $Source @refArgs
    }
}
$WPF_REFS = @(([System.Windows.Media.PointCollection].Assembly.Location), ([System.Windows.Point].Assembly.Location),
    ([System.Windows.Controls.Grid].Assembly.Location), ([System.Xaml.XamlReader].Assembly.Location))

Add-IslandType @'
using System;
using System.Runtime.InteropServices;
public static class IslandNative {
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    public static int[] CursorPos() { POINT p; GetCursorPos(out p); return new int[] { p.X, p.Y }; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields, x, y, dmDisplayOrientation, dmDisplayFixedOutput;
        public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    // Refresh rate layar (Hz), 0 kalau tidak diketahui
    public static int RefreshRate(string device) {
        var d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
        return EnumDisplaySettings(device, -1, ref d) ? d.dmDisplayFrequency : 0;
    }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, int flags);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, int flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int Size; public RECT Monitor, Work; public int Flags; }

    // Aplikasi di depan menutupi seluruh layar utama (game, video/browser F11, presentasi)
    public static bool ForegroundIsFullscreen(IntPtr self) {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero || h == self) return false;
        var cls = new System.Text.StringBuilder(64);
        GetClassName(h, cls, 64);
        string c = cls.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return false;
        // Lapisan alat screenshot juga menutupi layar penuh, tapi bukan aplikasi fullscreen:
        // island jangan tertutup/menutup kartunya saat pengguna sedang mengambil screenshot
        uint pid; GetWindowThreadProcessId(h, out pid);
        try {
            string pn = System.Diagnostics.Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant();
            if (pn == "screenclippinghost" || pn == "snippingtool" || pn == "screensketch" || pn == "sharex" || pn == "greenshot" || pn == "lightshot") return false;
        } catch { }
        // Hanya aplikasi di monitor tempat island berada yang dihitung
        IntPtr mon = MonitorFromWindow(h, 2);
        if (mon != MonitorFromWindow(self, 2)) return false;
        // 3 = game Direct3D fullscreen eksklusif (dicek setelah monitor: game di monitor lain tidak dihitung)
        int state;
        if (SHQueryUserNotificationState(out state) == 0 && state == 3) return true;
        var mi = new MONITORINFO(); mi.Size = Marshal.SizeOf(typeof(MONITORINFO));
        RECT r;
        if (!GetMonitorInfo(mon, ref mi) || !GetWindowRect(h, out r)) return false;
        if (r.L > mi.Monitor.L || r.T > mi.Monitor.T || r.R < mi.Monitor.R || r.B < mi.Monitor.B) return false;
        // Jendela biasa yang di-maximize (taskbar auto-hide) masih punya title bar: bukan fullscreen
        const int WS_CAPTION = 0x00C00000;
        if ((GetWindowLong(h, -16) & WS_CAPTION) == WS_CAPTION && IsZoomed(h)) return false;
        return true;
    }

    // top: paling atas (topmost). false: turun ke paling bawah, di belakang aplikasi fullscreen
    // Tombol mouse mana pun sedang ditekan (di jendela mana saja)
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    public static bool MouseDown() {
        return (GetAsyncKeyState(1) & 0x8000) != 0 || (GetAsyncKeyState(2) & 0x8000) != 0 || (GetAsyncKeyState(4) & 0x8000) != 0;
    }
    public static IntPtr Foreground() { return GetForegroundWindow(); }

    public static void SetTop(IntPtr h, bool top) {
        SetWindowPos(h, new IntPtr(top ? -1 : 1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010 | 0x0200);
    }

    // Halaman memori yang sedang tidak dipakai dikembalikan ke Windows (yang dibutuhkan lagi dimuat ulang sendiri)
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    public static void TrimMemory() { EmptyWorkingSet(GetCurrentProcess()); }
}

// Aplikasi yang sedang memakai mikrofon / kamera, dari catatan izin privasi Windows
// (LastUsedTimeStop = 0 berarti sedang dipakai). Nama ramah diambil dari deskripsi file exe-nya.
public static class IslandSensors {
    static readonly System.Collections.Generic.Dictionary<string, string> names = new System.Collections.Generic.Dictionary<string, string>();
    public static string[] InUse(string cap) {
        var list = new System.Collections.Generic.List<string>();
        try {
            using (var root = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\" + cap)) {
                if (root == null) return list.ToArray();
                Scan(root, list);
                using (var np = root.OpenSubKey("NonPackaged")) { if (np != null) Scan(np, list); }
            }
        } catch { }
        return list.ToArray();
    }
    static void Scan(Microsoft.Win32.RegistryKey k, System.Collections.Generic.List<string> list) {
        foreach (var n in k.GetSubKeyNames()) {
            if (n == "NonPackaged") continue;
            using (var s = k.OpenSubKey(n)) {
                if (s == null) continue;
                object stop = s.GetValue("LastUsedTimeStop"), start = s.GetValue("LastUsedTimeStart");
                if (stop is long && (long)stop == 0 && start is long && (long)start > 0) {
                    string f = Friendly(n);
                    if (!list.Contains(f)) list.Add(f);
                }
            }
        }
    }
    static string Friendly(string n) {
        string cached;
        if (names.TryGetValue(n, out cached)) return cached;
        string f;
        if (n.Contains("#")) {
            string path = n.Replace('#', '\\');
            f = System.IO.Path.GetFileNameWithoutExtension(path);
            try {
                string d = System.Diagnostics.FileVersionInfo.GetVersionInfo(path).FileDescription;
                if (!string.IsNullOrEmpty(d) && d.Length <= 32) f = d.Trim();
            } catch { }
        } else {
            // Nama paket Store: Penerbit.NamaAplikasi_hash
            f = n.Split('_')[0];
            int dot = f.LastIndexOf('.');
            if (dot >= 0) f = f.Substring(dot + 1);
        }
        if (f.Length > 0) f = char.ToUpper(f[0]) + f.Substring(1);
        names[n] = f;
        return f;
    }
}
'@
# Hitungan berat yang dulu ditulis di PowerShell (gelombang, warna cover) dibuat dalam C#: di PowerShell
# keduanya memakan ~1 detik di thread UI saat ganti lagu, membuat semua animasi tersendat
Add-IslandType -Refs $WPF_REFS @'
using System;
using System.Windows;
using System.Windows.Media;
public static class IslandFast {
    // Geser hue warna sekian derajat (saturasi & kecerahan bisa dikali), untuk warna lapisan gelombang
    public static Color ShiftHue(Color c, double deg, double satMul, double valMul) {
        double r = c.R / 255.0, g = c.G / 255.0, b = c.B / 255.0;
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        double hue = Hue(c.R, c.G, c.B), s = max == 0 ? 0 : (max - min) / max, v = max;
        hue = ((hue + deg) % 360 + 360) % 360;
        s = Math.Min(1, s * satMul); v = Math.Min(1, v * valMul);
        double cc = v * s, x = cc * (1 - Math.Abs((hue / 60) % 2 - 1)), m = v - cc, rr, gg, bb;
        if (hue < 60) { rr = cc; gg = x; bb = 0; } else if (hue < 120) { rr = x; gg = cc; bb = 0; }
        else if (hue < 180) { rr = 0; gg = cc; bb = x; } else if (hue < 240) { rr = 0; gg = x; bb = cc; }
        else if (hue < 300) { rr = x; gg = 0; bb = cc; } else { rr = cc; gg = 0; bb = x; }
        return Color.FromRgb((byte)Math.Round((rr + m) * 255), (byte)Math.Round((gg + m) * 255), (byte)Math.Round((bb + m) * 255));
    }
    public static double Hue(double r, double g, double b) {
        double max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b)), d = max - min;
        if (d == 0) return 0;
        double h;
        if (max == r) h = 60 * (((g - b) / d) % 6);
        else if (max == g) h = 60 * ((b - r) / d + 2);
        else h = 60 * ((r - g) / d + 4);
        if (h < 0) h += 360;
        return h;
    }
    // Rata-rata warna jenuh cover (piksel BGRA) yang hue-nya jauh (>= 35 derajat) dari warna yang sudah ada.
    // false kalau warna lain itu terlalu sedikit.
    public static bool SecondColor(byte[] px, double[] bases, out double r, out double g, out double b) {
        double sr = 0, sg = 0, sb = 0, sw = 0; int n = 0;
        for (int i = 0; i + 2 < px.Length; i += 12) {
            n++;
            double bb = px[i], gg = px[i + 1], rr = px[i + 2];
            double max = Math.Max(rr, Math.Max(gg, bb)), min = Math.Min(rr, Math.Min(gg, bb));
            if (max < 60 || (max - min) / max < 0.35) continue;
            double hue = Hue(rr, gg, bb);
            bool near = false;
            foreach (double bs in bases) {
                double diff = Math.Abs(hue - bs); if (diff > 180) diff = 360 - diff;
                if (diff < 35) { near = true; break; }
            }
            if (near) continue;
            double wt = (max - min) / max;
            sr += rr * wt; sg += gg * wt; sb += bb * wt; sw += wt;
        }
        r = g = b = 0;
        if (sw < n * 0.04) return false;
        r = sr / sw; g = sg / sw; b = sb / sw;
        return true;
    }
}
'@
# Gelombang progress digambar ulang tiap frame (maks ~60 fps) dalam C#: bukit-bukit tembus pandang yang
# mengalir dan naik-turun pelan, tingginya menyusut mulus ke nol di awal bar dan menjelang titik posisi lagu
# (tanpa masker/potongan). Hanya menggambar selama elemennya tampil di jendela (Loaded/Unloaded), jadi tidak
# ada animasi yang tertinggal jalan di latar.
Add-IslandType -Refs $WPF_REFS @'
using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
public class IslandWave {
    public readonly Grid Root = new Grid();
    public bool Playing = true;
    readonly Path[] paths;
    readonly double[] lens, pows, amps, speeds, shifts, breathW, breathP;
    readonly TranslateTransform knob;
    readonly double knobHalf, h, baseY, taper, fadeIn, fullAt;
    readonly Stopwatch clock = Stopwatch.StartNew();
    double lastDraw = -1, frozenT = -1, lastX = -1;
    // Jeda minimum antar gambar (detik); diatur island sesuai refresh rate layar
    public static double FrameTime = 0.0155;
    bool hooked;
    // Tinggi tiap lapis terhadap garis luar bersama, dan wadah garis luar itu (dipakai ulang tiap frame)
    static readonly double[] nest = { 1.0, 0.70, 0.45 };
    double[] prof = new double[0];
    // Satu pola bukit (0..1) lapis j di posisi x pada waktu t
    double Wave(double x, double t, int j) { return (1 - Math.Cos(2 * Math.PI * (x - speeds[j] * t + shifts[j]) / lens[j])) / 2; }
    // Maksimum dua nilai dengan sudut yang dibulatkan selebar k (polynomial smooth max)
    static double SMax(double a, double b, double k) { double d = Math.Max(k - Math.Abs(a - b), 0) / k; return Math.Max(a, b) + d * d * k * 0.25; }

    // ampScale: tinggi bukit saja (kartu musik sedikit lebih tinggi dari versi kecil di mini island)
    public IslandWave(double h, double baseY, double scale, double ampScale, Color[] colors, TranslateTransform knob, double knobHalf) {
        this.h = h; this.baseY = baseY; this.knob = knob; this.knobHalf = knobHalf;
        // Naik landai di awal bar dan turun landai menjelang titik (bukan tebing)
        taper = 50 * scale; fadeIn = 50 * scale; fullAt = 90 * scale;
        // Lebar bukit, kerampingan, tinggi, kecepatan (px/detik) per lapis; sengaja tidak sebanding
        lens = new[] { 170 * scale, 124 * scale, 92 * scale };
        // Pangkat 1 = gelombang sinus murni (puncak bulat). Pangkat > 1 membuat puncak runcing.
        pows = new[] { 1.0, 1.0, 1.0 };
        amps = new[] { 11.0 * scale * ampScale, 8.5 * scale * ampScale, 6.5 * scale * ampScale };
        // Semua lapis mengalir sama cepat (beda kecepatan membuat bentuknya acak dan janggal)
        speeds = new[] { 22.0 * scale, 22.0 * scale, 22.0 * scale };
        shifts = new[] { 0.0, 47 * scale, 21 * scale };
        breathW = new[] { 0.55, 0.83, 1.07 };
        breathP = new[] { 0.0, 2.1, 4.0 };
        Root.Height = h; Root.ClipToBounds = true; Root.IsHitTestVisible = false;
        paths = new Path[3];
        for (int i = 0; i < 3; i++) {
            // Gradasi satu warna per lapis: puncak bukit = warna lapisnya yang lebih terang, kakinya = warna itu
            // sendiri yang memudar ke arah bar (gradasi antar dua warna berbeda menghasilkan warna keruh)
            var c = colors[i];
            var hi = Color.FromArgb(225, (byte)(c.R + (255 - c.R) * 0.4), (byte)(c.G + (255 - c.G) * 0.4), (byte)(c.B + (255 - c.B) * 0.4));
            var fill = new LinearGradientBrush();
            fill.MappingMode = BrushMappingMode.Absolute;
            fill.StartPoint = new Point(0, baseY - amps[i]); fill.EndPoint = new Point(0, baseY);
            fill.GradientStops.Add(new GradientStop(hi, 0));
            fill.GradientStops.Add(new GradientStop(Color.FromArgb(120, c.R, c.G, c.B), 1));
            fill.Freeze();
            paths[i] = new Path { Fill = fill };
            Root.Children.Add(paths[i]);
        }
        Root.Loaded += (s, e) => { if (!hooked) { CompositionTarget.Rendering += OnRender; hooked = true; } };
        Root.Unloaded += (s, e) => { if (hooked) { CompositionTarget.Rendering -= OnRender; hooked = false; } };
    }

    static double Smooth(double u) { if (u <= 0) return 0; if (u >= 1) return 1; return u * u * (3 - 2 * u); }

    void OnRender(object sender, EventArgs e) {
        double now = clock.Elapsed.TotalSeconds;
        double W = Root.ActualWidth;
        double X = Math.Min(W, Math.Max(0, knob.X + knobHalf));
        double t;
        if (Playing) { t = now; frozenT = -1; if (lastDraw >= 0 && now - lastDraw < FrameTime) return; }
        else { if (frozenT < 0) frozenT = now; t = frozenT; if (X == lastX && lastDraw >= 0) return; }
        lastDraw = now; lastX = X;
        // Lereng naik di awal bar dan turun menjelang titik sama panjang (bentuk simetris, tidak miring)
        double tap = Math.Max(1, Math.Min(taper, X * 0.4)), fin = tap;
        // Tinggi gelombang dibatasi panjang bar (maks ~11% panjangnya): bar pendek di awal lagu dapat
        // gelombang rendah, jadi tidak membentuk gundukan/segitiga bersisi curam
        double grow = Math.Min(1.0, X * 0.11 / Math.Max(1, amps[0]));
        // Garis luar = gabungan ketiga bukit, dengan sudut di persilangannya dibulatkan (smooth max), lalu ketiga
        // lapis digambar bersarang di dalamnya (100% / 70% / 45%): tidak ada tepi yang bersilangan atau bersudut
        int n = (int)Math.Ceiling(X);
        if (prof.Length < n + 1) prof = new double[n + 64];
        double a0 = grow * amps[0] * (0.72 + 0.28 * Math.Sin(t * breathW[0] + breathP[0]));
        double a1 = grow * amps[1] * (0.72 + 0.28 * Math.Sin(t * breathW[1] + breathP[1]));
        double a2 = grow * amps[2] * (0.72 + 0.28 * Math.Sin(t * breathW[2] + breathP[2]));
        double k = Math.Max(0.5, 0.4 * a0);
        for (int j = 0; j <= n; j++) {
            double x = Math.Min(j, X);
            double env = Smooth(x / fin) * Smooth((X - x) / tap);
            // Lembah tidak sampai ke bar (minimal 30% tinggi), jadi tidak ada celah kosong di antara bukit
            double h0 = a0 * (0.3 + 0.7 * Wave(x, t, 0)), h1 = a1 * (0.3 + 0.7 * Wave(x, t, 1)), h2 = a2 * (0.3 + 0.7 * Wave(x, t, 2));
            prof[j] = env * SMax(SMax(h0, h1, k), h2, k);
        }
        for (int i = 0; i < 3; i++) {
            var g = new StreamGeometry();
            using (var ctx = g.Open()) {
                ctx.BeginFigure(new Point(0, h), true, true);
                for (int j = 0; j <= n; j++) ctx.LineTo(new Point(Math.Min(j, X), baseY - prof[j] * nest[i]), true, true);
                ctx.LineTo(new Point(X, h), true, false);
            }
            g.Freeze();
            paths[i].Data = g;
        }
    }
}
'@
# Ikon aplikasi dari shell Windows (cadangan untuk aplikasi non-Store seperti Discord yang logonya tidak
# diberikan API notifikasi), dan isi XML notifikasi dari database notifikasi Windows (untuk foto pengirim)
Add-IslandType -Refs $WPF_REFS @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
public static class IslandShell {
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm); }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)] struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory item);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int size, ref BITMAP bm);

    // Ikon (dengan transparansi) untuk "shell:AppsFolder\<AUMID>" atau path file
    public static BitmapSource Icon(string parsingName, int size) {
        IShellItemImageFactory f;
        SHCreateItemFromParsingName(parsingName, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out f);
        IntPtr hb;
        if (f.GetImage(new SIZE { cx = size, cy = size }, 0x4, out hb) != 0 || hb == IntPtr.Zero) return null;   // 0x4 = hanya ikon
        try {
            var bm = new BITMAP();
            GetObject(hb, Marshal.SizeOf(typeof(BITMAP)), ref bm);
            if (bm.bmBits == IntPtr.Zero || bm.bmBitsPixel != 32) return null;
            int stride = bm.bmWidthBytes, h = Math.Abs(bm.bmHeight);
            var px = new byte[stride * h];
            Marshal.Copy(bm.bmBits, px, 0, px.Length);
            // Bitmap DIB tersimpan dari baris bawah ke atas
            var rows = new byte[px.Length];
            for (int y = 0; y < h; y++) Buffer.BlockCopy(px, y * stride, rows, (h - 1 - y) * stride, stride);
            var bs = BitmapSource.Create(bm.bmWidth, h, 96, 96, PixelFormats.Pbgra32, null, rows, stride);
            bs.Freeze();
            return bs;
        } finally { DeleteObject(hb); }
    }
}
public static class IslandWpn {
    [DllImport("winsqlite3.dll")] static extern int sqlite3_open_v2(byte[] f, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_bind_int64(IntPtr st, int i, long v);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_step(IntPtr st);
    [DllImport("winsqlite3.dll")] static extern IntPtr sqlite3_column_blob(IntPtr st, int i);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_column_bytes(IntPtr st, int i);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_finalize(IntPtr st);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_close(IntPtr db);
    static byte[] Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

    // XML notifikasi (toast) dengan Id yang sama seperti UserNotification.Id; null kalau tidak ada.
    // Database dibuka hanya-baca.
    public static string Payload(long id) {
        string path = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData) + @"\Microsoft\Windows\Notifications\wpndatabase.db";
        IntPtr db, st;
        if (sqlite3_open_v2(Z(path), out db, 1, IntPtr.Zero) != 0) { sqlite3_close(db); return null; }
        string result = null;
        try {
            if (sqlite3_prepare_v2(db, Z("SELECT Payload FROM Notification WHERE Id = ?1"), -1, out st, IntPtr.Zero) != 0) return null;
            sqlite3_bind_int64(st, 1, id);
            if (sqlite3_step(st) == 100) {
                int n = sqlite3_column_bytes(st, 0);
                var b = new byte[n];
                if (n > 0) Marshal.Copy(sqlite3_column_blob(st, 0), b, 0, n);
                result = Encoding.UTF8.GetString(b);
            }
            sqlite3_finalize(st);
        } finally { sqlite3_close(db); }
        return result;
    }
}
'@
# Volume utama Windows lewat Core Audio (IAudioEndpointVolume pada perangkat output default).
# VolumeWatcher memberi tahu island setiap volume berubah (tombol keyboard, taskbar, aplikasi lain).
Add-IslandType -Refs @([System.Windows.Threading.Dispatcher].Assembly.Location) @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Threading;
[ComVisible(true), Guid("657804FA-D6AD-4496-8A60-352752AF4F89"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioEndpointVolumeCallback { [PreserveSig] int OnNotify(IntPtr data); }
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IAudioEndpointVolume {
    [PreserveSig] int RegisterControlChangeNotify(IntPtr p); [PreserveSig] int UnregisterControlChangeNotify(IntPtr p);
    int GetChannelCount();
    int SetMasterVolumeLevel();
    [PreserveSig] int SetMasterVolumeLevelScalar(float level, ref Guid ctx);
    int GetMasterVolumeLevel();
    [PreserveSig] int GetMasterVolumeLevelScalar(out float level);
    int SetChannelVolumeLevel(); int SetChannelVolumeLevelScalar(); int GetChannelVolumeLevel(); int GetChannelVolumeLevelScalar();
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx);
    [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o);
    int OpenPropertyStore();
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IMMDeviceEnumerator { int NotImpl1(); [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice dev); }
public static class SysVolume {
    // Perubahan dari slider island sendiri ditandai dengan konteks ini (tidak perlu pop-up volume)
    public static readonly Guid Own = new Guid("6C1E3F3A-5B7D-4D8E-9C21-1A2B3C4D5E6F");
    // Enumerator perangkat audio satu objek bersama untuk seluruh proses (AppAudio juga memakainya): dibuat
    // lewat CLSID dan langsung di-cast ke interface. Cast ke kelas pembungkus sendiri gagal kalau objeknya
    // sudah lebih dulu dibungkus kelas lain.
    static readonly Type enumType = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
    // Perangkat default diambil ulang tiap kali, jadi tetap benar kalau output pindah (mis. ke headset)
    internal static IMMDevice Device() {
        var en = (IMMDeviceEnumerator)Activator.CreateInstance(enumType); IMMDevice dev;
        Marshal.ThrowExceptionForHR(en.GetDefaultAudioEndpoint(0, 1, out dev));
        return dev;
    }
    internal static IAudioEndpointVolume Vol(IMMDevice dev) {
        var iid = typeof(IAudioEndpointVolume).GUID; object o;
        Marshal.ThrowExceptionForHR(dev.Activate(ref iid, 23, IntPtr.Zero, out o));
        return (IAudioEndpointVolume)o;
    }
    static IAudioEndpointVolume Vol() { return Vol(Device()); }
    public static float Get() { float v; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return v; }
    public static void Set(float v) { var g = Own; Marshal.ThrowExceptionForHR(Vol().SetMasterVolumeLevelScalar(Math.Max(0f, Math.Min(1f, v)), ref g)); }
    public static bool GetMute() { bool m; Marshal.ThrowExceptionForHR(Vol().GetMute(out m)); return m; }
    public static void SetMute(bool m) { var g = Own; Marshal.ThrowExceptionForHR(Vol().SetMute(m, ref g)); }
}
// Callback Core Audio datang dari thread audio; event Changed dijalankan di thread UI island
public class VolumeWatcher : IAudioEndpointVolumeCallback {
    public event EventHandler Changed;
    public float Level; public bool Muted; public bool Own; public string Error;
    readonly Dispatcher ui = Dispatcher.CurrentDispatcher;
    IAudioEndpointVolume vol; IntPtr cbPtr = IntPtr.Zero; string deviceId;
    public string DeviceId { get { return deviceId; } }
    public VolumeWatcher() { Check(); }
    // Dipanggil berkala: daftar ulang kalau perangkat output default berganti
    public void Check() {
        try {
            var dev = SysVolume.Device(); string id; dev.GetId(out id);
            if (id == deviceId && vol != null) return;
            Stop();
            vol = SysVolume.Vol(dev); deviceId = id;
            cbPtr = Marshal.GetComInterfaceForObject(this, typeof(IAudioEndpointVolumeCallback));
            Marshal.ThrowExceptionForHR(vol.RegisterControlChangeNotify(cbPtr));
            Error = null;
        } catch (Exception ex) { Error = ex.Message; }
    }
    public void Stop() {
        try { if (vol != null && cbPtr != IntPtr.Zero) vol.UnregisterControlChangeNotify(cbPtr); } catch { }
        if (cbPtr != IntPtr.Zero) { Marshal.Release(cbPtr); cbPtr = IntPtr.Zero; }
        vol = null; deviceId = null;
    }
    public int OnNotify(IntPtr data) {
        // AUDIO_VOLUME_NOTIFICATION_DATA: GUID konteks, BOOL bMuted, float fMasterVolume, ...
        try {
            var ctx = new byte[16]; Marshal.Copy(data, ctx, 0, 16);
            Own = new Guid(ctx) == SysVolume.Own;
            Muted = Marshal.ReadInt32(data, 16) != 0;
            Level = BitConverter.ToSingle(BitConverter.GetBytes(Marshal.ReadInt32(data, 20)), 0);
            ui.BeginInvoke(new Action(() => { var h = Changed; if (h != null) h(this, EventArgs.Empty); }));
        } catch { }
        return 0;
    }
}
'@
# Suara per aplikasi (sesi audio di semua perangkat output aktif): puncak level untuk memilih pemutar yang
# benar-benar bersuara (video bisu di browser tetap melapor "Playing" ke Windows), dan volume/bisu per
# aplikasi untuk slider volume kartu musik.
Add-IslandType @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IAaDeviceEnumerator { [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IAaDeviceCollection devices); }
[Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IAaDeviceCollection { [PreserveSig] int GetCount(out int n); [PreserveSig] int Item(int i, out IAaDevice dev); }
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IAaDevice { [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr p, [MarshalAs(UnmanagedType.IUnknown)] out object o); }
[Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IAaSessionManager2 { int GetAudioSessionControl(); int GetSimpleAudioVolume(); [PreserveSig] int GetSessionEnumerator(out IAaSessionEnumerator e); }
[Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IAaSessionEnumerator { [PreserveSig] int GetCount(out int n); [PreserveSig] int GetSession(int i, out IAaSessionControl2 s); }
[Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IAaSessionControl2 {
    int GetState(); int GetDisplayName(); int SetDisplayName(); int GetIconPath(); int SetIconPath(); int GetGroupingParam();
    int SetGroupingParam(); int RegisterAudioSessionNotification(); int UnregisterAudioSessionNotification();
    int GetSessionIdentifier(); int GetSessionInstanceIdentifier(); [PreserveSig] int GetProcessId(out uint pid);
}
[Guid("C02216F6-8C67-4B5B-9D00-D008E73E0064"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IAaMeter { [PreserveSig] int GetPeakValue(out float peak); }
[Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown), ComImport]
interface IAaSimpleVolume {
    [PreserveSig] int SetMasterVolume(float level, ref Guid ctx); [PreserveSig] int GetMasterVolume(out float level);
    [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool mute, ref Guid ctx); [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool mute);
}
public static class AppAudio {
    // Enumerator perangkat audio dipakai bersama satu proses dan SysVolume sudah membungkusnya dengan kelasnya
    // sendiri: dibuat lewat CLSID dan langsung di-cast ke interface (cast ke kelas lain akan gagal)
    static readonly Type enumType = Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E"));
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern int GetPackageFamilyName(IntPtr h, ref uint len, StringBuilder name);
    static readonly Dictionary<uint, string[]> keys = new Dictionary<uint, string[]>();
    static Guid ctx = new Guid("3D1F7A52-8C4B-4E6A-B1D9-5F2E0C7A9B41");

    // Semua sesi audio (PID + sesinya) di semua perangkat output aktif
    static List<KeyValuePair<uint, IAaSessionControl2>> Sessions() {
        var r = new List<KeyValuePair<uint, IAaSessionControl2>>();
        var en = (IAaDeviceEnumerator)Activator.CreateInstance(enumType);
        IAaDeviceCollection devs; int nd;
        if (en.EnumAudioEndpoints(0, 1, out devs) != 0 || devs.GetCount(out nd) != 0) return r;   // eRender, aktif
        for (int d = 0; d < nd; d++) {
            try {
                IAaDevice dev; object o; IAaSessionEnumerator se; int n;
                var iid = typeof(IAaSessionManager2).GUID;
                if (devs.Item(d, out dev) != 0 || dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) continue;
                if (((IAaSessionManager2)o).GetSessionEnumerator(out se) != 0 || se.GetCount(out n) != 0) continue;
                for (int i = 0; i < n; i++) {
                    try {
                        IAaSessionControl2 s; uint pid;
                        if (se.GetSession(i, out s) != 0) continue;
                        s.GetProcessId(out pid);
                        if (pid != 0) r.Add(new KeyValuePair<uint, IAaSessionControl2>(pid, s));
                    } catch { }
                }
            } catch { }
        }
        // Proses yang tidak punya sesi audio lagi dilupakan: PID-nya bisa dipakai ulang oleh proses lain
        var live = new Dictionary<uint, bool>();
        foreach (var s in r) live[s.Key] = true;
        foreach (var p in new List<uint>(keys.Keys)) if (!live.ContainsKey(p)) keys.Remove(p);
        return r;
    }

    // Puncak level (0..1) per aplikasi. Kunci: nama proses, dan untuk aplikasi Store juga nama keluarga
    // paketnya (= awalan AUMID sesi media, mis. AppleInc.AppleMusicWin_nzyj5cx40ttqa)
    public static Dictionary<string, float> Peaks() {
        var r = new Dictionary<string, float>(StringComparer.OrdinalIgnoreCase);
        foreach (var s in Sessions()) {
            try {
                float peak;
                if (((IAaMeter)s.Value).GetPeakValue(out peak) != 0) continue;
                foreach (var k in Keys(s.Key)) { float v; if (!r.TryGetValue(k, out v) || peak > v) r[k] = peak; }
            } catch { }
        }
        return r;
    }

    // Volume satu aplikasi = volume sesi-sesi audionya (yang diatur volume mixer Windows). Daftar sesinya
    // disimpan 2 detik: slider yang sedang digeser memanggil ini puluhan kali per detik.
    static string volKey; static List<IAaSimpleVolume> volList; static DateTime volAt;
    static List<IAaSimpleVolume> Volumes(string key) {
        if (key == volKey && volList != null && (DateTime.UtcNow - volAt).TotalSeconds < 2) return volList;
        var list = new List<IAaSimpleVolume>();
        foreach (var s in Sessions()) {
            foreach (var k in Keys(s.Key)) {
                if (!string.Equals(k, key, StringComparison.OrdinalIgnoreCase)) continue;
                try { list.Add((IAaSimpleVolume)s.Value); } catch { }
                break;
            }
        }
        volKey = key; volList = list; volAt = DateTime.UtcNow;
        return list;
    }
    // Volume aplikasi (0..1), atau -1 kalau aplikasinya belum punya sesi audio (belum pernah bersuara)
    public static float GetVolume(string key) {
        float best = -1;
        foreach (var v in Volumes(key)) { float l; try { if (v.GetMasterVolume(out l) == 0 && l > best) best = l; } catch { } }
        return best;
    }
    public static void SetVolume(string key, float level) {
        level = Math.Max(0f, Math.Min(1f, level));
        foreach (var v in Volumes(key)) { try { v.SetMasterVolume(level, ref ctx); } catch { } }
    }
    // Bisu kalau semua sesinya dibisukan
    public static bool GetMute(string key) {
        bool any = false;
        foreach (var v in Volumes(key)) { bool m; try { if (v.GetMute(out m) != 0) continue; if (!m) return false; any = true; } catch { } }
        return any;
    }
    public static void SetMute(string key, bool mute) {
        foreach (var v in Volumes(key)) { try { v.SetMute(mute, ref ctx); } catch { } }
    }

    static string[] Keys(uint pid) {
        string[] k;
        if (keys.TryGetValue(pid, out k)) return k;
        var list = new List<string>();
        try { list.Add(Process.GetProcessById((int)pid).ProcessName); } catch { }
        IntPtr h = OpenProcess(0x1000, false, pid);   // PROCESS_QUERY_LIMITED_INFORMATION
        if (h != IntPtr.Zero) {
            try { uint len = 256; var sb = new StringBuilder(256); if (GetPackageFamilyName(h, ref len, sb) == 0) list.Add(sb.ToString()); }
            finally { CloseHandle(h); }
        }
        // Gagal dibaca (mis. proses baru saja keluar): tidak disimpan, dicoba lagi lain kali
        k = list.ToArray();
        if (k.Length > 0) keys[pid] = k;
        return k;
    }
}
'@
# Kecerahan layar (laptop / monitor yang mendukung) berubah: event WMI, diteruskan ke thread UI
Add-Type -AssemblyName System.Management
Add-IslandType -Refs @([System.Windows.Threading.Dispatcher].Assembly.Location, [System.Management.ManagementEventWatcher].Assembly.Location) @'
using System;
using System.Management;
using System.Windows.Threading;
public class BrightnessWatcher {
    public event EventHandler Changed;
    public int Level;
    readonly Dispatcher ui = Dispatcher.CurrentDispatcher;
    readonly ManagementEventWatcher w;
    public BrightnessWatcher() {
        w = new ManagementEventWatcher(new ManagementScope(@"root\wmi"), new EventQuery("SELECT * FROM WmiMonitorBrightnessEvent"));
        w.EventArrived += (s, e) => {
            try { Level = Convert.ToInt32(e.NewEvent["Brightness"]); } catch { return; }
            ui.BeginInvoke(new Action(() => { var h = Changed; if (h != null) h(this, EventArgs.Empty); }));
        };
        w.Start();
    }
    public void Stop() { try { w.Stop(); } catch { } }
}
'@
# Aplikasi seperti WeChat tidak memakai notifikasi Windows; yang bisa ditangkap hanya
# kedipan tombol taskbar-nya (HSHELL_FLASH) lewat shell hook.
Add-Type -AssemblyName System.Windows.Forms
Add-IslandType -Refs @([System.Windows.Forms.Form].Assembly.Location) @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Forms;
// Menangkap scroll horizontal (swipe dua jari di touchpad) yang tidak diekspos WPF
public class HWheelHook : NativeWindow {
    public event EventHandler Scrolled;
    public int Delta;
    public HWheelHook(IntPtr hWnd) { AssignHandle(hWnd); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x020E) {
            Delta = (short)((m.WParam.ToInt64() >> 16) & 0xFFFF);
            if (Scrolled != null) Scrolled(this, EventArgs.Empty);
            m.Result = IntPtr.Zero;
            return;
        }
        base.WndProc(ref m);
    }
}
public class FlashWatcher : NativeWindow {
    [DllImport("user32.dll")] static extern int RegisterWindowMessage(string msg);
    [DllImport("user32.dll")] static extern bool RegisterShellHookWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool DeregisterShellHookWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    const int HSHELL_FLASH = 0x8006;
    readonly int shellMsg;
    readonly List<IntPtr> flashes = new List<IntPtr>();
    public FlashWatcher() {
        CreateHandle(new CreateParams());
        shellMsg = RegisterWindowMessage("SHELLHOOK");
        RegisterShellHookWindow(Handle);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == shellMsg && m.WParam.ToInt32() == HSHELL_FLASH) flashes.Add(m.LParam);
        base.WndProc(ref m);
    }
    public IntPtr[] Drain() { var a = flashes.ToArray(); flashes.Clear(); return a; }
    public void Stop() { DeregisterShellHookWindow(Handle); DestroyHandle(); }
    public static Process ProcessOf(IntPtr hWnd) {
        uint pid; GetWindowThreadProcessId(hWnd, out pid);
        try { return Process.GetProcessById((int)pid); } catch { return null; }
    }
}
'@
# DLL dari versi kode sebelumnya tidak terpakai lagi
try { Get-ChildItem $cacheDir -Filter 'island-*.dll' -ErrorAction Stop | Where-Object { $script:usedDlls -notcontains $_.FullName } | Remove-Item -Force -ErrorAction SilentlyContinue } catch {}
$null = [Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications, ContentType=WindowsRuntime]
$null = [Windows.UI.Notifications.UserNotification, Windows.UI.Notifications, ContentType=WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType=WindowsRuntime]
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType=WindowsRuntime]
$asStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@([Windows.Storage.Streams.IInputStream]))

$asTaskGeneric = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
} | Select-Object -First 1
function Await($op, [Type]$type) {
    $task = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    if (-not $task.Wait(3000)) { throw 'WinRT timeout' }
    $task.Result
}

$listener = [Windows.UI.Notifications.Management.UserNotificationListener]::Current
$access = Await ($listener.RequestAccessAsync()) ([Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus])
if ($access -ne 'Allowed') {
    [System.Windows.MessageBox]::Show((T "Island butuh izin membaca notifikasi.`nBuka Settings > Privacy & security > Notifications, lalu aktifkan akses notifikasi." "Island needs permission to read notifications.`nOpen Settings > Privacy & security > Notifications and allow notification access."), 'Mini Island') | Out-Null
    exit
}

# ---------- UI ----------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        Width="1000" Height="460" FontFamily="Segoe UI Variable Text, Segoe UI">
  <Window.Resources>
    <!-- Semua tooltip island ikut tema: kaca gelap, sudut membulat, teks putih -->
    <Style TargetType="ToolTip">
      <Setter Property="OverridesDefaultStyle" Value="True"/>
      <Setter Property="HasDropShadow" Value="False"/>
      <Setter Property="Foreground" Value="#F2FFFFFF"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border CornerRadius="10" Padding="10,6" BorderThickness="1">
              <Border.Background>
                <LinearGradientBrush StartPoint="0,0.5" EndPoint="1,0.5">
                  <GradientStop Color="#EE202024" Offset="0"/>
                  <GradientStop Color="#EE121214" Offset="1"/>
                </LinearGradientBrush>
              </Border.Background>
              <Border.BorderBrush>
                <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                  <GradientStop Color="#6EFFFFFF" Offset="0"/>
                  <GradientStop Color="#18FFFFFF" Offset="0.5"/>
                  <GradientStop Color="#2EFFFFFF" Offset="1"/>
                </LinearGradientBrush>
              </Border.BorderBrush>
              <ContentPresenter/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Grid>
    <Border x:Name="HotZone" Background="#01000000" Width="160" Height="8"
            HorizontalAlignment="Center" VerticalAlignment="Top">
      <Border x:Name="Handle" Width="8" Height="4" CornerRadius="2" Opacity="0"
              Background="#9A9AA0" BorderBrush="#40000000" BorderThickness="0.5"
              HorizontalAlignment="Center" VerticalAlignment="Center"/>
    </Border>
    <!-- Titik mikrofon (oranye) / kamera (hijau) sedang dipakai, di kanan garis penanda -->
    <StackPanel x:Name="SensorDots" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Top"
                Margin="96,2,0,0">
      <Ellipse x:Name="MicDot" Width="0" Height="5" Fill="#FF9F0A" Margin="2,0"/>
      <Ellipse x:Name="CamDot" Width="0" Height="5" Fill="#30D158" Margin="2,0"/>
    </StackPanel>
    <!-- Island; di kanannya gelembung kecil untuk timer saat island sedang dipakai lagu -->
    <StackPanel x:Name="IslandRow" Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Top" Margin="0,8,0,0">
    <Grid VerticalAlignment="Top">
    <!-- Cahaya samar warna album di belakang island selama lagu diputar (diam, tidak berkedip). Ukuran, sudut,
         geseran dan opacity-nya mengikuti island, jadi ikut menghilang saat island memudar. -->
    <Grid x:Name="GlowWrap" VerticalAlignment="Top" IsHitTestVisible="False">
    <Border x:Name="Glow" VerticalAlignment="Top" IsHitTestVisible="False" Background="#00000000"
            Width="{Binding ActualWidth, ElementName=Island}" Height="{Binding ActualHeight, ElementName=Island}"
            CornerRadius="{Binding CornerRadius, ElementName=Island}" Opacity="{Binding Opacity, ElementName=Island}"
            RenderTransform="{Binding RenderTransform, ElementName=Island}">
      <Border.Effect><BlurEffect Radius="16" RenderingBias="Performance"/></Border.Effect>
      <!-- Hasil blur disimpan sebagai bitmap: jendela transparan digambar ulang seluruhnya tiap ada animasi
           (gelombang, equalizer), dan tanpa cache cahaya ini ikut di-blur ulang 60 kali per detik
           (sekitar 40% dari CPU island saat lagu diputar). Napasnya (opacity) tidak membuat cache dibuat ulang. -->
      <Border.CacheMode><BitmapCache/></Border.CacheMode>
    </Border>
    </Grid>
    <Border x:Name="Island" Background="Black" CornerRadius="15" Width="120" Height="30" Opacity="0" IsHitTestVisible="False"
            BorderThickness="1" BorderBrush="#40FFFFFF" VerticalAlignment="Top" ClipToBounds="True">
      <Grid x:Name="IslandContent">
        <Grid x:Name="NotifView" Margin="12,0,22,0" Opacity="0" IsHitTestVisible="False">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <Border x:Name="NIconHost" VerticalAlignment="Center"/>
          <StackPanel Grid.Column="1" Margin="10,0,8,0" VerticalAlignment="Center">
            <TextBlock x:Name="NTitle" Foreground="White" FontSize="13" FontWeight="SemiBold" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="NBody" Foreground="#B8B8BD" FontSize="12" TextTrimming="CharacterEllipsis" Margin="0,1,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="2" VerticalAlignment="Center">
            <TextBlock x:Name="NAppName" FontSize="10.5" FontWeight="SemiBold" HorizontalAlignment="Right" MaxWidth="80" TextTrimming="CharacterEllipsis"/>
            <TextBlock x:Name="NApp" Foreground="#8E8E93" FontSize="10.5" HorizontalAlignment="Right" Margin="0,1,0,0"/>
          </StackPanel>
        </Grid>
        <Border x:Name="MediaView" Opacity="0" IsHitTestVisible="False"/>
        <StackPanel x:Name="ListView" Margin="8,12" Opacity="0" IsHitTestVisible="False"/>
        <Grid x:Name="MiniView" Opacity="0" IsHitTestVisible="False"/>
        <Grid x:Name="ActivityView" Opacity="0" IsHitTestVisible="False"/>
      </Grid>
    </Border>
    </Grid>
    <Border x:Name="Bubble" Height="24" Width="0" Opacity="0" CornerRadius="12" Margin="0" VerticalAlignment="Top"
            Background="#E6000000" BorderThickness="1" BorderBrush="#40FFFFFF" IsHitTestVisible="False" ClipToBounds="True">
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" VerticalAlignment="Center">
        <TextBlock x:Name="BubbleGlyph" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10" Foreground="#FF9F0A" VerticalAlignment="Center"/>
        <TextBlock x:Name="BubbleText" FontSize="10.5" FontWeight="SemiBold" Foreground="#FF9F0A" Margin="4,0,0,0" VerticalAlignment="Center"/>
      </StackPanel>
    </Border>
    </StackPanel>
  </Grid>
</Window>
'@
$window = [Windows.Markup.XamlReader]::Parse($xaml)
$island = $window.FindName('Island')
$hotZone = $window.FindName('HotZone')
$islandContent = $window.FindName('IslandContent')
$handle = $window.FindName('Handle')
$glowWrap = $window.FindName('GlowWrap'); $glow = $window.FindName('Glow'); $glow.Background = New-Object System.Windows.Media.SolidColorBrush([System.Windows.Media.Colors]::Transparent)
$bubble = $window.FindName('Bubble'); $bubbleText = $window.FindName('BubbleText'); $bubbleGlyph = $window.FindName('BubbleGlyph')
$sensorDots = $window.FindName('SensorDots'); $micDot = $window.FindName('MicDot'); $camDot = $window.FindName('CamDot')
$views = @{}
foreach ($v in 'NotifView', 'ListView', 'MediaView', 'MiniView', 'ActivityView') { $views[$v] = $window.FindName($v) }
# Teks yang terus bergerak (lirik, judul berjalan): digambar tanpa dikunci ke piksel, supaya geserannya
# mulus per sub-piksel dan tidak meloncat 1 piksel tiap beberapa frame
[System.Windows.Media.TextOptions]::SetTextHintingMode($views['MiniView'], [System.Windows.Media.TextHintingMode]::Animated)
$mediaView = $views['MediaView']
$nIconHost = $window.FindName('NIconHost'); $nTitle = $window.FindName('NTitle'); $nBody = $window.FindName('NBody'); $nApp = $window.FindName('NApp'); $nAppName = $window.FindName('NAppName')
$listPanel = $views['ListView']

$IDLE_W = 120; $IDLE_H = 30; $WIDE_W = 340; $NOTIF_H = 56; $ITEM_H = 48; $MAX_ITEMS = 4
# Mini island selama lagu diputar: sekecil island diam supaya tidak menutupi tab/judul aplikasi
$MINI_W = 148; $MINI_H = 28
# Lebar area judul berjalan di pil kecil (sisa setelah cover, equalizer, dan jarak)
$MINI_TEXT_W = $MINI_W - 66

function Brush($hex) { (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex) }
function Ms($n) { [TimeSpan]::FromMilliseconds($n) }

function Animate($el, $prop, $to, $ms, $delay = 0, $from = $null, $bouncy = $false) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation
    $a.To = $to
    if ($null -ne $from) { $a.From = $from }
    $a.Duration = New-Object System.Windows.Duration (Ms $ms)
    $a.BeginTime = Ms $delay
    if ($bouncy) { $e = New-Object System.Windows.Media.Animation.BackEase; $e.Amplitude = 0.3 }
    else { $e = New-Object System.Windows.Media.Animation.CubicEase }
    $e.EasingMode = 'EaseOut'
    $a.EasingFunction = $e
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $ANIM_FPS)
    $el.BeginAnimation($prop, $a)
}

# -Smooth: tanpa pantulan, lebih pelan (dipakai saat island menghilang supaya seirama dengan fade out)
function Resize-Island($w, $h, $radius, [switch]$Smooth, $Ms = 0) {
    $island.CornerRadius = New-Object System.Windows.CornerRadius($radius)
    $ms = if ($Ms -gt 0) { $Ms } elseif ($Smooth) { 520 } else { 420 }
    Animate $island ([System.Windows.FrameworkElement]::WidthProperty) $w $ms 0 $null (-not $Smooth)
    Animate $island ([System.Windows.FrameworkElement]::HeightProperty) $h $ms 0 $null (-not $Smooth)
}

# Durasi fade out tampilan lama saat pindah tampilan (Go-Idle memakai yang lebih panjang)
$script:viewFadeOutMs = 140
function Show-View($name, [switch]$Replay) {
    # Tampilan lain menggantikan mini island: equalizer-nya dibuang setelah selesai memudar
    if ($name -ne 'MiniView' -and $script:miniOn) { $script:miniOn = $false; $cleanupTimer.Stop(); $cleanupTimer.Start() }
    foreach ($v in $views.Keys) {
        $el = $views[$v]
        if ($v -eq $name) {
            $from = if ($Replay) { 0 } else { $null }
            Animate $el ([System.Windows.UIElement]::OpacityProperty) 1 340 120 $from
            # Masuk sambil naik sedikit (daftar punya animasi geser sendiri)
            if ($Replay -and $v -ne 'ListView') {
                $tt = New-Object System.Windows.Media.TranslateTransform(0, 6)
                $el.RenderTransform = $tt
                Animate60 $tt ([System.Windows.Media.TranslateTransform]::YProperty) 6.0 0.0 420 120
            }
            $el.IsHitTestVisible = $true
        } else {
            Animate $el ([System.Windows.UIElement]::OpacityProperty) 0 $script:viewFadeOutMs
            $el.IsHitTestVisible = $false
        }
    }
    Update-Bubble
}

# ---------- Warna ----------
$PALETTE = '#0A84FF', '#BF5AF2', '#FF9F0A', '#FF375F', '#64D2FF', '#30D158', '#5E5CE6'
$accentCache = @{}

function Rgb($r, $g, $b, $a = 255) { [System.Windows.Media.Color]::FromArgb([byte]$a, [byte]$r, [byte]$g, [byte]$b) }

# Warna dominan ikon: rata-rata piksel berbobot saturasi, lalu dicerahkan
function Get-DominantColor($bmp) {
    $src = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($bmp, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)
    $w = $src.PixelWidth; $h = $src.PixelHeight; $stride = $w * 4
    $px = New-Object byte[] ($stride * $h)
    $src.CopyPixels($px, $stride, 0)
    $sr = 0.0; $sg = 0.0; $sb = 0.0; $sw = 0.0
    for ($i = 0; $i -lt $px.Length; $i += 8) {
        if ($px[$i + 3] -lt 160) { continue }
        $b = $px[$i]; $g = $px[$i + 1]; $r = $px[$i + 2]
        $max = [Math]::Max($r, [Math]::Max($g, $b)); $min = [Math]::Min($r, [Math]::Min($g, $b))
        if ($max -lt 40) { continue }
        $sat = ($max - $min) / $max
        $wt = $sat * $sat + 0.02
        $sr += $r * $wt; $sg += $g * $wt; $sb += $b * $wt; $sw += $wt
    }
    if ($sw -eq 0) { return $null }
    $r = $sr / $sw; $g = $sg / $sw; $b = $sb / $sw
    $max = [Math]::Max($r, [Math]::Max($g, $b)); $min = [Math]::Min($r, [Math]::Min($g, $b))
    if ($max -le 0 -or (($max - $min) / $max) -lt 0.25) { return $null }
    $k = 235 / $max
    Rgb ($r * $k) ($g * $k) ($b * $k)
}

function Get-Accent($icon, $key) {
    if ($accentCache.ContainsKey($key)) { return $accentCache[$key] }
    $c = $null
    if ($icon) { try { $c = Get-DominantColor $icon } catch { Log "accent $key : $_" } }
    if (-not $c) {
        $hex = $PALETTE[("$key".GetHashCode() -band 0x7FFFFFFF) % $PALETTE.Count]
        $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    }
    # Tanpa ikon (mungkin hanya sementara gagal dibaca) warna cadangan tidak disimpan: ikon berikutnya dihitung ulang
    if ($icon) { $accentCache[$key] = $c }
    $c
}

# Satu kuas latar dipakai terus; ganti warna (lagu/aplikasi lain) dianimasikan, bukan diganti mendadak
$script:themeBrush = $null
function Set-Theme($c) {
    # Latar semi-transparan supaya tidak terlalu mencolok; teks tetap penuh
    $alpha = 170
    $tint = Rgb ($c.R * 0.3 + 6) ($c.G * 0.3 + 6) ($c.B * 0.3 + 7) $alpha
    if (-not $script:themeBrush) {
        $lg = New-Object System.Windows.Media.LinearGradientBrush
        $lg.StartPoint = '0,0.5'; $lg.EndPoint = '1,0.5'
        $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop($tint, 0)))
        $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb 14 14 16 $alpha), 0.45)))
        $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb 8 8 10 $alpha), 1)))
        $script:themeBrush = $lg
    } else {
        $ca = New-Object System.Windows.Media.Animation.ColorAnimation($tint, (New-Object System.Windows.Duration (Ms 650)))
        $e = New-Object System.Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $ca.EasingFunction = $e
        [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($ca, $ANIM_FPS)
        $script:themeBrush.GradientStops[0].BeginAnimation([System.Windows.Media.GradientStop]::ColorProperty, $ca)
    }
    $island.Background = $script:themeBrush
    $island.BorderBrush = $GLASS_BORDER
    # Cahaya warna album hanya selama lagu diputar dan island sedang menampilkan lagunya
    $on = $script:settings.Glow -and $script:media -and $script:media.Playing -and $c -eq $script:media.Accent
    $ga = New-Object System.Windows.Media.Animation.ColorAnimation((Rgb $c.R $c.G $c.B $(if ($on) { $GLOW_ALPHA } else { 0 })), (New-Object System.Windows.Duration (Ms 650)))
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($ga, $ANIM_FPS)
    $glow.Background.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ga)
    Set-GlowBreath $on
}

# Cahaya "bernapas": meredup dan menguat sangat pelan (6 detik per siklus) selama menyala. Saat dimatikan,
# napasnya dihentikan halus supaya tidak ada animasi yang terus jalan di latar.
$script:glowBreathing = $false
function Set-GlowBreath($on) {
    if ([bool]$on -eq $script:glowBreathing) { return }
    $script:glowBreathing = [bool]$on
    $op = [System.Windows.UIElement]::OpacityProperty
    if ($on) {
        $a = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.35, (New-Object System.Windows.Duration ([TimeSpan]::FromSeconds(3))))
        $a.AutoReverse = $true; $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $e = New-Object System.Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $a.EasingFunction = $e
        [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $AMBIENT_FPS)
        $glowWrap.BeginAnimation($op, $a)
    } else {
        Animate60 $glowWrap $op ([double]$glowWrap.Opacity) 1.0 650
    }
}
# Kekuatan cahaya warna album (0-255): sengaja samar supaya tidak mengganggu
$GLOW_ALPHA = 36

# Garis tepi gaya kaca: pantulan terang di atas, menipis ke tengah, sedikit memantul lagi di dasar
function New-GlassBorder {
    $b = New-Object System.Windows.Media.LinearGradientBrush
    $b.StartPoint = '0,0'; $b.EndPoint = '0,1'
    foreach ($s in @(@(110, 0.0), @(38, 0.3), @(12, 0.65), @(46, 1.0))) {
        $b.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb 255 255 255 $s[0]), $s[1])))
    }
    $b.Freeze()
    $b
}
$GLASS_BORDER = New-GlassBorder

function New-Icon($n, $size, $radius) {
    # Ada foto pengirim: foto bulat, ikon aplikasi kecil di pojok kanan bawahnya
    if ($n.Photo) {
        $g = New-Object System.Windows.Controls.Grid
        $g.Width = $size; $g.Height = $size
        $ph = New-Object System.Windows.Controls.Border
        $ph.CornerRadius = New-Object System.Windows.CornerRadius($size / 2)
        $ib = New-Object System.Windows.Media.ImageBrush($n.Photo); $ib.Stretch = 'UniformToFill'
        $ph.Background = $ib
        [void]$g.Children.Add($ph)
        if ($n.Icon) {
            $bs = [Math]::Round($size * 0.46)
            $badge = New-Object System.Windows.Controls.Border
            $badge.Width = $bs; $badge.Height = $bs
            $badge.CornerRadius = New-Object System.Windows.CornerRadius($bs * 0.3)
            $badge.BorderThickness = 1.5; $badge.BorderBrush = Brush '#F2141416'
            $bib = New-Object System.Windows.Media.ImageBrush($n.Icon); $bib.Stretch = 'Uniform'
            $badge.Background = $bib
            $badge.HorizontalAlignment = 'Right'; $badge.VerticalAlignment = 'Bottom'; $badge.Margin = '0,0,-3,-3'
            [void]$g.Children.Add($badge)
        }
        return $g
    }
    $b = New-Object System.Windows.Controls.Border
    $b.Width = $size; $b.Height = $size
    $b.CornerRadius = New-Object System.Windows.CornerRadius($radius)
    if ($n.Icon) {
        $ib = New-Object System.Windows.Media.ImageBrush($n.Icon)
        $ib.Stretch = 'Uniform'
        $b.Background = $ib
    } else {
        $c = $n.Accent
        $b.Background = New-Object System.Windows.Media.SolidColorBrush((Rgb ($c.R * 0.7) ($c.G * 0.7) ($c.B * 0.7)))
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = if ($n.App) { $n.App.Substring(0, 1).ToUpper() } else { '?' }
        $t.Foreground = Brush '#FFFFFF'; $t.FontWeight = 'SemiBold'; $t.FontSize = $size * 0.45
        $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
        $b.Child = $t
    }
    $b
}

# ---------- Notifikasi ----------
$iconCache = @{}
$notifCache = @{}
$seen = New-Object 'System.Collections.Generic.HashSet[uint32]'
$queue = New-Object System.Collections.Queue
$script:recent = @()
$script:mode = 'idle'
$script:current = $null
$script:hovering = $false
$script:overHot = $false
$script:initialized = $false

# Buang tepi transparan di logo supaya ikon terlihat penuh
function Trim-Bitmap($bmp) {
    $src = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($bmp, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)
    $w = $src.PixelWidth; $h = $src.PixelHeight; $stride = $w * 4
    $px = New-Object byte[] ($stride * $h)
    $src.CopyPixels($px, $stride, 0)
    $minX = $w; $minY = $h; $maxX = -1; $maxY = -1
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            if ($px[$y * $stride + $x * 4 + 3] -gt 24) {
                if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -lt 0) { return $bmp }
    $side = [Math]::Max($maxX - $minX + 1, $maxY - $minY + 1)
    if ($side -ge $w * 0.9) { return $bmp }
    $cx = [Math]::Floor(($minX + $maxX + 1 - $side) / 2); $cy = [Math]::Floor(($minY + $maxY + 1 - $side) / 2)
    $cx = [Math]::Max(0, [Math]::Min($cx, $w - $side)); $cy = [Math]::Max(0, [Math]::Min($cy, $h - $side))
    $crop = New-Object System.Windows.Media.Imaging.CroppedBitmap($src, (New-Object System.Windows.Int32Rect([int]$cx, [int]$cy, [int]$side, [int]$side)))
    $crop.Freeze()
    $crop
}

# Baca gambar dari RandomAccessStreamReference WinRT (logo aplikasi, cover album)
function Read-StreamImage($ref, $decodeWidth = 0) { New-StreamBitmap (Read-StreamBytes $ref) $decodeWidth }

function Read-StreamBytes($ref) {
    $stream = Await ($ref.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
    # Dipanggil lewat reflection: PowerShell gagal mengonversi sebagian stream (mis. cover album
    # Spotify) ke IInputStream, sedangkan reflection membiarkan .NET yang melakukan cast-nya
    $netStream = $asStreamForRead.Invoke($null, @($stream))
    $ms = New-Object System.IO.MemoryStream
    $netStream.CopyTo($ms); $netStream.Dispose()
    , $ms.ToArray()
}

function Get-BytesHash($bytes) {
    [BitConverter]::ToString((New-Object System.Security.Cryptography.SHA1Managed).ComputeHash($bytes))
}

function New-StreamBitmap($bytes, $decodeWidth = 0) {
    $ms = New-Object System.IO.MemoryStream(, $bytes)
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit(); $bmp.CacheOption = 'OnLoad'; $bmp.StreamSource = $ms
    if ($decodeWidth -gt 0) { $bmp.DecodePixelWidth = $decodeWidth }
    $bmp.EndInit(); $bmp.Freeze()
    $bmp
}

function Get-AppIcon($un, $aumid) {
    if ($iconCache.ContainsKey($aumid)) { return $iconCache[$aumid] }
    $bmp = $null
    try {
        $ref = $un.AppInfo.DisplayInfo.GetLogo((New-Object Windows.Foundation.Size(64, 64)))
        if ($ref) { $bmp = Trim-Bitmap (Read-StreamImage $ref) }
    } catch {}
    # Aplikasi non-Store (Discord, dll) sering tanpa logo di sini: ambil ikonnya dari daftar aplikasi Windows.
    # Kalau tetap tidak ada (mis. Dropbox), pakai inisial.
    if (-not $bmp -and $aumid) {
        try { $s = [IslandShell]::Icon("shell:AppsFolder\$aumid", 64); if ($s) { $bmp = Trim-Bitmap $s } } catch {}
    }
    # Gagal (bisa sementara, mis. sistem sibuk) tidak disimpan: dicoba lagi pada notifikasi berikutnya
    if ($bmp) { $iconCache[$aumid] = $bmp }
    $bmp
}

# Foto pengirim (avatar di notifikasi Discord, WhatsApp, Chrome, dll): gambar "appLogoOverride" di XML
# notifikasinya. Berkas lokal atau alamat web; $null kalau tidak ada. Foto dari web disimpan per alamat
# (pengirim yang sama tidak diunduh ulang); -NoNet: jangan menunggu jaringan sama sekali.
$photoCache = @{}
function Get-ToastPhoto($id, [switch]$NoNet) {
    $xml = $null
    try { $xml = [IslandWpn]::Payload([long]$id) } catch { Log "toast xml: $_" }
    if (-not $xml) { return $null }
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.LoadXml($xml)
        $img = @($doc.SelectNodes('//image')) | Where-Object { $_.GetAttribute('placement') -eq 'appLogoOverride' } | Select-Object -First 1
        if (-not $img) { return $null }
        $src = $img.GetAttribute('src')
        $bytes = $null
        $web = $src -match '^https?://'
        if ($web) {
            if ($photoCache.ContainsKey($src)) { return $photoCache[$src] }
            if ($NoNet) { return $null }
            # Ditunggu sebentar saja supaya island tidak tersendat kalau jaringan lambat
            $t = $http.GetByteArrayAsync($src)
            if ($t.Wait(1500)) { $bytes = $t.Result }
        } else {
            $path = if ($src -match '^file:') { ([uri]$src).LocalPath } else { $src }
            if ($path -and (Test-Path -LiteralPath $path)) { $bytes = [IO.File]::ReadAllBytes($path) }
        }
        if (-not $bytes) { return $null }
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit(); $bi.CacheOption = 'OnLoad'; $bi.DecodePixelWidth = 96
        $bi.StreamSource = New-Object System.IO.MemoryStream(, $bytes)
        $bi.EndInit(); $bi.Freeze()
        if ($web) {
            if ($photoCache.Count -gt 100) { $photoCache.Clear() }
            $photoCache[$src] = $bi
        }
        $bi
    } catch { Log "toast photo: $_"; $null }
}

function Convert-Notif($un) {
    $app = ''; $aumid = ''
    # Dibaca terpisah: DisplayInfo bisa gagal untuk sebagian aplikasi, AUMID-nya tetap dibutuhkan (ikon, klik untuk membuka)
    try { $aumid = $un.AppInfo.AppUserModelId } catch {}
    try { $app = $un.AppInfo.DisplayInfo.DisplayName } catch {}
    $texts = @()
    try {
        $binding = $un.Notification.Visual.GetBinding([Windows.UI.Notifications.KnownNotificationBindings]::ToastGeneric)
        if ($binding) { $texts = @($binding.GetTextElements() | ForEach-Object { $_.Text }) }
    } catch {}
    $title = if ($texts.Count -gt 0) { $texts[0] } else { $app }
    $body = (@($texts | Select-Object -Skip 1) -join ' ') -replace '\s+', ' '
    $icon = Get-AppIcon $un $aumid
    [PSCustomObject]@{
        Id     = $un.Id
        App    = $app
        Aumid  = $aumid
        Title  = $title
        Body   = $body
        Time   = $un.CreationTime.LocalDateTime
        Icon   = $icon
        # Notifikasi lama saat island baru mulai tidak menunggu unduhan foto (bisa puluhan, di thread UI)
        Photo  = (Get-ToastPhoto $un.Id -NoNet:(-not $script:notifsSeeded))
        Accent = (Get-Accent $icon $(if ($aumid) { $aumid } else { $app }))
    }
}

function Poll {
    try {
        $list = Await ($listener.GetNotificationsAsync([Windows.UI.Notifications.NotificationKinds]::Toast)) ([System.Collections.Generic.IReadOnlyList[Windows.UI.Notifications.UserNotification]])
        $present = @{}
        $fresh = @()
        foreach ($un in $list) {
            $id = $un.Id
            $present[$id] = $true
            if (-not $notifCache.ContainsKey($id)) { $notifCache[$id] = Convert-Notif $un }
            if ($seen.Add($id) -and $script:notifsSeeded) { $fresh += $notifCache[$id] }
        }
        foreach ($k in @($notifCache.Keys)) { if (-not $present.ContainsKey($k)) { $notifCache.Remove($k) } }
        foreach ($n in ($fresh | Sort-Object Time)) { Enqueue-Notif $n }
        Merge-Recent
        # Notifikasi yang sudah ada saat island mulai bukan notifikasi baru: yang baru dihitung setelah daftar
        # pertama berhasil dibaca (kalau pembacaan pertama gagal, notifikasi lama tidak ikut muncul sebagai pop-up)
        $script:notifsSeeded = $true
    } catch { Log "poll: $_" }
    try { Poll-Flashes } catch { Log "flash: $_" }
    try { Poll-Media } catch { Log "media: $_" }
    try { Check-Lyrics } catch { Log "lyrics: $_" }
    $script:initialized = $true
    # Notifikasi baru lebih penting daripada pil volume/baterai/info yang sedang tampil
    if ($script:mode -eq 'activity' -and $queue.Count -gt 0 -and $script:activity -and $script:activity.Kind -notin 'timerdone', 'update') {
        $activityTimer.Stop(); $script:activity = $null; $script:osdUI = $null; $script:mode = 'idle'
    }
    if ($script:mode -eq 'idle') { Process-Queue }
}

# Antrean dibatasi supaya banjir pesan (mis. grup WhatsApp) tidak jadi puluhan pop-up beruntun
$MAX_QUEUE = 3
function Enqueue-Notif($n) {
    $queue.Enqueue($n)
    while ($queue.Count -gt $MAX_QUEUE) { [void]$queue.Dequeue() }
}

# Ambil antrean berikutnya, lewati notifikasi yang sudah dihapus sebelum sempat tampil
function Next-Queued {
    while ($queue.Count -gt 0) {
        $n = $queue.Dequeue()
        if ($n.Flash -or $n.Kind -or $notifCache.ContainsKey($n.Id)) { return $n }
    }
    $null
}

# Layar tempat island berada (pilihan di menu; kembali ke layar utama kalau monitornya dicabut)
function Get-IslandScreen {
    $all = [System.Windows.Forms.Screen]::AllScreens
    $s = $null
    if ($script:settings.Monitor) { $s = $all | Where-Object { $_.DeviceName -eq $script:settings.Monitor } | Select-Object -First 1 }
    if (-not $s) { $s = [System.Windows.Forms.Screen]::PrimaryScreen }
    $s
}

# Posisi ikut berubah kalau resolusi/scaling layar diganti atau monitor dipilih/dicabut.
# Koordinat layar (piksel) diubah ke satuan WPF memakai skala DPI jendela.
function Update-Position {
    $b = (Get-IslandScreen).Bounds
    $k = 1.0
    try { $src = [System.Windows.PresentationSource]::FromVisual($window); if ($src) { $k = $src.CompositionTarget.TransformToDevice.M11 } } catch {}
    $left = [Math]::Round(($b.X + $b.Width / 2) / $k - $window.Width / 2)
    $top = [Math]::Round($b.Y / $k)
    if ($window.Left -ne $left) { $window.Left = $left }
    if ($window.Top -ne $top) { $window.Top = $top }
}

# ---------- Aplikasi tanpa notifikasi Windows (WeChat) ----------
# Nama proses -> nama yang ditampilkan
$FLASH_APPS = @{ 'Weixin' = 'WeChat'; 'WeChat' = 'WeChat' }
$FLASH_COOLDOWN = 8
# Taskbar terus berkedip selama pesan belum dibaca. Kedipan dianggap pesan baru hanya
# kalau sebelumnya sudah diam minimal $FLASH_QUIET detik.
$FLASH_QUIET = 5
$flashLast = @{}
$flashLastEvent = @{}
$exeIconCache = @{}
$script:flashId = [uint32]4000000000

function Get-ExeIcon($exe) {
    if ($exeIconCache.ContainsKey($exe)) { return $exeIconCache[$exe] }
    $bmp = $null
    try {
        Add-Type -AssemblyName System.Drawing
        $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($exe)
        $src = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $src.Freeze()
        $bmp = Trim-Bitmap $src
    } catch { Log "exe icon $exe : $_" }
    $exeIconCache[$exe] = $bmp
    $bmp
}

function Poll-Flashes {
    if (-not $script:flashWatcher) { return }
    foreach ($h in $script:flashWatcher.Drain()) {
        $p = [FlashWatcher]::ProcessOf($h)
        if (-not $p -or -not $FLASH_APPS.ContainsKey($p.ProcessName)) { continue }
        $name = $FLASH_APPS[$p.ProcessName]
        $now = Get-Date
        $prevEvent = $flashLastEvent[$name]
        $flashLastEvent[$name] = $now
        if ($prevEvent -and ($now - $prevEvent).TotalSeconds -lt $FLASH_QUIET) { continue }
        if ($flashLast.ContainsKey($name) -and ($now - $flashLast[$name]).TotalSeconds -lt $FLASH_COOLDOWN) { continue }
        $flashLast[$name] = $now
        $exe = $null
        try { $exe = $p.MainModule.FileName } catch {}
        $icon = if ($exe) { Get-ExeIcon $exe } else { $null }
        $script:flashId++
        Enqueue-Notif ([PSCustomObject]@{
            Id     = $script:flashId
            App    = $name
            Aumid  = ''
            # Penanda notifikasi kedipan taskbar (Exe bisa kosong kalau path-nya tidak bisa dibaca, mis. WeChat admin)
            Flash  = $true
            Exe    = $exe
            Title  = (T 'Pesan baru' 'New message')
            Body   = (T "Buka $name untuk membaca" "Open $name to read it")
            Time   = $now
            Icon   = $icon
            Accent = (Get-Accent $icon "flash:$name")
        })
    }
}

# ---------- Now Playing (Spotify, YouTube di browser, dll) ----------
$MEDIA_H = 60
# Semua animasi di 60 fps (diset eksplisit untuk animasi yang berjalan terus dan pergantian baris)
# Animasi mengikuti refresh rate layar island (mis. 100 fps di layar 100 Hz). Dikunci 60 fps di layar
# yang lebih cepat dari 60 Hz membuat sebagian frame tampil dobel: gerakan jadi tersendat.
function Update-AnimFps {
    # WPF menggambar mengikuti layar tercepat/utama, bukan layar tempat island berada. Batas animasi
    # diambil dari refresh tertinggi semua layar, supaya tiap frame layar mendapat posisi animasi baru.
    $hz = 0
    try { foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) { $hz = [Math]::Max($hz, [IslandNative]::RefreshRate($sc.DeviceName)) } } catch {}
    $script:ANIM_FPS = if ($hz -ge 50) { [Math]::Min(240, $hz + 20) } else { 60 }
    [IslandWave]::FrameTime = 1.0 / [Math]::Min($script:ANIM_FPS, $AMBIENT_FPS) - 0.002
}
$ANIM_FPS = 60
# Animasi yang berjalan terus selama lagu diputar (gelombang, equalizer, judul berjalan, sapuan lirik, napas
# cahaya) cukup 60 fps: geraknya pelan, jadi di layar 144-240 Hz tampak sama halusnya. Jendela island transparan
# digambar ulang oleh CPU tiap frame, jadi animasi terus-menerus di ~200 fps memakan hampir setengah inti CPU.
# Transisi singkat (buka/tutup, ganti ukuran, ganti warna) tetap mengikuti refresh rate layar.
$AMBIENT_FPS = 60
Update-AnimFps
$script:mediaMgr = $null
$script:media = $null
$script:mediaTick = 0
$script:mediaForce = $false
$script:pendingMediaPopup = $false
$script:progressBars = @()
# Pemutar di browser (YouTube, YouTube Music): judul video perlu diurai (Get-SongQuery), video bisu diabaikan (Poll-Media)
$BROWSER_APP = '(?i)chrome|msedge|edge|firefox|308046B0AF4A39CB|brave|opera|vivaldi'

# Kapan tiap aplikasi terakhir terdengar bersuara (kunci = nama proses / keluarga paket Store)
$script:audibleAt = @{}
function Update-AppAudio {
    try { $p = [AppAudio]::Peaks() } catch { Log "app audio: $_"; return }
    $now = Get-Date
    foreach ($k in $p.Keys) { if ($p[$k] -gt 0.0005) { $script:audibleAt[$k] = $now } }
}
# Kunci audio untuk AUMID sesi media: aplikasi Store "Keluarga!App" -> keluarganya, "Spotify.exe" -> Spotify,
# browser -> nama prosesnya (aplikasi web terpasang memakai AUMID browsernya, mis. Chrome._crx_...)
function Get-AppAudioKey($aumid) {
    if ($aumid -match '^([^!]+_[a-z0-9]{13})!') { return $matches[1] }
    # Sebagian pemutar memakai path lengkap exe-nya sebagai AUMID (C:\...\foobar2000.exe)
    if ($aumid -match '\\') { return [IO.Path]::GetFileNameWithoutExtension($aumid) }
    switch -regex ($aumid) {
        '^chrome' { return 'chrome' }
        '^msedge' { return 'msedge' }
        '^308046B0AF4A39CB' { return 'firefox' }
        '^(brave|opera|vivaldi)' { return $matches[1] }
    }
    $aumid -replace '\.exe$', ''
}
# Sesi ini masih memutar lagu/video yang sedang ditampilkan? (judulnya hanya dibaca untuk sesi milik pemutar
# yang sedang tampil, jadi paling banyak satu permintaan metadata tambahan per tick)
function Test-ShownMedia($s) {
    $m = $script:media
    if (-not $m -or $s.SourceAppUserModelId -ne $m.App) { return $false }
    try { $p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]) } catch { return $false }
    "$($m.App)|$($p.Title)|$($p.Artist)" -eq $m.Key
}

# Bersuara dalam 3 detik terakhir (jeda antarlagu / bagian hening tidak langsung dianggap bisu)
function Test-AppAudible($aumid) {
    $t = $script:audibleAt[(Get-AppAudioKey $aumid)]
    [bool]($t -and ((Get-Date) - $t).TotalSeconds -lt 3)
}
$GLYPH_PREV = [string][char]0xE892; $GLYPH_NEXT = [string][char]0xE893
$GLYPH_PLAY = [string][char]0xE768; $GLYPH_PAUSE = [string][char]0xE769; $GLYPH_MUSIC = [string][char]0xE8D6

function Poll-Media {
    if (-not $script:mediaMgr) { return }
    # Spotify, Chrome (YouTube Music), Apple Music bisa terbuka bersamaan. Urutan: diputar dan bersuara,
    # diputar, lalu yang di-pause; kalau sama kuat, pemutar yang sedang ditampilkan menang (lalu pilihan Windows).
    # Video bisu di browser (autoplay reels/feed Facebook, Instagram, dll) tetap melapor "Playing": diabaikan,
    # supaya tidak menutupi musik yang sedang diputar. Kecuali lagu/video yang sedang ditampilkan: jeda hening,
    # buffering, atau dibisukan dari island sendiri tidak membuatnya hilang.
    $all = @($script:mediaMgr.GetSessions())
    $on = @(foreach ($s in $all) { "$($s.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing' })
    # Level suara per aplikasi hanya dibaca kalau bisa mengubah pilihan: ada browser yang diputar, atau lebih
    # dari satu pemutar diputar bersamaan
    $nOn = 0; $browserOn = $false
    for ($i = 0; $i -lt $all.Count; $i++) { if ($on[$i]) { $nOn++; if ($all[$i].SourceAppUserModelId -match $BROWSER_APP) { $browserOn = $true } } }
    if ($browserOn -or $nOn -gt 1) { Update-AppAudio }
    $sess = $null; $best = -1
    $shown = if ($script:media) { $script:media.App } else { '' }
    $winCur = $script:mediaMgr.GetCurrentSession()
    $winApp = if ($winCur) { $winCur.SourceAppUserModelId } else { '' }
    for ($i = 0; $i -lt $all.Count; $i++) {
        $s = $all[$i]; $a = $s.SourceAppUserModelId
        $loud = Test-AppAudible $a
        if ($on[$i] -and -not $loud -and $a -match $BROWSER_APP -and -not (Test-ShownMedia $s)) { continue }
        $score = $(if ($on[$i] -and $loud) { 8 } elseif ($on[$i]) { 6 } else { 2 })
        if ($a -eq $shown) { $score += 1 } elseif ($a -eq $winApp) { $score += 0.5 }
        if ($score -gt $best) { $sess = $s; $best = $score }
    }
    if (-not $sess) {
        if ($script:media) { $script:media = $null; Media-Changed $false }
        return
    }
    $playing = "$($sess.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing'
    # Info lagu dicek tiap detik selama diputar (supaya pop-up lagu berikutnya langsung muncul),
    # tiap 3 detik saat pause; langsung kalau pemutar/status berubah atau tombol baru ditekan
    $app = $sess.SourceAppUserModelId
    $old = $script:media
    $script:mediaTick++
    if ($old -and $old.App -eq $app -and $old.Playing -eq $playing -and -not $playing -and -not $script:mediaForce -and ($script:mediaTick % 3) -ne 0) { return }
    $script:mediaForce = $false
    $props = Await ($sess.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
    if (-not $props.Title) {
        # Metadata kadang kosong sesaat saat ganti lagu (pemutar yang sama): tunggu tick berikutnya. Pemutar lain
        # tanpa judul (mis. setelah pemutar yang tampil ditutup) tidak boleh membekukan lagu lama di island.
        if ($old -and $old.App -ne $app) { $script:media = $null; Media-Changed $false }
        return
    }
    $key = "$app|$($props.Title)|$($props.Artist)"
    if (-not $old -or $old.Key -ne $key) {
        $cv = Read-Cover $props.Thumbnail
        $tl = Get-Timeline $sess $playing
        $script:media = [PSCustomObject]@{
            Key = $key; App = $app; Title = $props.Title; Artist = $props.Artist; Album = $props.AlbumTitle
            Art = $cv.Art; Accent = $cv.Accent; Accent2 = $cv.Accent2; Accent3 = $cv.Accent3; CoverHash = $cv.Hash; CoverChecks = 0
            Playing = $playing; Session = $sess; Pos = $tl.Pos; End = $tl.End; PosAt = (Get-Date)
        }
        # Durasi lagu sering belum tersedia tepat saat ganti lagu: cek lagi di tick berikutnya
        if ($tl.End -le 0) { $script:mediaForce = $true }
        $script:endMismatch = 0
        try { Request-Lyrics } catch { Log "lyrics req: $_" }
        # Pop-up hanya saat lagu berganti dan sedang diputar (bukan saat island baru dijalankan)
        Media-Changed ($playing -and $script:initialized)
    } elseif ($old.Playing -ne $playing) {
        $tl = Get-Timeline $sess $playing
        $hadEnd = $old.End -gt 0
        $old.Playing = $playing; $old.Session = $sess
        $old.Pos = $tl.Pos; $old.End = $tl.End; $old.PosAt = Get-Date
        Media-Changed $false
        # Durasi bisa datang bersamaan dengan play/pause (video yang dibuka dalam keadaan pause): lirik video
        # baru dicari setelah durasinya ada (lihat Request-Lyrics)
        if (-not $hadEnd -and $tl.End -gt 0) { try { Request-Lyrics } catch { Log "lyrics req: $_" } }
    } else {
        # Lagu sama: kalau posisi meleset (lagu digeser, pemutar/PC tersendat), sinkronkan progress bar
        # dan acuan posisi lirik. Laporan posisi baru dari pemutar (Spotify: tiap ~4,5 detik) paling bisa
        # dipercaya, jadi saat ada laporan baru selisih 0,3 detik pun sudah disinkronkan; di luar itu 1 detik.
        $tl = Get-Timeline $sess $playing
        $predicted = $old.Pos + $(if ($playing) { ((Get-Date) - $old.PosAt).TotalSeconds } else { 0 })
        $fresh = $tl.Reported -and $tl.Reported -ne $old.Reported
        $old | Add-Member -NotePropertyName Reported -NotePropertyValue $tl.Reported -Force
        $tolerance = if ($fresh -and $playing) { 0.3 } else { 1.0 }
        if ([Math]::Abs($tl.End - $old.End) -le 1) { $script:endMismatch = 0 }
        if (($old.End -gt 0) -ne ($tl.End -gt 0)) {
            # Durasi baru datang (atau hilang): tampilan perlu dibangun ulang supaya gelombang muncul
            $old.Pos = $tl.Pos; $old.End = $tl.End; $old.PosAt = Get-Date
            Media-Changed $false
            # Lirik video di browser baru dicari setelah durasinya diketahui (lihat Request-Lyrics)
            if ($tl.End -gt 0) { try { Request-Lyrics } catch { Log "lyrics req: $_" } }
        } elseif ($old.End -gt 0 -and [Math]::Abs($tl.End - $old.End) -gt 1 -and $script:endMismatch -lt 3) {
            # Durasi berubah tapi judul belum: Spotify mengirim timeline lagu baru sesaat sebelum judulnya.
            # Jangan sinkronkan (progress lagu lama akan lompat ke 0:00); tunggu judul baru di tick berikutnya.
            # Kalau tetap begitu 3 tick berturut-turut, durasinya memang berubah: terima.
            $script:endMismatch++
            $script:mediaForce = $true
        } elseif ($script:seekHold -and (Get-Date) -lt $script:seekHold -and -not $fresh) {
            # Baru saja digeser dari island: posisi lama dari pemutar belum diperbarui, jangan dipakai
        } elseif ($tl.End -ne $old.End -or [Math]::Abs($tl.Pos - $predicted) -gt $tolerance) {
            $script:endMismatch = 0
            $old.Pos = $tl.Pos; $old.End = $tl.End; $old.PosAt = Get-Date
            foreach ($st in $script:progressBars) { Start-Progress $st }
            if ($script:miniBar) { Start-Progress $script:miniBar }
        }
    }
    # Cover sering datang terlambat dengan judul yang sama: browser mengirim ikonnya sendiri dulu (thumbnail
    # video menyusul beberapa detik kemudian), Apple Music mengirim judul tanpa cover lalu covernya ~1 detik
    # kemudian. Cek ulang cover selama 30 tick pertama lagu, untuk semua pemutar.
    $m = $script:media
    if ($m -and $m.Key -eq $key -and $m.CoverChecks -lt 30 -and $props.Thumbnail) {
        $m.CoverChecks++
        $h = $m.CoverHash
        try { $h = Get-BytesHash (Read-StreamBytes $props.Thumbnail) } catch {}
        if ($h -ne $m.CoverHash) {
            $cv = Read-Cover $props.Thumbnail
            $m.Art = $cv.Art; $m.Accent = $cv.Accent; $m.Accent2 = $cv.Accent2; $m.Accent3 = $cv.Accent3; $m.CoverHash = $cv.Hash
            # Mini island hanya dibangun ulang saat lagunya berganti: paksa supaya cover & warna barunya ikut tampil
            if ($script:mode -eq 'idle') { $script:miniKey = $null }
            Media-Changed $false
        }
    }
}

# Cover lagu dan warna-warnanya (warna dominan + dua warna pendamping)
function Read-Cover($thumb) {
    $c = [PSCustomObject]@{ Art = $null; Accent = $null; Accent2 = $null; Accent3 = $null; Hash = '' }
    if ($thumb) {
        try {
            $bytes = Read-StreamBytes $thumb
            $c.Hash = Get-BytesHash $bytes
            $c.Art = New-StreamBitmap $bytes 96
            $c.Accent = Get-DominantColor $c.Art
            if ($c.Accent) {
                $c.Accent2 = Get-SecondColor $c.Art $c.Accent
                $c.Accent3 = Get-SecondColor $c.Art $c.Accent $c.Accent2
            }
        } catch { Log "cover: $_" }
    }
    # Cover hitam-putih (tidak ada warna dominan): palet perak supaya tetap cocok dengan covernya.
    # Hijau hanya untuk lagu tanpa cover sama sekali.
    if (-not $c.Accent -and $c.Art) { $c.Accent = Rgb 200 200 210; $c.Accent2 = Rgb 240 240 246; $c.Accent3 = Rgb 150 150 162 }
    if (-not $c.Accent) { $c.Accent = [System.Windows.Media.ColorConverter]::ConvertFromString('#30D158') }
    if (-not $c.Accent2) { $a = $c.Accent; $c.Accent2 = Rgb ($a.R + (255 - $a.R) * 0.5) ($a.G + (255 - $a.G) * 0.5) ($a.B + (255 - $a.B) * 0.5) }
    $c
}

function Get-Timeline($sess, $playing) {
    $pos = 0; $end = 0; $reported = $null
    try {
        $t = $sess.GetTimelineProperties()
        $reported = $t.LastUpdatedTime
        $end = ($t.EndTime - $t.StartTime).TotalSeconds
        $pos = ($t.Position - $t.StartTime).TotalSeconds
        # Posisi yang dilaporkan bisa basi; tambahkan waktu sejak pemutar terakhir melapor
        # (kecuali waktunya tidak masuk akal, mis. pemutar tidak mengisi LastUpdatedTime)
        $elapsed = ([DateTimeOffset]::Now - $t.LastUpdatedTime).TotalSeconds
        if ($playing -and $elapsed -ge 0 -and $elapsed -lt [Math]::Max(5.0, $end)) { $pos += $elapsed }
    } catch {}
    # Catatan: argumen pertama Math.Max/Min harus double (0.0, bukan 0). Dengan integer, PowerShell
    # memilih versi integer dan membulatkan hasilnya (Max(0, 0.9) = 1).
    @{ Pos = [Math]::Max(0.0, [Math]::Min([double]$pos, [double]$end)); End = [double]$end; Reported = $reported }
}

function Media-Changed($popup) {
    switch ($script:mode) {
        'media' { if ($script:media) { Show-Media -Refresh } else { Go-Idle } }
        'list'  { if (-not $script:deleting) { Show-List -Refresh } }
        'idle'  { if ($popup -and -not $script:fullscreen) { Show-Media } else { Update-Mini } }
        # Pop-up notifikasi sedang tampil: pop-up lagu baru ditunda sampai notifikasinya selesai
        'notif' { if ($popup) { $script:pendingMediaPopup = $true } }
    }
}

function Media-Command($cmd) {
    $sess = if ($script:media) { $script:media.Session } else { $null }
    if (-not $sess) { return }
    try {
        switch ($cmd) {
            'prev'   { [void]$sess.TrySkipPreviousAsync() }
            'toggle' { [void]$sess.TryTogglePlayPauseAsync() }
            'next'   { [void]$sess.TrySkipNextAsync() }
        }
    } catch { Log "media cmd $cmd : $_" }
    $script:mediaForce = $true
}

# Pemutar mengizinkan lompat ke posisi lain lewat kontrol media Windows? (Apple Music tidak: posisinya
# hanya bisa digeser di aplikasinya sendiri, jadi progress dan baris lirik tidak dibuat bisa diklik)
function Test-MediaSeekable {
    $m = $script:media
    if (-not $m -or -not $m.Session -or $m.End -le 0) { return $false }
    try { [bool]$m.Session.GetPlaybackInfo().Controls.IsPlaybackPositionEnabled } catch { $true }
}

# Lompat ke detik tertentu (klik / geser gelombang progress)
function Media-Seek($sec) {
    $m = $script:media
    if (-not (Test-MediaSeekable)) { return }
    $sec = [Math]::Max(0.0, [Math]::Min($m.End - 0.5, [double]$sec))
    try { [void]$m.Session.TryChangePlaybackPositionAsync([long]($sec * 10000000)) } catch { Log "seek: $_" }
    $m.Pos = $sec; $m.PosAt = Get-Date
    $script:seekHold = (Get-Date).AddSeconds(3)
    foreach ($st in $script:progressBars) { Start-Progress $st }
    if ($script:miniBar) { Start-Progress $script:miniBar }
    $script:lyricIdx = -2
}

# Selama gelombang ditarik: bar dan titik mengikuti kursor, waktu menunjukkan tujuan
function Preview-Seek($pb, $x) {
    $W = $pb.Root.ActualWidth
    if ($W -le 0 -or -not $script:media -or $script:media.End -le 0) { return }
    $x = [Math]::Max(0.0, [Math]::Min($W, $x))
    $xp = [System.Windows.Media.TranslateTransform]::XProperty
    foreach ($t in $pb.Movers) { $t.BeginAnimation($xp, $null); $t.X = $x }
    $pb.Knob.BeginAnimation($xp, $null); $pb.Knob.X = $x - $pb.KnobHalf
    if ($pb.PosText) { $pb.PosText.Text = Format-Time ($x / $W * $script:media.End) }
}

# Tiga batang equalizer; bergerak saat lagu diputar, diam saat pause
function New-Equalizer($color, $playing, $fps = $AMBIENT_FPS) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.VerticalAlignment = 'Center'; $sp.Margin = '6,0,0,0'
    $i = 0
    foreach ($dur in 420, 560, 360) {
        $r = New-Object System.Windows.Shapes.Rectangle
        $r.Width = 3; $r.Height = 12; $r.RadiusX = 1.5; $r.RadiusY = 1.5; $r.Margin = '1,0'
        $r.Fill = New-Object System.Windows.Media.SolidColorBrush($color)
        $r.RenderTransformOrigin = '0.5,1'
        $st = New-Object System.Windows.Media.ScaleTransform(1, 0.35)
        $r.RenderTransform = $st
        if ($playing) {
            $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0.3, 1, (New-Object System.Windows.Duration (Ms $dur)))
            $a.AutoReverse = $true
            $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
            [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $fps)
            $a.BeginTime = Ms ($i * 90)
            $st.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $a)
            Track-Anim $r $st ([System.Windows.Media.ScaleTransform]::ScaleYProperty)
        }
        [void]$sp.Children.Add($r)
        $i++
    }
    $sp
}

function New-MediaButton($glyph, $cmd, $size) {
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 28; $b.Height = 28; $b.CornerRadius = New-Object System.Windows.CornerRadius(14)
    $b.Background = Brush '#00FFFFFF'; $b.Cursor = 'Hand'; $b.Tag = $cmd
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $glyph; $t.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $t.FontSize = $size
    $t.Foreground = Brush '#FFFFFF'; $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $b.Child = $t
    $b.Add_MouseEnter({ param($s, $e) $s.Background = Brush '#2EFFFFFF' })
    $b.Add_MouseLeave({ param($s, $e) $s.Background = Brush '#00FFFFFF' })
    $b.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Media-Command $s.Tag })
    $b
}

# Isi Now Playing: cover | judul + equalizer / artis | tombol kontrol
# Artis untuk ditampilkan: Apple Music menaruh nama album di kolom artis ("Artis (em dash) Album"), albumnya dibuang
function Get-DisplayArtist($m) { "$($m.Artist)" -replace '\s+\u2014\s+.*$', '' }

# Teks satu baris yang berjalan kalau tidak muat (judul/artis panjang di kartu musik): diam 2 detik, lalu
# bergeser sampai salinan keduanya tepat di posisi awal (putaran tanpa sambungan), diam lagi, dan seterusnya.
# Tepinya memudar selama berjalan. Kalau muat, tetap diam seperti teks biasa.
$SCROLL_GAP = 28
function New-ScrollText($text, $size, $weight, $color) {
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.ClipToBounds = $true
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    foreach ($i in 0, 1) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = "$text"; $tb.FontSize = $size; $tb.FontWeight = $weight; $tb.Foreground = Brush $color
        if ($i -eq 1) { $tb.Margin = "$SCROLL_GAP,0,0,0"; $tb.Visibility = 'Collapsed' }
        [void]$sp.Children.Add($tb)
    }
    $sp.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    [void]$cv.Children.Add($sp)
    $sp.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
    $cv.Height = $sp.DesiredSize.Height
    $cv.Tag = @{ Panel = $sp; TextW = $sp.DesiredSize.Width; W = -1 }
    $cv.Add_SizeChanged({ param($s, $e) Update-ScrollText $s })
    $cv
}
function Update-ScrollText($cv) {
    $st = $cv.Tag; $sp = $st.Panel; $W = $cv.ActualWidth
    if ($W -le 0 -or [Math]::Abs($W - $st.W) -lt 0.5) { return }
    $st.W = $W
    $tt = $sp.RenderTransform; $xp = [System.Windows.Media.TranslateTransform]::XProperty
    $tt.BeginAnimation($xp, $null); $tt.X = 0
    if ($st.TextW -le $W + 0.5) {
        $sp.Children[1].Visibility = 'Collapsed'; $cv.OpacityMask = $null
        return
    }
    $sp.Children[1].Visibility = 'Visible'
    $cycle = $st.TextW + $SCROLL_GAP
    $hold = 2.0; $run = $cycle / $MARQUEE_SPEED
    $a = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $a.Duration = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds($hold + $run))
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    [void]$a.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($hold)))))
    [void]$a.KeyFrames.Add((New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame((-$cycle), [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($hold + $run)))))
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $AMBIENT_FPS)
    $tt.BeginAnimation($xp, $a)
    Track-Anim $sp $tt $xp
    $mask = New-Object System.Windows.Media.LinearGradientBrush
    $mask.MappingMode = 'Absolute'; $mask.StartPoint = '0,0'; $mask.EndPoint = "$W,0"
    $f = [Math]::Min(0.12, 14 / $W)
    # (1 - $f) dalam kurung: koma lebih kuat dari minus di PowerShell, tanpa kurung jadi (255, 1) - $f
    foreach ($s in @(@(0, 0.0), @(255, $f), @(255, (1 - $f)), @(0, 1.0))) {
        $mask.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb 0 0 0 $s[0]), $s[1])))
    }
    $cv.OpacityMask = $mask
}

function New-MediaContent {
    $m = $script:media
    $g = New-Object System.Windows.Controls.Grid
    $g.VerticalAlignment = 'Center'
    foreach ($w in 'Auto', '*', 'Auto') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
        $g.ColumnDefinitions.Add($cd)
    }
    $art = New-Object System.Windows.Controls.Border
    $art.Width = 40; $art.Height = 40; $art.CornerRadius = New-Object System.Windows.CornerRadius(10)
    if ($m.Art) {
        $ib = New-Object System.Windows.Media.ImageBrush($m.Art); $ib.Stretch = 'UniformToFill'
        $art.Background = $ib
    } else {
        $c = $m.Accent
        $art.Background = New-Object System.Windows.Media.SolidColorBrush((Rgb ($c.R * 0.6) ($c.G * 0.6) ($c.B * 0.6)))
        $gt = New-Object System.Windows.Controls.TextBlock
        $gt.Text = $GLYPH_MUSIC; $gt.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $gt.FontSize = 16
        $gt.Foreground = Brush '#FFFFFF'; $gt.HorizontalAlignment = 'Center'; $gt.VerticalAlignment = 'Center'
        $art.Child = $gt
    }
    [void]$g.Children.Add($art)

    $mid = New-Object System.Windows.Controls.StackPanel
    $mid.Margin = '10,0,6,0'; $mid.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($mid, 1)
    $titleRow = New-Object System.Windows.Controls.DockPanel
    $eq = New-Equalizer $m.Accent $m.Playing
    [System.Windows.Controls.DockPanel]::SetDock($eq, 'Right')
    [void]$titleRow.Children.Add($eq)
    # Judul / artis yang terlalu panjang berjalan pelan (bukan dipotong dengan "...")
    [void]$titleRow.Children.Add((New-ScrollText $m.Title 13 'SemiBold' '#FFFFFF'))
    [void]$mid.Children.Add($titleRow); [void]$mid.Children.Add((New-ScrollText (Get-DisplayArtist $m) 12 'Normal' '#A1A1A6'))
    [void]$g.Children.Add($mid)

    $ctl = New-Object System.Windows.Controls.StackPanel
    $ctl.Orientation = 'Horizontal'; $ctl.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($ctl, 2)
    [void]$ctl.Children.Add((New-MediaButton $GLYPH_PREV 'prev' 12))
    [void]$ctl.Children.Add((New-MediaButton $(if ($m.Playing) { $GLYPH_PAUSE } else { $GLYPH_PLAY }) 'toggle' 15))
    [void]$ctl.Children.Add((New-MediaButton $GLYPH_NEXT 'next' 12))
    [void]$g.Children.Add($ctl)

    $script:progressBars = @()
    $outer = New-Object System.Windows.Controls.Grid
    $r0 = New-Object System.Windows.Controls.RowDefinition
    $r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = 'Auto'
    $outer.RowDefinitions.Add($r0); $outer.RowDefinitions.Add($r1)
    $g.Margin = '10,6,12,0'
    [void]$outer.Children.Add($g)
    # Baris bawah: progress lagu bergelombang, atau slider volume (mode volume / pemutar tanpa durasi).
    # Ditaruh dalam wadah sendiri supaya bisa diganti dengan animasi tanpa membangun ulang semuanya.
    $script:volUI = $null
    $bottomHost = New-Object System.Windows.Controls.Grid
    $bottomHost.ClipToBounds = $true
    [System.Windows.Controls.Grid]::SetRow($bottomHost, 1)
    [void]$bottomHost.Children.Add((New-BottomRow))
    [void]$outer.Children.Add($bottomHost)
    $script:bottomHost = $bottomHost
    $outer
}

function New-BottomRow {
    if ($script:volumeMode -or (Get-MediaFraction) -lt 0) { New-VolumeRow } else { New-WaveProgress $WIDE_W }
}

# Animasi panjang/berulang (equalizer, judul berjalan, progress) terus jalan dan makan CPU walau elemennya
# sudah dibuang dari island. Semuanya dicatat di sini, lalu tiap detik yang elemennya sudah tidak tampil
# di jendela dihentikan.
$script:liveAnims = New-Object System.Collections.Generic.List[object]
function Track-Anim($owner, $target, $prop) {
    # Progress dimulai ulang tiap sinkron: jangan dicatat dobel
    foreach ($a in $script:liveAnims) { if ([object]::ReferenceEquals($a.Target, $target) -and $a.Prop -eq $prop) { return } }
    $script:liveAnims.Add([PSCustomObject]@{ Owner = $owner; Target = $target; Prop = $prop })
}
function Prune-Anims {
    for ($i = $script:liveAnims.Count - 1; $i -ge 0; $i--) {
        $a = $script:liveAnims[$i]
        if (-not [System.Windows.PresentationSource]::FromVisual($a.Owner)) {
            try { $a.Target.BeginAnimation($a.Prop, $null) } catch {}
            $script:liveAnims.RemoveAt($i)
        }
    }
}

# Pudar halus untuk pergantian lagu: kurva Sine masuk-keluar (mulai dan berhenti pelan, tanpa geser)
$SONG_FADE_MS = 380
function Fade-Smooth($el, $to, $ms = $SONG_FADE_MS, $delay = 0) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation($to, (New-Object System.Windows.Duration (Ms $ms)))
    $a.BeginTime = Ms $delay
    $e = New-Object System.Windows.Media.Animation.SineEase; $e.EasingMode = 'EaseInOut'; $a.EasingFunction = $e
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $ANIM_FPS)
    $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $a)
}

function Animate60($el, $prop, $from, $to, $ms, $delay = 0) {
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation($from, $to, (New-Object System.Windows.Duration (Ms $ms)))
    $a.BeginTime = Ms $delay
    $e = New-Object System.Windows.Media.Animation.CubicEase; $e.EasingMode = 'EaseOut'
    $a.EasingFunction = $e
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $ANIM_FPS)
    $el.BeginAnimation($prop, $a)
}

# Ganti baris bawah (progress <-> volume) dengan animasi silang: baris lama bergeser keluar sambil
# memudar, baris baru masuk dari arah berlawanan. Bagian atas (cover, judul, tombol) tetap diam.
$script:oldBottom = $null
$bottomSwapTimer = New-Object System.Windows.Threading.DispatcherTimer
$bottomSwapTimer.Interval = Ms 520
$bottomSwapTimer.Add_Tick({
    $bottomSwapTimer.Stop()
    if ($script:oldBottom -and $script:oldBottom.Parent) { $script:oldBottom.Parent.Children.Remove($script:oldBottom) }
    $script:oldBottom = $null
    # Tinggi baris volume dan progress bisa beda sedikit: sesuaikan ukuran island dengan halus
    if ($script:mode -eq 'media' -and $mediaView.Child) {
        $h, $r = Get-MediaPopupSize $mediaView.Child
        if ([Math]::Abs($h - $island.ActualHeight) -gt 1) { Resize-Island $WIDE_W $h $r }
    } elseif ($script:mode -eq 'list') {
        $listPanel.Measure((New-Object System.Windows.Size(($WIDE_W - 2), [double]::PositiveInfinity)))
        $h = [Math]::Min($MAX_ISLAND_H, [Math]::Max(56.0, [Math]::Ceiling($listPanel.DesiredSize.Height) + 2))
        if ([Math]::Abs($h - $island.ActualHeight) -gt 1) { Resize-Island $WIDE_W $h 24 }
    }
})

function Switch-BottomRow {
    $hostG = $script:bottomHost
    if (-not $hostG -or -not $hostG.Parent -or $hostG.Children.Count -eq 0) {
        $script:volumeMode = -not $script:volumeMode; Refresh-MediaView; return
    }
    # Baris lama dari pergantian sebelumnya yang belum selesai: buang langsung
    if ($script:oldBottom) { $bottomSwapTimer.Stop(); [void]$hostG.Children.Remove($script:oldBottom); $script:oldBottom = $null }
    $old = $hostG.Children[$hostG.Children.Count - 1]
    $script:volumeMode = -not $script:volumeMode
    $script:volUI = $null; $script:progressBars = @()
    $new = New-BottomRow
    [void]$hostG.Children.Add($new)
    $old.IsHitTestVisible = $false
    $dir = if ($script:volumeMode) { 1 } else { -1 }
    $xp = [System.Windows.Media.TranslateTransform]::XProperty
    $op = [System.Windows.UIElement]::OpacityProperty
    $ot = New-Object System.Windows.Media.TranslateTransform; $old.RenderTransform = $ot
    $nt = New-Object System.Windows.Media.TranslateTransform; $new.RenderTransform = $nt
    $new.Opacity = 0
    Animate60 $ot $xp 0 (-28 * $dir) 380
    Animate60 $old $op 1 0 340
    Animate60 $nt $xp (28 * $dir) 0 420 90
    Animate60 $new $op 0 1 380 90
    $script:oldBottom = $old
    $bottomSwapTimer.Start()
}

# ---------- Volume (aplikasi pemutar, atau volume utama Windows) ----------
$script:volumeMode = $false
$script:volUI = $null
$BOTTOM_ROW_H = 24
$GLYPH_VOL = [string][char]0xE767; $GLYPH_MUTE = [string][char]0xE74F

# Kunci audio pemutar yang sedang ditampilkan kalau slider mengatur volume aplikasinya (seperti di volume
# mixer Windows), atau $null = volume utama Windows: dimatikan di menu, atau aplikasinya belum punya sesi
# audio (belum pernah bersuara). Pemutar di browser: volume seluruh browser (Windows tidak membedakan tab).
function Get-VolTarget {
    if (-not $script:settings.AppVolume -or -not $script:media) { return $null }
    $k = Get-AppAudioKey $script:media.App
    try { if ([AppAudio]::GetVolume($k) -ge 0) { return $k } } catch { Log "app volume: $_" }
    $null
}
function Get-Vol {
    $k = Get-VolTarget
    try { if ($k) { [double][AppAudio]::GetVolume($k) } else { [double][SysVolume]::Get() } } catch { -1.0 }
}
function Get-Muted {
    $k = Get-VolTarget
    try { if ($k) { [AppAudio]::GetMute($k) } else { [SysVolume]::GetMute() } } catch { $false }
}

function Set-Vol($v) {
    try {
        $v = [Math]::Max(0.0, [Math]::Min(1.0, [double]$v))
        $k = Get-VolTarget
        if ($k) {
            [AppAudio]::SetVolume($k, [float]$v)
            if ($v -gt 0 -and [AppAudio]::GetMute($k)) { [AppAudio]::SetMute($k, $false) }
        } else {
            [SysVolume]::Set([float]$v)
            if ($v -gt 0 -and [SysVolume]::GetMute()) { [SysVolume]::SetMute($false) }
        }
    } catch { Log "volume: $_" }
    Update-VolumeUI
}

function Toggle-Mute {
    $k = Get-VolTarget
    try { if ($k) { [AppAudio]::SetMute($k, -not [AppAudio]::GetMute($k)) } else { [SysVolume]::SetMute(-not [SysVolume]::GetMute()) } } catch { Log "mute: $_" }
    Update-VolumeUI
}

function Update-VolumeUI {
    $ui = $script:volUI
    if (-not $ui) { return }
    $v = Get-Vol
    if ($v -lt 0) { return }
    $muted = Get-Muted
    $shown = if ($muted) { 0.0 } else { $v }
    $ui.Fill.ScaleX = $shown
    $W = $ui.Track.ActualWidth
    if ($W -gt 0) { $ui.Knob.X = $shown * $W - 5.5 }
    $ui.Text.Text = if ($muted) { T 'Bisu' 'Muted' } else { '{0}%' -f [int][Math]::Round($v * 100) }
    $ui.MuteGlyph.Text = if ($muted -or $v -le 0.001) { $GLYPH_MUTE } else { $GLYPH_VOL }
}

function Refresh-MediaView {
    if ($script:mode -eq 'media') { Show-Media -Refresh }
    elseif ($script:mode -eq 'list') { Show-List -Refresh }
}

# Tombol speaker di ujung kanan baris bawah: pindah antara progress lagu dan slider volume
function New-VolumeToggle {
    $tip = if ($script:volumeMode) { T 'Kembali ke progress lagu' 'Back to song progress' } else { T 'Atur volume' 'Volume' }
    $b = New-RoundButton $GLYPH_VOL '#33FFFFFF' $tip
    $b.Child.FontSize = 11; $b.Child.Foreground = Brush '#D9FFFFFF'; $b.Margin = '8,0,0,0'; $b.Cursor = 'Hand'
    # Transparan saat diam; menyala tipis saat di-hover atau saat mode volume aktif
    $b.Resources['RestHex'] = if ($script:volumeMode) { '#40FFFFFF' } else { '#00FFFFFF' }
    $b.Background = Brush $b.Resources['RestHex']
    $b.Add_MouseLeave({ param($s, $e) $s.Background = Brush $s.Resources['RestHex'] })
    $b.Add_MouseLeftButtonUp({
        param($s, $e)
        $e.Handled = $true
        Switch-BottomRow
    })
    $b
}

function Set-VolFromMouse($s, $e) {
    $W = $s.ActualWidth
    if ($W -le 0) { return }
    Set-Vol ($e.GetPosition($s).X / $W)
}

# Baris volume: mute | slider (gradasi warna album) | persen | tombol kembali ke progress.
# Tag 'nodrag' supaya geseran slider tidak dianggap swipe pindah halaman.
function New-VolumeRow {
    $m = $script:media
    $outer = New-Object System.Windows.Controls.Grid
    $outer.Margin = '12,8,16,4'; $outer.Height = $BOTTOM_ROW_H; $outer.Tag = 'nodrag'
    foreach ($cw in 'Auto', '*', 'Auto', 'Auto') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($cw)
        $outer.ColumnDefinitions.Add($cd)
    }
    $mb = New-Object System.Windows.Controls.Border
    $mb.Width = 24; $mb.Height = 22; $mb.CornerRadius = New-Object System.Windows.CornerRadius(11)
    $mb.Background = Brush '#00FFFFFF'; $mb.Cursor = 'Hand'; $mb.ToolTip = T 'Bisukan / bunyikan' 'Mute / unmute'
    $mg = New-Object System.Windows.Controls.TextBlock
    $mg.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $mg.FontSize = 12; $mg.Foreground = Brush '#E6FFFFFF'
    $mg.HorizontalAlignment = 'Center'; $mg.VerticalAlignment = 'Center'
    $mb.Child = $mg
    $mb.Add_MouseEnter({ param($s, $e) $s.Background = Brush '#2EFFFFFF' })
    $mb.Add_MouseLeave({ param($s, $e) $s.Background = Brush '#00FFFFFF' })
    $mb.Add_MouseLeftButtonUp({
        param($s, $e)
        $e.Handled = $true
        Toggle-Mute
    })
    [void]$outer.Children.Add($mb)

    $sl = New-Object System.Windows.Controls.Grid
    $sl.Height = 18; $sl.Margin = '6,0,8,0'; $sl.Background = Brush '#01000000'; $sl.Cursor = 'Hand'
    [System.Windows.Controls.Grid]::SetColumn($sl, 1)
    $track = New-Object System.Windows.Controls.Border
    $track.Height = 4; $track.CornerRadius = New-Object System.Windows.CornerRadius(2)
    $track.Background = Brush '#33FFFFFF'; $track.VerticalAlignment = 'Center'
    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = 4; $fill.CornerRadius = New-Object System.Windows.CornerRadius(2); $fill.VerticalAlignment = 'Center'
    $lg = New-Object System.Windows.Media.LinearGradientBrush
    $lg.StartPoint = '0,0.5'; $lg.EndPoint = '1,0.5'
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop($m.Accent, 0)))
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop($m.Accent2, 1)))
    $fill.Background = $lg
    $fill.RenderTransformOrigin = '0,0.5'
    $fst = New-Object System.Windows.Media.ScaleTransform(0, 1)
    $fill.RenderTransform = $fst
    $knob = New-Object System.Windows.Shapes.Ellipse
    $knob.Width = 11; $knob.Height = 11; $knob.Fill = Brush '#FFFFFFFF'
    $knob.HorizontalAlignment = 'Left'; $knob.VerticalAlignment = 'Center'
    $kt = New-Object System.Windows.Media.TranslateTransform
    $knob.RenderTransform = $kt
    [void]$sl.Children.Add($track); [void]$sl.Children.Add($fill); [void]$sl.Children.Add($knob)
    $sl.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; [void]$s.CaptureMouse(); Set-VolFromMouse $s $e })
    $sl.Add_MouseMove({ param($s, $e) if ($s.IsMouseCaptured) { Set-VolFromMouse $s $e } })
    $sl.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; $s.ReleaseMouseCapture() })
    $sl.Add_SizeChanged({ Update-VolumeUI })
    [void]$outer.Children.Add($sl)

    $pct = New-Object System.Windows.Controls.TextBlock
    $pct.Foreground = Brush '#B8B8BD'; $pct.FontSize = 10.5; $pct.MinWidth = 32; $pct.TextAlignment = 'Right'
    $pct.VerticalAlignment = 'Center'; $pct.Typography.NumeralAlignment = 'Tabular'
    [System.Windows.Controls.Grid]::SetColumn($pct, 2)
    [void]$outer.Children.Add($pct)

    # Pemutar tanpa durasi tidak punya progress untuk dituju, jadi tombol kembali tidak perlu
    if ((Get-MediaFraction) -ge 0) {
        $tg = New-VolumeToggle
        [System.Windows.Controls.Grid]::SetColumn($tg, 3)
        [void]$outer.Children.Add($tg)
    }
    $script:volUI = @{ Track = $sl; Fill = $fst; Knob = $kt; Text = $pct; MuteGlyph = $mg }
    Update-VolumeUI
    $progressClock.Start()
    $outer
}

# ---------- Progress bar lagu ----------
# Posisi lagu sekarang (0..1), atau -1 kalau pemutar tidak memberi durasi
function Get-MediaFraction {
    $m = $script:media
    if (-not $m -or $m.End -le 0) { return -1 }
    $p = $m.Pos
    if ($m.Playing) { $p += ((Get-Date) - $m.PosAt).TotalSeconds }
    [Math]::Min(1.0, [Math]::Max(0.0, $p / $m.End))
}

# Batas gelombang = posisi lagu. Gelombang dipotong (Clip) selebar bagian yang sudah diputar dan
# penanda digeser ke ujungnya; keduanya satu animasi linear sampai lagu selesai, tanpa update tiap detik.
# Lebar dibaca dari layout, jadi dijalankan ulang saat ukuran berubah.
function Start-Progress($pb) {
    $m = $script:media
    $f = Get-MediaFraction
    $W = $pb.Root.ActualWidth
    if ($f -lt 0 -or $W -le 0) { return }
    # Clip dan titik sama-sama digeser (TranslateTransform) ke posisi lagu
    # Semua yang mengikuti posisi lagu (masker pudar, lereng, bar terisi) digeser bersama; titik di tengahnya
    $knob = $pb.Knob; $half = $pb.KnobHalf
    $xp = [System.Windows.Media.TranslateTransform]::XProperty
    foreach ($t in $pb.Movers) { $t.BeginAnimation($xp, $null); $t.X = $f * $W }
    $knob.BeginAnimation($xp, $null); $knob.X = $f * $W - $half
    if ($m.Playing -and $f -lt 1) {
        $dur = New-Object System.Windows.Duration ([TimeSpan]::FromSeconds((1 - $f) * $m.End))
        foreach ($t in $pb.Movers) {
            $t.BeginAnimation($xp, (New-Object System.Windows.Media.Animation.DoubleAnimation($W, $dur)))
            Track-Anim $pb.Root $t $xp
        }
        $knob.BeginAnimation($xp, (New-Object System.Windows.Media.Animation.DoubleAnimation(($W - $half), $dur)))
        Track-Anim $pb.Root $knob $xp
    }
    Update-ProgressTime $pb
}

function Format-Time($sec) {
    $s = [int][Math]::Floor([Math]::Max(0.0, $sec))
    '{0}:{1:00}' -f [int][Math]::Floor($s / 60), ($s % 60)
}

function Update-ProgressTime($pb) {
    $f = Get-MediaFraction
    if ($f -lt 0 -or $pb.Root.IsMouseCaptured) { return }
    if ($pb.PosText) {
        $pb.PosText.Text = Format-Time ($f * $script:media.End)
        $pb.EndText.Text = Format-Time $script:media.End
    }
    # Area pudar dekat titik menyesuaikan panjang progress: pendek di awal lagu supaya gelombang
    # tetap terlihat, maksimal FadeMax px
    $W = $pb.Root.ActualWidth
    if ($pb.Mask -and $W -gt 0) {
        $fw = [Math]::Min($pb.FadeMax, [Math]::Max($pb.FadeMax * 0.25, $f * $W * 0.4))
        $pb.Mask.StartPoint = New-Object System.Windows.Point((-$fw - 2), 0)
    }
}

# Progress bergelombang: waktu berjalan | gelombang palet album sampai titik penanda, sisanya
# garis datar | durasi lagu
function New-WaveProgress($w) {
    $outer = New-Object System.Windows.Controls.Grid
    # Tinggi dan jarak sama persis dengan baris volume ($BOTTOM_ROW_H) supaya pergantian keduanya tidak meloncat.
    # Waktu, bar + titik, dan tombol sejajar di garis tengah baris; bukit gelombang naik di atasnya.
    $outer.Margin = '16,8,16,4'; $outer.Height = $BOTTOM_ROW_H
    foreach ($cw in 'Auto', '*', 'Auto', 'Auto', 'Auto') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($cw)
        $outer.ColumnDefinitions.Add($cd)
    }
    $lt = New-LyricsToggle
    [System.Windows.Controls.Grid]::SetColumn($lt, 3)
    [void]$outer.Children.Add($lt)
    $posText = New-Object System.Windows.Controls.TextBlock
    $endText = New-Object System.Windows.Controls.TextBlock
    foreach ($t in $posText, $endText) {
        $t.Foreground = Brush '#B8B8BD'; $t.FontSize = 10.5; $t.VerticalAlignment = 'Center'
        $t.FontFamily = 'Segoe UI Variable Text, Segoe UI'
        $t.Typography.NumeralAlignment = 'Tabular'
    }
    $posText.MinWidth = 28
    $endText.MinWidth = 28; $endText.TextAlignment = 'Right'
    [System.Windows.Controls.Grid]::SetColumn($endText, 2)
    [void]$outer.Children.Add($posText); [void]$outer.Children.Add($endText)
    $tg = New-VolumeToggle
    [System.Windows.Controls.Grid]::SetColumn($tg, 4)
    [void]$outer.Children.Add($tg)
    # Bar (4 px, di dasar jalur gelombang) tepat di garis tengah baris: jalurnya menjorok ke atas baris
    # (margin atas negatif, jadi tidak terpotong) untuk ruang bukit gelombang
    $waveH = 22
    $pb = New-WaveStrip $w $waveH
    $pb.PosText = $posText; $pb.EndText = $endText
    $pb.Root.Margin = "6,$($BOTTOM_ROW_H / 2 + 2 - $waveH),6,$($BOTTOM_ROW_H / 2 - 2)"
    $r = $pb.Root
    $r.IsHitTestVisible = $true; $r.Background = Brush '#01000000'
    if (Test-MediaSeekable) {
        # Klik / geser di gelombang = lompat ke bagian lagu itu. 'nodrag': geseran ini bukan swipe pindah halaman.
        $outer.Tag = 'nodrag'
        $r.Cursor = 'Hand'
        $r.Add_MouseLeftButtonDown({ param($s, $e) $e.Handled = $true; [void]$s.CaptureMouse(); Preview-Seek $s.Tag ($e.GetPosition($s).X) })
        $r.Add_MouseMove({ param($s, $e) if ($s.IsMouseCaptured) { Preview-Seek $s.Tag ($e.GetPosition($s).X) } })
        $r.Add_MouseLeftButtonUp({
            param($s, $e)
            if (-not $s.IsMouseCaptured) { return }
            $e.Handled = $true
            $x = $e.GetPosition($s).X; $W = $s.ActualWidth
            $s.ReleaseMouseCapture()
            if ($W -gt 0 -and $script:media) { Media-Seek ([Math]::Max(0.0, [Math]::Min(1.0, $x / $W)) * $script:media.End) }
        })
    } else {
        $r.ToolTip = T 'Posisi lagu ini hanya bisa digeser di aplikasi pemutarnya' 'This player only lets you jump within its own app'
    }
    [System.Windows.Controls.Grid]::SetColumn($pb.Root, 1)
    [void]$outer.Children.Add($pb.Root)
    $script:progressBars += $pb
    Update-ProgressTime $pb
    $progressClock.Start()
    $outer
}

# Satu jalur progress bergelombang (dipakai kartu musik dan versi kecil di mini island), meniru gaya
# pemutar musik modern: bar terisi tebal berwarna album, sisa lagu garis tipis, titik bercincin putih,
# dan bukit-bukit tembus pandang (IslandWave) yang berdiri di atas bar dan menyusut mulus ke titik.
# Hasil: objek progress ($pb) untuk Start-Progress; elemennya di $pb.Root.
function New-WaveStrip($w, $h, [switch]$Small) {
    $m = $script:media
    $c1 = $m.Accent
    # Warna tiap lapis bukit harus jelas beda dari bar dan satu sama lain (seperti referensi: bar merah,
    # bukit merah muda / oranye / kuning). Pakai warna kedua/ketiga cover kalau hue-nya cukup jauh;
    # kalau cover cenderung satu warna, ambil hue tetangga warna utama (lebih hangat & lebih sejuk).
    $hue1 = [IslandFast]::Hue($c1.R, $c1.G, $c1.B)
    function Far($c) { if (-not $c) { return $false }; $d = [Math]::Abs([IslandFast]::Hue($c.R, $c.G, $c.B) - $hue1); if ($d -gt 180) { $d = 360 - $d }; $d -ge 28 }
    $l1 = [IslandFast]::ShiftHue($c1, -8, 0.85, 1.15)
    $l2 = if (Far $m.Accent2) { $m.Accent2 } else { [IslandFast]::ShiftHue($c1, 32, 1.0, 1.1) }
    $l3 = if ((Far $m.Accent3) -and $m.Accent3 -ne $l2) { $m.Accent3 } else { [IslandFast]::ShiftHue($c1, -34, 1.0, 1.1) }
    $barH = if ($Small) { 2.0 } else { 4.0 }
    $trackH = if ($Small) { 1.0 } else { 2.0 }
    $knobS = if ($Small) { 5.0 } else { 11.0 }
    # Versi kecil: bar diangkat sedikit supaya titiknya tidak terpotong tepi bawah
    $barBottom = if ($Small) { 1.5 } else { 0.0 }
    # Dasar bukit sedikit masuk ke dalam bar supaya bukit tampak tumbuh dari bar
    $baseY = $h - $barBottom - $barH * 0.75
    $root = New-Object System.Windows.Controls.Grid
    $root.Height = $h; $root.VerticalAlignment = 'Bottom'; $root.IsHitTestVisible = $false
    $track = New-Object System.Windows.Controls.Border
    $track.Height = $trackH; $track.CornerRadius = New-Object System.Windows.CornerRadius($trackH / 2)
    $track.Background = Brush '#38FFFFFF'; $track.VerticalAlignment = 'Bottom'
    $track.Margin = "0,0,0,$($barBottom + $barH / 2 - $trackH / 2)"
    [void]$root.Children.Add($track)

    $kt = New-Object System.Windows.Media.TranslateTransform
    $wave = New-Object IslandWave($h, $baseY, $(if ($Small) { 0.42 } else { 1.0 }), $(if ($Small) { 1.0 } else { 1.15 }), [System.Windows.Media.Color[]]@($l1, $l2, $l3), $kt, ($knobS / 2))
    $wave.Playing = [bool]$m.Playing
    [void]$root.Children.Add($wave.Root)

    # Bar terisi (bagian lagu yang sudah lewat): tebal, warna album yang makin terang ke kanan, dipotong di posisi lagu
    $bar = New-Object System.Windows.Controls.Border
    $bar.Height = $barH; $bar.CornerRadius = New-Object System.Windows.CornerRadius($barH / 2)
    $bg = New-Object System.Windows.Media.LinearGradientBrush
    $bg.StartPoint = '0,0.5'; $bg.EndPoint = '1,0.5'
    $bg.GradientStops.Add((New-Object System.Windows.Media.GradientStop($c1, 0)))
    $bg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb ($c1.R + (255 - $c1.R) * 0.35) ($c1.G + (255 - $c1.G) * 0.35) ($c1.B + (255 - $c1.B) * 0.35)), 1)))
    $bar.Background = $bg
    $bar.VerticalAlignment = 'Bottom'; $bar.Margin = "0,0,0,$barBottom"
    $barT = New-Object System.Windows.Media.TranslateTransform
    $barClip = New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect(-4000, -4, 4000, ($barH + 8))))
    $barClip.Transform = $barT
    $bar.Clip = $barClip
    [void]$root.Children.Add($bar)

    # Titik penanda bercincin putih dengan cahaya warna album
    $knob = New-Object System.Windows.Shapes.Ellipse
    $knob.Width = $knobS; $knob.Height = $knobS
    $knob.Fill = New-Object System.Windows.Media.SolidColorBrush($c1)
    $knob.Stroke = Brush '#FFFFFFFF'; $knob.StrokeThickness = $(if ($Small) { 1.2 } else { 2.0 })
    $knob.HorizontalAlignment = 'Left'; $knob.VerticalAlignment = 'Bottom'; $knob.Margin = "0,0,0,$($barBottom + $barH / 2 - $knobS / 2)"
    if (-not $Small) {
        $glow = New-Object System.Windows.Media.Effects.DropShadowEffect
        $glow.Color = $c1; $glow.BlurRadius = 9; $glow.ShadowDepth = 0; $glow.Opacity = 0.8
        $knob.Effect = $glow
    }
    $knob.RenderTransform = $kt
    [void]$root.Children.Add($knob)

    $pb = [PSCustomObject]@{ Root = $root; Movers = @($barT); Knob = $kt; KnobHalf = $knobS / 2
        Mask = $null; FadeMax = 0; PosText = $null; EndText = $null }
    $root.Tag = $pb
    $root.Add_SizeChanged({ param($s, $e) Start-Progress $s.Tag })
    $pb
}

function Hue($r, $g, $b) {
    $max = [Math]::Max($r, [Math]::Max($g, $b)); $min = [Math]::Min($r, [Math]::Min($g, $b)); $d = $max - $min
    if ($d -eq 0) { return 0 }
    if ($max -eq $r) { $h = 60 * ((($g - $b) / $d) % 6) }
    elseif ($max -eq $g) { $h = 60 * (($b - $r) / $d + 2) }
    else { $h = 60 * (($r - $g) / $d + 4) }
    if ($h -lt 0) { $h += 360 }
    $h
}

# Warna tambahan cover: rata-rata piksel berwarna yang hue-nya cukup jauh dari semua warna yang
# sudah dipakai ($c, dan $c2 kalau ada). Kalau tidak ada, pakai versi terang dari warna utama.
function Get-SecondColor($bmp, $c, $c2 = $null) {
    $bases = @([IslandFast]::Hue($c.R, $c.G, $c.B))
    if ($c2) { $bases += [IslandFast]::Hue($c2.R, $c2.G, $c2.B) }
    $src = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap($bmp, [System.Windows.Media.PixelFormats]::Bgra32, $null, 0)
    $w = $src.PixelWidth; $stride = $w * 4
    $px = New-Object byte[] ($stride * $src.PixelHeight)
    $src.CopyPixels($px, $stride, 0)
    $r = 0.0; $g = 0.0; $b = 0.0
    if (-not [IslandFast]::SecondColor($px, [double[]]$bases, [ref]$r, [ref]$g, [ref]$b)) {
        return Rgb ($c.R + (255 - $c.R) * 0.5) ($c.G + (255 - $c.G) * 0.5) ($c.B + (255 - $c.B) * 0.5)
    }
    $k = 235 / [Math]::Max(1.0, [Math]::Max($r, [Math]::Max($g, $b)))
    Rgb ($r * $k) ($g * $k) ($b * $k)
}

# Tinggi pop-up diukur dari isinya. Tanpa progress: pil penuh. Dengan baris progress, sudutnya
# lebih kecil supaya lengkungan sudut bawah tidak memotong label waktu di kiri/kanan.
function Get-MediaPopupSize($content) {
    $content.Measure((New-Object System.Windows.Size(($WIDE_W - 2), [double]::PositiveInfinity)))
    $h = [Math]::Max([double]$MEDIA_H, [Math]::Ceiling($content.DesiredSize.Height) + 6)
    $r = 24.0
    $h, $r
}

# Isi kartu lama yang sedang memudar keluar saat lagu berganti (dibuang setelah animasinya selesai)
$mediaSwapTimer = New-Object System.Windows.Threading.DispatcherTimer
# Setelah isi lama selesai memudar (jeda 80 + 380 ms, lihat Show-Media)
$mediaSwapTimer.Interval = Ms 500
$mediaSwapTimer.Add_Tick({
    $mediaSwapTimer.Stop()
    $hostG = $mediaView.Child
    if ($hostG -is [System.Windows.Controls.Grid] -and $hostG.Tag -eq 'holder') {
        foreach ($el in @($hostG.Children)) { if ($el.Tag -eq 'out') { $hostG.Children.Remove($el) } }
    }
})

function Show-Media([switch]$Refresh) {
    if (-not $script:media) { return }
    $script:mode = 'media'
    if (-not $Refresh) { $script:volumeMode = $false }
    Set-Theme $script:media.Accent
    $content = New-MediaContent
    # Kartu dibungkus wadah supaya saat lagu berganti isi lama & baru bisa bertumpuk sebentar
    $hostG = $mediaView.Child
    $newSong = $Refresh -and $script:mediaViewKey -and $script:mediaViewKey -ne $script:media.Key
    if ($newSong -and $hostG -is [System.Windows.Controls.Grid] -and $hostG.Tag -eq 'holder') {
        # Lagu berganti saat kartu terbuka: crossfade halus di tempat (tanpa geser). Isi lama mulai memudar
        # sedikit setelah isi baru mulai menampak, jadi kartu tidak sempat redup di tengah.
        foreach ($old in @($hostG.Children)) {
            if ($old.Tag -eq 'out') { continue }
            $old.Tag = 'out'; $old.IsHitTestVisible = $false
            Fade-Smooth $old 0 $SONG_FADE_MS 80
        }
        $content.Opacity = 0
        [void]$hostG.Children.Add($content)
        Fade-Smooth $content 1
        $mediaSwapTimer.Stop(); $mediaSwapTimer.Start()
    } else {
        $hostG = New-Object System.Windows.Controls.Grid
        $hostG.Tag = 'holder'
        [void]$hostG.Children.Add($content)
        $mediaView.Child = $hostG
    }
    $script:mediaViewKey = $script:media.Key
    $h, $r = Get-MediaPopupSize $content
    Resize-Island $WIDE_W $h $r
    Set-IslandVisible $true
    if ($Refresh) { Show-View 'MediaView' } else { Show-View 'MediaView' -Replay }
    if ($Refresh -and $script:hovering) { return }
    $dismissTimer.Stop()
    $dismissTimer.Interval = Ms 4000
    if (-not $script:hovering) { $dismissTimer.Start() }
}

function Open-Notif($n) {
    if ($n.Kind -eq 'update') { Start-SelfUpdate; return }
    # Kedipan taskbar (WeChat) bukan notifikasi Windows: buka exe-nya kalau diketahui, tidak ada yang dihapus
    if ($n.Flash) { if ($n.Exe) { try { Start-Process $n.Exe } catch { Log "open exe: $_" } } }
    else {
        Open-App $n.Aumid
        # Sudah dibuka berarti sudah dibaca: hapus juga dari Pusat Notifikasi
        Remove-Notif $n.Id
    }
}

# Saat diam island disembunyikan; muncul lagi saat ada notifikasi atau kursor di HotZone
function Set-IslandVisible($visible) {
    $island.IsHitTestVisible = $visible
    $to = if ($visible) { 1 } else { 0 }
    $ms = if ($visible) { 320 } else { 480 }
    Animate $island ([System.Windows.UIElement]::OpacityProperty) $to $ms
}

function Open-App($aumid) {
    if (-not $aumid) { return }
    try { Start-Process explorer.exe "shell:AppsFolder\$aumid" } catch { Log "open: $_" }
}

# ---------- Mode ----------
function Go-Idle {
    $script:listPinned = $false
    $script:mode = 'idle'
    $dismissTimer.Stop()
    # Konfirmasi "Hapus semua" tidak boleh terbawa ke daftar berikutnya
    $script:confirmClear = $false; $confirmTimer.Stop()
    $script:viewFadeOutMs = 300
    if (Want-Mini) { Show-Mini }
    else {
        $script:miniOn = $false; $script:miniVisible = $false; $miniTimer.Stop()
        # Cahaya album ikut padam dan napasnya berhenti: tanpa ini animasinya terus jalan di latar selama island
        # tersembunyi (mis. selama main game fullscreen), sampai notifikasi berikutnya
        $gc = $glow.Background.Color
        $ga = New-Object System.Windows.Media.Animation.ColorAnimation((Rgb $gc.R $gc.G $gc.B 0), (New-Object System.Windows.Duration (Ms 300)))
        $glow.Background.BeginAnimation([System.Windows.Media.SolidColorBrush]::ColorProperty, $ga)
        Set-GlowBreath $false
        # Menghilang pelan dan seirama: isi memudar, island mengecil halus (tanpa pantulan) sambil memudar
        Resize-Island $IDLE_W $IDLE_H 15 -Smooth
        Show-View 'none'
        Set-IslandVisible $false
        if (-not $script:overHot -and -not $script:exiting) { Animate $handle ([System.Windows.UIElement]::OpacityProperty) 0.55 300 }
    }
    $script:viewFadeOutMs = 140
    $cleanupTimer.Stop(); $cleanupTimer.Start()
    Process-Queue
}

# ---------- Mini island saat lagu diputar ----------
$script:miniOn = $false
function Want-Mini {
    [bool]((($script:media -and $script:media.Playing) -or $script:clock) -and -not $script:fullscreen -and -not $script:exiting)
}
# Isi mini island: lagu yang diputar (timer pindah ke gelembung di sebelahnya), atau timer saja
function Get-MiniKey {
    if ($script:media -and $script:media.Playing) { $script:media.Key } elseif ($script:clock) { 'clock' } else { '' }
}

# Cover kecil di kiri, lirik / judul berjalan di tengah, equalizer di kanan (semua 60 fps)
function New-MiniContent {
    $m = $script:media
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in 'Auto', '*', 'Auto') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
        $g.ColumnDefinitions.Add($cd)
    }
    $lyr = New-Object System.Windows.Controls.Grid
    $lyr.ClipToBounds = $true; $lyr.Margin = '7,0,7,0'
    [System.Windows.Controls.Grid]::SetColumn($lyr, 1)
    [void]$g.Children.Add($lyr)
    $script:miniLyricHost = $lyr
    $art = New-Object System.Windows.Controls.Border
    $art.Width = 19; $art.Height = 19; $art.CornerRadius = New-Object System.Windows.CornerRadius(6)
    $art.HorizontalAlignment = 'Left'; $art.VerticalAlignment = 'Center'; $art.Margin = '5,0,0,0'
    if ($m.Art) {
        $ib = New-Object System.Windows.Media.ImageBrush($m.Art); $ib.Stretch = 'UniformToFill'
        $art.Background = $ib
    } else {
        $gt = New-Object System.Windows.Controls.TextBlock
        $gt.Text = $GLYPH_MUSIC; $gt.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $gt.FontSize = 11
        $gt.Foreground = New-Object System.Windows.Media.SolidColorBrush($m.Accent)
        $gt.HorizontalAlignment = 'Center'; $gt.VerticalAlignment = 'Center'
        $art.Child = $gt
    }
    [void]$g.Children.Add($art)
    $eq = New-Equalizer $m.Accent $true
    $eq.HorizontalAlignment = 'Right'; $eq.Margin = '0,0,9,0'
    [System.Windows.Controls.Grid]::SetColumn($eq, 2)
    $eq.LayoutTransform = New-Object System.Windows.Media.ScaleTransform(0.95, 0.95)
    [void]$g.Children.Add($eq)
    $g
}

# Mini island selama lagu diputar: pil kecil berisi judul & artis yang berjalan. Saat ada baris lirik,
# pil membesar mulus menjadi baris lirik, lalu kembali mengecil saat lirik selesai / jeda instrumental.
function Show-Mini {
    # Lagu berganti saat mini island sedang menampilkan lagu: isi lama memudar keluar sambil isi baru memudar masuk
    $crossfade = $script:miniOn -and $script:miniVisible -and $script:miniKey -and $script:miniKey -ne 'clock' -and
        $script:mode -eq 'idle' -and (Get-MiniKey) -ne 'clock'
    $script:miniOn = $true
    $script:miniVisible = $true
    $script:miniKey = Get-MiniKey
    $script:miniFaded = $false
    $music = $script:miniKey -ne 'clock'
    $mv = $views['MiniView']
    if ($crossfade) {
        foreach ($old in @($mv.Children)) {
            if ($old.Tag -eq 'out') { continue }
            $old.Tag = 'out'
            Fade-Smooth $old 0 $SONG_FADE_MS 80
        }
        $miniSwapTimer.Stop(); $miniSwapTimer.Start()
    } else { $mv.Children.Clear() }
    $script:miniW = -1; $script:miniH = -1
    $script:lyricIdx = -2
    if ($music) {
        Set-Theme $script:media.Accent
        $nc = New-MiniContent
        if ($crossfade) { $nc.Opacity = 0 }
        [void]$mv.Children.Add($nc)
        if ($crossfade) { Fade-Smooth $nc 1 }
    } else {
        Set-Theme $CLOCK_COLOR
        $script:miniLyricHost = $null; $script:miniBar = $null
        [void]$mv.Children.Add((New-ClockMini))
        Set-MiniSize $MINI_W $MINI_H
    }
    Show-View 'MiniView'
    $views['MiniView'].IsHitTestVisible = $false
    Set-IslandVisible $true
    # Mini island tidak menangkap klik; daftar tetap dibuka lewat garis penanda di atasnya
    $island.IsHitTestVisible = $false
    if (-not $script:overHot) { Animate $handle ([System.Windows.UIElement]::OpacityProperty) 0 200 }
    if ($music) {
        Update-MiniLyric
        $lyricTimer.Start()
    }
    Update-Bubble
    $miniTimer.Start()
}

# Isi mini island lagu sebelumnya dibuang setelah selesai memudar (lihat crossfade di Show-Mini)
$miniSwapTimer = New-Object System.Windows.Threading.DispatcherTimer
$miniSwapTimer.Interval = Ms 500
$miniSwapTimer.Add_Tick({
    $miniSwapTimer.Stop()
    $mv = $views['MiniView']
    foreach ($el in @($mv.Children)) { if ($el.Tag -eq 'out') { $mv.Children.Remove($el) } }
})

# Antar baris lirik ukurannya berubah lebih cepat supaya tidak terasa tertinggal dari teksnya
function Set-MiniSize($w, $ht, $ms = 0) {
    if ($w -eq $script:miniW -and $ht -eq $script:miniH) { return }
    $script:miniW = $w; $script:miniH = $ht
    Resize-Island $w $ht ($ht / 2) -Smooth -Ms $ms
}

# Judul - artis yang berjalan terus ke kiri di dalam pil kecil (dua salinan supaya putarannya tanpa sambungan),
# tepinya memudar
$MARQUEE_SPEED = 22   # px per detik
function New-MiniMarquee {
    $m = $script:media
    $artist = Get-DisplayArtist $m
    $txt = if ($artist) { "$($m.Title)  " + [char]0x00B7 + "  $artist" } else { "$($m.Title)" }
    $cv = New-Object System.Windows.Controls.Canvas
    $cv.ClipToBounds = $true; $cv.Height = 15
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'
    foreach ($i in 0, 1) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $txt; $tb.FontSize = 11; $tb.FontWeight = 'SemiBold'; $tb.Foreground = Brush '#D9FFFFFF'
        $tb.Margin = '0,0,28,0'
        [void]$sp.Children.Add($tb)
    }
    [void]$cv.Children.Add($sp)
    $sp.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
    $cycle = $sp.DesiredSize.Width / 2
    [System.Windows.Controls.Canvas]::SetTop($sp, (15 - $sp.DesiredSize.Height) / 2)
    $tt = New-Object System.Windows.Media.TranslateTransform
    $sp.RenderTransform = $tt
    $a = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, (-$cycle), (New-Object System.Windows.Duration ([TimeSpan]::FromSeconds($cycle / $MARQUEE_SPEED))))
    $a.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($a, $AMBIENT_FPS)
    $tt.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $a)
    Track-Anim $sp $tt ([System.Windows.Media.TranslateTransform]::XProperty)
    # Tepi kiri/kanan memudar (selebar area teks di pil kecil)
    $mask = New-Object System.Windows.Media.LinearGradientBrush
    $mask.MappingMode = 'Absolute'; $mask.StartPoint = '0,0'; $mask.EndPoint = "$MINI_TEXT_W,0"
    foreach ($st in @(@(0, 0.0), @(255, 0.16), @(255, 0.84), @(0, 1.0))) {
        $mask.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb 0 0 0 $st[0]), $st[1])))
    }
    $cv.OpacityMask = $mask
    # Di bawah judul: progress bergelombang versi kecil (gaya sama dengan kartu musik)
    $box = New-Object System.Windows.Controls.StackPanel
    $box.Name = 'marquee'; $box.VerticalAlignment = 'Center'
    [void]$box.Children.Add($cv)
    $pb = New-WaveStrip $MINI_TEXT_W 9 -Small
    $pb.Root.Margin = '1,0,1,0'
    [void]$box.Children.Add($pb.Root)
    $script:miniBar = $pb
    $box.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $box
}

# Kursor mendekati mini island: island memudar habis. Piksel yang benar-benar transparan
# tembus klik, jadi tab/tombol aplikasi di bawahnya tetap bisa diklik.
$miniTimer = New-Object System.Windows.Threading.DispatcherTimer
$miniTimer.Interval = Ms 120
$miniTimer.Add_Tick({
    if ($script:mode -ne 'idle' -or -not $script:miniOn) { $miniTimer.Stop(); return }
    # Sedang tersembunyi (tidak ada lirik): tidak ada yang perlu dipudarkan
    if (-not $script:miniVisible) { $script:miniFaded = $false; return }
    $near = $false
    try {
        $p = [IslandNative]::CursorPos()
        $q = $island.PointFromScreen((New-Object System.Windows.Point($p[0], $p[1])))
        # Gelembung timer di kanan island ikut dihitung
        $right = $island.ActualWidth + $bubble.ActualWidth + $bubble.Margin.Left
        # Jarak ikut cahaya warna album di sekeliling island (bagian itu juga menghalangi klik)
        $near = $q.X -ge -22 -and $q.X -le ($right + 22) -and $q.Y -ge -1 -and $q.Y -le ($island.ActualHeight + 20)
    } catch {}
    if ($near -ne $script:miniFaded) {
        $script:miniFaded = $near
        if ($near) { Animate $island ([System.Windows.UIElement]::OpacityProperty) 0 160 }
        else { Animate $island ([System.Windows.UIElement]::OpacityProperty) 1 300 }
        Update-Bubble
    }
})

# Status lagu / timer berubah saat island diam: mini island muncul/hilang/ganti isi
function Update-Mini {
    if ($script:mode -ne 'idle') { return }
    $want = Want-Mini
    if ($want -ne $script:miniOn -or ($want -and $script:miniKey -ne (Get-MiniKey))) { Go-Idle }
}

# ---------- Lirik (LRCLIB) ----------
# Lirik tersinkron per baris dari lrclib.net (gratis, tanpa akun): satu pencarian per lagu, hasilnya
# disimpan di memori. Selama lirik dimatikan tidak ada permintaan sama sekali.
Add-Type -AssemblyName System.Net.Http
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$http = New-Object System.Net.Http.HttpClient
$http.Timeout = [TimeSpan]::FromSeconds(12)
[void]$http.DefaultRequestHeaders.UserAgent.TryParseAdd("MiniIsland/$APP_VERSION (+$REPO_URL)")
$lyricsCache = @{}
$lyricsFails = @{}
$script:lyricsReq = $null
$script:lyricsRetry = $null
$MINI_MAX_W = 380
$GLYPH_LYRICS = [string][char]0xE90B

# "(feat. X)", "[Official Video]", "- Remastered 2011" membuat pencarian meleset
function Clean-SongText($s) {
    $s = [regex]::Replace("$s", '\s*[\(\[][^\)\]]*(feat|ft\.|official|video|audio|lyric|remaster|m/?v)[^\)\]]*[\)\]]', '', 'IgnoreCase')
    $s = [regex]::Replace($s, '\s+-\s+.*remaster.*$', '', 'IgnoreCase')
    $s.Trim()
}

# Video biasa di browser (YouTube, Facebook, dll; tanpa album): judulnya berisi artis dan tag video, "artis"-nya
# nama channel. YouTube Music, Spotify, Apple Music mengisi album, jadi judul dan artisnya dipakai apa adanya.
# Video = video browser; Music = judulnya memang seperti lagu (video lain, mis. reels, tidak dicarikan lirik).
function Get-SongQuery($m) {
    $title = "$($m.Title)"; $artist = "$($m.Artist)"
    # Aplikasi YouTube Music yang dipasang dari Chrome punya AUMID sendiri: itu pemutar musik, bukan video
    $video = "$($m.App)" -match $BROWSER_APP -and "$($m.App)" -notmatch 'cinhimbnkkaeohfgghhklpknlkffjgod' -and -not $m.Album
    $music = -not $video
    if ($video) {
        # Tanda video musik (kata utuh, bukan sekadar "video" di akhir judul vlog): Official, MV/PV, Music/Lyric
        # Video, Lyrics, (Audio); atau channel lagu: "Artis - Topic" (dibuat otomatis YouTube), "ArtisVEVO", "Artis Official"
        $music = $title -match '(?i)\bofficial\b|\bm/?v\b|\bpv\b|\bmusic\s*video\b|\blyrics?\b|[\(\[]\s*audio\s*[\)\]]' -or
            $artist -match '(?i)\s-\sTopic$|VEVO$|\bofficial\b|\u516C\u5F0F'
        # [MV], (Official Video), [OFFICIAL], (lebar penuh) MV, "| channel" di belakang, "Official Music Video" di akhir
        # (juga versi: "(Full version)", "<Platinum Long Version>" kurung sudut lebar penuh, "(TV size)")
        $t = [regex]::Replace($title, '\s*[\(\[\u3010\uff1c<\u3008][^\)\]\u3011\uff1e>\u3009]*(official|video|audio|lyric|m/?v|4k|hd|\bver\b|version|\bfull\b|\blong\b|\bsize\b)[^\)\]\u3011\uff1e>\u3009]*[\)\]\u3011\uff1e>\u3009]', '', 'IgnoreCase')
        $t = [regex]::Replace($t, '\s*[|\uFF5C].*$', '')
        $title = [regex]::Replace($t, '\s*\b(official\s*)?(music\s*video|lyric\s*video|video|audio|m/?v)\s*$', '', 'IgnoreCase')
        # Artis dari nama channel: "ArtisVEVO", "Artis Official", "Artis (kanji) official channel"
        $artist = $artist -replace 'VEVO$', '' -replace '(?i)\s*(official|\u516C\u5F0F).*$', ''
        # Judul lagu dalam tanda kutip: Kano "Stella-rium", YOASOBI (kurung siku Jepang) Idol, Ado (kurung lebar penuh) Show
        if ($title -match '^(.*?)\s*["\u201C\u300C\u300E\u3010](.+?)["\u201D\u300D\u300F\u3011]') {
            if ($matches[1].Trim()) { $artist = $matches[1] }
            $title = $matches[2]; $music = $true
        } elseif ($title -match '^(.+?)\s+[-\u2013\u2014]\s+(.+)$') {
            # "Artis - Judul"; "Judul - Artis" kalau bagian kanan = nama channel
            if ($artist -and $artist.IndexOf($matches[1].Trim(), [StringComparison]::OrdinalIgnoreCase) -lt 0 -and
                $artist.IndexOf($matches[2].Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0) { $title = $matches[1]; $artist = $matches[2] }
            else { $artist = $matches[1]; $title = $matches[2] }
            $music = $true
        } elseif ($title -match '^(.+?)(?:\s+/\s+|\s*\uFF0F\s*)(.+)$') {
            # "Judul / Artis" (umum di video Jepang); "Artis / Judul" kalau bagian kiri = nama channel
            if ($artist -and $artist.IndexOf($matches[1].Trim(), [StringComparison]::OrdinalIgnoreCase) -ge 0) { $artist = $matches[1]; $title = $matches[2] }
            else { $title = $matches[1]; $artist = $matches[2] }
            $music = $true
        }
        # "Get Lucky ft. Pharrell Williams" di luar kurung: penyanyi tamu bukan bagian judul lagu
        $title = $title -replace '(?i)\s+(ft|feat|featuring)\.?\s.*$', ''
    }
    # Artis pertama saja; YouTube Music kadang menambah " - Topic", Apple Music menambah " (em dash) Album",
    # channel kadang memakai dua nama ("nama Jepang / nama Latin")
    $artist = (($artist -replace '\s+-\s+Topic$', '' -replace '\s+\u2014\s+.*$', '') -split ',|&|\s+/\s+|\s+(?:feat|ft)\.?\s+|\s+x\s+')[0].Trim()
    @{ Title = Clean-SongText $title; Artist = $artist; Video = $video; Music = $music }
}

# Lirik yang sudah pernah dicari disimpan di folder lyrics (satu file per lagu): lagu yang sering diputar
# tidak perlu dicari lagi di internet, dan geseran timing per lagu ikut tersimpan di file itu.
# Lagu yang liriknya tidak ketemu dicoba lagi setelah 3 hari.
$lyricsDir = Join-Path $here 'lyrics'
function Get-LyricsFile($title, $artist) {
    $sha = New-Object System.Security.Cryptography.SHA1Managed
    $h = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes(("$title|$artist").ToLowerInvariant()))) -replace '-', ''
    Join-Path $lyricsDir ($h.Substring(0, 20) + '.json')
}

# Data lirik satu lagu: Lines (bersinkron) atau Plain (teks biasa, waktunya ditaksir), Offset (detik)
function New-LyricsEntry($d, $file) {
    $e = @{ Synced = [string]$d.Synced; Plain = [string]$d.Plain; Duration = [double]$d.Duration; None = [bool]$d.None
        Offset = [double]$d.Offset; Fetched = [string]$d.Fetched; File = $file; Lines = $null }
    if (-not $e.Fetched) { $e.Fetched = (Get-Date).ToString('o') }
    if ($e.Synced) { $e.Lines = @(Parse-Lrc $e.Synced) }
    $e
}

function Save-LyricsEntry($e) {
    if (-not $e.File) { return }
    try {
        if (-not (Test-Path $lyricsDir)) { [void](New-Item -ItemType Directory -Path $lyricsDir) }
        [PSCustomObject]@{ Synced = $e.Synced; Plain = $e.Plain; Duration = $e.Duration; None = $e.None
            Offset = $e.Offset; Fetched = $e.Fetched } | ConvertTo-Json | Set-Content -Path $e.File -Encoding UTF8
    } catch { Log "lyrics save: $_" }
}

# Lirik baru tersedia untuk lagu yang sedang diputar
function Lyrics-Arrived {
    $script:lyricIdx = -2
    if ($script:miniOn) { $lyricTimer.Start() }
    # Daftar terbuka: titik halaman lirik muncul
    if ($script:mode -eq 'list') { Update-PageDots }
}

function Request-Lyrics {
    $m = $script:media
    if (-not $m -or -not $script:settings.Lyrics) { return }
    if ($lyricsCache.ContainsKey($m.Key)) { return }
    if ($script:lyricsReq -and $script:lyricsReq.Key -eq $m.Key) { return }
    $q = Get-SongQuery $m
    # Video di browser: hanya yang judulnya seperti lagu, dan setelah durasinya diketahui (tanpa durasi,
    # hasil pencarian apa pun diterima). Dipanggil lagi dari Poll-Media saat durasinya datang.
    if ($q.Video -and (-not $q.Music -or $m.End -le 0)) { return }
    $title = $q.Title; $artist = $q.Artist
    $file = Get-LyricsFile $title $artist
    if (Test-Path $file) {
        try {
            $j = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $fresh = -not $j.None -or ((Get-Date) - [datetime]::Parse($j.Fetched)).TotalDays -lt 3
            # Versi lain lagu yang sama (mis. video klip lebih panjang) punya timing berbeda: cari ulang
            $fits = -not ($m.End -gt 0 -and $j.Duration -gt 0 -and [Math]::Abs([double]$j.Duration - $m.End) -gt 8)
            if ($fresh -and $fits) {
                if ($lyricsCache.Count -gt 200) { $lyricsCache.Clear() }
                $lyricsCache[$m.Key] = New-LyricsEntry $j $file
                Lyrics-Arrived
                return
            }
        } catch { Log "lyrics file: $_" }
    }
    $url = 'https://lrclib.net/api/search?track_name={0}&artist_name={1}' -f [uri]::EscapeDataString($title), [uri]::EscapeDataString($artist)
    try { $task = $http.GetStringAsync($url) } catch { Log "lyrics: $_"; return }
    $script:lyricsReq = @{ Key = $m.Key; Task = $task; Stage = 1; Title = $title; Artist = $artist; File = $file; Plain = $null; Strict = $q.Video }
}

# Lirik lagu yang sedang diputar (baris berwaktu), atau $null. Lirik biasa (tanpa waktu) dibagi rata
# sepanjang lagu menurut panjang barisnya; dihitung ulang kalau durasi lagu baru diketahui.
function Get-Lyrics {
    $m = $script:media
    if (-not $m -or -not $script:settings.Lyrics) { return $null }
    $e = $lyricsCache[$m.Key]
    if (-not $e) { return $null }
    if ($e.Lines -and $e.Lines.Count) { return , $e.Lines }
    if ($e.Plain -and $m.End -gt 0) {
        if ($e.PlainEnd -ne $m.End) { $e.PlainLines = @(Estimate-PlainLines $e.Plain $m.End); $e.PlainEnd = $m.End }
        if ($e.PlainLines.Count) { return , $e.PlainLines }
    }
    $null
}

function Estimate-PlainLines($text, $end) {
    $items = @(); $total = 0.0
    foreach ($l in ("$text" -split "`r?`n")) {
        $t = $l.Trim()
        # Baris kosong = jeda antar bait
        $w = if ($t) { 6.0 + $t.Length } else { 10.0 }
        $items += @{ Text = $t; W = $w }; $total += $w
    }
    if ($total -le 0) { return @() }
    # Intro dan outro lagu biasanya tanpa vokal
    $start = $end * 0.08; $span = $end * 0.86; $at = 0.0
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($it in $items) {
        $t0 = $start + $span * $at / $total
        $at += $it.W
        if ($it.Text) { $out.Add([PSCustomObject]@{ T = $t0; Text = $it.Text; Words = @(); End = $start + $span * $at / $total; Estimated = $true }) }
    }
    $out.ToArray()
}

# Geseran timing lirik lagu ini (scroll di tombol lirik), ditambah geseran umum dari menu
function Get-SongOffset {
    $e = if ($script:media) { $lyricsCache[$script:media.Key] } else { $null }
    if ($e) { [double]$e.Offset } else { 0.0 }
}
function Get-LyricDelay { $script:settings.LyricDelay + (Get-SongOffset) }

# Langkah berikutnya: pencarian bebas "judul artis" (2), lalu judul saja (3). lrclib menolak permintaan
# yang terlalu rapat (503, walau retry-after-nya 1 detik; jeda 1,5 detik masih ditolak), jadi dikirim
# Check-Lyrics sesudah jeda.
function Queue-FreeSearch($r, $stage = 2) {
    $q = if ($stage -eq 3) { $r.Title } else { "$($r.Title) $($r.Artist)" }
    $r.Url = 'https://lrclib.net/api/search?q={0}' -f [uri]::EscapeDataString($q)
    $r.Task = $null; $r.Stage = $stage; $r.At = (Get-Date).AddSeconds(3)
    $script:lyricsReq = $r
}

# Huruf dan angka saja, huruf kecil: "Chimame-tai" -> "chimametai"
function Get-PlainText($s) { ("$s" -replace '[^\p{L}\p{N}]', '').ToLowerInvariant() }

# Nama sama kalau huruf/angkanya sama, abaikan tanda baca, spasi dan besar kecil ("Chimame-tai" = "chimametai").
# Salah satu boleh lebih panjang ("Stella-rium" di "Stella-rium (TV size)") asal yang pendek minimal 4 huruf dan
# paling tidak separuh panjang yang lain ("Ado" bukan "Tornado")
function Test-SameText($a, $b) {
    $a = Get-PlainText $a; $b = Get-PlainText $b
    if (-not $a -or -not $b) { return $false }
    if ($a.Length -gt $b.Length) { $a, $b = $b, $a }
    $a -eq $b -or ($a.Length -ge 4 -and $a.Length * 2 -ge $b.Length -and $b.Contains($a))
}

# Dicek tiap detik (Poll) dan tiap tick lirik; tidak pernah menunggu jaringan di thread UI
function Check-Lyrics {
    $rt = $script:lyricsRetry
    if ($rt -and (Get-Date) -ge $rt.At) {
        $script:lyricsRetry = $null
        if ($script:media -and $script:media.Key -eq $rt.Key) { Request-Lyrics }
    }
    $r = $script:lyricsReq
    # Pencarian bebas yang ditunda (lihat jeda setelah pencarian ketat gagal di bawah). Lirik dimatikan atau
    # lagunya sudah berganti selama menunggu: tidak usah dikirim.
    if ($r -and -not $r.Task -and (Get-Date) -ge $r.At) {
        if (-not $script:settings.Lyrics -or -not $script:media -or $script:media.Key -ne $r.Key) { $script:lyricsReq = $null; return }
        try { $r.Task = $http.GetStringAsync($r.Url) } catch { Log "lyrics: $_"; $script:lyricsReq = $null; return }
    }
    if (-not $r -or -not $r.Task -or -not $r.Task.IsCompleted) { return }
    $script:lyricsReq = $null
    $pick = $null
    if ($r.Task.Status -eq 'RanToCompletion') {
        $end = if ($script:media -and $script:media.Key -eq $r.Key) { $script:media.End } else { 0 }
        try {
            # (Tanpa @(): ConvertFrom-Json PowerShell 5.1 mengeluarkan array JSON sebagai satu objek)
            $res = ConvertFrom-Json $r.Task.Result
            # Pencarian judul saja bisa menemukan lagu lain berjudul sama ("Stay"): judul dan artisnya harus sama
            # (durasi yang kebetulan mirip tidak cukup; hasilnya disimpan selamanya). Video di browser (judulnya bisa
            # kalimat biasa): di semua tahap judul lagunya harus memuat seluruh judul video (lagu "Food" bukan
            # "trying street food in Jakarta"), dan artisnya sama atau durasinya cocok sampai 1 detik.
            if ($r.Strict) {
                $t = Get-PlainText $r.Title
                $res = @($res | Where-Object { $t -and (Get-PlainText $_.trackName).Contains($t) -and
                    ((Test-SameText $_.artistName $r.Artist) -or ($end -gt 0 -and [Math]::Abs([double]$_.duration - $end) -le 1)) })
            } elseif ($r.Stage -eq 3) { $res = @($res | Where-Object { (Test-SameText $_.trackName $r.Title) -and (Test-SameText $_.artistName $r.Artist) }) }
            $pick = Pick-Lyrics $res $end
        } catch { Log "lyrics parse: $_" }
    } else {
        # Gagal jaringan / server sibuk (503): coba lagi 20 detik kemudian, maksimal 3 kali per lagu
        Log "lyrics net: $($r.Task.Exception.InnerException.Message)"
        # Pencarian ketat bisa ditolak server untuk teks tertentu (mis. 503): coba pencarian bebas
        if ($r.Stage -eq 1) { Queue-FreeSearch $r; return }
        $n = 1 + [int]$lyricsFails[$r.Key]
        $lyricsFails[$r.Key] = $n
        if ($n -lt 3) { $script:lyricsRetry = @{ Key = $r.Key; At = (Get-Date).AddSeconds(20) } }
        else { $lyricsCache[$r.Key] = New-LyricsEntry @{ None = $true } $null }   # hanya di memori
        return
    }
    # Pencarian ketat tidak menemukan lirik bersinkron: coba pencarian bebas "judul artis"
    # (lirik biasa dari pencarian pertama disimpan sebagai cadangan)
    if ((-not $pick -or -not $pick.Synced) -and $r.Stage -lt 3) {
        if ($pick -and -not $r.Plain) { $r.Plain = $pick }
        # Nama artis sering ditulis beda di lrclib (mis. tanpa tanda hubung): terakhir, cari judulnya saja
        Queue-FreeSearch $r ($r.Stage + 1); return
    }
    if ((-not $pick -or -not $pick.Synced) -and $r.Plain) { $pick = $r.Plain }
    if (-not $pick) { $pick = @{ None = $true } }
    if ($lyricsCache.Count -gt 200) { $lyricsCache.Clear() }
    $e = New-LyricsEntry $pick $r.File
    $lyricsCache[$r.Key] = $e
    Save-LyricsEntry $e
    Lyrics-Arrived
}

# Pilih hasil bersinkron dengan durasi paling dekat (versi lain lagu yang sama bisa beda timing).
# Kalau tidak ada yang bersinkron, lirik biasa dengan durasi yang cocok.
function Pick-Lyrics($results, $end) {
    $best = $null; $bestD = [double]::MaxValue; $plain = $null; $plainD = [double]::MaxValue
    foreach ($x in @($results)) {
        if ($x.instrumental) { continue }
        $d = if ($end -gt 0 -and $x.duration) { [Math]::Abs([double]$x.duration - $end) } else { 0.0 }
        if ($x.syncedLyrics -and $d -lt $bestD) { $best = $x; $bestD = $d }
        if ($x.plainLyrics -and $d -lt $plainD) { $plain = $x; $plainD = $d }
    }
    # Durasi beda > 5 detik = kemungkinan versi lain (radio edit, MV) dengan timing berbeda: lebih baik tanpa lirik
    if ($best -and -not ($end -gt 0 -and $bestD -gt 5)) { return @{ Synced = $best.syncedLyrics; Duration = [double]$best.duration } }
    if ($plain -and -not ($end -gt 0 -and $plainD -gt 8)) { return @{ Plain = $plain.plainLyrics; Duration = [double]$plain.duration } }
    $null
}

# "[01:02.50] teks" -> {T, Text, Words, End}. Format LRC lanjutan "<01:02.80> kata" (waktu per kata)
# dipakai untuk sapuan karaoke yang lebih tepat kalau tersedia.
function Parse-Lrc($text) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($raw in ("$text" -split "`r?`n")) {
        $tags = [regex]::Matches($raw, '\[(\d+):(\d+(?:\.\d+)?)\]')
        if ($tags.Count -eq 0) { continue }
        $body = [regex]::Replace($raw, '\[\d+:\d+(?:\.\d+)?\]', '')
        $parts = [regex]::Split($body, '<(\d+:\d+(?:\.\d+)?)>')
        $clean = ''; $words = @(); $pending = $null
        for ($i = 0; $i -lt $parts.Count; $i++) {
            # [double], bukan [int]: menit tidak wajar di file lirik ([99999999999:00]) tidak boleh membuat error
            if ($i % 2 -eq 1) { $a = $parts[$i] -split ':'; $pending = [double]$a[0] * 60 + [double]$a[1]; continue }
            $p = $parts[$i]
            if ($clean.EndsWith(' ')) { $p = $p.TrimStart() }
            if ($null -ne $pending) { $words += [PSCustomObject]@{ T = $pending; C = $clean.Length }; $pending = $null }
            $clean += $p
        }
        $lead = $clean.Length - $clean.TrimStart().Length
        $clean = $clean.Trim()
        # Baris tanpa huruf/angka sama sekali (mis. hanya not musik) = penanda bagian instrumental:
        # diperlakukan seperti baris kosong, jadi island menampilkan judul & artis, bukan simbolnya
        if ($clean -notmatch '[\p{L}\p{N}]') { $clean = ''; $words = @() }
        foreach ($w in $words) { $w.C = [Math]::Max(0, $w.C - $lead) }
        foreach ($t in $tags) {
            $out.Add([PSCustomObject]@{ T = [double]$t.Groups[1].Value * 60 + [double]$t.Groups[2].Value; Text = $clean; Words = $words; End = 0.0 })
        }
    }
    $sorted = @($out | Sort-Object T)
    for ($i = 0; $i -lt $sorted.Count; $i++) {
        $sorted[$i].End = if ($i + 1 -lt $sorted.Count) { $sorted[$i + 1].T } else { $sorted[$i].T + 6 }
    }
    $sorted
}

function Get-SongPos {
    $m = $script:media
    $p = $m.Pos
    if ($m.Playing) { $p += ((Get-Date) - $m.PosAt).TotalSeconds }
    $p
}

# Baris terakhir yang waktunya sudah lewat (pencarian biner)
function Find-LyricLine($lines, $pos) {
    $lo = 0; $hi = $lines.Count - 1; $ans = -1
    while ($lo -le $hi) {
        $mid = [int][Math]::Floor(($lo + $hi) / 2)
        if ($lines[$mid].T -le $pos) { $ans = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 }
    }
    $ans
}

# ---------- Furigana ----------
# Bacaan hiragana kecil di atas kanji, dari pembaca bawaan Windows (JapanesePhoneticAnalyzer, offline).
# Okurigana (kana yang menempel setelah kanji) tidak diberi furigana.
# Catatan: file ini dibaca PowerShell 5.1 sebagai ANSI, jadi semua karakter non-ASCII dibuat lewat [char]
$KANJI = '[\p{IsCJKUnifiedIdeographs}\p{IsCJKUnifiedIdeographsExtensionA}' + [char]0x3005 + [char]0x3006 + [char]0x30F6 + ']'
$JAPANESE = '[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}\p{IsCJKUnifiedIdeographsExtensionA}' + [char]0x3005 + ']'
try { $null = [Windows.Globalization.JapanesePhoneticAnalyzer, Windows.Globalization, ContentType = WindowsRuntime] } catch { Log "furigana: $_" }

function To-Hiragana($s) {
    -join ($s.ToCharArray() | ForEach-Object { if ($_ -ge [char]0x30A1 -and $_ -le [char]0x30F6) { [char]([int]$_ - 0x60) } else { $_ } })
}

# ---------- Romaji ----------
# Hepburn sederhana dari bacaan hiragana. Tabel urut kode Unicode U+3041..U+3096 (dibuat dari kode supaya
# file tetap ASCII); awalan "_" = kana kecil yang menempel ke suku kata sebelumnya.
$KANA_ROMAJI = @{}
$code = 0x3041
foreach ($r in ('_a a _i i _u u _e e _o o ka ga ki gi ku gu ke ge ko go sa za shi ji su zu se ze so zo ' +
        'ta da chi ji _tsu tsu zu te de to do na ni nu ne no ha ba pa hi bi pi fu bu pu he be pe ho bo po ' +
        'ma mi mu me mo _ya ya _yu yu _yo yo ra ri ru re ro _wa wa i e wo n vu ka ke') -split ' ') {
    $KANA_ROMAJI[[char]$code] = $r; $code++
}
if ($code -ne 0x3097) { Log "romaji: tabel tidak lengkap ($code)" }
$ROMAJI_PUNCT = @{ [char]0x3001 = ','; [char]0x3002 = '.'; [char]0xFF01 = '!'; [char]0xFF1F = '?'; [char]0x3000 = ' '
    [char]0x300C = '"'; [char]0x300D = '"'; [char]0x300E = '"'; [char]0x300F = '"'; [char]0xFF08 = '('; [char]0xFF09 = ')'
    [char]0x30FB = ' '; [char]0xFF5E = '~'; [char]0x301C = '~' }
# Partikel ditulis terpisah (boku wa, ashita wo); partikel ha/he dibaca "wa"/"e"
$PARTICLES = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($c in 0x306F, 0x304C, 0x3092, 0x306B, 0x3067, 0x3068, 0x3082, 0x3078, 0x306E, 0x304B, 0x3088, 0x306D) { [void]$PARTICLES.Add([string][char]$c) }

function Kana-ToRomaji($kana) {
    $out = New-Object System.Text.StringBuilder
    $double = $false
    foreach ($ch in (To-Hiragana $kana).ToCharArray()) {
        if ($ch -eq [char]0x30FC) {
            # Tanda panjang: ulangi vokal terakhir
            if ($out.Length -gt 0 -and 'aeiou'.Contains([string]$out[$out.Length - 1])) { [void]$out.Append($out[$out.Length - 1]) }
            continue
        }
        $r = $KANA_ROMAJI[$ch]
        if (-not $r) {
            $p = $ROMAJI_PUNCT[$ch]
            [void]$out.Append($(if ($p) { $p } else { $ch }))
            $double = $false; continue
        }
        if ($r -eq '_tsu') { $double = $true; continue }   # tsu kecil: konsonan berikutnya digandakan
        if ($r.StartsWith('_')) {
            $v = $r.Substring(1); $s = $out.ToString()
            if ($v.StartsWith('y') -and $s -match '(sh|ch|j)i$') { $out.Length = $out.Length - 1; [void]$out.Append($v.Substring(1)) }   # shi+ya = sha
            elseif ($v.StartsWith('y') -and $s -match '[kgnhbpmr]i$') { $out.Length = $out.Length - 1; [void]$out.Append($v) }          # ki+ya = kya
            elseif ($v.Length -eq 1 -and $s -match '[bcdfghjkmnprstvwz][aeiou]$') { $out.Length = $out.Length - 1; [void]$out.Append($v) } # fu+a = fa
            else { [void]$out.Append($v) }
            continue
        }
        if ($double) { $double = $false; [void]$out.Append($(if ($r.StartsWith('ch')) { 't' } else { $r[0] })) }
        [void]$out.Append($r)
    }
    $out.ToString()
}

# Teks lirik -> {Segs: potongan {Text, Ruby}, HasRuby, Romaji}. Ruby (furigana) hanya di atas kanji;
# Romaji hanya untuk baris berbahasa Jepang. Satu panggilan pembaca Windows untuk keduanya.
function Get-LyricParts($text) {
    $segs = New-Object System.Collections.Generic.List[object]
    $add = {
        param($t, $r)
        if (-not $t) { return }
        if (-not $r -and $segs.Count -gt 0 -and -not $segs[$segs.Count - 1].Ruby) { $segs[$segs.Count - 1].Text += $t }
        else { $segs.Add([PSCustomObject]@{ Text = $t; Ruby = $r }) }
    }
    $words = @()
    if ($text -match $JAPANESE) {
        try { $words = @([Windows.Globalization.JapanesePhoneticAnalyzer]::GetWords($text, $false)) } catch { Log "furigana: $_" }
    }
    # Pembaca Windows mengubah huruf Latin/spasi jadi lebar penuh (love -> lebar penuh). Kalau panjang
    # totalnya sama, teks tiap kata diambil dari teks asli supaya tampilannya tidak berubah.
    $items = New-Object System.Collections.Generic.List[object]
    $sum = 0; foreach ($w in $words) { $sum += $w.DisplayText.Length }
    $at = 0
    foreach ($w in $words) {
        $len = $w.DisplayText.Length
        $d = if ($sum -eq $text.Length) { $text.Substring($at, $len) } else { $w.DisplayText }
        $at += $len
        $items.Add([PSCustomObject]@{ D = $d; Y = $w.YomiText; Phrase = $w.IsPhraseStart })
    }
    $romaji = $null
    if ($items.Count) {
        $parts = New-Object System.Collections.Generic.List[string]
        foreach ($it in $items) {
            $d = $it.D; $y = $it.Y
            $r = if ($d -notmatch $JAPANESE) { Kana-ToRomaji $d }   # tanda baca Jepang -> , . ! ?; Latin apa adanya
                 elseif ($d -eq [string][char]0x306F) { 'wa' }
                 elseif ($d -eq [string][char]0x3078) { 'e' }
                 else { Kana-ToRomaji $(if ($y) { $y } else { $d }) }
            if ($parts.Count -gt 0 -and ($it.Phrase -or $PARTICLES.Contains($d))) { $parts.Add(' ') }
            $parts.Add($r)
        }
        $romaji = ((-join $parts) -replace '\s+', ' ' -replace '\s+([,.!?)~])', '$1' -replace '\(\s+', '(').Trim()
    }
    if (-not $items.Count) { & $add $text $null }
    foreach ($it in $items) {
        $d = $it.D; $y = $it.Y
        if ($d -notmatch $KANJI -or -not $y) { & $add $d $null; continue }
        # Kana yang sama di awal/akhir kata dan bacaannya tidak perlu furigana
        $hd = To-Hiragana $d
        $p = 0
        while ($p -lt $d.Length -and $p -lt $y.Length -and "$($d[$p])" -notmatch $KANJI -and $hd[$p] -eq $y[$p]) { $p++ }
        $s = 0
        while ($s -lt ($d.Length - $p) -and $s -lt ($y.Length - $p) -and "$($d[$d.Length - 1 - $s])" -notmatch $KANJI -and $hd[$hd.Length - 1 - $s] -eq $y[$y.Length - 1 - $s]) { $s++ }
        & $add $d.Substring(0, $p) $null
        & $add $d.Substring($p, $d.Length - $p - $s) $y.Substring($p, $y.Length - $p - $s)
        & $add $d.Substring($d.Length - $s) $null
    }
    [PSCustomObject]@{ Segs = $segs; HasRuby = [bool](@($segs | Where-Object { $_.Ruby }).Count); Romaji = $romaji }
}

# Satu lapis teks lirik: tiap potongan = furigana (kalau ada) di atas teks dasarnya, romaji di bawah baris
function New-LyricLayer($parts, $brush) {
    $hasRuby = $parts.HasRuby -and $script:settings.Furigana
    $outer = New-Object System.Windows.Controls.StackPanel
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.HorizontalAlignment = 'Center'
    [void]$outer.Children.Add($sp)
    if ($parts.Romaji -and $script:settings.Romaji) {
        $ro = New-Object System.Windows.Controls.TextBlock
        $ro.Text = $parts.Romaji; $ro.FontSize = 8.5; $ro.Foreground = $brush; $ro.Opacity = 0.85
        $ro.HorizontalAlignment = 'Center'; $ro.Margin = '0,-1,0,0'
        [void]$outer.Children.Add($ro)
    }
    foreach ($sg in $parts.Segs) {
        $col = New-Object System.Windows.Controls.StackPanel
        $col.VerticalAlignment = 'Bottom'
        if ($hasRuby) {
            $rt = New-Object System.Windows.Controls.TextBlock
            $rt.Text = if ($sg.Ruby) { $sg.Ruby } else { ' ' }
            $rt.FontSize = 8; $rt.LineStackingStrategy = 'BlockLineHeight'; $rt.LineHeight = 9; $rt.Height = 9
            $rt.HorizontalAlignment = 'Center'; $rt.Foreground = $brush; $rt.Margin = '0,0,0,-1'
            [void]$col.Children.Add($rt)
        }
        $bt = New-Object System.Windows.Controls.TextBlock
        $bt.Text = $sg.Text; $bt.FontSize = 11.5; $bt.FontWeight = 'SemiBold'
        $bt.HorizontalAlignment = 'Center'; $bt.Foreground = $brush
        [void]$col.Children.Add($bt)
        [void]$sp.Children.Add($col)
    }
    $outer
}

# Teks lirik dengan sapuan karaoke: lapisan terang di atas lapisan redup, ditampakkan dari kiri ke kanan
# (OpacityMask) selama baris dinyanyikan, furigana ikut tersapu. Tanpa waktu per kata, kecepatan sapuan
# ditaksir dari panjang baris (dibatasi durasi baris). Baris kepanjangan diperkecil supaya muat.
# Furigana/romaji per baris dihitung sekali lalu disimpan di baris itu (lihat juga Prepare-NextLyric)
$script:partsVer = 0   # naik saat romaji dinyalakan/dimatikan: furigana/romaji yang tersimpan dihitung ulang
function Get-LineParts($line) {
    if (-not $line.PSObject.Properties['Parts'] -or $line.PartsVer -ne $script:partsVer) {
        $line | Add-Member -NotePropertyName Parts -NotePropertyValue (Get-LyricParts $line.Text) -Force
        $line | Add-Member -NotePropertyName PartsVer -NotePropertyValue $script:partsVer -Force
    }
    $line.Parts
}

function New-LyricText($line, $pos) {
    $parts = Get-LineParts $line
    $c = $script:media.Accent
    $bright = Rgb ($c.R + (255 - $c.R) * 0.55) ($c.G + (255 - $c.G) * 0.55) ($c.B + (255 - $c.B) * 0.55)
    $g = New-Object System.Windows.Controls.Grid
    $g.VerticalAlignment = 'Center'; $g.HorizontalAlignment = 'Center'
    [void]$g.Children.Add((New-LyricLayer $parts (Brush '#69FFFFFF')))
    $hi = New-LyricLayer $parts (New-Object System.Windows.Media.SolidColorBrush($bright))
    $br = New-Object System.Windows.Media.LinearGradientBrush
    $br.StartPoint = '0,0.5'; $br.EndPoint = '1,0.5'
    $s1 = New-Object System.Windows.Media.GradientStop((Rgb 0 0 0 255), 0)
    $s2 = New-Object System.Windows.Media.GradientStop((Rgb 0 0 0 0), 0.06)
    $br.GradientStops.Add($s1); $br.GradientStops.Add($s2)
    $hi.OpacityMask = $br
    [void]$g.Children.Add($hi)
    # Lirik biasa (waktunya hanya taksiran): baris ditampilkan utuh tanpa sapuan karaoke
    if ($line.Estimated) { $hi.OpacityMask = $null; $hi.Opacity = 0.8 }
    else {
    $dur = [Math]::Max(0.3, $line.End - $line.T)
    $len = [Math]::Max(1, $line.Text.Length)
    # Batas atas lama menyanyikan satu baris (per karakter; Jepang lebih lambat daripada huruf Latin),
    # dipakai kalau baris disusul jeda panjang sebelum baris berikutnya
    $maxPerChar = if ($line.Text -match '[\p{IsHiragana}\p{IsKatakana}\p{IsCJKUnifiedIdeographs}]') { 0.38 } else { 0.16 }
    $ka = New-Object System.Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $kf = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(0.0, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero))
    [void]$ka.KeyFrames.Add($kf)
    $words = @($line.Words | Where-Object { $_.T -ge $line.T })
    if ($words.Count -gt 1) {
        foreach ($w in $words) {
            $k = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(($w.C / $len), [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($w.T - $line.T)))
            [void]$ka.KeyFrames.Add($k)
        }
        $last = [Math]::Min($dur, ($words[-1].T - $line.T) + 0.6)
    } else {
        # Biasanya baris dinyanyikan sampai sesaat sebelum baris berikutnya (sisa jeda napas), jadi
        # sapuan mengikuti durasi baris; kalau setelahnya ada jeda panjang, dibatasi panjang baris
        $sing = $dur - [Math]::Min(0.5, $dur * 0.12)
        $last = [Math]::Max(0.8, [Math]::Min($sing, $len * $maxPerChar))
    }
    $kEnd = New-Object System.Windows.Media.Animation.LinearDoubleKeyFrame(1.06, [System.Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromSeconds($last)))
    [void]$ka.KeyFrames.Add($kEnd)
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($ka, $AMBIENT_FPS)
    # Mulai dari tengah jalan kalau baris ini sudah dinyanyikan sebagian (BeginTime negatif)
    $ka.BeginTime = [TimeSpan]::FromSeconds(-[Math]::Max(0.0, $pos - $line.T))
    $s1.BeginAnimation([System.Windows.Media.GradientStop]::OffsetProperty, $ka)
    $kb = $ka.Clone()
    foreach ($k in $kb.KeyFrames) { $k.Value = [Math]::Min(1.12, $k.Value + 0.06) }
    $s2.BeginAnimation([System.Windows.Media.GradientStop]::OffsetProperty, $kb)
    }
    $el = $g
    $g.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
    $avail = $MINI_MAX_W - 64
    if ($g.DesiredSize.Width -gt $avail) {
        $el = New-Object System.Windows.Controls.Viewbox
        $el.StretchDirection = 'DownOnly'; $el.Width = $avail; $el.VerticalAlignment = 'Center'
        $el.Child = $g
    }
    $el.RenderTransform = New-Object System.Windows.Media.TranslateTransform
    $el
}

# Ganti baris di mini island: baris lama naik sambil memudar, baris baru masuk dari bawah,
# lebar island menyesuaikan panjang baris
$lyricOutTimer = New-Object System.Windows.Threading.DispatcherTimer
$lyricOutTimer.Interval = Ms 240
$lyricOutTimer.Add_Tick({
    $lyricOutTimer.Stop()
    $h = $script:miniLyricHost
    if ($h) { foreach ($el in @($h.Children)) { if ($el.Tag -eq 'out') { $h.Children.Remove($el) } } }
})
function Set-MiniLyric($line, $pos, [switch]$Quiet) {
    # Isi mini island dibuang selama tersembunyi (lihat cleanupTimer): bangun lagi saat lirik muncul
    if ($line -and $views['MiniView'].Children.Count -eq 0) { [void]$views['MiniView'].Children.Add((New-MiniContent)) }
    $h = $script:miniLyricHost
    if (-not $h) { return }
    if ($Quiet) {
        # Baris sama dipasang ulang langsung (tanpa animasi/ubah ukuran): hanya sapuan karaoke yang bergeser
        $keep = @($h.Children | Where-Object { $_.Tag -ne 'out' })
        $tb = New-LyricText $line $pos
        [void]$h.Children.Add($tb)
        foreach ($old in $keep) { $h.Children.Remove($old) }
        return
    }
    $yp = [System.Windows.Media.TranslateTransform]::YProperty
    # Baris/judul baru disusun dulu (beberapa ms), baru semua animasi dimulai bersamaan: kalau baris lama
    # sudah mulai bergerak sebelum penyusunan, animasinya kehilangan frame (tersendat)
    $tb = if ($line) { New-LyricText $line $pos } else { $null }
    $mq = if (-not $line) { New-MiniMarquee } else { $null }
    $wasLyric = $false
    foreach ($old in @($h.Children)) {
        if ($old.Tag -eq 'out') { continue }
        if ($old.Name -ne 'marquee') { $wasLyric = $true }   # 'marquee' = judul berjalan + wave kecil
        $old.Tag = 'out'
        Animate60 $old.RenderTransform $yp 0.0 -8.0 200
        Animate60 $old ([System.Windows.UIElement]::OpacityProperty) ([double]$old.Opacity) 0.0 150
    }
    $lyricOutTimer.Stop(); $lyricOutTimer.Start()
    if (-not $line) {
        # Tanpa lirik: kembali ke pil kecil dengan judul & artis berjalan
        $mq.Opacity = 0
        [void]$h.Children.Add($mq)
        Animate60 $mq.RenderTransform $yp 8 0 320 120
        Animate60 $mq ([System.Windows.UIElement]::OpacityProperty) 0 1 320 120
        Set-MiniSize $MINI_W $MINI_H
        return
    }
    $tb.Opacity = 0
    [void]$h.Children.Add($tb)
    # Baris baru langsung masuk (tanpa jeda) supaya pas dengan suara
    Animate60 $tb.RenderTransform $yp 7 0 220
    Animate60 $tb ([System.Windows.UIElement]::OpacityProperty) 0 1 170
    $tb.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
    # 64 = cover + equalizer + jarak. Tinggi mengikuti isi: furigana/romaji membuat island lebih tinggi
    $w = [Math]::Min($MINI_MAX_W, [Math]::Max($MINI_W, [Math]::Ceiling($tb.DesiredSize.Width) + 64))
    $th = $tb.DesiredSize.Height
    $ht = if ($th -le 17) { $MINI_H } else { [Math]::Ceiling($th) + 10 }
    # Dari baris ke baris: 280 ms; dari judul berjalan (pil kecil) membesar pelan seperti biasa
    Set-MiniSize $w $ht $(if ($wasLyric) { 280 } else { 0 })
}

function Update-MiniLyric {
    if (-not $script:miniOn -or -not $script:miniLyricHost -or -not $script:media) { return }
    $m = $script:media
    $lines = Get-Lyrics
    $idx = -1; $line = $null; $pos = 0.0
    if ($lines) {
        $pos = (Get-SongPos) - (Get-LyricDelay)
        $idx = Find-LyricLine $lines $pos
        # Baris terakhir selesai (End = mulai + 6 detik) juga dianggap tidak ada lirik
        if ($idx -ge 0 -and $lines[$idx].Text -and $pos -lt $lines[$idx].End) { $line = $lines[$idx] } else { $idx = -1 }
        # Jeda singkat (< 2,5 detik) sebelum baris berikutnya: island tidak usah menyusut lalu muncul lagi
        if ($idx -lt 0 -and $script:lyricIdx -ge 0) {
            $nx = Find-LyricLine $lines ($pos + 2.5)
            if ($nx -ge 0 -and $lines[$nx].T -gt $pos -and $lines[$nx].Text) { return }
        }
    }
    # Posisi lagu baru saja disinkronkan ulang (PC/pemutar sempat tersendat) tapi barisnya sama:
    # pasang ulang baris itu diam-diam supaya sapuan karaokenya lompat ke posisi yang benar,
    # tanpa animasi masuk (kalau dianimasikan, baris akan berkedip setiap kali sinkron).
    $resynced = $m.PosAt -ne $script:lyricPosAt
    $script:lyricPosAt = $m.PosAt
    if ($idx -eq $script:lyricIdx) {
        if ($resynced -and $line) { Set-MiniLyric $line $pos -Quiet }
        return
    }
    $script:lyricIdx = $idx
    Set-MiniLyric $line $pos
}

# Baris lirik dicek selama mini island tampil dan lagunya punya lirik. Timer dibangunkan tepat saat
# baris berikutnya jatuh tempo (bukan tiap 150 ms), paling lama 250 ms sekali untuk menangkap lagu digeser.
$lyricTimer = New-Object System.Windows.Threading.DispatcherTimer([System.Windows.Threading.DispatcherPriority]::Render)
$lyricTimer.Interval = Ms 100
$lyricTimer.Add_Tick({
    Check-Lyrics
    if ($script:mode -ne 'idle' -or -not $script:miniOn -or -not $script:media) { $lyricTimer.Stop(); return }
    Update-MiniLyric
    $lines = Get-Lyrics
    # Tidak ada lirik (dan tidak sedang dicari): berhenti, dinyalakan lagi saat lirik datang
    if (-not $lines) { if (-not $script:lyricsReq) { $lyricTimer.Stop() }; return }
    $pos = (Get-SongPos) - (Get-LyricDelay)
    $nx = (Find-LyricLine $lines $pos) + 1
    $wait = 0.25
    if ($nx -lt $lines.Count) {
        $wait = [Math]::Min($wait, $lines[$nx].T - $pos)
        # Siapkan furigana/romaji baris berikutnya sekarang, jadi saat jatuh tempo tinggal ditampilkan
        if ($lines[$nx].Text) { [void](Get-LineParts $lines[$nx]) }
    }
    $lyricTimer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(10.0, $wait * 1000 + 5))
})

# Tombol lirik di baris progress: nyala/mati, diingat di settings.json
function New-LyricsToggle {
    $b = New-RoundButton $GLYPH_LYRICS '#33FFFFFF' (T 'Lirik di island' 'Lyrics on the island')
    $b.Child.FontSize = 11; $b.Margin = '6,0,0,0'; $b.Cursor = 'Hand'
    Set-LyricsToggleLook $b
    $b.Add_MouseLeave({ param($s, $e) $s.Background = Brush $s.Resources['RestHex'] })
    $b.Add_MouseLeftButtonUp({
        param($s, $e)
        $e.Handled = $true
        $script:settings.Lyrics = -not $script:settings.Lyrics
        Save-Settings
        if ($script:settings.Lyrics) { Request-Lyrics }
        Set-LyricsToggleLook $s
        Update-PageDots
    })
    # Scroll di tombol ini menggeser timing lirik lagu ini 0,1 detik (ke atas = lirik lebih awal); geseran
    # untuk semua lagu ada di menu klik kanan. Ditangani di sini supaya tidak sampai ke scroll volume.
    $b.Add_MouseWheel({
        param($s, $e)
        $e.Handled = $true
        $le = if ($script:media) { $lyricsCache[$script:media.Key] } else { $null }
        if ($le -and -not $le.None) {
            $d = [Math]::Round($le.Offset - 0.1 * [Math]::Sign($e.Delta), 1)
            $le.Offset = [Math]::Max(-5.0, [Math]::Min(5.0, $d))
            $script:lyricIdx = -2
            $script:offsetDirty = $le
            $saveDelayTimer.Stop(); $saveDelayTimer.Start()
        }
        Set-LyricsToggleLook $s
        $s.ToolTip.IsOpen = $true
    })
    $b
}
# Simpan geseran timing setelah scroll berhenti (bukan tiap langkah scroll)
$saveDelayTimer = New-Object System.Windows.Threading.DispatcherTimer
$saveDelayTimer.Interval = Ms 800
$saveDelayTimer.Add_Tick({
    $saveDelayTimer.Stop()
    if ($script:offsetDirty) { Save-LyricsEntry $script:offsetDirty; $script:offsetDirty = $null }
})
function Set-LyricsToggleLook($b) {
    $on = [bool]$script:settings.Lyrics
    $b.Resources['RestHex'] = if ($on) { '#40FFFFFF' } else { '#00FFFFFF' }
    $b.Background = Brush $b.Resources['RestHex']
    $b.Child.Foreground = Brush $(if ($on) { '#FFFFFF' } else { '#73FFFFFF' })
    $tip = if ($on) {
        $so = Get-SongOffset
        $songTiming = if ([Math]::Abs($so) -lt 0.05) { T 'pas' 'as is' } elseif ($so -gt 0) { T "ditunda $(Fmt '{0:0.0}' $so) dtk" "$(Fmt '{0:0.0}' $so) s later" } else { T "dimajukan $(Fmt '{0:0.0}' (-$so)) dtk" "$(Fmt '{0:0.0}' (-$so)) s earlier" }
        T "Lirik: nyala (klik untuk matikan)`nTiming lagu ini: $songTiming (scroll untuk geser)" "Lyrics: on (click to turn off)`nTiming for this song: $songTiming (scroll to shift)"
    } else { T 'Lirik: mati (klik untuk nyalakan)' 'Lyrics: off (click to turn on)' }
    if (-not ($b.ToolTip -is [System.Windows.Controls.ToolTip])) {
        $t = New-Object System.Windows.Controls.ToolTip
        $t.PlacementTarget = $b
        $b.ToolTip = $t
        # Tooltip yang dibuka lewat scroll tidak tertutup sendiri
        $b.Add_MouseLeave({ param($s, $e) $s.ToolTip.IsOpen = $false })
    }
    $b.ToolTip.Content = $tip
}

function Process-Queue {
    if ($script:mode -ne 'idle') { return }
    # Jangan ganggu game/video fullscreen; Windows juga menahan banner pada saat seperti ini
    if ($script:fullscreen) { $queue.Clear(); $script:pendingMediaPopup = $false; return }
    $n = Next-Queued
    if ($n) { Show-Notif $n; return }
    # Pemberitahuan island sendiri (update, timer selesai) yang tadi tertunda
    $pa = $script:pendingActivity
    if ($pa) {
        $script:pendingActivity = $null
        switch ($pa.Kind) {
            'info' { if ($pa.Ms) { Show-Info $pa.Arg $pa.Ms } else { Show-Info $pa.Arg } }
        }
        return
    }
    # Pop-up lagu yang tertunda karena tadi ada notifikasi
    if ($script:pendingMediaPopup) {
        $script:pendingMediaPopup = $false
        if ($script:media -and $script:media.Playing) { Show-Media }
    }
}

# Pop-up memanjang untuk menampilkan isi pesan lengkap saat di-hover
$MAX_ISLAND_H = 440
function Set-NotifExpanded($on) {
    foreach ($t in $nTitle, $nBody) {
        $t.TextWrapping = if ($on) { 'Wrap' } else { 'NoWrap' }
    }
    $nTitle.MaxHeight = if ($on) { 40 } else { [double]::PositiveInfinity }
    $nBody.MaxHeight = if ($on) { 300 } else { [double]::PositiveInfinity }
    $h = $NOTIF_H
    if ($on) {
        $v = $views['NotifView']
        $v.Measure((New-Object System.Windows.Size(($WIDE_W - 2), [double]::PositiveInfinity)))
        $h = [Math]::Min($MAX_ISLAND_H, [Math]::Max($NOTIF_H, [Math]::Ceiling($v.DesiredSize.Height) + 24))
    }
    $r = if ($h -gt $NOTIF_H) { 22 } else { $NOTIF_H / 2 }
    Resize-Island $WIDE_W $h $r
}

$notifSwapTimer = New-Object System.Windows.Threading.DispatcherTimer
$notifSwapTimer.Interval = Ms 170
$notifSwapTimer.Add_Tick({
    $notifSwapTimer.Stop()
    $n = $script:pendingNotif; $script:pendingNotif = $null
    if ($n -and $script:mode -eq 'notif') { Show-Notif $n -NoSwap }
})
function Show-Notif($n, [switch]$NoSwap) {
    if (-not $NoSwap -and $script:mode -eq 'notif' -and $views['NotifView'].Opacity -gt 0.3) {
        $script:pendingNotif = $n
        $dismissTimer.Stop()
        Animate $views['NotifView'] ([System.Windows.UIElement]::OpacityProperty) 0 160
        $notifSwapTimer.Stop(); $notifSwapTimer.Start()
        return
    }
    $script:mode = 'notif'
    $script:current = $n
    # Sisa geseran dari pop-up yang ditarik sebelumnya
    $island.RenderTransform = [System.Windows.Media.Transform]::Identity
    Set-Theme $n.Accent
    $nIconHost.Child = New-Icon $n 34 17
    $nAppName.Text = $n.App
    $nAppName.Foreground = New-Object System.Windows.Media.SolidColorBrush($n.Accent)
    $nTitle.Text = $n.Title
    $nBody.Text = $n.Body
    $nApp.Text = $n.Time.ToString('HH:mm')
    $nApp.ToolTip = $n.App
    Set-NotifExpanded ([bool]$script:hovering)
    Set-IslandVisible $true
    Show-View 'NotifView' -Replay
    $dismissTimer.Stop()
    # Lebih singkat kalau masih ada antrean
    $dismissTimer.Interval = Ms $(if ($queue.Count -gt 0) { 3000 } else { 5000 })
    if (-not $script:hovering) { $dismissTimer.Start() }
}

function Remove-Notif($id) {
    if (Remove-IslandItem $id) { return }
    try { $listener.RemoveNotification([uint32]$id) } catch { Log "remove: $_" }
    $notifCache.Remove($id)
    $script:recent = @($script:recent | Where-Object { $_.Id -ne $id })
}

# ClearNotifications() gagal ("Element not found") untuk aplikasi tanpa paket, jadi hapus satu per satu
function Clear-AllNotifs {
    foreach ($id in @($notifCache.Keys)) {
        try { $listener.RemoveNotification([uint32]$id) } catch { Log "clear $id : $_" }
    }
    $notifCache.Clear()
    foreach ($it in @($script:islandItems)) { [void](Remove-IslandItem $it.Id) }
    $script:recent = @()
}

# Tiap baris diberi warna tipis sesuai aplikasinya
function Row-Brush($c, $hover) {
    $a = if ($hover) { 95 } else { 45 }
    $lg = New-Object System.Windows.Media.LinearGradientBrush
    $lg.StartPoint = '0,0.5'; $lg.EndPoint = '1,0.5'
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb $c.R $c.G $c.B $a), 0)))
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb $c.R $c.G $c.B ($a * 0.25)), 0.75)))
    $lg.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb 255 255 255 $(if ($hover) { 18 } else { 0 })), 1)))
    $lg
}

$CLOSE_GLYPH = [string][char]0xE711
$script:confirmClear = $false

function New-ListHeader {
    $hg = New-Object System.Windows.Controls.Grid
    $hg.Height = 26; $hg.Margin = '8,0,8,2'
    $lbl = New-Object System.Windows.Controls.TextBlock
    $total = @($script:recent).Count
    $lbl.Text = if ($total -gt $MAX_ITEMS) { T "Notifikasi ($MAX_ITEMS dari $total)" "Notifications ($MAX_ITEMS of $total)" } else { T 'Notifikasi' 'Notifications' }
    $lbl.Foreground = Brush '#8E8E93'; $lbl.FontSize = 11; $lbl.FontWeight = 'SemiBold'
    $lbl.VerticalAlignment = 'Center'
    [void]$hg.Children.Add($lbl)
    $btn = New-Object System.Windows.Controls.TextBlock
    $btn.FontSize = 11; $btn.FontWeight = 'SemiBold'; $btn.Cursor = 'Hand'
    $btn.HorizontalAlignment = 'Right'; $btn.VerticalAlignment = 'Center'
    if ($script:confirmClear) { $btn.Text = T 'Klik lagi untuk hapus semua' 'Click again to clear all'; $btn.Foreground = Brush '#FF6961' }
    else { $btn.Text = T 'Hapus semua' 'Clear all'; $btn.Foreground = Brush '#A1A1A6' }
    $btn.Add_MouseLeftButtonUp({
        param($s, $e)
        $e.Handled = $true
        if ($script:confirmClear) {
            $script:confirmClear = $false; $confirmTimer.Stop()
            $s.Text = T 'Hapus semua' 'Clear all'; $s.Foreground = Brush '#A1A1A6'
            $rows = @($listPanel.Children | Where-Object { $_.Tag -and $_.Tag.N })
            Start-Delete $rows @() $true
        } else {
            $script:confirmClear = $true; $confirmTimer.Start()
            Show-List -Refresh
        }
    })
    [void]$hg.Children.Add($btn)
    $hg
}

$EXPAND_GLYPH = [string][char]0xE70D
$COLLAPSE_GLYPH = [string][char]0xE70E
# Id notifikasi yang teksnya sedang dibuka penuh di daftar
$expanded = New-Object 'System.Collections.Generic.HashSet[uint32]'

function New-RoundButton($glyph, $hoverHex, $tip) {
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 22; $b.Height = 22; $b.CornerRadius = New-Object System.Windows.CornerRadius(11)
    $b.Background = Brush '#33FFFFFF'; $b.ToolTip = $tip; $b.VerticalAlignment = 'Center'
    $b.Resources['HoverHex'] = $hoverHex
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $glyph; $t.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $t.FontSize = 9
    $t.Foreground = Brush '#FFFFFF'; $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $b.Child = $t
    $b.Add_MouseEnter({ param($s, $e) $s.Background = Brush $s.Resources['HoverHex'] })
    $b.Add_MouseLeave({ param($s, $e) $s.Background = Brush '#33FFFFFF' })
    $b
}

# ---------- Animasi hapus (swipe) ----------
# Tahap 1: baris geser ke kanan + memudar. Tahap 2: data dihapus, baris menyusut, island mengecil.
# Tahap 3: daftar dibangun ulang.
$script:deleting = $null
# Durasi animasi hapus (ms): geser keluar, jeda antar baris saat hapus semua, menyusut
$SWIPE_MS = 450; $SWIPE_STAGGER = 80; $COLLAPSE_MS = 340

function Slide-Out($row, $delay) {
    $row.IsHitTestVisible = $false
    # Kalau baris sedang ditarik, lanjutkan dari posisi tarikannya (bukan mulai dari 0)
    $tt = $row.RenderTransform
    if ($tt -isnot [System.Windows.Media.TranslateTransform] -or $tt.IsFrozen) {
        $tt = New-Object System.Windows.Media.TranslateTransform
        $row.RenderTransform = $tt
    }
    Animate $tt ([System.Windows.Media.TranslateTransform]::XProperty) ($WIDE_W * 0.9) $SWIPE_MS $delay
    Animate $row ([System.Windows.UIElement]::OpacityProperty) 0 ($SWIPE_MS - 30) $delay
}

function Start-Delete($rows, $ids, $all) {
    if ($script:deleting -or $rows.Count -eq 0) { return }
    for ($i = 0; $i -lt $rows.Count; $i++) { Slide-Out $rows[$i] ($i * $SWIPE_STAGGER) }
    $script:deleting = @{ Rows = $rows; Ids = $ids; All = $all; Stage = 1 }
    $deleteTimer.Interval = Ms ($SWIPE_MS - 10 + ($rows.Count - 1) * $SWIPE_STAGGER)
    $deleteTimer.Start()
}

$deleteTimer = New-Object System.Windows.Threading.DispatcherTimer
$deleteTimer.Add_Tick({
    $d = $script:deleting
    if (-not $d) { $deleteTimer.Stop(); return }
    if ($d.Stage -eq 1) {
        if ($d.All) { Clear-AllNotifs } else { foreach ($id in $d.Ids) { Remove-Notif $id } }
        foreach ($r in $d.Rows) {
            # Baris yang terbuka penuh tingginya otomatis (NaN); kunci dulu supaya bisa dianimasikan
            $r.Height = $r.ActualHeight; $r.MinHeight = 0
            $r.Margin = '0'
            Animate $r ([System.Windows.FrameworkElement]::HeightProperty) 0 $COLLAPSE_MS
        }
        foreach ($id in $d.Ids) { [void]$expanded.Remove([uint32]$id) }
        if ($script:mode -eq 'list') {
            $gone = 0
            foreach ($r in $d.Rows) { $gone += $r.ActualHeight + 2 }
            $newH = [Math]::Max(56.0, $island.ActualHeight - $gone)
            Resize-Island $WIDE_W $newH 24
        }
        $d.Stage = 2
        $deleteTimer.Interval = Ms ($COLLAPSE_MS + 30)
    } else {
        $deleteTimer.Stop()
        $script:deleting = $null
        if ($script:mode -eq 'list') { Show-List -Refresh }
    }
})

# ---------- Halaman daftar (notifikasi / musik) ----------
$script:listPage = 'notif'
$script:swipeStart = $null
$script:swiped = $false
$script:hwheelSum = 0
$script:lastPageSwitch = [DateTime]::MinValue

# Halaman yang tersedia, urut kiri ke kanan: notifikasi (kalau ada, atau kalau tidak ada lagu), musik,
# dan lirik penuh (kalau lagunya punya lirik)
function Get-ListPages {
    $p = @()
    if (@($script:recent).Count -gt 0 -or -not $script:media) { $p += 'notif' }
    if ($script:media) {
        $p += 'music'
        if (Get-Lyrics) { $p += 'lyrics' }
    }
    , $p
}

function New-PageDot($p) {
    $d = New-Object System.Windows.Shapes.Ellipse
    $on = $p -eq $script:listPage
    $d.Width = $(if ($on) { 7 } else { 6 }); $d.Height = $d.Width; $d.Margin = '4,0'
    $d.Fill = Brush $(if ($on) { '#FFFFFFFF' } else { '#55FFFFFF' })
    $d.Cursor = 'Hand'; $d.Tag = $p; $d.VerticalAlignment = 'Center'
    $d.ToolTip = switch ($p) { 'notif' { T 'Notifikasi' 'Notifications' } 'music' { T 'Musik' 'Music' } default { T 'Lirik' 'Lyrics' } }
    $d.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Switch-ListPage $s.Tag })
    $d
}
function New-PageDots {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.HorizontalAlignment = 'Center'; $sp.Margin = '0,8,0,0'; $sp.Height = 7
    foreach ($p in (Get-ListPages)) { [void]$sp.Children.Add((New-PageDot $p)) }
    $sp
}

# Halaman bertambah/berkurang saat daftar terbuka (lirik dinyalakan/dimatikan, lirik selesai dimuat):
# titik halaman muncul/hilang dengan animasi, tinggi island menyesuaikan halus. Kalau halaman yang
# sedang dibuka hilang, daftar bergeser ke halaman musik.
$script:pageDots = $null
$dotsCleanupTimer = New-Object System.Windows.Threading.DispatcherTimer
$dotsCleanupTimer.Interval = Ms 340
$dotsCleanupTimer.Add_Tick({
    $dotsCleanupTimer.Stop()
    foreach ($el in @($script:dotsLeaving)) { if ($el.Parent) { $el.Parent.Children.Remove($el) } }
    $script:dotsLeaving = @()
})
$script:dotsLeaving = @()
# Tinggi daftar yang dituju: diukur dari isinya tanpa baris titik (tinggi island saat ini bisa masih
# beranimasi, mis. lirik datang sesaat setelah daftar dibuka), ditambah $extra
function Get-ListTargetHeight($dots, $extra) {
    $listPanel.Measure((New-Object System.Windows.Size(($WIDE_W - 2), [double]::PositiveInfinity)))
    $h = [Math]::Ceiling($listPanel.DesiredSize.Height) + 2
    if ($dots) { $h -= $dots.DesiredSize.Height }
    [Math]::Min($MAX_ISLAND_H, [Math]::Max(56.0, $h + $extra))
}

function Update-PageDots {
    if ($script:mode -ne 'list' -or $script:deleting) { return }
    $pages = Get-ListPages
    if ($pages -notcontains $script:listPage) {
        $target = if ($pages -contains 'music') { 'music' } else { $pages[0] }
        $script:listPage = $target
        Show-List -Refresh
        Slide-ListIn $false
        return
    }
    $sp = $script:pageDots
    $wp = [System.Windows.FrameworkElement]::WidthProperty
    $hp = [System.Windows.FrameworkElement]::HeightProperty
    $op = [System.Windows.UIElement]::OpacityProperty
    $mp = [System.Windows.FrameworkElement]::MarginProperty
    if ($pages.Count -lt 2) {
        # Tinggal satu halaman: baris titik menutup, island memendek
        if ($sp -and $sp.Parent) {
            $script:pageDots = $null
            Resize-Island $WIDE_W (Get-ListTargetHeight $sp 0) 24 -Smooth -Ms 360
            Animate60 $sp $hp 7.0 0.0 320
            Animate60 $sp $op 1.0 0.0 220
            $sp.BeginAnimation($mp, (New-Object System.Windows.Media.Animation.ThicknessAnimation((New-Object System.Windows.Thickness(0)), (New-Object System.Windows.Duration (Ms 320)))))
            $script:dotsLeaving += $sp
            $dotsCleanupTimer.Stop(); $dotsCleanupTimer.Start()
        }
        return
    }
    if (-not $sp -or -not $sp.Parent) {
        # Baris titik muncul: island memanjang, titik membesar & menampak
        $sp = New-PageDots
        $sp.Height = 0; $sp.Opacity = 0; $sp.Margin = '0'
        [void]$listPanel.Children.Add($sp)
        $script:pageDots = $sp
        # Titik setinggi 7 + jarak 8 di atasnya
        Resize-Island $WIDE_W (Get-ListTargetHeight $sp 15) 24 -Smooth -Ms 360
        Animate60 $sp $hp 0.0 7.0 320
        Animate60 $sp $op 0.0 1.0 300 80
        $sp.BeginAnimation($mp, (New-Object System.Windows.Media.Animation.ThicknessAnimation((New-Object System.Windows.Thickness(0)), (New-Object System.Windows.Thickness(0, 8, 0, 0)), (New-Object System.Windows.Duration (Ms 320)))))
        return
    }
    # Titik halaman yang baru: menyelip masuk dari ukuran nol
    $have = @($sp.Children | Where-Object { $_.Tag -and $script:dotsLeaving -notcontains $_ } | ForEach-Object { $_.Tag })
    for ($i = 0; $i -lt $pages.Count; $i++) {
        if ($have -contains $pages[$i]) { continue }
        $d = New-PageDot $pages[$i]
        $w = $d.Width; $d.Width = 0; $d.Height = 0; $d.Opacity = 0; $d.Margin = '0'
        $sp.Children.Insert([Math]::Min($i, $sp.Children.Count), $d)
        Animate60 $d $wp 0.0 $w 300; Animate60 $d $hp 0.0 $w 300; Animate60 $d $op 0.0 1.0 300
        $d.BeginAnimation($mp, (New-Object System.Windows.Media.Animation.ThicknessAnimation((New-Object System.Windows.Thickness(0)), (New-Object System.Windows.Thickness(4, 0, 4, 0)), (New-Object System.Windows.Duration (Ms 300)))))
    }
    # Titik halaman yang hilang: mengecil lalu dibuang
    foreach ($d in @($sp.Children)) {
        if ($pages -contains $d.Tag -or $script:dotsLeaving -contains $d) { continue }
        Animate60 $d $wp ([double]$d.ActualWidth) 0.0 280; Animate60 $d $hp ([double]$d.ActualHeight) 0.0 280; Animate60 $d $op 1.0 0.0 220
        $d.BeginAnimation($mp, (New-Object System.Windows.Media.Animation.ThicknessAnimation((New-Object System.Windows.Thickness(0)), (New-Object System.Windows.Duration (Ms 280)))))
        $script:dotsLeaving += $d
        $dotsCleanupTimer.Stop(); $dotsCleanupTimer.Start()
    }
}

# Pindah halaman dengan animasi geser. $target: nama halaman, 'next' / 'prev', atau kosong (berikutnya, memutar)
function Switch-ListPage($target) {
    if ($script:mode -ne 'list' -or $script:deleting) { return }
    $pages = Get-ListPages
    if ($pages.Count -lt 2) { return }
    $i = [array]::IndexOf($pages, $script:listPage)
    if ($target -eq 'next') { $target = $pages[[Math]::Min($pages.Count - 1, $i + 1)] }
    elseif ($target -eq 'prev') { $target = $pages[[Math]::Max(0, $i - 1)] }
    elseif (-not $target) { $target = $pages[($i + 1) % $pages.Count] }
    if ($target -eq $script:listPage -or $pages -notcontains $target) { return }
    $script:lastPageSwitch = Get-Date
    $script:listPage = $target
    Show-List -Refresh
    Slide-ListIn ([array]::IndexOf($pages, $target) -gt $i)
}

# Isi daftar masuk dengan geser + memudar (halaman di kanan masuk dari kanan, dan sebaliknya)
function Slide-ListIn($fromRight) {
    $from = if ($fromRight) { 60 } else { -60 }
    $tt = New-Object System.Windows.Media.TranslateTransform
    $listPanel.RenderTransform = $tt
    Animate $tt ([System.Windows.Media.TranslateTransform]::XProperty) 0 300 0 $from
    Animate $listPanel ([System.Windows.UIElement]::OpacityProperty) 1 260 0 0
}

# ---------- Halaman lirik penuh ----------
# Seluruh lirik lagu bergulir sendiri: baris yang sedang dinyanyikan terang di tengah kartu,
# baris lain redup, tepi atas & bawah memudar. Klik satu baris = lompat ke bagian lagu itu.
# Tombol di pojok kanan atas: pin (island tetap terbuka walau kursor pergi), dan untuk lirik Jepang
# furigana & romaji. Furigana/romaji dihitung bertahap mulai dari baris yang sedang dinyanyikan,
# jadi halaman langsung tampil tanpa menunggu semua baris.
$LYRICS_PAGE_H = 196
$GLYPH_PIN = [string][char]0xE718; $GLYPH_PINNED = [string][char]0xE840
$script:lyricsPage = $null
$script:listPinned = $false
$DIM_LINE = Rgb 255 255 255 92

# Isi satu baris: potongan teks (furigana di atas kanji kalau dinyalakan) yang bisa turun baris, romaji di bawahnya
function Set-PageLine($block, $parts, [switch]$Fade) {
    $brush = $block.Tag.Brush
    $block.Tag.Parts = $parts
    $block.Children.Clear()
    $rubies = New-Object System.Collections.Generic.List[object]
    $wp = New-Object System.Windows.Controls.WrapPanel
    [void]$block.Children.Add($wp)
    # Furigana & romaji selalu ada di baris; yang dimatikan bertinggi 0. Tombol tinggal menganimasikan
    # tingginya, tanpa membangun ulang baris (membangun ulang membuat halaman tersendat & melompat).
    $furi = [bool]$script:settings.Furigana
    $ruby = $parts -and $parts.HasRuby
    $segs = if ($parts) { $parts.Segs } else { @([PSCustomObject]@{ Text = $block.Tag.Line.Text; Ruby = $null }) }
    foreach ($sg in $segs) {
        $col = New-Object System.Windows.Controls.StackPanel
        $col.VerticalAlignment = 'Bottom'
        if ($ruby) {
            $rt = New-Object System.Windows.Controls.TextBlock
            $rt.Text = if ($sg.Ruby) { $sg.Ruby } else { ' ' }
            $rt.FontSize = 9; $rt.LineStackingStrategy = 'BlockLineHeight'; $rt.LineHeight = 10; $rt.Height = 10
            $rt.HorizontalAlignment = 'Center'; $rt.Foreground = $brush
            Use-PageScale $rt $script:lyricsPage.RubyScale
            [void]$col.Children.Add($rt)
            $rubies.Add($rt)
        }
        $bt = New-Object System.Windows.Controls.TextBlock
        $bt.Text = $sg.Text; $bt.FontSize = 14.5; $bt.FontWeight = 'SemiBold'; $bt.Foreground = $brush
        $bt.TextWrapping = 'Wrap'; $bt.MaxWidth = $WIDE_W - 54
        [void]$col.Children.Add($bt)
        [void]$wp.Children.Add($col)
    }
    $ro = $null
    if ($parts -and $parts.Romaji) {
        $rt2 = New-Object System.Windows.Controls.TextBlock
        $rt2.Text = $parts.Romaji; $rt2.FontSize = 10.5; $rt2.Foreground = $brush
        $rt2.TextWrapping = 'Wrap'; $rt2.Margin = '0,1,0,0'
        Use-PageScale $rt2 $script:lyricsPage.RomajiScale
        # Romaji sedikit lebih redup dari teks utamanya
        $ro = New-Object System.Windows.Controls.Border
        $ro.Opacity = 0.8; $ro.Child = $rt2
        [void]$block.Children.Add($ro)
    }
    $block.Tag.Rubies = $rubies; $block.Tag.Romaji = $ro
    # Baris yang baru mendapat furigana/romaji: tambahannya memudar masuk
    if ($Fade) {
        $op = [System.Windows.UIElement]::OpacityProperty
        foreach ($x in @($block.Children)) { if ($x -isnot [System.Windows.Controls.WrapPanel]) { $x.Opacity = 0; Animate60 $x $op 0.0 0.8 260 } }
        if ($rubies.Count) { $wp.Opacity = 0.6; Animate60 $wp $op 0.6 1.0 260 }
    }
}

# Semua furigana (dan semua romaji) di halaman memakai satu ScaleTransform bersama sebagai LayoutTransform,
# opacity-nya mengikuti skala itu. Menyalakan/mematikan = satu animasi saja (bukan ratusan per potongan
# teks), dan baris memendek/memanjang mulus karena tinggi tata letaknya ikut skala.
function Use-PageScale($el, $scale) {
    $el.LayoutTransform = $scale
    $b = New-Object System.Windows.Data.Binding('ScaleY')
    $b.Source = $scale
    [void]$el.SetBinding([System.Windows.UIElement]::OpacityProperty, $b)
}

# Tombol bulat kecil di pojok kartu lirik; $on = menyala
function New-PageToggle($content, $tip, $on, [switch]$Glyph) {
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 24; $b.Height = 24; $b.CornerRadius = New-Object System.Windows.CornerRadius(12)
    $b.Margin = '4,0,0,0'; $b.Cursor = 'Hand'; $b.ToolTip = $tip
    $b.Resources['RestHex'] = if ($on) { '#55FFFFFF' } else { '#26FFFFFF' }
    $b.Background = Brush $b.Resources['RestHex']
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $content; $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    $t.Foreground = Brush $(if ($on) { '#FFFFFFFF' } else { '#99FFFFFF' })
    if ($Glyph) { $t.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $t.FontSize = 11 } else { $t.FontSize = 10.5; $t.FontWeight = 'SemiBold' }
    $b.Child = $t
    $b.Add_MouseEnter({ param($s, $e) $s.Background = Brush '#66FFFFFF' })
    $b.Add_MouseLeave({ param($s, $e) $s.Background = Brush $s.Resources['RestHex'] })
    $b
}

function New-LyricsPage {
    # (Get-Lyrics) dalam kurung: hasilnya array utuh, baru dipecah per baris oleh pipa
    $lines = @((Get-Lyrics) | Where-Object { $_.Text })
    $card = New-Object System.Windows.Controls.Border
    $card.Height = $LYRICS_PAGE_H; $card.ClipToBounds = $true
    [System.Windows.Media.TextOptions]::SetTextHintingMode($card, [System.Windows.Media.TextHintingMode]::Animated)
    $card.CornerRadius = New-Object System.Windows.CornerRadius(14)
    $card.Background = Row-Brush $script:media.Accent $true
    $layers = New-Object System.Windows.Controls.Grid
    $card.Child = $layers
    # Canvas: daftar baris boleh jauh lebih tinggi dari kartu tanpa dipotong layout (Grid memotong anak yang
    # lebih besar dari tempatnya, sehingga baris bawah tidak pernah tampil saat digulir). Masker pudar dipasang
    # di pembungkusnya: masker pada elemen yang isinya bergeser ikut bergeser bersama isinya.
    $hostG = New-Object System.Windows.Controls.Canvas
    $hostG.ClipToBounds = $true
    $fade = New-Object System.Windows.Controls.Grid
    [void]$fade.Children.Add($hostG)
    [void]$layers.Children.Add($fade)
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Width = $WIDE_W - 18
    $tt = New-Object System.Windows.Media.TranslateTransform
    $sp.RenderTransform = $tt
    $estimated = $lines.Count -and $lines[0].Estimated
    $japanese = @($lines | Where-Object { $_.Text -match $JAPANESE }).Count -gt 0
    $blocks = New-Object System.Collections.Generic.List[object]
    $pageRuby = New-Object System.Windows.Media.ScaleTransform(1, $(if ($script:settings.Furigana) { 1 } else { 0 }))
    $pageRomaji = New-Object System.Windows.Media.ScaleTransform(1, $(if ($script:settings.Romaji) { 1 } else { 0 }))
    # Set-PageLine di bawah sudah butuh skala ini (halaman lengkapnya diisi setelah semua baris dibuat)
    $script:lyricsPage = @{ RubyScale = $pageRuby; RomajiScale = $pageRomaji }
    foreach ($l in $lines) {
        $blk = New-Object System.Windows.Controls.StackPanel
        $blk.Margin = '18,5,18,5'; $blk.Background = Brush '#01000000'
        $blk.Tag = [PSCustomObject]@{ Line = $l; Brush = (New-Object System.Windows.Media.SolidColorBrush($DIM_LINE)); Parts = $null; Rubies = $null; Romaji = $null }
        # Furigana/romaji yang sudah pernah dihitung (mis. oleh mini island) langsung dipakai
        $ready = if ($japanese -and $l.PSObject.Properties['Parts'] -and $l.PartsVer -eq $script:partsVer) { $l.Parts } else { $null }
        Set-PageLine $blk $ready
        # Lirik biasa hanya taksiran waktu: tidak bisa dipakai untuk lompat (begitu juga pemutar yang tidak mengizinkannya)
        if (-not $estimated -and (Test-MediaSeekable)) {
            $blk.Cursor = 'Hand'
            $blk.Add_MouseLeftButtonUp({
                param($s, $e)
                $e.Handled = $true
                Media-Seek ($s.Tag.Line.T + (Get-LyricDelay) + 0.05)
                if ($script:lyricsPage) { $script:lyricsPage.Cur = -2 }
                Update-LyricsPage
            })
        }
        [void]$sp.Children.Add($blk)
        $blocks.Add($blk)
    }
    [void]$hostG.Children.Add($sp)
    # Tepi atas & bawah memudar (ukuran tetap setinggi kartu; daftar baris jauh lebih panjang dari kartu)
    $mask = New-Object System.Windows.Media.LinearGradientBrush
    $mask.MappingMode = 'Absolute'; $mask.StartPoint = '0,0'; $mask.EndPoint = "0,$LYRICS_PAGE_H"
    foreach ($st in @(@(0, 0.0), @(255, 0.22), @(255, 0.78), @(0, 1.0))) {
        $mask.GradientStops.Add((New-Object System.Windows.Media.GradientStop((Rgb 0 0 0 $st[0]), $st[1])))
    }
    $fade.OpacityMask = $mask

    # Tombol pojok kanan atas
    $bar = New-Object System.Windows.Controls.StackPanel
    $bar.Orientation = 'Horizontal'; $bar.HorizontalAlignment = 'Right'; $bar.VerticalAlignment = 'Top'; $bar.Margin = '0,8,8,0'
    $script:furiButton = $null; $script:romajiButton = $null
    if ($japanese) {
        $fb = New-PageToggle ([string][char]0x3042) (T 'Furigana' 'Furigana') $script:settings.Furigana
        $fb.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Toggle-LyricOption 'Furigana' })
        [void]$bar.Children.Add($fb); $script:furiButton = $fb
        $rb = New-PageToggle 'Ro' (T 'Romaji' 'Romaji') $script:settings.Romaji
        $rb.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Toggle-LyricOption 'Romaji' })
        [void]$bar.Children.Add($rb); $script:romajiButton = $rb
    }
    $pinTip = if ($script:listPinned) { T 'Lepas pin (island menutup lagi saat kursor pergi)' 'Unpin (closes again when the mouse leaves)' } else { T 'Pin: island tetap terbuka' 'Pin: keep the island open' }
    $pb = New-PageToggle $(if ($script:listPinned) { $GLYPH_PINNED } else { $GLYPH_PIN }) $pinTip $script:listPinned -Glyph
    $pb.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Toggle-ListPin })
    [void]$bar.Children.Add($pb)
    $script:pinButton = $pb
    [void]$layers.Children.Add($bar)

    $script:lyricsPage = @{ Lines = $lines; Blocks = $blocks; Tops = $null; Shift = $tt; Cur = -2; Root = $card; Panel = $sp
        RubyScale = $pageRuby; RomajiScale = $pageRomaji; Layers = $layers; Fade = $fade
        Pending = $(if ($japanese) { New-Object System.Collections.Generic.List[int] } else { $null }) }
    Measure-LyricsPage
    Update-LyricsPage -Instant
    $lyricsPageTimer.Start()
    if ($japanese) { Queue-PageParts; $pagePartsTimer.Start() }
    $card
}

# Posisi atas tiap baris (dihitung ulang setiap tinggi baris berubah karena furigana/romaji)
function Measure-LyricsPage {
    $lp = $script:lyricsPage
    $lp.Panel.Measure((New-Object System.Windows.Size(($WIDE_W - 18), [double]::PositiveInfinity)))
    $tops = New-Object System.Collections.Generic.List[double]
    $heights = New-Object System.Collections.Generic.List[double]
    $y = 0.0
    foreach ($b in $lp.Blocks) { $tops.Add($y); $heights.Add($b.DesiredSize.Height); $y += $b.DesiredSize.Height }
    $lp.Tops = $tops; $lp.Heights = $heights
}

# Geseran supaya baris $idx tepat di tengah kartu (sebelum lirik mulai: baris pertama)
function Get-LyricsPageTarget($lp, $idx) {
    $i = [Math]::Max(0, $idx)
    if ($i -ge $lp.Tops.Count) { return 0.0 }
    $LYRICS_PAGE_H / 2 - ($lp.Tops[$i] + $lp.Heights[$i] / 2)
}

# Urutan baris yang furigana/romaji-nya dihitung: dari baris sekarang ke bawah, lalu ke atas
function Queue-PageParts {
    $lp = $script:lyricsPage
    $pos = (Get-SongPos) - (Get-LyricDelay)
    $c = [Math]::Max(0, (Find-LyricLine $lp.Lines $pos))
    $lp.Pending.Clear()
    for ($i = $c; $i -lt $lp.Blocks.Count; $i++) { $lp.Pending.Add($i) }
    for ($i = $c - 1; $i -ge 0; $i--) { $lp.Pending.Add($i) }
}

$pagePartsTimer = New-Object System.Windows.Threading.DispatcherTimer([System.Windows.Threading.DispatcherPriority]::Background)
$pagePartsTimer.Interval = Ms 15
$pagePartsTimer.Add_Tick({
    $lp = $script:lyricsPage
    if (-not $lp -or -not $lp.Pending -or $lp.Pending.Count -eq 0 -or $script:mode -ne 'list' -or $script:listPage -ne 'lyrics') { $pagePartsTimer.Stop(); return }
    # Beberapa baris per tick (masing-masing beberapa ms), lalu posisi digeser supaya baris aktif tidak melompat
    for ($n = 0; $n -lt 3 -and $lp.Pending.Count; $n++) {
        $i = $lp.Pending[0]; $lp.Pending.RemoveAt(0)
        $blk = $lp.Blocks[$i]
        if ($blk.Tag.Line.Text -match $JAPANESE) { Set-PageLine $blk (Get-LineParts $blk.Tag.Line) -Fade }
    }
    # Baris yang terisi kebanyakan di luar kartu; baris aktif dikunci di tengah (tanpa animasi gulir yang
    # dimulai ulang tiap batch, yang membuat halaman bergoyang naik-turun)
    Measure-LyricsPage
    $lp.Shift.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $null)
    $lp.Shift.Y = Get-LyricsPageTarget $lp $lp.Cur
})


function Update-LyricsPage([switch]$Instant) {
    $lp = $script:lyricsPage
    if (-not $lp -or $script:mode -ne 'list' -or $script:listPage -ne 'lyrics' -or -not $script:media) { $lyricsPageTimer.Stop(); return }
    if ($lp.Lines.Count -eq 0) { return }
    $pos = (Get-SongPos) - (Get-LyricDelay)
    $idx = Find-LyricLine $lp.Lines $pos
    if ($idx -eq $lp.Cur) { return }
    $ca = [System.Windows.Media.SolidColorBrush]::ColorProperty
    for ($i = 0; $i -lt $lp.Blocks.Count; $i++) {
        $want = if ($i -eq $idx) { Rgb 255 255 255 255 } else { $DIM_LINE }
        $br = $lp.Blocks[$i].Tag.Brush
        if ($br.Color -ne $want -or $i -eq $lp.Cur -or $i -eq $idx) {
            if ($Instant) { $br.BeginAnimation($ca, $null); $br.Color = $want }
            else {
                $cAnim = New-Object System.Windows.Media.Animation.ColorAnimation($want, (New-Object System.Windows.Duration (Ms 300)))
                [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($cAnim, $ANIM_FPS)
                $br.BeginAnimation($ca, $cAnim)
            }
        }
    }
    $lp.Cur = $idx
    # Baris aktif di tengah kartu; sebelum lirik mulai, baris pertama
    $target = Get-LyricsPageTarget $lp $idx
    $yp = [System.Windows.Media.TranslateTransform]::YProperty
    if ($Instant) { $lp.Shift.BeginAnimation($yp, $null); $lp.Shift.Y = $target }
    else { Animate60 $lp.Shift $yp $lp.Shift.Y $target 520 }
}

# Baris aktif dicek selama halaman lirik terbuka
$lyricsPageTimer = New-Object System.Windows.Threading.DispatcherTimer
$lyricsPageTimer.Interval = Ms 120
$lyricsPageTimer.Add_Tick({ Update-LyricsPage })

# Furigana / romaji nyala-mati (berlaku juga untuk mini island)
# Di halaman lirik tidak dibangun ulang: yang dimatikan memudar keluar dulu, yang dinyalakan memudar masuk,
# baris-baris bergeser halus ke posisi barunya.
# Di halaman lirik: tampilan sekarang difoto, tata letak baru dipasang sekaligus (baris aktif tetap di
# tengah), lalu foto lama memudar keluar sementara tampilan baru memudar masuk. Tidak ada guliran
# naik-turun, dan tata letak hanya dihitung sekali (bukan tiap frame).
function Toggle-LyricOption($name) {
    $on = -not $script:settings.$name
    $script:settings.$name = $on
    Save-Settings
    $script:lyricIdx = -2
    $lp = $script:lyricsPage
    if (-not ($lp -and $script:mode -eq 'list' -and $script:listPage -eq 'lyrics')) { return }
    $snap = $null
    try {
        $k = 1.0
        $src = [System.Windows.PresentationSource]::FromVisual($window)
        if ($src) { $k = $src.CompositionTarget.TransformToDevice.M11 }
        $w = [int][Math]::Ceiling($lp.Layers.ActualWidth * $k); $h = [int][Math]::Ceiling($lp.Layers.ActualHeight * $k)
        if ($w -gt 0 -and $h -gt 0) {
            $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, (96 * $k), (96 * $k), [System.Windows.Media.PixelFormats]::Pbgra32)
            $rtb.Render($lp.Layers); $rtb.Freeze()
            $snap = New-Object System.Windows.Controls.Image
            $snap.Source = $rtb; $snap.Stretch = 'None'; $snap.IsHitTestVisible = $false
            $snap.HorizontalAlignment = 'Left'; $snap.VerticalAlignment = 'Top'
        }
    } catch { Log "lyrics snapshot: $_" }
    Update-PageToggles
    $sc = if ($name -eq 'Furigana') { $lp.RubyScale } else { $lp.RomajiScale }
    $sc.BeginAnimation([System.Windows.Media.ScaleTransform]::ScaleYProperty, $null)
    $sc.ScaleY = $(if ($on) { 1.0 } else { 0.0 })
    # Tata letak baru dihitung sekarang juga (bukan di frame berikutnya), supaya posisi tengahnya tepat
    $lp.Panel.UpdateLayout()
    Measure-LyricsPage
    $yp = [System.Windows.Media.TranslateTransform]::YProperty
    $lp.Shift.BeginAnimation($yp, $null)
    $lp.Shift.Y = Get-LyricsPageTarget $lp $lp.Cur
    $op = [System.Windows.UIElement]::OpacityProperty
    if ($snap) {
        [void]$lp.Layers.Children.Add($snap)
        Animate60 $snap $op 1.0 0.0 300
        $script:lyricsSnap = $snap
        $snapTimer.Stop(); $snapTimer.Start()
    }
    Animate60 $lp.Fade $op 0.0 1.0 300
}
$snapTimer = New-Object System.Windows.Threading.DispatcherTimer
$snapTimer.Interval = Ms 320
$snapTimer.Add_Tick({
    $snapTimer.Stop()
    $sn = $script:lyricsSnap; $script:lyricsSnap = $null
    if ($sn -and $sn.Parent) { $sn.Parent.Children.Remove($sn) }
})

# Tampilan tombol pojok halaman lirik mengikuti pengaturan (tanpa membangun ulang halaman)
function Set-PageToggleLook($b, $on, $content) {
    if (-not $b) { return }
    $b.Resources['RestHex'] = if ($on) { '#55FFFFFF' } else { '#26FFFFFF' }
    if (-not $b.IsMouseOver) { $b.Background = Brush $b.Resources['RestHex'] }
    $b.Child.Foreground = Brush $(if ($on) { '#FFFFFFFF' } else { '#99FFFFFF' })
    if ($content) { $b.Child.Text = $content }
}
function Update-PageToggles {
    Set-PageToggleLook $script:furiButton $script:settings.Furigana
    Set-PageToggleLook $script:romajiButton $script:settings.Romaji
    Set-PageToggleLook $script:pinButton $script:listPinned $(if ($script:listPinned) { $GLYPH_PINNED } else { $GLYPH_PIN })
    if ($script:pinButton) {
        $script:pinButton.ToolTip = if ($script:listPinned) { T 'Lepas pin (island menutup lagi saat kursor pergi)' 'Unpin (closes again when the mouse leaves)' } else { T 'Pin: island tetap terbuka' 'Pin: keep the island open' }
    }
}

# Pin: daftar tidak menutup sendiri saat kursor pergi (dilepas lagi lewat tombol yang sama)
function Toggle-ListPin {
    $script:listPinned = -not $script:listPinned
    Update-PageToggles
    if (-not $script:listPinned -and -not $script:hovering -and -not $script:overHot) { $closeTimer.Start() }
}

function Show-List([switch]$Refresh) {
    $script:mode = 'list'
    if (-not $Refresh) { $script:volumeMode = $false }
    $listPanel.Children.Clear()
    $items = @($script:recent | Select-Object -First $MAX_ITEMS)
    Set-Theme (Rgb 110 110 118)
    # Halaman: notifikasi (prioritas kalau ada), musik, lirik. Tanpa notifikasi, halaman notifikasi tidak
    # ditampilkan sama sekali: langsung player musik (juga saat notifikasi terakhir dihapus).
    $pages = Get-ListPages
    $prevPage = $script:listPage
    if (-not $Refresh) { $script:listPage = $pages[0] }
    elseif ($pages -notcontains $script:listPage) { $script:listPage = if ($script:media) { 'music' } else { $pages[0] } }
    # Tombol pin hanya ada di halaman lirik: kalau halaman itu hilang atau ditinggalkan, pin dilepas supaya
    # daftar bisa menutup lagi saat kursor pergi (tanpa tombolnya, pin tidak bisa dilepas)
    if ($script:listPinned -and $script:listPage -ne 'lyrics') {
        $script:listPinned = $false
        if (-not $script:hovering -and -not $script:overHot) { $closeTimer.Start() }
    }
    $script:lyricsPage = $null
    $script:listClockText = $null
    if ($script:clock) { [void]$listPanel.Children.Add((New-ClockRow)) }
    if ($script:listPage -eq 'music') {
        Set-Theme $script:media.Accent
        $card = New-Object System.Windows.Controls.Border
        $card.MinHeight = 56; $card.Padding = '0,4,0,0'; $card.ClipToBounds = $true
        $card.CornerRadius = New-Object System.Windows.CornerRadius(14)
        $card.Background = Row-Brush $script:media.Accent $true
        $card.Child = New-MediaContent
        [void]$listPanel.Children.Add($card)
        # Lagu berganti saat halaman musik terbuka: kartu baru memudar masuk dengan halus di tempat
        if ($Refresh -and $prevPage -eq 'music' -and $script:listMediaKey -and $script:listMediaKey -ne $script:media.Key) {
            $card.Opacity = 0
            Fade-Smooth $card 1
        }
        $script:listMediaKey = $script:media.Key
    } elseif ($script:listPage -eq 'lyrics') {
        Set-Theme $script:media.Accent
        [void]$listPanel.Children.Add((New-LyricsPage))
    } elseif ($items.Count -eq 0) {
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = T 'Tidak ada notifikasi' 'No notifications'
        $t.Foreground = Brush '#A1A1A6'; $t.FontSize = 13
        $t.HorizontalAlignment = 'Center'; $t.Margin = '0,6,0,6'
        [void]$listPanel.Children.Add($t)
    } else {
        [void]$listPanel.Children.Add((New-ListHeader))
        foreach ($n in $items) {
            $isOpen = $expanded.Contains($n.Id)
            $vAlign = if ($isOpen) { 'Top' } else { 'Center' }
            $row = New-Object System.Windows.Controls.Border
            $row.Cursor = 'Hand'; $row.Margin = '0,0,0,2'
            $row.Background = Row-Brush $n.Accent $false
            $row.CornerRadius = New-Object System.Windows.CornerRadius(14)
            if ($isOpen) { $row.MinHeight = $ITEM_H; $row.Padding = '8,9' } else { $row.Height = $ITEM_H; $row.Padding = '8,0' }
            $g = New-Object System.Windows.Controls.Grid
            $row.Child = $g
            foreach ($w in 'Auto', '*', 'Auto') {
                $cd = New-Object System.Windows.Controls.ColumnDefinition
                $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
                $g.ColumnDefinitions.Add($cd)
            }
            $icon = New-Icon $n 30 15
            $icon.VerticalAlignment = $vAlign
            [void]$g.Children.Add($icon)

            $sp = New-Object System.Windows.Controls.StackPanel
            $sp.Margin = '12,0,10,0'; $sp.VerticalAlignment = $vAlign
            [System.Windows.Controls.Grid]::SetColumn($sp, 1)
            $t1 = New-Object System.Windows.Controls.TextBlock
            $t1.Text = $n.Title; $t1.Foreground = Brush '#FFFFFF'; $t1.FontSize = 13; $t1.FontWeight = 'SemiBold'; $t1.TextTrimming = 'CharacterEllipsis'
            $t2 = New-Object System.Windows.Controls.TextBlock
            $t2.Text = $n.Body; $t2.Foreground = Brush '#A1A1A6'; $t2.FontSize = 12; $t2.TextTrimming = 'CharacterEllipsis'
            if ($isOpen) {
                $t1.TextWrapping = 'Wrap'; $t1.MaxHeight = 40
                $t2.TextWrapping = 'Wrap'; $t2.MaxHeight = 220; $t2.Margin = '0,2,0,0'
            }
            [void]$sp.Children.Add($t1); [void]$sp.Children.Add($t2)
            [void]$g.Children.Add($sp)

            # Kolom kanan: jam; saat baris di-hover diganti tombol buka/tutup teks dan hapus
            $right = New-Object System.Windows.Controls.Grid
            $right.VerticalAlignment = $vAlign
            [System.Windows.Controls.Grid]::SetColumn($right, 2)
            $tt = New-Object System.Windows.Controls.TextBlock
            $tt.Text = $n.Time.ToString('HH:mm'); $tt.Foreground = Brush '#8E8E93'; $tt.FontSize = 11
            $tt.VerticalAlignment = 'Center'; $tt.HorizontalAlignment = 'Right'
            [void]$right.Children.Add($tt)
            $btns = New-Object System.Windows.Controls.StackPanel
            $btns.Orientation = 'Horizontal'; $btns.Visibility = 'Collapsed'; $btns.HorizontalAlignment = 'Right'

            $tip = if ($isOpen) { T 'Tutup pesan' 'Collapse' } else { T 'Baca pesan lengkap' 'Read full message' }
            $glyph = if ($isOpen) { $COLLAPSE_GLYPH } else { $EXPAND_GLYPH }
            $xb = New-RoundButton $glyph '#55FFFFFF' $tip
            $xb.Margin = '0,0,6,0'; $xb.Tag = $n.Id
            $xb.Add_MouseLeftButtonUp({
                param($s, $e)
                $e.Handled = $true
                if (-not $expanded.Remove([uint32]$s.Tag)) { [void]$expanded.Add([uint32]$s.Tag) }
                Show-List -Refresh
            })
            [void]$btns.Children.Add($xb)

            $cb = New-RoundButton $CLOSE_GLYPH '#FF453A' (T 'Hapus notifikasi' 'Dismiss')
            $cb.Tag = [PSCustomObject]@{ Id = $n.Id; Row = $row }
            $cb.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Start-Delete @($s.Tag.Row) @($s.Tag.Id) $false })
            [void]$btns.Children.Add($cb)
            [void]$right.Children.Add($btns)
            [void]$g.Children.Add($right)

            $row.Tag = [PSCustomObject]@{ N = $n; Close = $btns; Time = $tt }
            $row.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Open-Notif $s.Tag.N; Go-Idle })
            $row.Add_MouseEnter({
                param($s, $e)
                $s.Background = Row-Brush $s.Tag.N.Accent $true
                $s.Tag.Close.Visibility = 'Visible'; $s.Tag.Time.Visibility = 'Hidden'
            })
            $row.Add_MouseLeave({
                param($s, $e)
                $s.Background = Row-Brush $s.Tag.N.Accent $false
                $s.Tag.Close.Visibility = 'Collapsed'; $s.Tag.Time.Visibility = 'Visible'
            })
            [void]$listPanel.Children.Add($row)
        }
    }
    # Titik halaman hanya kalau memang ada dua halaman
    $script:pageDots = $null
    if ($pages.Count -gt 1) { $script:pageDots = New-PageDots; [void]$listPanel.Children.Add($script:pageDots) }
    $listPanel.Measure((New-Object System.Windows.Size(($WIDE_W - 2), [double]::PositiveInfinity)))
    $h = [Math]::Min($MAX_ISLAND_H, [Math]::Max(56, [Math]::Ceiling($listPanel.DesiredSize.Height) + 2))
    Resize-Island $WIDE_W $h 24
    Set-IslandVisible $true
    if ($Refresh) { Show-View 'ListView' } else { Show-View 'ListView' -Replay }
    # Halaman berpindah sendiri (mis. notifikasi terakhir dihapus -> player musik): beri animasi geser
    if ($Refresh -and $prevPage -ne $script:listPage) { Slide-ListIn ([array]::IndexOf($pages, $script:listPage) -gt [array]::IndexOf($pages, $prevPage)) }
}

# ---------- Aktivitas singkat ----------
# Pil sementara untuk hal-hal kecil: volume/kecerahan berubah, mulai mengisi daya, baterai lemah,
# timer selesai, update tersedia. Setelah waktunya habis island kembali seperti semula (mini island / diam).
$script:activity = $null
$script:pendingActivity = $null
$GLYPH_BRIGHT = [string][char]0xE706; $GLYPH_CLOCK = [string][char]0xE916; $GLYPH_BOLT = [string][char]0xE945
$GLYPH_DOWNLOAD = [string][char]0xE896; $GLYPH_INFO = [string][char]0xE946
$CLOCK_COLOR = Rgb 255 159 10

$activityTimer = New-Object System.Windows.Threading.DispatcherTimer
$activityTimer.Add_Tick({
    $activityTimer.Stop()
    if ([System.Windows.Input.Mouse]::Captured) { $activityTimer.Start(); return }
    if ($script:mode -eq 'activity') { End-Activity }
})
function End-Activity {
    $activityTimer.Stop()
    if ($script:alarm) { try { $script:alarm.Stop() } catch {}; $script:alarm = $null }
    $script:activity = $null; $script:osdUI = $null
    Go-Idle
}

# Pemberitahuan lama di island tidak menimpa notifikasi / kartu yang sedang dibuka
function Can-ShowActivity {
    -not $script:fullscreen -and -not $script:exiting -and ($script:mode -eq 'idle' -or $script:mode -eq 'activity')
}

function Show-Activity($kind, $content, $w, $h, $accent, $ms, $click = $null) {
    $same = $script:mode -eq 'activity' -and $script:activity -and $script:activity.Kind -eq $kind
    $dismissTimer.Stop(); $closeTimer.Stop()
    $script:mode = 'activity'
    $script:activity = @{ Kind = $kind; Click = $click }
    $island.RenderTransform = [System.Windows.Media.Transform]::Identity
    Set-Theme $accent
    $av = $views['ActivityView']
    $av.Children.Clear()
    [void]$av.Children.Add($content)
    Resize-Island $w $h ([Math]::Min(24.0, $h / 2))
    Set-IslandVisible $true
    if ($same) { Show-View 'ActivityView' } else { Show-View 'ActivityView' -Replay }
    $activityTimer.Stop(); $activityTimer.Interval = Ms $ms
    if (-not $script:hovering) { $activityTimer.Start() }
}

function New-Glyph($glyph, $size, $color) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $glyph; $t.FontFamily = 'Segoe Fluent Icons, Segoe MDL2 Assets'; $t.FontSize = $size
    $t.Foreground = if ($color -is [System.Windows.Media.Color]) { New-Object System.Windows.Media.SolidColorBrush($color) } else { Brush $color }
    $t.VerticalAlignment = 'Center'
    $t
}
function New-Label($text, $size, $hex, $weight = 'Normal') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.Foreground = Brush $hex; $t.FontWeight = $weight
    $t.VerticalAlignment = 'Center'; $t.TextTrimming = 'CharacterEllipsis'
    $t
}
function New-Columns($widths) {
    $g = New-Object System.Windows.Controls.Grid
    foreach ($w in $widths) {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
        $g.ColumnDefinitions.Add($cd)
    }
    $g
}
function Add-Cell($g, $el, $col) { [System.Windows.Controls.Grid]::SetColumn($el, $col); [void]$g.Children.Add($el) }

# Pil pendek berisi satu baris teks (hasil cek update, dll)
function Show-Info($text, $ms = 2800) {
    # Ditunda (mis. sedang ada pop-up): lamanya ikut disimpan ("Mengunduh update..." harus tampil 60 detik, bukan 2,8)
    if (-not (Can-ShowActivity)) { $script:pendingActivity = @{ Kind = 'info'; Arg = $text; Ms = $ms }; return }
    $g = New-Columns 'Auto', '*'
    $g.Margin = '14,0,16,0'
    Add-Cell $g (New-Glyph $GLYPH_INFO 13 '#D9FFFFFF') 0
    $l = New-Label $text 12 '#FFFFFF' 'SemiBold'; $l.Margin = '10,0,0,0'
    Add-Cell $g $l 1
    $g.Measure((New-Object System.Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)))
    $w = [Math]::Min($WIDE_W, [Math]::Max(200.0, [Math]::Ceiling($g.DesiredSize.Width) + 34))
    Show-Activity 'info' $g $w 36 (Rgb 110 110 118) $ms
}

# ---------- Volume & kecerahan ----------
# Pil berisi ikon | bar | persen. Saat tombol volume ditahan, pil yang sama diperbarui (tidak dibangun ulang).
$script:osdUI = $null
function Show-LevelOsd($kind, $glyph, $frac, $text) {
    if (-not (Can-ShowActivity)) { return }
    $ui = $script:osdUI
    if (-not ($script:mode -eq 'activity' -and $script:activity.Kind -eq $kind -and $ui)) {
        $g = New-Columns 'Auto', '*', 'Auto'
        $g.Margin = '14,0,14,0'
        $gl = New-Glyph $glyph 13 '#F2FFFFFF'; $gl.Width = 16
        Add-Cell $g $gl 0
        $tr = New-Object System.Windows.Controls.Grid
        $tr.Margin = '10,0,10,0'; $tr.VerticalAlignment = 'Center'; $tr.Height = 6
        $bg = New-Object System.Windows.Controls.Border
        $bg.CornerRadius = New-Object System.Windows.CornerRadius(3); $bg.Background = Brush '#33FFFFFF'
        $fill = New-Object System.Windows.Controls.Border
        $fill.CornerRadius = New-Object System.Windows.CornerRadius(3); $fill.Background = Brush '#F2FFFFFF'
        $fill.RenderTransformOrigin = '0,0.5'
        $fs = New-Object System.Windows.Media.ScaleTransform($frac, 1)
        $fill.RenderTransform = $fs
        [void]$tr.Children.Add($bg); [void]$tr.Children.Add($fill)
        Add-Cell $g $tr 1
        $pct = New-Label $text 11 '#D9FFFFFF' 'SemiBold'
        $pct.MinWidth = 30; $pct.TextAlignment = 'Right'; $pct.Typography.NumeralAlignment = 'Tabular'
        Add-Cell $g $pct 2
        $accent = if ($script:media -and $script:media.Playing) { $script:media.Accent } else { Rgb 110 110 118 }
        Show-Activity $kind $g 230 34 $accent 1600
        $script:osdUI = @{ Glyph = $gl; Fill = $fs; Text = $pct }
        return
    }
    $activityTimer.Stop()
    if (-not $script:hovering) { $activityTimer.Start() }
    $ui.Glyph.Text = $glyph; $ui.Text.Text = $text
    Animate $ui.Fill ([System.Windows.Media.ScaleTransform]::ScaleXProperty) $frac 140
}

function On-VolumeChanged {
    $vw = $script:volWatcher
    # Slider di kartu musik ikut bergerak kalau volume diubah dari keyboard/taskbar
    if ($script:volUI) { Update-VolumeUI }
    if (-not $script:settings.VolumeOsd -or $vw.Own) { return }
    $v = [double]$vw.Level
    $muted = $vw.Muted -or $v -le 0.001
    $glyph = if ($muted) { $GLYPH_MUTE } elseif ($v -lt 0.34) { [string][char]0xE993 } elseif ($v -lt 0.67) { [string][char]0xE994 } else { [string][char]0xE995 }
    $text = if ($vw.Muted) { T 'Bisu' 'Muted' } else { '{0}%' -f [int][Math]::Round($v * 100) }
    Show-LevelOsd 'volume' $glyph $(if ($vw.Muted) { 0.0 } else { $v }) $text
}

function On-BrightnessChanged {
    if (-not $script:settings.VolumeOsd) { return }
    $b = [Math]::Max(0, [Math]::Min(100, $script:brightWatcher.Level))
    Show-LevelOsd 'brightness' $GLYPH_BRIGHT ($b / 100.0) ('{0}%' -f $b)
}

# ---------- Baterai ----------
# Ikon baterai kecil: kotak bergaris tepi, isi sesuai persen, tonjolan kutub di kanan
function New-BatteryIcon($pct, $color) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.VerticalAlignment = 'Center'
    $body = New-Object System.Windows.Controls.Border
    $body.Width = 25; $body.Height = 12; $body.CornerRadius = New-Object System.Windows.CornerRadius(3.5)
    $body.BorderThickness = 1.2; $body.BorderBrush = Brush '#8CFFFFFF'; $body.Padding = '1.5'
    $fill = New-Object System.Windows.Controls.Border
    $fill.CornerRadius = New-Object System.Windows.CornerRadius(2); $fill.HorizontalAlignment = 'Left'
    $fill.Width = [Math]::Max(2.0, 19.6 * [Math]::Min(100, $pct) / 100)
    $fill.Background = New-Object System.Windows.Media.SolidColorBrush($color)
    $body.Child = $fill
    $nub = New-Object System.Windows.Controls.Border
    $nub.Width = 2; $nub.Height = 4.5; $nub.Margin = '1,0,0,0'; $nub.VerticalAlignment = 'Center'
    $nub.CornerRadius = New-Object System.Windows.CornerRadius(0, 1.5, 1.5, 0); $nub.Background = Brush '#8CFFFFFF'
    [void]$sp.Children.Add($body); [void]$sp.Children.Add($nub)
    $sp
}

# $true kalau pilnya benar-benar tampil (tidak bisa saat ada pop-up / aplikasi fullscreen)
function Show-Battery($pct, $charging) {
    if (-not (Can-ShowActivity)) { return $false }
    $color = if ($charging) { Rgb 48 209 88 } elseif ($pct -le 10) { Rgb 255 69 58 } else { Rgb 255 159 10 }
    $g = New-Columns '*', 'Auto', 'Auto'
    $g.Margin = '16,0,14,0'
    $label = if ($charging) { T 'Mengisi daya' 'Charging' } else { T 'Baterai lemah' 'Low battery' }
    Add-Cell $g (New-Label $label 12.5 '#FFFFFF' 'SemiBold') 0
    $right = New-Object System.Windows.Controls.StackPanel
    $right.Orientation = 'Horizontal'
    if ($charging) { [void]$right.Children.Add((New-Glyph $GLYPH_BOLT 11 $color)) }
    $p = New-Label ('{0}%' -f $pct) 12.5 '#FFFFFF' 'SemiBold'
    $p.Foreground = New-Object System.Windows.Media.SolidColorBrush($color); $p.Margin = '3,0,8,0'
    [void]$right.Children.Add($p)
    Add-Cell $g $right 1
    Add-Cell $g (New-BatteryIcon $pct $color) 2
    Show-Activity 'battery' $g 250 36 $color 2800
    $true
}

$script:powerLine = $null
$script:lowWarned = 100
function Check-Power {
    if (-not $script:settings.Charging) { return }
    $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
    if ($ps.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery) { return }
    $pct = [int][Math]::Round([Math]::Min(1.0, $ps.BatteryLifePercent) * 100)
    $online = "$($ps.PowerLineStatus)" -eq 'Online'
    if ($null -ne $script:powerLine -and $online -and -not $script:powerLine) { [void](Show-Battery $pct $true) }
    $script:powerLine = $online
    # Peringatan baterai lemah sekali di 20% dan sekali di 10% (diulang lagi setelah dicas). Baru dianggap sudah
    # diperingatkan kalau pilnya benar-benar tampil: saat main game fullscreen, peringatannya menunggu, tidak hilang.
    if ($online) { $script:lowWarned = 100 }
    elseif ($pct -le 10 -and $script:lowWarned -gt 10) { if (Show-Battery $pct $false) { $script:lowWarned = 10 } }
    elseif ($pct -le 20 -and $script:lowWarned -gt 20) { if (Show-Battery $pct $false) { $script:lowWarned = 20 } }
}

# ---------- Headset Bluetooth ----------
# Output audio default pindah ke perangkat Bluetooth (headset/earbuds baru tersambung): pil berisi nama
# perangkat dan baterainya, seperti pop-up earbuds di ponsel. Nama dan jenis perangkat dibaca dari catatan
# audio Windows; baterai (kalau perangkat melaporkannya) dicari di latar belakang lalu ditambahkan ke pil.
$GLYPH_HEADPHONE = [string][char]0xE7F6
$BT_COLOR = Rgb 10 132 255
$MMDEV_RENDER = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$script:audioDevice = $null
$script:batteryJob = $null

# Nama dan jenis koneksi perangkat output dari ID endpoint Core Audio ("{0.0.0.00000000}.{guid}")
function Get-EndpointInfo($id) {
    if (-not $id) { return $null }
    $guid = $id.Substring($id.LastIndexOf('.') + 1)
    $p = Get-ItemProperty (Join-Path (Join-Path $MMDEV_RENDER $guid) 'Properties') -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $endpoint = $p.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
    $device = $p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
    $enum = "$($p.'{a45c254e-df1c-4efd-8020-67d146a850e0},24') $($p.'{b3f8fa53-0004-438e-9003-51a46e139bfc},2')"
    @{ Name = $(if ($device) { "$device" } else { "$endpoint" }); Bluetooth = $enum -match 'BTH' }
}

$BATTERY_JOB = {
    param($name)
    try {
        foreach ($d in @(Get-PnpDevice -PresentOnly -FriendlyName $name -ErrorAction Stop)) {
            $p = Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2' -ErrorAction SilentlyContinue
            if ($p -and $null -ne $p.Data) { return @{ Battery = [int]$p.Data } }
        }
    } catch {}
    @{ Battery = -1 }
}

function Check-AudioDevice {
    if (-not $script:volWatcher) { return }
    $id = $script:volWatcher.DeviceId
    if (-not $id -or $id -eq $script:audioDevice) { return }
    $first = $null -eq $script:audioDevice
    $script:audioDevice = $id
    # Perangkat yang sudah tersambung saat island mulai tidak perlu diumumkan
    if ($first -or -not $script:settings.Headset) { return }
    $info = Get-EndpointInfo $id
    if ($info -and $info.Bluetooth) { Show-Headset $info.Name -1 }
}

function Show-Headset($name, $battery) {
    if (-not (Can-ShowActivity)) { return }
    $g = New-Columns 'Auto', '*', 'Auto'
    $g.Margin = '10,0,14,0'
    $ic = New-Object System.Windows.Controls.Border
    $ic.Width = 32; $ic.Height = 32; $ic.CornerRadius = New-Object System.Windows.CornerRadius(16)
    $ic.Background = New-Object System.Windows.Media.SolidColorBrush((Rgb 10 132 255 60))
    $hg = New-Glyph $GLYPH_HEADPHONE 15 $BT_COLOR; $hg.HorizontalAlignment = 'Center'
    $ic.Child = $hg
    Add-Cell $g $ic 0
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = '11,0,10,0'; $sp.VerticalAlignment = 'Center'
    [void]$sp.Children.Add((New-Label $name 13 '#FFFFFF' 'SemiBold'))
    [void]$sp.Children.Add((New-Label (T 'Tersambung' 'Connected') 11 '#A1A1A6'))
    Add-Cell $g $sp 1
    $right = New-Object System.Windows.Controls.StackPanel
    $right.Orientation = 'Horizontal'; $right.VerticalAlignment = 'Center'
    Add-Cell $g $right 2
    Set-HeadsetBattery $right $battery
    Show-Activity 'headset' $g 290 52 $BT_COLOR 4000
    $script:headsetUI = $right
    # Baterai belum diketahui: cari di latar belakang, pil diperbarui kalau ketemu
    if ($battery -lt 0) {
        $script:batteryJob = Start-BgJob $BATTERY_JOB @($name)
        $batteryTimer.Start()
    }
}

function Set-HeadsetBattery($panel, $battery) {
    $panel.Children.Clear()
    if ($battery -lt 0) { return }
    $color = if ($battery -le 20) { Rgb 255 69 58 } else { Rgb 48 209 88 }
    $p = New-Label ('{0}%' -f $battery) 12.5 '#FFFFFF' 'SemiBold'
    $p.Margin = '0,0,8,0'
    [void]$panel.Children.Add($p)
    [void]$panel.Children.Add((New-BatteryIcon $battery $color))
    $panel.Opacity = 0
    Animate $panel ([System.Windows.UIElement]::OpacityProperty) 1 260
}

$batteryTimer = New-Object System.Windows.Threading.DispatcherTimer
$batteryTimer.Interval = Ms 300
$batteryTimer.Add_Tick({
    $r = Receive-BgJob $script:batteryJob
    if (-not $r) { return }
    $batteryTimer.Stop(); $script:batteryJob = $null
    if ($r.Battery -ge 0 -and $script:mode -eq 'activity' -and $script:activity.Kind -eq 'headset' -and $script:headsetUI) {
        Set-HeadsetBattery $script:headsetUI $r.Battery
    }
})

# ---------- Mikrofon & kamera ----------
# Titik oranye = mikrofon, hijau = kamera sedang dipakai (seperti indikator privasi di ponsel)
function Set-Dot($dot, $on) {
    if ([bool]$dot.Tag -eq $on) { return }
    $dot.Tag = $on
    Animate $dot ([System.Windows.FrameworkElement]::WidthProperty) $(if ($on) { 5 } else { 0 }) 260
}
function Check-Sensors {
    $mic = @(); $cam = @()
    if ($script:settings.MicCam -and -not $script:exiting) {
        $mic = @([IslandSensors]::InUse('microphone'))
        $cam = @([IslandSensors]::InUse('webcam'))
    }
    Set-Dot $micDot ($mic.Count -gt 0)
    Set-Dot $camDot ($cam.Count -gt 0)
    $tip = @()
    if ($mic.Count) { $tip += (T 'Mikrofon dipakai: ' 'Microphone in use: ') + ($mic -join ', ') }
    if ($cam.Count) { $tip += (T 'Kamera dipakai: ' 'Camera in use: ') + ($cam -join ', ') }
    $text = $tip -join "`n"
    if ($text -ne $script:sensorTip) { $script:sensorTip = $text; $sensorDots.ToolTip = $(if ($text) { $text } else { $null }) }
}

# ---------- Timer & stopwatch ----------
# Dimulai dari menu klik kanan. Tanpa lagu: mini island menampilkan sisa waktu. Saat lagu diputar: lagu
# tetap di mini island, timer di gelembung kecil di sebelah kanannya. Kontrol (jeda/hentikan) ada di daftar.
$script:clock = $null
# Semua waktu timer memakai UTC: jam lokal bisa melompat (pergantian musim panas, jam diubah), UTC tidak
function Start-Countdown($min) {
    $script:clock = @{ Kind = 'timer'; Running = $true; End = [DateTime]::UtcNow.AddMinutes($min); Left = [TimeSpan]::FromMinutes($min) }
    Clock-Changed
}
function Start-Stopwatch {
    $script:clock = @{ Kind = 'stopwatch'; Running = $true; Start = [DateTime]::UtcNow; Acc = [TimeSpan]::Zero }
    Clock-Changed
}
function Get-ClockSpan {
    $c = $script:clock
    if (-not $c) { return [TimeSpan]::Zero }
    if ($c.Kind -eq 'timer') { if ($c.Running) { $c.End - [DateTime]::UtcNow } else { $c.Left } }
    else { if ($c.Running) { $c.Acc + ([DateTime]::UtcNow - $c.Start) } else { $c.Acc } }
}
function Toggle-Clock {
    $c = $script:clock
    if (-not $c) { return }
    if ($c.Running) {
        if ($c.Kind -eq 'timer') { $c.Left = $c.End - [DateTime]::UtcNow } else { $c.Acc = $c.Acc + ([DateTime]::UtcNow - $c.Start) }
        $c.Running = $false
    } else {
        if ($c.Kind -eq 'timer') { $c.End = [DateTime]::UtcNow + $c.Left } else { $c.Start = [DateTime]::UtcNow }
        $c.Running = $true
    }
    Clock-Changed
}
function Stop-Clock { $script:clock = $null; Clock-Changed }
function Format-Clock($ts) {
    # Timer dibulatkan ke atas (sisa 0,4 detik masih tampil 0:01)
    $s = if ($script:clock -and $script:clock.Kind -eq 'timer') { [Math]::Ceiling($ts.TotalSeconds) } else { [Math]::Floor($ts.TotalSeconds) }
    $s = [int][Math]::Max(0, $s)
    if ($s -ge 3600) { '{0}:{1:00}:{2:00}' -f [int][Math]::Floor($s / 3600), [int][Math]::Floor(($s % 3600) / 60), ($s % 60) }
    else { '{0}:{1:00}' -f [int][Math]::Floor($s / 60), ($s % 60) }
}

# Mini island berisi timer saja (tidak ada lagu yang diputar)
function New-ClockMini {
    $g = New-Columns 'Auto', '*'
    $g.Margin = '9,0,11,0'
    Add-Cell $g (New-Glyph $GLYPH_CLOCK 12 $CLOCK_COLOR) 0
    $t = New-Label (Format-Clock (Get-ClockSpan)) 12 '#FFFFFF' 'SemiBold'
    $t.Foreground = New-Object System.Windows.Media.SolidColorBrush($CLOCK_COLOR)
    $t.HorizontalAlignment = 'Right'; $t.Typography.NumeralAlignment = 'Tabular'
    Add-Cell $g $t 1
    $script:miniClockText = $t
    $g
}

# Gelembung timer di kanan mini island (hanya saat mini island sedang menampilkan lagu)
function Update-Bubble {
    $show = [bool]($script:clock -and $script:mode -eq 'idle' -and $script:miniOn -and $script:miniKey -ne 'clock' -and
        -not $script:miniFaded -and -not $script:fullscreen -and -not $script:exiting)
    if ($show -eq [bool]$bubble.Tag) { return }
    $bubble.Tag = $show
    $bubbleGlyph.Text = $GLYPH_CLOCK
    $bubbleText.Text = Format-Clock (Get-ClockSpan)
    $w = if ($show) { 64 } else { 0 }
    Animate $bubble ([System.Windows.FrameworkElement]::WidthProperty) $w 320
    Animate $bubble ([System.Windows.UIElement]::OpacityProperty) $(if ($show) { 1 } else { 0 }) $(if ($show) { 260 } else { 160 })
    $ma = New-Object System.Windows.Media.Animation.ThicknessAnimation((New-Object System.Windows.Thickness($(if ($show) { 6 } else { 0 }), 0, 0, 0)), (New-Object System.Windows.Duration (Ms 320)))
    $bubble.BeginAnimation([System.Windows.FrameworkElement]::MarginProperty, $ma)
}

# Teks waktu diperbarui tiap pergantian detik (mini island, gelembung, baris di daftar)
$clockTimer = New-Object System.Windows.Threading.DispatcherTimer
$clockTimer.Interval = Ms 200
$clockTimer.Add_Tick({
    $c = $script:clock
    if (-not $c) { $clockTimer.Stop(); return }
    $span = Get-ClockSpan
    if ($c.Kind -eq 'timer' -and $c.Running -and $span.TotalSeconds -le 0) { Timer-Done; return }
    $txt = Format-Clock $span
    if ($txt -eq $script:clockShown) { return }
    $script:clockShown = $txt
    foreach ($t in $script:miniClockText, $bubbleText, $script:listClockText) { if ($t) { $t.Text = $txt } }
})

function Clock-Changed {
    $script:clockShown = $null
    if ($script:clock) { $clockTimer.Start() } else { $clockTimer.Stop(); $script:miniClockText = $null }
    Update-Mini
    Update-Bubble
    if ($script:mode -eq 'list') { Show-List -Refresh }
}

function Timer-Done {
    Stop-Clock
    try { $script:alarm = New-Object System.Media.SoundPlayer (Join-Path $env:WINDIR 'Media\Alarm01.wav'); $script:alarm.Play() } catch {}
    if ($script:fullscreen -or $script:exiting) { return }
    # Penting: boleh menimpa kartu yang sedang terbuka (bukan saat aplikasi fullscreen)
    $g = New-Columns 'Auto', '*'
    $g.Margin = '16,0,18,0'
    $gl = New-Glyph $GLYPH_CLOCK 18 $CLOCK_COLOR
    Add-Cell $g $gl 0
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = '12,0,0,0'; $sp.VerticalAlignment = 'Center'
    [void]$sp.Children.Add((New-Label (T 'Timer selesai' 'Timer done') 13 '#FFFFFF' 'SemiBold'))
    [void]$sp.Children.Add((New-Label (T 'Klik untuk menutup' 'Click to dismiss') 11 '#A1A1A6'))
    Add-Cell $g $sp 1
    # Ikon berdenyut pelan selama pemberitahuan tampil
    $pulse = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.35, (New-Object System.Windows.Duration (Ms 650)))
    $pulse.AutoReverse = $true; $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
    [System.Windows.Media.Animation.Timeline]::SetDesiredFrameRate($pulse, $AMBIENT_FPS)
    $gl.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
    Track-Anim $gl $gl ([System.Windows.UIElement]::OpacityProperty)
    Show-Activity 'timerdone' $g 260 52 $CLOCK_COLOR 12000 'dismiss'
}

# Baris timer di bagian atas daftar: ikon | nama | waktu | jeda/lanjut | hentikan
function New-ClockRow {
    $c = $script:clock
    $row = New-Object System.Windows.Controls.Border
    $row.Height = 44; $row.Margin = '0,0,0,4'; $row.Padding = '10,0,8,0'
    $row.CornerRadius = New-Object System.Windows.CornerRadius(14)
    $row.Background = Row-Brush $CLOCK_COLOR $false
    $g = New-Columns 'Auto', '*', 'Auto', 'Auto', 'Auto'
    $row.Child = $g
    Add-Cell $g (New-Glyph $GLYPH_CLOCK 15 $CLOCK_COLOR) 0
    $name = if ($c.Kind -eq 'timer') { 'Timer' } else { 'Stopwatch' }
    $l = New-Label $name 12.5 '#FFFFFF' 'SemiBold'; $l.Margin = '10,0,0,0'
    Add-Cell $g $l 1
    $t = New-Label (Format-Clock (Get-ClockSpan)) 17 '#FFFFFF' 'SemiBold'
    $t.Foreground = New-Object System.Windows.Media.SolidColorBrush($CLOCK_COLOR)
    $t.Typography.NumeralAlignment = 'Tabular'; $t.Margin = '0,0,10,0'
    Add-Cell $g $t 2
    $script:listClockText = $t
    $pb = New-RoundButton $(if ($c.Running) { $GLYPH_PAUSE } else { $GLYPH_PLAY }) '#55FFFFFF' $(if ($c.Running) { T 'Jeda' 'Pause' } else { T 'Lanjutkan' 'Resume' })
    $pb.Width = 26; $pb.Height = 26; $pb.CornerRadius = New-Object System.Windows.CornerRadius(13); $pb.Margin = '0,0,6,0'; $pb.Cursor = 'Hand'
    $pb.Child.FontSize = 11
    $pb.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Toggle-Clock })
    Add-Cell $g $pb 3
    $sb = New-RoundButton $CLOSE_GLYPH '#FF453A' (T 'Hentikan' 'Stop')
    $sb.Width = 26; $sb.Height = 26; $sb.CornerRadius = New-Object System.Windows.CornerRadius(13); $sb.Cursor = 'Hand'
    $sb.Child.FontSize = 10
    $sb.Add_MouseLeftButtonUp({ param($s, $e) $e.Handled = $true; Stop-Clock })
    Add-Cell $g $sb 4
    $row
}

# ---------- Cek update ----------
# Sekali saat mulai lalu tiap 24 jam: file VERSION di GitHub dibandingkan dengan versi ini. Kalau lebih baru,
# ringkasan perubahannya diambil dari pesan commit yang menaikkan VERSION. Semua jaringan berjalan di
# runspace latar belakang, jadi island tidak pernah tersendat.
# Versi baru muncul sebagai pop-up sekali, lalu tetap ada di daftar notifikasi sampai diklik (= pasang
# update) atau dihapus (= lewati versi itu).
$REPO_RAW = 'https://raw.githubusercontent.com/nkzwsn/mini-island-windows'
$REPO_API = 'https://api.github.com/repos/nkzwsn/mini-island-windows'
$REPO_ZIP = 'https://github.com/nkzwsn/mini-island-windows/archive/refs/heads/main.zip'
$UPDATE_ID = [uint32]4100000000
$script:islandItems = @()       # item daftar notifikasi milik island sendiri (update)
$script:updateJob = $null
$script:lastUpdateCheck = [DateTime]::MinValue

function Start-BgJob([scriptblock]$Script, [object[]]$Arguments) {
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Script)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    @{ PS = $ps; Handle = $ps.BeginInvoke() }
}
# Hasil job (hashtable) kalau sudah selesai, $null kalau belum
function Receive-BgJob($job) {
    if (-not $job -or -not $job.Handle.IsCompleted) { return $null }
    try { $r = @($job.PS.EndInvoke($job.Handle)); if ($r.Count) { $r[-1] } else { @{ Error = 'no result' } } }
    catch { @{ Error = "$_" } }
    finally { $job.PS.Dispose() }
}

$UPDATE_CHECK_JOB = {
    param($cur, $raw, $api)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        function Get-Text($url) {
            $wc = New-Object System.Net.WebClient
            $wc.Headers['User-Agent'] = 'MiniIsland'; $wc.Encoding = [Text.Encoding]::UTF8
            try { $wc.DownloadString($url) } finally { $wc.Dispose() }
        }
        $latest = (Get-Text "$raw/main/VERSION?t=$([DateTime]::UtcNow.Ticks)").Trim()
        $notes = @()
        if ([version]$latest -gt [version]$cur) {
            # Commit yang mengubah VERSION, terbaru dulu; berhenti di versi yang sedang dipakai
            # (disimpan dulu ke variabel: ConvertFrom-Json di PowerShell 5.1 tidak memecah array lewat pipa).
            # Daftar perubahan hanya pelengkap: kalau gagal diambil (mis. batas API GitHub), update tetap ditawarkan.
            try {
                $commits = ConvertFrom-Json (Get-Text "$api/commits?path=VERSION&per_page=15")
                foreach ($c in $commits) {
                    $v = (Get-Text "$raw/$($c.sha)/VERSION").Trim()
                    if ([version]$v -le [version]$cur) { break }
                    $notes += (($c.commit.message -split "`n")[0]).Trim()
                }
            } catch {}
        }
        @{ Latest = $latest; Notes = $notes }
    } catch { @{ Error = "$_" } }
}

function Start-UpdateCheck([switch]$Manual) {
    # Cek otomatis masih berjalan: cukup tandai sebagai manual supaya hasilnya tetap ditampilkan
    if ($script:updateJob) { if ($Manual) { $script:updateJob.Manual = $true }; return }
    $script:lastUpdateCheck = Get-Date
    $script:updateJob = Start-BgJob $UPDATE_CHECK_JOB @($APP_VERSION, $REPO_RAW, $REPO_API)
    $script:updateJob.Manual = [bool]$Manual
}

function Check-Update {
    if ($script:settings.CheckUpdates -and ((Get-Date) - $script:lastUpdateCheck).TotalHours -ge 24) { Start-UpdateCheck }
    $j = $script:updateJob
    if (-not $j) { return }
    $r = Receive-BgJob $j
    if (-not $r) { return }
    $script:updateJob = $null
    if ($r.Error) {
        Log "update: $($r.Error)"
        if ($j.Manual) { Show-Info (T 'Gagal mengecek update' 'Could not check for updates') }
        return
    }
    $newer = $false
    try { $newer = [version]$r.Latest -gt [version]$APP_VERSION } catch { Log "update version: $($r.Latest)" }
    if ($newer -and ($j.Manual -or $script:settings.SkipVersion -ne $r.Latest)) {
        Show-UpdateAvailable $r.Latest @($r.Notes) -Popup:($j.Manual -or $script:settings.NotifiedVersion -ne $r.Latest)
    } elseif ($j.Manual) { Show-Info (T "Sudah versi terbaru (v$APP_VERSION)" "You're up to date (v$APP_VERSION)") }
}

# Ikon Mini Island untuk item update: pil putih di kotak biru membulat
function New-IslandLogo {
    $dv = New-Object System.Windows.Media.DrawingVisual
    $dc = $dv.RenderOpen()
    $dc.DrawRoundedRectangle((New-Object System.Windows.Media.SolidColorBrush((Rgb 10 132 255))), $null, (New-Object System.Windows.Rect(0, 0, 64, 64)), 16, 16)
    $dc.DrawRoundedRectangle([System.Windows.Media.Brushes]::White, $null, (New-Object System.Windows.Rect(12, 25, 40, 14)), 7, 7)
    $dc.Close()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($dv); $bmp.Freeze()
    $bmp
}

# Item "Update tersedia" di daftar notifikasi (pop-up hanya sekali per versi)
function Show-UpdateAvailable($latest, $notes = @(), [switch]$Popup) {
    $dot = '  ' + [char]0x00B7 + '  '
    $click = T 'Klik untuk memasang' 'Click to install'
    $body = if (@($notes).Count) { ((@($notes) | Select-Object -First 4) -join $dot) + $dot + $click } else { $click }
    if (-not $script:islandLogo) { $script:islandLogo = New-IslandLogo }
    $item = [PSCustomObject]@{
        Id = $UPDATE_ID; App = 'Mini Island'; Aumid = ''; Kind = 'update'; Version = $latest
        Title = (T "Update tersedia: v$latest" "Update available: v$latest"); Body = $body
        Time = (Get-Date); Icon = $script:islandLogo; Photo = $null; Accent = (Rgb 10 132 255)
    }
    $script:islandItems = @($item)
    Merge-Recent
    if ($Popup) {
        $script:settings.NotifiedVersion = $latest; Save-Settings
        Enqueue-Notif $item
        if ($script:mode -eq 'idle') { Process-Queue }
    }
    if ($script:mode -eq 'list') { Show-List -Refresh }
}

# Daftar notifikasi = notifikasi Windows + item island sendiri, terbaru di atas
function Merge-Recent {
    $script:recent = @(@($notifCache.Values) + @($script:islandItems) | Where-Object { $_ } | Sort-Object Time -Descending)
}

# Item island dihapus dari daftar: versi itu dilewati (tidak ditawarkan lagi)
function Remove-IslandItem($id) {
    $it = @($script:islandItems | Where-Object { $_.Id -eq $id })
    if (-not $it.Count) { return $false }
    if ($it[0].Kind -eq 'update') { $script:settings.SkipVersion = $it[0].Version; Save-Settings }
    $script:islandItems = @($script:islandItems | Where-Object { $_.Id -ne $id })
    Merge-Recent
    $true
}

# ---------- Update sekali klik ----------
# Unduh ZIP repo, cek isinya (versi terbaca, skrip bisa di-parse), salin file aplikasi ke folder island
# (cadangan island.ps1 lama disimpan sebagai island.ps1.bak), lalu island keluar dengan kode 3 supaya
# launcher menjalankan versi baru. Pengaturan, lirik tersimpan dan cache tidak disentuh.
$UPDATE_DOWNLOAD_JOB = {
    param($zipUrl)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $tmp = Join-Path $env:TEMP ('MiniIslandUpdate-' + [guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $tmp)
        $zip = Join-Path $tmp 'update.zip'
        $wc = New-Object System.Net.WebClient
        $wc.Headers['User-Agent'] = 'MiniIsland'
        try { $wc.DownloadFile($zipUrl, $zip) } finally { $wc.Dispose() }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, (Join-Path $tmp 'x'))
        $src = Get-ChildItem (Join-Path $tmp 'x') -Directory | Select-Object -First 1
        $file = Join-Path $src.FullName 'island.ps1'
        $text = [IO.File]::ReadAllText($file)
        if ($text -notmatch "APP_VERSION = '([0-9.]+)'") { throw 'versi tidak terbaca' }
        $ver = $Matches[1]
        # Diperiksa persis seperti powershell -File akan membacanya: file tanpa BOM dibaca sebagai ANSI, jadi
        # satu huruf non-ASCII saja bisa membuat skrip gagal jalan walau lolos kalau dibaca sebagai UTF-8
        if ([Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($file)) -match '[^\x00-\x7F]') { throw 'skrip berisi karakter non-ASCII' }
        $tokens = $null; $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errs)
        if (@($errs).Count) { throw "skrip rusak: $($errs[0].Message)" }
        @{ Dir = $src.FullName; Version = $ver; Tmp = $tmp }
    } catch {
        # Unduhan gagal / rusak: folder sementaranya tidak ditinggalkan
        if ($tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
        @{ Error = "$_" }
    }
}

function Start-SelfUpdate {
    if ($script:selfUpdateJob) { return }
    $script:selfUpdateJob = Start-BgJob $UPDATE_DOWNLOAD_JOB @($REPO_ZIP)
    $updateTimer.Start()
    Show-Info (T 'Mengunduh update...' 'Downloading update...') 60000
}

$updateTimer = New-Object System.Windows.Threading.DispatcherTimer
$updateTimer.Interval = Ms 300
$updateTimer.Add_Tick({
    $r = Receive-BgJob $script:selfUpdateJob
    if (-not $r) { return }
    $updateTimer.Stop(); $script:selfUpdateJob = $null
    if ($r.Error) {
        Log "self-update: $($r.Error)"
        Show-Info (T 'Update gagal, coba lagi nanti' 'Update failed, try again later')
        return
    }
    try {
        if ([version]$r.Version -le [version]$APP_VERSION) { Show-Info (T "Sudah versi terbaru (v$APP_VERSION)" "You're up to date (v$APP_VERSION)"); return }
        $self = Join-Path $here 'island.ps1'
        Copy-Item $self (Join-Path $here 'island.ps1.bak') -Force
        Copy-Item (Join-Path $r.Dir 'island.ps1') $self -Force
        # File lain hanya diperbarui kalau memang ada di folder ini (folder instalasi biasa)
        foreach ($f in 'Start Island.vbs', 'uninstall.ps1', 'Uninstall.cmd') {
            $dst = Join-Path $here $f
            if ((Test-Path $dst) -and (Test-Path (Join-Path $r.Dir $f))) { Copy-Item (Join-Path $r.Dir $f) $dst -Force }
        }
        Log "self-update: $APP_VERSION -> $($r.Version)"
        $script:restartCode = 3
        Show-Info (T "Memasang v$($r.Version)..." "Installing v$($r.Version)...") 60000
        $restartTimer.Start()
    } catch {
        Log "self-update apply: $_"
        Show-Info (T 'Update gagal, coba lagi nanti' 'Update failed, try again later')
    } finally {
        Remove-Item $r.Tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
})
# Keluar dengan kode bukan 0: launcher menjalankan island lagi (sekarang versi baru)
$restartTimer = New-Object System.Windows.Threading.DispatcherTimer
$restartTimer.Interval = Ms 1200
$restartTimer.Add_Tick({ $restartTimer.Stop(); Exit-Island })

# Klik pada pil aktivitas
function Click-Activity {
    $a = $script:activity
    if (-not $a -or -not $a.Click) { return }
    switch ($a.Click) {
        'repo' { try { Start-Process $REPO_URL } catch { Log "open repo: $_" } }
    }
    End-Activity
}

# ---------- Menu klik kanan (pengaturan) ----------
# Tema gelap seperti tooltip; isi menu dibangun ulang setiap dibuka supaya centang & bahasa selalu baru
$MENU_XAML = @'
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <LinearGradientBrush x:Key="MenuBg" StartPoint="0,0" EndPoint="0,1">
    <GradientStop Color="#F4222226" Offset="0"/>
    <GradientStop Color="#F4141416" Offset="1"/>
  </LinearGradientBrush>
  <LinearGradientBrush x:Key="MenuEdge" StartPoint="0,0" EndPoint="0,1">
    <GradientStop Color="#6EFFFFFF" Offset="0"/>
    <GradientStop Color="#18FFFFFF" Offset="0.5"/>
    <GradientStop Color="#2EFFFFFF" Offset="1"/>
  </LinearGradientBrush>
  <Style TargetType="ContextMenu">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="HasDropShadow" Value="False"/>
    <Setter Property="Foreground" Value="#F2FFFFFF"/>
    <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
    <Setter Property="FontSize" Value="12"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="ContextMenu">
          <Border CornerRadius="12" Padding="0,5" BorderThickness="1" MinWidth="210"
                  Background="{StaticResource MenuBg}" BorderBrush="{StaticResource MenuEdge}">
            <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
          </Border>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style TargetType="MenuItem">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
    <Setter Property="Foreground" Value="#F2FFFFFF"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="MenuItem">
          <Border x:Name="Bd" Background="Transparent" CornerRadius="7" Padding="8,5,10,5" Margin="5,0">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="20"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <TextBlock x:Name="Check" Text="&#xE73E;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="10"
                         VerticalAlignment="Center" Visibility="Hidden"/>
              <ContentPresenter Grid.Column="1" ContentSource="Header" RecognizesAccessKey="False" VerticalAlignment="Center"/>
              <TextBlock x:Name="Arrow" Grid.Column="2" Text="&#xE76C;" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets"
                         FontSize="8" Margin="14,0,0,0" VerticalAlignment="Center" Visibility="Collapsed" Opacity="0.7"/>
              <Popup x:Name="PART_Popup" Placement="Right" HorizontalOffset="6" VerticalOffset="-6" AllowsTransparency="True"
                     Focusable="False" PopupAnimation="Fade"
                     IsOpen="{Binding IsSubmenuOpen, RelativeSource={RelativeSource TemplatedParent}}">
                <Border CornerRadius="12" Padding="0,5" BorderThickness="1" MinWidth="170"
                        Background="{StaticResource MenuBg}" BorderBrush="{StaticResource MenuEdge}">
                  <StackPanel IsItemsHost="True" KeyboardNavigation.DirectionalNavigation="Cycle"/>
                </Border>
              </Popup>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#2AFFFFFF"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="Check" Property="Visibility" Value="Visible"/></Trigger>
            <Trigger Property="HasItems" Value="True"><Setter TargetName="Arrow" Property="Visibility" Value="Visible"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
  <Style x:Key="{x:Static MenuItem.SeparatorStyleKey}" TargetType="Separator">
    <Setter Property="OverridesDefaultStyle" Value="True"/>
    <Setter Property="Template">
      <Setter.Value>
        <ControlTemplate TargetType="Separator"><Border Height="1" Margin="12,4" Background="#22FFFFFF"/></ControlTemplate>
      </Setter.Value>
    </Setter>
  </Style>
</ResourceDictionary>
'@

function New-MI($header, $tag = $null, $onClick = $null, [switch]$Check, [bool]$Checked = $false, [switch]$Stay, [switch]$Disabled) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $header; $mi.Tag = $tag
    if ($Check) { $mi.IsCheckable = $false; $mi.IsChecked = $Checked }
    if ($Disabled) { $mi.IsEnabled = $false }
    if ($onClick) {
        # WPF menutup menu seketika setelah item diklik; menu ditutup sendiri supaya bisa memudar
        $mi.StaysOpenOnClick = $true
        $mi.Add_Click($onClick)
        if (-not $Stay) { $mi.Add_Click({ Close-Menu }) }
    }
    $mi
}
function Add-MI($parent, $item) { [void]$parent.Items.Add($item); $item }
function Add-Sep($parent) { [void]$parent.Items.Add((New-Object System.Windows.Controls.Separator)) }

function Format-Delay($d) {
    if ([Math]::Abs($d) -lt 0.05) { T 'pas' '0 s' }
    elseif ($d -gt 0) { T "$(Fmt '+{0:0.0#}' $d) dtk" "$(Fmt '+{0:0.0#}' $d) s" }
    else { T "$(Fmt '{0:0.0#}' $d) dtk" "$(Fmt '{0:0.0#}' $d) s" }
}

# Opsi nyala/mati: Tag = nama pengaturan
$onToggle = {
    param($s, $e)
    $name = $s.Tag
    $script:settings.$name = -not $script:settings.$name
    Save-Settings
    switch ($name) {
        'Lyrics' {
            if ($script:settings.Lyrics) { Request-Lyrics }
            $script:lyricIdx = -2
            if ($script:mode -eq 'list') { Update-PageDots } else { Refresh-MediaView }
        }
        'Romaji' { $script:lyricIdx = -2; if ($script:mode -eq 'list') { Show-List -Refresh } }
        'Furigana' { $script:lyricIdx = -2; if ($script:mode -eq 'list') { Show-List -Refresh } }
        'MicCam' { Check-Sensors }
        'AppVolume' { Update-VolumeUI }
        'Glow' {
            $showing = $script:mode -eq 'media' -or ($script:mode -eq 'idle' -and $script:miniOn -and $script:miniKey -ne 'clock') -or ($script:mode -eq 'list' -and $script:listPage -ne 'notif')
            if ($script:media -and $showing) { Set-Theme $script:media.Accent }
        }
    }
}

function Build-Menu {
    $menu.Items.Clear()
    [void](Add-MI $menu (New-MI "Mini Island v$APP_VERSION" -Disabled))
    Add-Sep $menu
    [void](Add-MI $menu (New-MI (T 'Lirik' 'Lyrics') 'Lyrics' $onToggle -Check -Checked $script:settings.Lyrics))
    [void](Add-MI $menu (New-MI (T 'Furigana untuk lirik Jepang' 'Furigana for Japanese lyrics') 'Furigana' $onToggle -Check -Checked $script:settings.Furigana))
    [void](Add-MI $menu (New-MI (T 'Romaji untuk lirik Jepang' 'Romaji for Japanese lyrics') 'Romaji' $onToggle -Check -Checked $script:settings.Romaji))
    $tm = Add-MI $menu (New-MI ((T 'Timing lirik (semua lagu): ' 'Lyric timing (all songs): ') + (Format-Delay $script:settings.LyricDelay)))
    $shift = {
        param($s, $e)
        $d = if ($s.Tag -eq 0) { 0.15 } else { [Math]::Round($script:settings.LyricDelay + $s.Tag, 1) }
        $script:settings.LyricDelay = [Math]::Max(-3.0, [Math]::Min(3.0, $d))
        $script:lyricIdx = -2
        Save-Settings
        $s.Parent.Header = (T 'Timing lirik (semua lagu): ' 'Lyric timing (all songs): ') + (Format-Delay $script:settings.LyricDelay)
    }
    [void](Add-MI $tm (New-MI (T 'Lebih awal 0,1 dtk' '0.1 s earlier') (-0.1) $shift -Stay))
    [void](Add-MI $tm (New-MI (T 'Lebih lambat 0,1 dtk' '0.1 s later') 0.1 $shift -Stay))
    [void](Add-MI $tm (New-MI (T 'Kembalikan ke bawaan' 'Reset to default') 0 $shift -Stay))
    Add-Sep $menu

    $cm = Add-MI $menu (New-MI 'Timer')
    $startTimer = { param($s, $e) Start-Countdown $s.Tag }
    foreach ($min in 1, 3, 5, 10, 15, 25, 30, 60) {
        [void](Add-MI $cm (New-MI $(if ($min -eq 1) { T '1 menit' '1 minute' } else { T "$min menit" "$min minutes" }) $min $startTimer))
    }
    Add-Sep $cm
    [void](Add-MI $cm (New-MI 'Stopwatch' $null { Start-Stopwatch }))
    if ($script:clock) {
        Add-Sep $cm
        $label = if ($script:clock.Running) { T 'Jeda' 'Pause' } else { T 'Lanjutkan' 'Resume' }
        [void](Add-MI $cm (New-MI $label $null { Toggle-Clock }))
        [void](Add-MI $cm (New-MI (T 'Hentikan' 'Stop') $null { Stop-Clock }))
    }
    Add-Sep $menu

    [void](Add-MI $menu (New-MI (T 'Volume musik: aplikasi pemutarnya saja' 'Music volume: player app only') 'AppVolume' $onToggle -Check -Checked $script:settings.AppVolume))
    $sm = Add-MI $menu (New-MI (T 'Tampilkan' 'Show'))
    [void](Add-MI $sm (New-MI (T 'Perubahan volume & kecerahan' 'Volume & brightness changes') 'VolumeOsd' $onToggle -Check -Checked $script:settings.VolumeOsd))
    [void](Add-MI $sm (New-MI (T 'Mengisi daya & baterai lemah' 'Charging & low battery') 'Charging' $onToggle -Check -Checked $script:settings.Charging))
    [void](Add-MI $sm (New-MI (T 'Mikrofon / kamera sedang dipakai' 'Microphone / camera in use') 'MicCam' $onToggle -Check -Checked $script:settings.MicCam))
    [void](Add-MI $sm (New-MI (T 'Headset Bluetooth tersambung' 'Bluetooth headset connected') 'Headset' $onToggle -Check -Checked $script:settings.Headset))
    [void](Add-MI $sm (New-MI (T 'Cahaya warna album' 'Album color glow') 'Glow' $onToggle -Check -Checked $script:settings.Glow))
    $screens = @([System.Windows.Forms.Screen]::AllScreens)
    if ($screens.Count -gt 1) {
        $mm = Add-MI $menu (New-MI 'Monitor')
        $cur = (Get-IslandScreen).DeviceName
        $pickScreen = {
            param($s, $e)
            $script:settings.Monitor = $s.Tag
            Save-Settings
            Update-Position
            Update-AnimFps
        }
        $i = 1
        foreach ($sc in $screens) {
            $name = "Monitor $i ($($sc.Bounds.Width)x$($sc.Bounds.Height))"
            if ($sc.Primary) { $name += T ', utama' ', main' }
            $tag = if ($sc.Primary) { '' } else { $sc.DeviceName }
            [void](Add-MI $mm (New-MI $name $tag $pickScreen -Check -Checked ($sc.DeviceName -eq $cur)))
            $i++
        }
    }
    $lm = Add-MI $menu (New-MI (T 'Bahasa' 'Language'))
    $pickLang = {
        param($s, $e)
        $script:settings.Language = $s.Tag
        Save-Settings
        Refresh-MediaView
        Check-Sensors
    }
    [void](Add-MI $lm (New-MI 'English' 'en' $pickLang -Check -Checked ($script:settings.Language -eq 'en')))
    [void](Add-MI $lm (New-MI 'Bahasa Indonesia' 'id' $pickLang -Check -Checked ($script:settings.Language -eq 'id')))
    Add-Sep $menu
    [void](Add-MI $menu (New-MI (T 'Cek update' 'Check for updates') $null { Start-UpdateCheck -Manual }))
    [void](Add-MI $menu (New-MI (T 'Muat ulang Island' 'Restart Island') $null { $script:restartCode = 3; Exit-Island }))
    [void](Add-MI $menu (New-MI (T 'Keluar dari Island' 'Quit Island') $null { Exit-Island }))
}

# ---------- Timer & event ----------
$dismissTimer = New-Object System.Windows.Threading.DispatcherTimer
$dismissTimer.Add_Tick({
    $dismissTimer.Stop()
    # Jangan ganti/tutup pop-up selagi sedang ditarik / slider volume sedang digeser
    if ($script:rowDragging -or [System.Windows.Input.Mouse]::Captured) { $dismissTimer.Start(); return }
    $n = Next-Queued
    if ($n) { Show-Notif $n } else { Go-Idle }
})

# Memori: sampah .NET dibersihkan (termasuk objek besar) lalu halaman yang tidak terpakai dikembalikan ke Windows.
# Hanya saat island tersembunyi, dan sekali setelah mulai (sisa kompilasi & pembuatan jendela); saat tampil
# memorinya memang sedang dipakai. Task Manager turun dari ~130 MB ke ~20 MB, yang dibutuhkan lagi dimuat ulang
# sendiri. Tanpa WaitForPendingFinalizers: di thread UI (STA) dengan banyak objek COM itu bisa tersendat.
$script:lastCompact = [DateTime]::MinValue
function Compact-Memory {
    if (([DateTime]::UtcNow - $script:lastCompact).TotalSeconds -lt 60) { return }
    $script:lastCompact = [DateTime]::UtcNow
    [System.Runtime.GCSettings]::LargeObjectHeapCompactionMode = [System.Runtime.GCLargeObjectHeapCompactionMode]::CompactOnce
    [GC]::Collect(2, [GCCollectionMode]::Forced, $true, $true)
    try { [IslandNative]::TrimMemory() } catch { Log "trim: $_" }
}
$memTimer = New-Object System.Windows.Threading.DispatcherTimer
$memTimer.Interval = [TimeSpan]::FromSeconds(15)
$memTimer.Add_Tick({ $memTimer.Stop(); try { Compact-Memory } catch { Log "memory: $_" } })

# Setelah island tersembunyi, buang isinya supaya animasi (equalizer) tidak terus berjalan di latar
$cleanupTimer = New-Object System.Windows.Threading.DispatcherTimer
$cleanupTimer.Interval = Ms 700
$cleanupTimer.Add_Tick({
    $cleanupTimer.Stop()
    if ($script:mode -eq 'idle') {
        $mediaView.Child = $null; $listPanel.Children.Clear(); $nIconHost.Child = $null
        $script:volUI = $null; $script:progressBars = @()
    }
    # Mini island tersembunyi (tidak ada lirik) juga dikosongkan supaya equalizer-nya tidak jalan di latar
    if (-not $script:miniOn -or -not $script:miniVisible) { $views['MiniView'].Children.Clear() }
    # Island benar-benar tersembunyi: memori yang tidak terpakai dikembalikan
    if ($script:mode -eq 'idle' -and -not $script:miniOn) { try { Compact-Memory } catch { Log "memory: $_" } }
})

# Waktu lagu berjalan diperbarui tiap detik, hanya selama tampilan musik terbuka
$progressClock = New-Object System.Windows.Threading.DispatcherTimer
$progressClock.Interval = Ms 1000
$progressClock.Add_Tick({
    if ((@($script:progressBars).Count -eq 0 -and -not $script:volUI) -or ($script:mode -ne 'media' -and $script:mode -ne 'list')) {
        $progressClock.Stop(); return
    }
    foreach ($pb in $script:progressBars) { Update-ProgressTime $pb }
    # Slider ikut berubah kalau volume diatur dari keyboard/taskbar
    Update-VolumeUI
})

# Konfirmasi "Hapus semua" kedaluwarsa setelah 3 detik
$confirmTimer = New-Object System.Windows.Threading.DispatcherTimer
$confirmTimer.Interval = Ms 3000
$confirmTimer.Add_Tick({
    $confirmTimer.Stop()
    $script:confirmClear = $false
    if ($script:mode -eq 'list') { Show-List -Refresh }
})

$hoverTimer = New-Object System.Windows.Threading.DispatcherTimer
$hoverTimer.Interval = Ms 300
$hoverTimer.Add_Tick({
    $hoverTimer.Stop()
    if ($script:overHot -and $script:mode -eq 'idle') {
        try { Show-List } catch { Log "show-list: $_ | $($_.ScriptStackTrace -replace '\s+', ' ')" }
    }
})

# Menutup daftar kalau kursor sudah tidak di HotZone maupun di island
$closeTimer = New-Object System.Windows.Threading.DispatcherTimer
$closeTimer.Interval = Ms 350
$closeTimer.Add_Tick({
    $closeTimer.Stop()
    # Jangan tutup daftar selagi baris sedang ditarik (kursor boleh keluar dari island)
    if ($script:rowDragging -or [System.Windows.Input.Mouse]::Captured) { $closeTimer.Start(); return }
    if ($script:mode -eq 'list' -and -not $script:hovering -and -not $script:overHot -and -not $script:listPinned) { Go-Idle }
})

$hotZone.Add_MouseEnter({
    $script:overHot = $true
    Animate $handle ([System.Windows.FrameworkElement]::WidthProperty) 64 200
    Animate $handle ([System.Windows.UIElement]::OpacityProperty) 1 200
    $closeTimer.Stop()
    if ($script:mode -eq 'idle') { $hoverTimer.Start() }
})
$hotZone.Add_MouseLeave({
    $script:overHot = $false
    Animate $handle ([System.Windows.FrameworkElement]::WidthProperty) 40 200
    # Selama mini island tampil, penanda disembunyikan
    $rest = if ($script:miniOn -and $script:miniVisible -and $script:mode -eq 'idle') { 0 } else { 0.55 }
    Animate $handle ([System.Windows.UIElement]::OpacityProperty) $rest 200
    $hoverTimer.Stop()
    if ($script:mode -eq 'list') { $closeTimer.Start() }
})

$pollTimer = New-Object System.Windows.Threading.DispatcherTimer
$pollTimer.Interval = Ms 1000
$script:pollCount = 0
$pollTimer.Add_Tick({
    $script:pollCount++
    # Tiap langkah dijaga sendiri: error di satu bagian tidak boleh menghentikan sisanya
    try { Update-Position } catch { Log "position: $_" }
    try { Update-ZOrder } catch { Log "zorder: $_" }
    try { Poll } catch { Log "poll tick: $_" }
    try { Prune-Anims } catch { Log "anims: $_" }
    try { Check-Sensors } catch { Log "sensors: $_" }
    try { Check-Power } catch { Log "power: $_" }
    try { Check-Update } catch { Log "update: $_" }
    # Output audio bisa pindah (headset dicolok): pantau perangkat yang baru
    if ($script:volWatcher -and ($script:pollCount % 3) -eq 0) {
        try { $script:volWatcher.Check() } catch { Log "volume watcher: $_" }
        try { Check-AudioDevice } catch { Log "headset: $_" }
    }
})

# Island selalu di atas aplikasi lain, kecuali saat aplikasi fullscreen di depan:
# island turun ke belakang dan pop-up ditahan (notifikasinya tetap ada di daftar)
$script:fullscreen = $false
function Update-ZOrder {
    if (-not $script:hwnd) { return }
    $fs = $false
    try { $fs = [IslandNative]::ForegroundIsFullscreen($script:hwnd) } catch { Log "fullscreen: $_" }
    if ($fs -ne $script:fullscreen) {
        $script:fullscreen = $fs
        if ($fs -and $script:mode -ne 'idle' -and -not $script:rowDragging) { Go-Idle }
        else { Update-Mini }
    }
    # Dipasang ulang tiap detik: jendela topmost lain bisa saja naik menutupi island.
    # Kecuali saat menu klik kanan / tooltip island sendiri terbuka: island akan menutupinya.
    if ($fs) { [IslandNative]::SetTop($script:hwnd, $false) }
    elseif (-not $menu.IsOpen -and -not $script:hovering) { [IslandNative]::SetTop($script:hwnd, $true) }
}

# Potong isi island mengikuti sudut membulat (ClipToBounds hanya memotong kotak)
$island.Add_SizeChanged({
    $r = [Math]::Max(0.0, $island.CornerRadius.TopLeft - 1)
    $w = [Math]::Max(0.0, $island.ActualWidth - 2); $h = [Math]::Max(0.0, $island.ActualHeight - 2)
    $islandContent.Clip = New-Object System.Windows.Media.RectangleGeometry((New-Object System.Windows.Rect(0, 0, $w, $h)), $r, $r)
})

$island.Add_MouseEnter({
    $script:hovering = $true
    $hoverWatch.Start()
    $closeTimer.Stop()
    if ($script:mode -eq 'notif') { $dismissTimer.Stop(); Set-NotifExpanded $true }
    elseif ($script:mode -eq 'media') { $dismissTimer.Stop() }
    elseif ($script:mode -eq 'activity') { $activityTimer.Stop() }
})
$island.Add_MouseLeave({ On-IslandLeave })
function On-IslandLeave {
    $script:hovering = $false
    $hoverWatch.Stop()
    if ($script:mode -eq 'notif') { Set-NotifExpanded $false; $dismissTimer.Interval = Ms 2000; $dismissTimer.Start() }
    elseif ($script:mode -eq 'media') { $dismissTimer.Interval = Ms 2000; $dismissTimer.Start() }
    elseif ($script:mode -eq 'list') { $closeTimer.Start() }
    elseif ($script:mode -eq 'activity') {
        # Timer selesai tetap tampil cukup lama supaya terlihat
        $activityTimer.Interval = Ms $(if ($script:activity -and $script:activity.Kind -eq 'timerdone') { 5000 } else { 1500 })
        $activityTimer.Start()
    }
}

# WPF kadang tidak mengirim MouseLeave (mis. setelah tombol di island diklik), sehingga island mengira
# kursor masih di atasnya dan tidak pernah menutup. Selama kursor dianggap di atas island, posisinya
# dicek sendiri; kalau ternyata sudah di luar, diperlakukan seperti MouseLeave biasa.
$hoverWatch = New-Object System.Windows.Threading.DispatcherTimer
$hoverWatch.Interval = Ms 250
$hoverWatch.Add_Tick({
    if (-not $script:hovering) { $hoverWatch.Stop(); return }
    if ($menu.IsOpen -or [IslandNative]::MouseDown()) { return }
    try {
        $p = [IslandNative]::CursorPos()
        $q = $island.PointFromScreen((New-Object System.Windows.Point($p[0], $p[1])))
        $inside = $q.X -ge -2 -and $q.Y -ge -10 -and $q.X -le $island.ActualWidth + 2 -and $q.Y -le $island.ActualHeight + 2
    } catch { $inside = $true }
    if (-not $inside) {
        # Tangkapan mouse yang tertinggal (tombol mouse sudah dilepas) juga dilepas
        if ([System.Windows.Input.Mouse]::Captured) { [void][System.Windows.Input.Mouse]::Capture($null) }
        On-IslandLeave
    }
})
$island.Add_MouseLeftButtonUp({
    if ($script:mode -eq 'notif' -and $script:current) { Open-Notif $script:current; Go-Idle }
    elseif ($script:mode -eq 'activity') { Click-Activity }
})

# Menu klik kanan: di island yang terbuka maupun di garis penanda di atasnya (island diam / mini island)
$menu = New-Object System.Windows.Controls.ContextMenu
try { $menu.Resources = [Windows.Markup.XamlReader]::Parse($MENU_XAML) } catch { Log "menu style: $_" }
# Island tidak pernah jadi jendela aktif (supaya tidak mencuri fokus), sehingga WPF tidak tahu saat
# pengguna mengklik di luar menu. Selama menu terbuka, klik di luar menu (dan submenunya) dipantau
# sendiri; menu juga ditutup kalau pengguna pindah ke aplikasi lain.
# Kotak menu yang sedang tampil: menu utama + submenu yang terbuka
function Get-MenuBoxes {
    $boxes = New-Object System.Collections.Generic.List[object]
    $boxes.Add($menu)
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($menu)
    while ($stack.Count) {
        foreach ($it in $stack.Pop().Items) {
            if ($it -isnot [System.Windows.Controls.MenuItem] -or -not $it.IsSubmenuOpen) { continue }
            $pp = $it.Template.FindName('PART_Popup', $it)
            if ($pp -and $pp.Child) { $boxes.Add($pp.Child) }
            $stack.Push($it)
        }
    }
    , $boxes
}
function Test-OverMenu {
    $p = [IslandNative]::CursorPos()
    foreach ($el in (Get-MenuBoxes)) {
        try {
            if (-not [System.Windows.PresentationSource]::FromVisual($el)) { continue }
            $tl = $el.PointToScreen((New-Object System.Windows.Point(0, 0)))
            $br = $el.PointToScreen((New-Object System.Windows.Point($el.ActualWidth, $el.ActualHeight)))
            if ($p[0] -ge $tl.X -and $p[0] -le $br.X -and $p[1] -ge $tl.Y -and $p[1] -le $br.Y) { return $true }
        } catch {}
    }
    $false
}
$menuWatch = New-Object System.Windows.Threading.DispatcherTimer
$menuWatch.Interval = Ms 40
$menuWatch.Add_Tick({
    if (-not $menu.IsOpen) { $menuWatch.Stop(); return }
    $down = [IslandNative]::MouseDown()
    # Hanya tekanan baru (klik kanan yang membuka menu belum tentu sudah dilepas)
    $press = $down -and -not $script:menuWasDown
    $script:menuWasDown = $down
    if (($press -and -not (Test-OverMenu)) -or [IslandNative]::Foreground() -ne $script:menuFg) { Close-Menu }
})

# Menu (dan submenunya) memudar sambil sedikit naik, baru ditutup
$script:menuFading = @()
$menuCloseTimer = New-Object System.Windows.Threading.DispatcherTimer
$menuCloseTimer.Interval = Ms 220
$menuCloseTimer.Add_Tick({ $menuCloseTimer.Stop(); $menu.IsOpen = $false })
function Close-Menu {
    if (-not $menu.IsOpen -or $menuCloseTimer.IsEnabled) { return }
    $menuWatch.Stop()
    $script:menuFading = (Get-MenuBoxes).ToArray()
    foreach ($el in $script:menuFading) {
        $tt = New-Object System.Windows.Media.TranslateTransform
        $el.RenderTransform = $tt
        Animate60 $el ([System.Windows.UIElement]::OpacityProperty) 1 0 210
        Animate60 $tt ([System.Windows.Media.TranslateTransform]::YProperty) 0 -6 220
    }
    $menuCloseTimer.Start()
}
$menu.Add_Opened({
    $hoverTimer.Stop()
    $script:menuWasDown = $true
    $script:menuFg = [IslandNative]::Foreground()
    $menuWatch.Start()
})
$menu.Add_Closed({
    $menuWatch.Stop(); $menuCloseTimer.Stop()
    # Siap tampil normal lagi saat dibuka berikutnya
    foreach ($el in $script:menuFading) {
        $el.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $el.Opacity = 1
        $el.RenderTransform = [System.Windows.Media.Transform]::Identity
    }
    $script:menuFading = @()
})
Build-Menu
foreach ($el in $island, $hotZone) {
    $el.ContextMenu = $menu
    $el.Add_ContextMenuOpening({ Build-Menu })
}

# Penanda muncul turun dari atas sambil melebar saat island baru jalan
$handle.RenderTransform = New-Object System.Windows.Media.TranslateTransform(0, -12)
function Show-Intro {
    Animate $handle.RenderTransform ([System.Windows.Media.TranslateTransform]::YProperty) 0 520 250 $null $true
    Animate $handle ([System.Windows.UIElement]::OpacityProperty) 0.55 420 250
    Animate $handle ([System.Windows.FrameworkElement]::WidthProperty) 40 560 330 $null $true
}

# Keluar: island & penanda naik ke atas sambil memudar, baru jendelanya ditutup
$script:exiting = $false
$exitTimer = New-Object System.Windows.Threading.DispatcherTimer
$exitTimer.Interval = Ms 520
$exitTimer.Add_Tick({ $exitTimer.Stop(); $window.Close() })
function Exit-Island {
    if ($script:exiting) { return }
    $script:exiting = $true
    $pollTimer.Stop(); $dismissTimer.Stop(); $closeTimer.Stop(); $hoverTimer.Stop(); $miniTimer.Stop(); $activityTimer.Stop()
    $island.IsHitTestVisible = $false; $hotZone.IsHitTestVisible = $false
    Animate $bubble ([System.Windows.UIElement]::OpacityProperty) 0 300
    Animate $sensorDots ([System.Windows.UIElement]::OpacityProperty) 0 300
    $up = New-Object System.Windows.Media.TranslateTransform
    $island.RenderTransform = $up
    Animate $up ([System.Windows.Media.TranslateTransform]::YProperty) -24 440
    Animate $island ([System.Windows.UIElement]::OpacityProperty) 0 400
    Animate $handle.RenderTransform ([System.Windows.Media.TranslateTransform]::YProperty) -12 440
    Animate $handle ([System.Windows.UIElement]::OpacityProperty) 0 380
    Animate $handle ([System.Windows.FrameworkElement]::WidthProperty) 8 420
    $exitTimer.Start()
}

$window.Add_SourceInitialized({
    $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
    $script:hwnd = $hwnd
    $GWL_EXSTYLE = -20; $WS_EX_TOOLWINDOW = 0x80; $WS_EX_NOACTIVATE = 0x08000000
    $style = [IslandNative]::GetWindowLong($hwnd, $GWL_EXSTYLE)
    [void][IslandNative]::SetWindowLong($hwnd, $GWL_EXSTYLE, ($style -bor $WS_EX_TOOLWINDOW -bor $WS_EX_NOACTIVATE))
    try {
        $script:hwheel = New-Object HWheelHook($hwnd)
        $script:hwheel.add_Scrolled({
            param($s, $e)
            if ($script:mode -ne 'list') { return }
            # Touchpad mengirim banyak delta kecil: kumpulkan dulu, lalu pindah sekali per gerakan
            if (((Get-Date) - $script:lastPageSwitch).TotalMilliseconds -lt 600) { $script:hwheelSum = 0; return }
            $script:hwheelSum += $s.Delta
            if ([Math]::Abs($script:hwheelSum) -ge 120) {
                $target = if ($script:hwheelSum -gt 0) { 'next' } else { 'prev' }
                $script:hwheelSum = 0
                Switch-ListPage $target
            }
        })
    } catch { Log "hwheel: $_" }
})

# Klik-tahan lalu geser di daftar:
# - mulai di baris notifikasi lalu tarik ke kanan = hapus notifikasi itu (lewat batas lalu lepas)
# - selain itu, geser ke kiri/kanan = pindah halaman notifikasi/musik
$DRAG_DELETE = 110
$script:dragRow = $null
$script:rowDragging = $false

# Cari baris notifikasi (Border dengan Tag.N) dari elemen yang diklik
function Find-Row($el) {
    try {
        while ($el) {
            if ($el -is [System.Windows.Controls.Border] -and $el.Tag -and $el.Tag.N) { return $el }
            $el = if ($el -is [System.Windows.Media.Visual]) { [System.Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
        }
    } catch {}
    $null
}

function End-RowDrag {
    $script:rowDragging = $false
    $script:dragRow = $null
    if ($island.IsMouseCaptured) { $island.ReleaseMouseCapture() }
}

# Pop-up notifikasi ditarik ke kanan lewat batas: isinya meluncur keluar, notifikasi dihapus,
# lalu lanjut ke antrean berikutnya / sembunyi
$popupTimer = New-Object System.Windows.Threading.DispatcherTimer
$popupTimer.Interval = Ms 290
$popupTimer.Add_Tick({
    $popupTimer.Stop()
    $n = $script:current
    # Notifikasi WeChat (dari kedipan taskbar) bukan notifikasi Windows: cukup ditutup
    if ($n -and -not $n.Flash) { Remove-Notif $n.Id }
    $island.RenderTransform = [System.Windows.Media.Transform]::Identity
    $island.BorderBrush = $GLASS_BORDER
    Go-Idle
})

# Seluruh island (bukan cuma isinya) meluncur ke kanan sambil memudar
function Dismiss-Popup {
    $script:mode = 'dismiss'   # cegah timer/hover lain mengganggu selama animasi keluar
    $dismissTimer.Stop()
    Animate $island.RenderTransform ([System.Windows.Media.TranslateTransform]::XProperty) ($WIDE_W * 0.9) 260
    Animate $island ([System.Windows.UIElement]::OpacityProperty) 0 240
    $popupTimer.Start()
}

# Elemen bertanda 'nodrag' (slider volume) mengurus geserannya sendiri
function Is-NoDrag($el) {
    try {
        while ($el) {
            if ($el -is [System.Windows.FrameworkElement] -and $el.Tag -is [string] -and $el.Tag -eq 'nodrag') { return $true }
            $el = if ($el -is [System.Windows.Media.Visual]) { [System.Windows.Media.VisualTreeHelper]::GetParent($el) } else { $el.Parent }
        }
    } catch {}
    $false
}

# Scroll mouse di atas player musik = atur volume (slider langsung ditampilkan)
$island.Add_MouseWheel({
    param($s, $e)
    $onMusic = $script:mode -eq 'media' -or ($script:mode -eq 'list' -and $script:listPage -eq 'music')
    if (-not $onMusic -or -not $script:media) { return }
    $e.Handled = $true
    if (-not $script:volumeMode) { Switch-BottomRow }
    $v = Get-Vol
    if ($v -ge 0) { Set-Vol ($v + 0.02 * [Math]::Sign($e.Delta)) }
})

$island.Add_PreviewMouseLeftButtonDown({
    param($s, $e)
    $script:swiped = $false
    $script:rowDragging = $false
    $script:dragPopup = $false
    if (Is-NoDrag $e.OriginalSource) { $script:swipeStart = $null; $script:dragRow = $null; return }
    # Posisi diukur terhadap jendela, bukan island: island sendiri ikut bergeser saat ditarik
    $script:swipeStart = if ($script:mode -eq 'list' -or $script:mode -eq 'notif') { $e.GetPosition($window) } else { $null }
    if ($script:mode -eq 'notif') {
        # Pop-up: seluruh island yang ditarik
        $script:dragPopup = $true
        $script:dragRow = $island
    } else {
        $script:dragRow = if ($script:swipeStart -and $script:listPage -eq 'notif' -and -not $script:deleting) { Find-Row $e.OriginalSource } else { $null }
    }
})
$island.Add_PreviewMouseMove({
    param($s, $e)
    if (-not $script:swipeStart -or $e.LeftButton -ne 'Pressed') { return }
    $dx = $e.GetPosition($window).X - $script:swipeStart.X
    $row = $script:dragRow
    if ($row -and ($script:rowDragging -or $dx -gt 6)) {
        if (-not $script:rowDragging) {
            # Siapkan transform dulu, baru tangkap mouse: CaptureMouse langsung memicu event
            # gerak berikutnya (re-entrant) yang sudah butuh transform ini
            $row.RenderTransform = New-Object System.Windows.Media.TranslateTransform
            # Opacity isi pop-up masih dipegang animasi Show-View; lepas dulu supaya bisa diatur
            $row.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null); $row.Opacity = 1
            $script:rowDragging = $true; $script:swiped = $true
            [void]$island.CaptureMouse()
        }
        if ($row.RenderTransform -isnot [System.Windows.Media.TranslateTransform]) { return }
        $x = [Math]::Max(0.0, $dx)
        $row.RenderTransform.X = $x
        $row.Opacity = 1.0 - [Math]::Min(0.6, $x / ($WIDE_W * 0.9))
        # Kemerahan saat sudah lewat batas hapus (baris daftar; pop-up memakai garis tepi island)
        if ($script:dragPopup) {
            $island.BorderBrush = if ($x -ge $DRAG_DELETE) { Brush '#CCFF453A' } else { $GLASS_BORDER }
        } else {
            $row.Background = if ($x -ge $DRAG_DELETE) { Brush '#66FF453A' } else { Row-Brush $row.Tag.N.Accent $true }
        }
        return
    }
    if ($script:swiped -or $script:mode -ne 'list') { return }
    if ([Math]::Abs($dx) -gt 40) {
        $script:swiped = $true
        Switch-ListPage $(if ($dx -lt 0) { 'next' } else { 'prev' })
    }
})
$island.Add_PreviewMouseLeftButtonUp({
    param($s, $e)
    $script:swipeStart = $null
    if ($script:rowDragging) {
        $row = $script:dragRow
        $isPopup = $script:dragPopup
        $x = if ($row.RenderTransform -is [System.Windows.Media.TranslateTransform]) { $row.RenderTransform.X } else { 0.0 }
        End-RowDrag
        if ($isPopup) { $island.BorderBrush = $GLASS_BORDER }
        if ($x -ge $DRAG_DELETE) {
            if ($isPopup) { Dismiss-Popup } else { Start-Delete @($row) @($row.Tag.N.Id) $false }
        } else {
            # Belum lewat batas: kembali ke tempat semula
            if ($row.RenderTransform -is [System.Windows.Media.TranslateTransform]) {
                Animate $row.RenderTransform ([System.Windows.Media.TranslateTransform]::XProperty) 0 220
            }
            Animate $row ([System.Windows.UIElement]::OpacityProperty) 1 200
            if (-not $isPopup) { $row.Background = Row-Brush $row.Tag.N.Accent $false }
        }
    }
    $script:dragRow = $null
    $script:dragPopup = $false
    # Lepas klik setelah swipe jangan dianggap klik baris (membuka aplikasi)
    if ($script:swiped) { $script:swiped = $false; $e.Handled = $true }
})
# Tangkapan mouse hilang di tengah tarikan (klik kanan membuka menu, Alt-Tab): baris / pop-up kembali ke
# tempatnya dan status tarikan dilepas (kalau tidak, daftar tidak pernah menutup sendiri lagi). Pelepasan
# normal lewat End-RowDrag sudah mematikan rowDragging lebih dulu, jadi tidak ikut terpicu di sini.
$island.Add_LostMouseCapture({
    param($s, $e)
    if (-not $script:rowDragging) { return }
    $row = $script:dragRow; $isPopup = $script:dragPopup
    $script:rowDragging = $false; $script:dragRow = $null; $script:dragPopup = $false; $script:swipeStart = $null
    if (-not $row) { return }
    if ($row.RenderTransform -is [System.Windows.Media.TranslateTransform]) {
        Animate $row.RenderTransform ([System.Windows.Media.TranslateTransform]::XProperty) 0 220
    }
    Animate $row ([System.Windows.UIElement]::OpacityProperty) 1 200
    if ($isPopup) { $island.BorderBrush = $GLASS_BORDER } else { $row.Background = Row-Brush $row.Tag.N.Accent $false }
})
$window.Add_Loaded({
    Update-Position
    Show-Intro
    try { $script:flashWatcher = New-Object FlashWatcher } catch { Log "flash watcher: $_" }
    try {
        $script:mediaMgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])
    } catch { Log "media manager: $_" }
    try {
        $script:volWatcher = New-Object VolumeWatcher
        $script:volWatcher.add_Changed({ try { On-VolumeChanged } catch { Log "volume osd: $_" } })
        if ($script:volWatcher.Error) { Log "volume watcher: $($script:volWatcher.Error)" }
    } catch { Log "volume watcher: $_" }
    # Kecerahan hanya tersedia di laptop / monitor yang mendukungnya
    try {
        $script:brightWatcher = New-Object BrightnessWatcher
        $script:brightWatcher.add_Changed({ try { On-BrightnessChanged } catch { Log "brightness osd: $_" } })
    } catch { Log "brightness watcher (tidak didukung?): $($_.Exception.InnerException.Message)" }
    # Cache lirik dibatasi sekitar 1500 lagu: yang paling lama tidak dipakai dibuang
    try {
        $files = @(Get-ChildItem $lyricsDir -Filter '*.json' -ErrorAction Stop)
        if ($files.Count -gt 1500) { $files | Sort-Object LastWriteTime | Select-Object -First ($files.Count - 1000) | Remove-Item -Force -ErrorAction SilentlyContinue }
    } catch {}
    Poll
    try { Check-Sensors } catch { Log "sensors: $_" }
    if ($script:settings.CheckUpdates) { Start-UpdateCheck }
    $pollTimer.Start()
    # Sisa kompilasi kode C# dan pembuatan jendela saat mulai dibersihkan sekali
    $memTimer.Start()
})
$window.Add_Closed({
    if ($script:flashWatcher) { $script:flashWatcher.Stop() }
    if ($script:volWatcher) { $script:volWatcher.Stop() }
    if ($script:brightWatcher) { $script:brightWatcher.Stop() }
})

# Error tak terduga di event handler tidak boleh mematikan island: catat lalu lanjut. Timer berulang yang
# tick-nya error berhenti berdetak walau IsEnabled tetap True (WPF baru menjadwalkan tick berikutnya setelah
# tick selesai normal, dan Start() pada timer yang dianggap masih jalan tidak berbuat apa-apa): jalankan ulang.
$window.Dispatcher.add_UnhandledException({
    param($s, $e)
    Log "ui error: $($e.Exception.Message)"
    $e.Handled = $true
    foreach ($v in Get-Variable -Scope Script) {
        if ($v.Value -is [System.Windows.Threading.DispatcherTimer] -and $v.Value.IsEnabled) { $v.Value.Stop(); $v.Value.Start() }
    }
})

$exitCode = 0
try { [void]$window.ShowDialog() } catch { Log "fatal: $_"; $exitCode = 1 }
$mutex.ReleaseMutex()
# Kode bukan 0 membuat launcher menjalankan ulang island (juga setelah update terpasang)
if ($script:restartCode) { $exitCode = $script:restartCode }
exit $exitCode
