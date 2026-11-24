using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Dispatching;
using Windows.Graphics.Imaging;
using Windows.Storage.Streams;

namespace Lat3ncyToolbox.ImeHudWinUi;

/// <summary>One shell icon on the existing WinUI dispatcher. No tray thread or window.</summary>
internal sealed class ToolboxTray : IDisposable
{
    const uint CallbackMessage = 0x8000 + 84;
    const uint IconId = 1;
    readonly IntPtr _owner;
    readonly Action _openSettings;
    readonly Func<uint, bool>? _notifyOverride;
    readonly CancellationTokenSource _lifetime = new();
    readonly int _ownerThread = Environment.CurrentManagedThreadId;
    readonly DispatcherQueueTimer _timer;
    readonly uint _taskbarCreated = RegisterWindowMessageW("TaskbarCreated");
    IntPtr _black, _white;
    bool _shown, _dark, _version4, _disposed, _refreshing;
    bool _visiblePreference = true;
    bool _ready;
    string _previousProfile = "<initial>";

    public ToolboxTray(IntPtr owner, Action openSettings, DispatcherQueue dispatcher, Func<uint, bool>? notifyOverride = null)
    {
        _owner = owner; _openSettings = openSettings;
        _notifyOverride = notifyOverride;
        _timer = dispatcher.CreateTimer();
        _timer.Interval = TimeSpan.FromSeconds(1);
        _timer.Tick += async (_, _) => await RefreshPreferencesAsync();
        _timer.Start();
        _ = InitializeAsync();
    }

    void CheckThread()
    {
        if (Environment.CurrentManagedThreadId != _ownerThread)
            throw new InvalidOperationException("tray_dispatcher_required");
    }

    async Task InitializeAsync()
    {
        try
        {
            string path = Path.Combine(AppContext.BaseDirectory, "Assets", "toolbox-logo.png");
            byte[] png = await File.ReadAllBytesAsync(path);
            using var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream))
            {
                writer.WriteBytes(png); await writer.StoreAsync(); writer.DetachStream();
            }
            stream.Seek(0);
            BitmapDecoder decoder = await BitmapDecoder.CreateAsync(stream);
            int size = Math.Clamp(GetSystemMetrics(49), 16, 64);
            var transform = new BitmapTransform { ScaledWidth = (uint)size, ScaledHeight = (uint)size };
            PixelDataProvider pixels = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight,
                transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
            byte[] source = pixels.DetachPixelData();
            if (_disposed) return;
            CheckThread();
            _black = CreateMonochromeIcon(source, size, false);
            _white = CreateMonochromeIcon(source, size, true);
            await RefreshPreferencesAsync(force: true);
            _ready = !_disposed;
            if (!_disposed) HudLog.Line("toolbox-tray=ready thread=ui");
        }
        catch (Exception error)
        {
            HudLog.Line("toolbox-tray=unavailable kind=" + error.GetType().Name);
            DestroyIcons();
        }
    }

    public async Task RefreshPreferencesAsync(bool force = false)
    {
        if (_disposed || _refreshing || _black == IntPtr.Zero || _white == IntPtr.Zero) return;
        CheckThread(); _refreshing = true;
        try
        {
            string? root = FindRepository();
            if (root == null) return;
            string path = Path.Combine(root, ".toolbox-controls.json");
            string text = "";
            if (File.Exists(path))
            {
                using var reader = new StreamReader(path);
                char[] buffer = new char[16385];
                int count = await reader.ReadBlockAsync(buffer.AsMemory());
                if (count > 16384) throw new InvalidDataException();
                text = new string(buffer, 0, count);
            }
            if (_disposed) return;
            CheckThread();
            if (force || text != _previousProfile)
            {
                _visiblePreference = ReadVisibility(text);
                _previousProfile = text;
            }
            Apply(_visiblePreference, Native.TaskbarUsesDarkMode());
        }
        catch (Exception error)
        {
            // Preserve the last known visibility; an invalid profile cannot
            // remove the settings recovery entry point.
            if (!_disposed) Apply(_visiblePreference, Native.TaskbarUsesDarkMode());
            if (force) HudLog.Line("toolbox-tray=profile-unavailable kind=" + error.GetType().Name);
        }
        finally { _refreshing = false; }
    }

    internal static bool ReadVisibility(string text)
    {
        if (text.Length == 0) return true;
        using JsonDocument document = JsonDocument.Parse(text);
        JsonElement root = document.RootElement;
        if (root.ValueKind != JsonValueKind.Object || root.GetProperty("version").GetInt32() != 1
            || root.EnumerateObject().Select(item => item.Name).Distinct().Count() != root.EnumerateObject().Count())
            throw new InvalidDataException();
        return !root.TryGetProperty("tray_visible", out var visible) || visible.GetBoolean();
    }

    static string? FindRepository()
    {
        DirectoryInfo? current = new(AppContext.BaseDirectory);
        for (int depth = 0; depth < 7 && current != null; depth++, current = current.Parent)
            if (File.Exists(Path.Combine(current.FullName, "tools", "toolbox_controls.py"))
                && Directory.Exists(Path.Combine(current.FullName, "ahk"))) return current.FullName;
        return null;
    }

    void Apply(bool visible, bool dark)
    {
        CheckThread();
        if (!visible)
        {
            if (_shown) { Notify(2); _shown = false; HudLog.Line("toolbox-tray=hidden"); }
            return;
        }
        if (!_shown)
        {
            _dark = dark;
            _shown = Notify(0);
            if (_shown) { _version4 = Notify(4, version: 4); HudLog.Line("toolbox-tray=shown color=" + (dark ? "white" : "black")); }
        }
        else if (_dark != dark)
        {
            bool previous = _dark; _dark = dark;
            if (!Notify(1)) _dark = previous;
            else HudLog.Line("toolbox-tray=color-" + (dark ? "white" : "black"));
        }
    }

    public void SyncTheme()
    {
        if (!_disposed && _black != IntPtr.Zero && _white != IntPtr.Zero)
            Apply(_visiblePreference, Native.TaskbarUsesDarkMode());
    }

    public bool HandleMessage(uint message, IntPtr wParam, IntPtr lParam)
    {
        if (_disposed) return false;
        CheckThread();
        if (_taskbarCreated != 0 && message == _taskbarCreated)
        {
            _shown = false; SyncTheme(); return true;
        }
        if (message != CallbackMessage) return false;
        uint value = (uint)lParam.ToInt64();
        uint id = _version4 ? value >> 16 : (uint)wParam.ToInt64();
        uint action = value & 0xFFFF;
        if (id == IconId && _shown)
        {
            if (action == 0x7B || (!_version4 && action == 0x205)) ShowContextMenu();
            else if (action is 0x400 or 0x401 || (!_version4 && action == 0x202)) _openSettings();
        }
        return true;
    }

    void ShowContextMenu()
    {
        if (!GetCursorPos(out TrayPoint point)) { _openSettings(); return; }
        IntPtr menu = CreatePopupMenu();
        if (menu == IntPtr.Zero) return;
        try
        {
            AppendMenuW(menu, 0, new UIntPtr(1), "打开工具箱设置");
            AppendMenuW(menu, 0, new UIntPtr(2), "隐藏主托盘图标");
            SetForegroundWindow(_owner);
            uint command = TrackPopupMenu(menu, 0x100 | 0x80, point.X, point.Y, 0, _owner, IntPtr.Zero);
            PostMessageW(_owner, 0, IntPtr.Zero, IntPtr.Zero);
            if (command == 1) _openSettings();
            else if (command == 2) _ = HideFromMenuAsync();
        }
        finally { DestroyMenu(menu); }
    }

    async Task HideFromMenuAsync()
    {
        try
        {
            JsonElement current = await PreferencesBridge.RunControlsAsync(null, _lifetime.Token);
            var request = new { revision = current.GetProperty("revision").GetString(), changes = new { tray_visible = false } };
            await PreferencesBridge.RunControlsAsync(request, _lifetime.Token);
            await RefreshPreferencesAsync(force: true);
        }
        catch { if (!_disposed) HudLog.Line("toolbox-tray=hide-save-failed"); }
    }

    bool Notify(uint operation, uint version = 0)
    {
        if (_notifyOverride != null) return _notifyOverride(operation);
        var data = new NotifyIconData
        {
            Size = (uint)Marshal.SizeOf<NotifyIconData>(), Window = _owner, Id = IconId,
            Flags = 1 | 2 | 4 | 0x80, Callback = CallbackMessage, Icon = _dark ? _white : _black,
            Tip = "lat3ncy 工具箱 · 打开设置", Info = "", InfoTitle = "", TimeoutOrVersion = version,
        };
        return Shell_NotifyIconW(operation, ref data);
    }

    public void Dispose()
    {
        if (_disposed) return;
        CheckThread(); _disposed = true; _ready = false; _lifetime.Cancel(); _timer.Stop();
        if (_shown) { Notify(2); _shown = false; }
        DestroyIcons();
        _lifetime.Dispose();
    }

    void DestroyIcons()
    {
        if (_black != IntPtr.Zero) { DestroyIcon(_black); _black = IntPtr.Zero; }
        if (_white != IntPtr.Zero) { DestroyIcon(_white); _white = IntPtr.Zero; }
    }

    internal static byte[] Tint(byte[] source, bool white)
    {
        byte[] result = new byte[source.Length];
        for (int i = 0; i < source.Length; i += 4)
        {
            byte alpha = source[i + 3];
            result[i] = result[i + 1] = result[i + 2] = white ? alpha : (byte)0;
            result[i + 3] = alpha;
        }
        return result;
    }

    internal static async Task<IntPtr> LoadWindowIconAsync()
    {
        byte[] png = await File.ReadAllBytesAsync(Path.Combine(AppContext.BaseDirectory, "Assets", "toolbox-logo.png"));
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream)) { writer.WriteBytes(png); await writer.StoreAsync(); writer.DetachStream(); }
        stream.Seek(0); var decoder = await BitmapDecoder.CreateAsync(stream);
        const int size = 64;
        var data = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Straight,
            new BitmapTransform { ScaledWidth = size, ScaledHeight = size }, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        return CreateMonochromeIcon(data.DetachPixelData(), size, null);
    }
    internal static void ReleaseWindowIcon(IntPtr icon) { if (icon != IntPtr.Zero) DestroyIcon(icon); }

    static IntPtr CreateMonochromeIcon(byte[] source, int size, bool? white)
    {
        if (source.Length != size * size * 4) throw new InvalidDataException();
        var header = new BitmapHeader { Size = 40, Width = size, Height = -size, Planes = 1, BitCount = 32 };
        IntPtr color = CreateDIBSection(IntPtr.Zero, ref header, 0, out IntPtr bits, IntPtr.Zero, 0);
        IntPtr mask = IntPtr.Zero;
        try
        {
            if (color == IntPtr.Zero || bits == IntPtr.Zero) throw new InvalidOperationException("tray_bitmap_failed");
            byte[] tinted;
            if (white.HasValue) tinted = Tint(source, white.Value);
            else
            {
                tinted = (byte[])source.Clone();
                for (int i = 0; i < tinted.Length; i += 4)
                    for (int channel = 0; channel < 3; channel++) tinted[i + channel] = (byte)((tinted[i + channel] * tinted[i + 3] + 127) / 255);
            }
            Marshal.Copy(tinted, 0, bits, tinted.Length);
            mask = CreateBitmap(size, size, 1, 1, new byte[((size + 15) / 16) * 2 * size]);
            if (mask == IntPtr.Zero) throw new InvalidOperationException("tray_mask_failed");
            var info = new IconInfo { IsIcon = true, Color = color, Mask = mask };
            IntPtr icon = CreateIconIndirect(ref info);
            if (icon == IntPtr.Zero) throw new InvalidOperationException("tray_icon_failed");
            return icon;
        }
        finally { if (color != IntPtr.Zero) DeleteObject(color); if (mask != IntPtr.Zero) DeleteObject(mask); }
    }

    public static int SelfTest()
    {
        if (Marshal.SizeOf<NotifyIconData>() != 976 || !ReadVisibility("") || ReadVisibility("{\"version\":1,\"tray_visible\":false}")) return 1;
        byte[] source = [40, 80, 160, 128, 0, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 64];
        byte[] white = Tint(source, true), black = Tint(source, false);
        if (white[0] != 128 || white[3] != 128 || white[4] != 0 || black[0] != 0 || black[3] != 128) return 1;
        IntPtr a = IntPtr.Zero, b = IntPtr.Zero;
        try { a = CreateMonochromeIcon(source, 2, false); b = CreateMonochromeIcon(source, 2, true); return a != IntPtr.Zero && b != IntPtr.Zero ? 0 : 1; }
        finally { if (a != IntPtr.Zero) DestroyIcon(a); if (b != IntPtr.Zero) DestroyIcon(b); }
    }

    internal static async Task VerifyHostedAsync(IntPtr owner, DispatcherQueue dispatcher)
    {
        int thread = Environment.CurrentManagedThreadId, opened = 0;
        var operations = new List<uint>();
        using var tray = new ToolboxTray(owner, () => opened++, dispatcher, operation =>
        {
            if (Environment.CurrentManagedThreadId != thread) throw new InvalidOperationException("tray_wrong_thread");
            operations.Add(operation); return true;
        });
        var elapsed = System.Diagnostics.Stopwatch.StartNew();
        while (!tray._ready && elapsed.Elapsed < TimeSpan.FromSeconds(8)) await Task.Delay(20);
        if (!tray._ready) throw new InvalidOperationException("tray_not_ready");
        tray._timer.Stop(); tray.Apply(false, false); operations.Clear();
        tray.Apply(true, false); tray.Apply(true, false); tray.Apply(true, true);
        tray.Apply(false, true); tray.Apply(false, false); tray.Apply(true, false);
        tray._visiblePreference = true;
        tray.HandleMessage(tray._taskbarCreated, IntPtr.Zero, IntPtr.Zero);
        tray.HandleMessage(CallbackMessage, IntPtr.Zero, new IntPtr((1 << 16) | 0x400));
        tray.HandleMessage(CallbackMessage, IntPtr.Zero, new IntPtr((2 << 16) | 0x400));
        if (opened != 1 || !operations.SequenceEqual(new uint[] { 0, 4, 1, 2, 0, 4, 0, 4 }))
            throw new InvalidOperationException("tray_lifecycle_failed");
        bool rejected = await Task.Run(() =>
        {
            try { tray.Apply(true, false); return false; }
            catch (InvalidOperationException) { return true; }
        });
        if (!rejected) throw new InvalidOperationException("tray_thread_not_guarded");
        tray.Dispose();
        if (tray._black != IntPtr.Zero || tray._white != IntPtr.Zero || tray._shown) throw new InvalidOperationException("tray_resources_retained");
        HudLog.Line("toolbox-tray-probe=passed thread=ui shell=simulated");
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct NotifyIconData
    {
        public uint Size; public IntPtr Window; public uint Id, Flags, Callback; public IntPtr Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State, StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint TimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Guid; public IntPtr BalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)] struct BitmapHeader { public uint Size; public int Width, Height; public ushort Planes, BitCount; public uint Compression, ImageSize; public int XPels, YPels; public uint Used, Important; }
    [StructLayout(LayoutKind.Sequential)] struct IconInfo { [MarshalAs(UnmanagedType.Bool)] public bool IsIcon; public uint X, Y; public IntPtr Mask, Color; }
    [StructLayout(LayoutKind.Sequential)] struct TrayPoint { public int X, Y; }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool Shell_NotifyIconW(uint operation, ref NotifyIconData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern uint RegisterWindowMessageW(string text);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr CreateIconIndirect(ref IconInfo info);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool DestroyIcon(IntPtr icon);
    [DllImport("gdi32.dll")] static extern IntPtr CreateDIBSection(IntPtr dc, ref BitmapHeader info, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] static extern IntPtr CreateBitmap(int width, int height, uint planes, uint bitCount, byte[] bits);
    [DllImport("gdi32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool DeleteObject(IntPtr handle);
    [DllImport("user32.dll")] static extern IntPtr CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] static extern bool AppendMenuW(IntPtr menu, uint flags, UIntPtr id, string text);
    [DllImport("user32.dll")] static extern uint TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr owner, IntPtr rect);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool GetCursorPos(out TrayPoint point);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] static extern bool PostMessageW(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
}
