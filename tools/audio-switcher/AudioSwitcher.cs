using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Lat3ncyToolbox
{
    public enum ERole { eConsole = 0, eMultimedia = 1, eCommunications = 2 }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    public class MMDeviceEnumerator {}

    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceEnumerator
    {
        int EnumAudioEndpoints(int dataFlow, int dwStateMask, out IMMDeviceCollection ppDevices);
        int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppEndpoint);
    }

    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDeviceCollection
    {
        int GetCount(out int pcDevices);
        int Item(int nDevice, out IMMDevice ppDevice);
    }

    [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IMMDevice
    {
        int Activate(ref Guid iid, int dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface);
        int OpenPropertyStore(int stgmAccess, out IPropertyStore ppProperties);
        int GetId([MarshalAs(UnmanagedType.LPWStr)] out string ppstrId);
        int GetState(out int pdwState);
    }

    [Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IPropertyStore
    {
        int GetCount(out int cProps);
        int GetAt(int iProp, out PropertyKey pkey);
        int GetValue(ref PropertyKey key, out PropVariant pv);
    }

    public struct PropertyKey
    {
        public Guid fmtid;
        public int pid;
    }

    [StructLayout(LayoutKind.Explicit)]
    public struct PropVariant
    {
        [FieldOffset(0)] public short vt;
        [FieldOffset(8)] public IntPtr pwszVal;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct BluetoothFindRadioParams
    {
        public int dwSize;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SystemTime
    {
        public ushort wYear;
        public ushort wMonth;
        public ushort wDayOfWeek;
        public ushort wDay;
        public ushort wHour;
        public ushort wMinute;
        public ushort wSecond;
        public ushort wMilliseconds;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct BluetoothDeviceSearchParams
    {
        public int dwSize;
        public int fReturnAuthenticated;
        public int fReturnRemembered;
        public int fReturnUnknown;
        public int fReturnConnected;
        public int fIssueInquiry;
        public byte cTimeoutMultiplier;
        public IntPtr hRadio;
    }

    // 与 BluetoothAPIs.h 中 BLUETOOTH_DEVICE_INFO 对齐：dwSize 后按 8 字节对齐地址。
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    internal struct BluetoothDeviceInfo
    {
        public int dwSize;
        public ulong Address;
        public uint ulClassofDevice;
        public int fConnected;
        public int fRemembered;
        public int fAuthenticated;
        public SystemTime stLastSeen;
        public SystemTime stLastUsed;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 248)]
        public string szName;
    }

    public class AudioSwitcher
    {
        // eRender：活动终点能出声；枚举全部状态才能找到“已配对但未建 A2DP”的 AirPods。
        const int DataFlowRender = 0;
        const int DeviceStateActive = 0x00000001;
        const int DeviceStateUnplugged = 0x00000008;
        const int DeviceStateMaskAll = 0x0000000F;
        static int ConnectWaitMs = 12000;
        static int ConnectPollMs = 200;
        // Enable-PnpDevice 常 8s+ 超时，默认关闭；需要时在 config.toml 打开。
        static bool PnpFallbackEnabled = false;
        static bool DebugMode = false;
        static string DebugLog { get { return System.IO.Path.Combine(System.IO.Path.GetTempPath(), "lat3ncy-audio-debug.log"); } }
        static void LogDebug(string msg) {
            try {
                string line = DateTime.Now.ToString("HH:mm:ss.fff") + " " + msg;
                System.IO.File.AppendAllText(DebugLog, line + Environment.NewLine, System.Text.Encoding.UTF8);
                if (DebugMode) Console.Error.WriteLine("DEBUG|" + msg);
            } catch {}
        }

        static void LogInstalledServicesForDevice(IntPtr radio, BluetoothDeviceInfo info) {
            try {
                int count = 32;
                Guid[] guids = new Guid[count];
                // 需要可写的 count，先传数组长度
                uint ret = BluetoothEnumerateInstalledServices(radio, ref info, ref count, guids);
                LogDebug("  BluetoothEnumerateInstalledServices ret=" + ret + " count=" + count + " for " + info.szName);
                for (int i = 0; i < count && i < guids.Length; i++) LogDebug("   service[" + i + "]=" + guids[i]);
            } catch (Exception ex) { LogDebug("  LogInstalledServices ex " + ex.Message); }
        }
        static void DumpDebugInfo() {
            try {
                LogDebug("---- DumpDebugInfo start ----");
                LogDebug(" Marshal.SizeOf WsaQuerySet=" + Marshal.SizeOf(typeof(WsaQuerySet)) + " CsAddrInfo=" + Marshal.SizeOf(typeof(CsAddrInfo)) + " SockAddrBth=" + Marshal.SizeOf(typeof(SockAddrBth)));
                EnsureConfigLoaded();
                LogDebug("Config headset=" + string.Join(",", HeadsetKeywords) + " exclude=" + string.Join(",", HeadsetExclude));
                // WASAPI
                string defId; var all = GetDevices(DeviceStateMaskAll, out defId);
                LogDebug("WASAPI all=" + all.Count + " defaultId=" + defId);
                foreach (var d in all) {
                    LogDebug(" WASAPI State=" + d.State + " Default=" + d.IsDefault + " Name=" + d.Name + " Id=" + d.Id);
                }
                var active = GetDevices(DeviceStateActive, out defId);
                LogDebug("WASAPI active=" + active.Count);
                foreach (var d in active) LogDebug("  ACTIVE " + d.Name);
                // Bluetooth
                var rp = new BluetoothFindRadioParams(); rp.dwSize = Marshal.SizeOf(typeof(BluetoothFindRadioParams));
                IntPtr radio; IntPtr fr = BluetoothFindFirstRadio(ref rp, out radio);
                if (fr==IntPtr.Zero) { LogDebug("No Bluetooth radio"); return; }
                try {
                    do {
                        LogDebug("Radio " + radio);
                        var search = new BluetoothDeviceSearchParams(); search.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceSearchParams));
                        search.fReturnAuthenticated=1; search.fReturnRemembered=1; search.fReturnUnknown=1; search.fReturnConnected=1; search.fIssueInquiry=0; search.cTimeoutMultiplier=0; search.hRadio=radio;
                        var info = new BluetoothDeviceInfo(); info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                        IntPtr fd = BluetoothFindFirstDevice(ref search, ref info);
                        if (fd!=IntPtr.Zero) {
                            try {
                                do {
                                    string n = info.szName ?? "";
                                    bool isHead = IsPreferredHeadset(n);
                                    // 尝试刷新名
                                    var fresh = new BluetoothDeviceInfo(); fresh.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo)); fresh.Address = info.Address;
                                    uint q = BluetoothGetDeviceInfo(radio, ref fresh);
                                    string freshName = (q==0? fresh.szName : "");
                                    LogDebug(" BT Dev name=" + n + " fresh=" + freshName + " addr=" + FormatBtAddress(info.Address) + " conn=" + info.fConnected + " rem=" + info.fRemembered + " auth=" + info.fAuthenticated + " isHead=" + isHead + " q=" + q);
                                    if (isHead) {
                                        try {
                                            var tmp2 = new BluetoothDeviceInfo(); tmp2.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo)); tmp2.Address = info.Address;
                                            uint qq2 = BluetoothGetDeviceInfo(radio, ref tmp2);
                                            if (qq2 == 0) LogInstalledServicesForDevice(radio, tmp2); else LogInstalledServicesForDevice(radio, info);
                                        } catch {}
                                    }
                                    info = new BluetoothDeviceInfo(); info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                                } while (BluetoothFindNextDevice(fd, ref info));
                            } finally { BluetoothFindDeviceClose(fd); }
                        } else {
                            LogDebug("  FindFirstDevice none err=" + Marshal.GetLastWin32Error());
                        }
                        CloseHandle(radio); radio=IntPtr.Zero;
                    } while (BluetoothFindNextRadio(fr, out radio) && radio!=IntPtr.Zero);
                } finally { BluetoothFindRadioClose(fr); }
                LogDebug("---- Dump end, log at " + DebugLog + " ----");
                Console.WriteLine("DEBUG DUMP written to " + DebugLog);
            } catch (Exception ex) { LogDebug("Dump ex " + ex); Console.WriteLine("DEBUG DUMP failed " + ex.Message); }
        }
        // 可配置的首选设备关键词（默认硬编码，config.toml 覆盖）
        static string[] HeadsetKeywords = new string[] { "AirPods" };
        static string[] HeadsetExclude = new string[] { "Hands-Free", "Hands Free", "iPhone" };
        static string[] SpeakerKeywords = new string[] { "G27Q2", "NVIDIA High Definition Audio" };
        static string[] SpeakerExclude = new string[] { "Virtual" };
        static bool ConfigLoaded = false;

        static void EnsureConfigLoaded()
        {
            if (ConfigLoaded) return;
            ConfigLoaded = true;
            try {
                string exeDir = System.IO.Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
                if (string.IsNullOrEmpty(exeDir)) exeDir = System.IO.Directory.GetCurrentDirectory();
                string cfg = System.IO.Path.Combine(exeDir, "config.toml");
                if (!System.IO.File.Exists(cfg)) {
                    // 兼容源码直接运行：向上找 tools/audio-switcher/config.toml
                    string cur = exeDir;
                    for (int i=0;i<6;i++) {
                        string cand = System.IO.Path.Combine(cur, "tools", "audio-switcher", "config.toml");
                        if (System.IO.File.Exists(cand)) { cfg = cand; break; }
                        string parent = System.IO.Path.GetDirectoryName(cur);
                        if (string.IsNullOrEmpty(parent) || parent==cur) break;
                        cur = parent;
                    }
                }
                if (!System.IO.File.Exists(cfg)) return;
                string text = System.IO.File.ReadAllText(cfg, System.Text.Encoding.UTF8);
                // 极简 TOML 解析：只处理本文件需要的 6 个键
                HeadsetKeywords = ParseStringArray(text, "headset_keywords") ?? HeadsetKeywords;
                HeadsetExclude = ParseStringArray(text, "headset_exclude") ?? HeadsetExclude;
                SpeakerKeywords = ParseStringArray(text, "speaker_keywords") ?? SpeakerKeywords;
                SpeakerExclude = ParseStringArray(text, "speaker_exclude") ?? SpeakerExclude;
                int? w = ParseInt(text, "connect_wait_ms");
                if (w.HasValue) ConnectWaitMs = Math.Max(1000, Math.Min(30000, w.Value));
                int? p = ParseInt(text, "poll_ms");
                if (p.HasValue) ConnectPollMs = Math.Max(50, Math.Min(1000, p.Value));
                bool? pnp = ParseBool(text, "pnp_fallback");
                if (pnp.HasValue) PnpFallbackEnabled = pnp.Value;
            } catch {}
        }

        static string[] ParseStringArray(string text, string key)
        {
            try {
                var m = System.Text.RegularExpressions.Regex.Match(text, key + "\\s*=\\s*\\[(.*?)\\]", System.Text.RegularExpressions.RegexOptions.Singleline);
                if (!m.Success) return null;
                string inner = m.Groups[1].Value;
                var list = new List<string>();
                foreach (System.Text.RegularExpressions.Match q in System.Text.RegularExpressions.Regex.Matches(inner, "\"([^\"]*)\"")) {
                    string v = q.Groups[1].Value.Trim();
                    if (!string.IsNullOrEmpty(v)) list.Add(v);
                }
                return list.Count>0 ? list.ToArray() : null;
            } catch { return null; }
        }

        static int? ParseInt(string text, string key)
        {
            try {
                var m = System.Text.RegularExpressions.Regex.Match(text, key + "\\s*=\\s*(\\d+)");
                if (!m.Success) return null;
                int v; if (int.TryParse(m.Groups[1].Value, out v)) return v;
            } catch {}
            return null;
        }

        static bool? ParseBool(string text, string key)
        {
            try {
                var m = System.Text.RegularExpressions.Regex.Match(
                    text,
                    key + "\\s*=\\s*(true|false)",
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                if (!m.Success) return null;
                return string.Equals(m.Groups[1].Value, "true", StringComparison.OrdinalIgnoreCase);
            } catch {}
            return null;
        }
        // CONFIGRET CR_NO_SUCH_DEVINST：对未插入 / 未建链的 PnP 节点操作时出现。
        const uint CrNoSuchDevinst = 0xE000020B;
        // A2DP Audio Sink / Advanced Audio。只启用立体声，不碰 Hands-Free / HFP。
        static readonly Guid A2dpSinkUuid = new Guid("0000110B-0000-1000-8000-00805F9B34FB");
        static readonly Guid AdvancedAudioUuid = new Guid("0000110D-0000-1000-8000-00805F9B34FB");
        const uint BluetoothServiceEnable = 0x00000001;
        const int NsBth = 16;
        const int AfBth = 32;
        const int SockStream = 1;
        const int SockSeqpacket = 5;
        const int BthProtoRfcomm = 3;
        const int BthProtoL2cap = 0x0100;
        const int RnrServiceRegister = 0;
        const int LupReturnName = 0x0010;
        const int LupReturnAddr = 0x0100;
        const int LupFlushCache = 0x1000;
        const int WsaDataVersion = 0x0202;

        [DllImport("ole32.dll")]
        static extern int CoCreateInstance(ref Guid rclsid, IntPtr pUnkOuter, uint dwClsContext, ref Guid riid, out IntPtr ppv);

        [DllImport("BluetoothAPIs.dll", SetLastError = true)]
        static extern IntPtr BluetoothFindFirstRadio(ref BluetoothFindRadioParams pbtfrp, out IntPtr phRadio);

        [DllImport("BluetoothAPIs.dll", SetLastError = true)]
        static extern bool BluetoothFindNextRadio(IntPtr hFind, out IntPtr phRadio);

        [DllImport("BluetoothAPIs.dll", SetLastError = true)]
        static extern bool BluetoothFindRadioClose(IntPtr hFind);

        [DllImport("BluetoothAPIs.dll", SetLastError = true)]
        static extern IntPtr BluetoothFindFirstDevice(ref BluetoothDeviceSearchParams pbtsp, ref BluetoothDeviceInfo pbtdi);

        [DllImport("BluetoothAPIs.dll", SetLastError = true)]
        static extern bool BluetoothFindNextDevice(IntPtr hFind, ref BluetoothDeviceInfo pbtdi);

        [DllImport("BluetoothAPIs.dll", SetLastError = true)]
        static extern bool BluetoothFindDeviceClose(IntPtr hFind);

        [DllImport("BluetoothAPIs.dll", SetLastError = true)]
        static extern uint BluetoothGetDeviceInfo(IntPtr hRadio, ref BluetoothDeviceInfo pbtdi);

        [DllImport("BluetoothAPIs.dll", SetLastError = true)]
        static extern uint BluetoothSetServiceState(IntPtr hRadio, ref BluetoothDeviceInfo pbtdi, ref Guid pGuidService, uint dwServiceFlags);

        [DllImport("BluetoothAPIs.dll", SetLastError = true)]
        static extern uint BluetoothEnumerateInstalledServices(IntPtr hRadio, ref BluetoothDeviceInfo pbtdi, ref int pcServiceInout, [In, Out] Guid[] pGuidServices);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr hObject);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern int RegOpenKeyEx(IntPtr hKey, string lpSubKey, int ulOptions, int samDesired, out IntPtr phkResult);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern int RegEnumKeyEx(IntPtr hKey, int dwIndex, System.Text.StringBuilder lpName, ref int lpcchName, IntPtr reserved, IntPtr lpClass, IntPtr lpcchClass, IntPtr lpftLastWriteTime);

        [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern int RegQueryValueEx(IntPtr hKey, string lpValueName, IntPtr lpReserved, out int lpType, byte[] lpData, ref int lpcbData);

        [DllImport("advapi32.dll", SetLastError = true)]
        static extern int RegCloseKey(IntPtr hKey);

        [DllImport("ws2_32.dll", CharSet = CharSet.Unicode)]
        static extern int WSAStartup(ushort wVersionRequested, ref WsaData lpWSAData);

        [DllImport("ws2_32.dll")]
        static extern int WSACleanup();

        [DllImport("ws2_32.dll")]
        static extern int WSAGetLastError();

        [DllImport("ws2_32.dll", CharSet = CharSet.Unicode)]
        static extern int WSASetService(ref WsaQuerySet lpqsRegInfo, int essoperation, int dwControlFlags);

        [DllImport("ws2_32.dll", CharSet = CharSet.Unicode)]
        static extern int WSALookupServiceBegin(ref WsaQuerySet qs, int dwControlFlags, out IntPtr lphLookup);

        [DllImport("ws2_32.dll", CharSet = CharSet.Unicode)]
        static extern int WSALookupServiceNext(IntPtr hLookup, int dwControlFlags, ref int lpdwBufferLength, IntPtr lpqsResults);

        [DllImport("ws2_32.dll")]
        static extern int WSALookupServiceEnd(IntPtr hLookup);

        [StructLayout(LayoutKind.Sequential)]
        struct WsaData
        {
            public short wVersion;
            public short wHighVersion;
            public ushort iMaxSockets;
            public ushort iMaxUdpDg;
            public IntPtr lpVendorInfo;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 257)]
            public string szDescription;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 129)]
            public string szSystemStatus;
        }

        // ws2bth.h：SOCKADDR_BTH 按 1 字节对齐，总长 30。
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        struct SockAddrBth
        {
            public ushort addressFamily;
            public ulong btAddr;
            public Guid serviceClassId;
            public uint port;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SocketAddress
        {
            public IntPtr lpSockaddr;
            public int iSockaddrLength;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct CsAddrInfo
        {
            public SocketAddress LocalAddr;
            public SocketAddress RemoteAddr;
            public int iSocketType;
            public int iProtocol;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct WsaQuerySet
        {
            public int dwSize;
            public IntPtr lpszServiceInstanceName;
            public IntPtr lpServiceClassId;
            public IntPtr lpVersion;
            public IntPtr lpszComment;
            public int dwNameSpace;
            public IntPtr lpNSProviderId;
            public IntPtr lpszContext;
            public int dwNumberOfProtocols;
            public IntPtr lpafpProtocols;
            public IntPtr lpszQueryString;
            public int dwNumberOfCsAddrs;
            public IntPtr lpcsaBuffer;
            public int dwOutputFlags;
            public IntPtr lpBlob;
        }

        [UnmanagedFunctionPointer(CallingConvention.StdCall)]
        delegate int SetDefaultEndpointDelegate(IntPtr thisPtr, [MarshalAs(UnmanagedType.LPWStr)] string deviceId, ERole role);

        private static PropertyKey PKEY_Device_FriendlyName = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 14 };
        // 未建链时 FriendlyName 可能读不到，DeviceDesc 仍能识别 AirPods 立体声。
        private static PropertyKey PKEY_Device_DeviceDesc = new PropertyKey { fmtid = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0"), pid = 2 };

        public class DeviceInfo
        {
            public string Id;
            public string Name;
            public bool IsDefault;
            public int State;
        }

        // Enable/WSA/PNP 的结果与蓝牙层状态分开，避免「经典蓝牙已连」被当成立体声已就绪。
        public class HeadsetConnectAttempt
        {
            public DeviceInfo ActiveHeadset;
            public bool LinkActionSucceeded;
            public bool BluetoothConnected;
            public bool Remembered;
        }

        static bool ContainsIgnore(string text, string needle)
        {
            return !string.IsNullOrEmpty(text)
                && text.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0;
        }

        static bool IsNoSuchDevinst(Exception ex)
        {
            var com = ex as COMException;
            if (com == null)
                return ContainsIgnore(ex.Message, "0xE000020B");
            return unchecked((uint)com.ErrorCode) == CrNoSuchDevinst
                || ContainsIgnore(com.Message, "0xE000020B");
        }

        // 首选耳机：默认 AirPods 立体声，config.toml 可覆盖
        static bool IsPreferredHeadset(string name)
        {
            EnsureConfigLoaded();
            if (HeadsetKeywords==null || HeadsetKeywords.Length==0) return false;
            bool hit=false;
            foreach (var k in HeadsetKeywords) if (ContainsIgnore(name,k)) { hit=true; break; }
            if (!hit) return false;
            if (HeadsetExclude!=null) foreach (var ex in HeadsetExclude) if (ContainsIgnore(name,ex)) return false;
            return true;
        }

        // 首选回退：默认 G27Q2，config.toml 可覆盖
        static bool IsPreferredSpeaker(string name)
        {
            EnsureConfigLoaded();
            if (SpeakerExclude!=null) foreach (var ex in SpeakerExclude) if (ContainsIgnore(name,ex)) return false;
            if (SpeakerKeywords!=null) foreach (var k in SpeakerKeywords) if (ContainsIgnore(name,k)) return true;
            return false;
        }

        static DeviceInfo FindPreferredHeadset(List<DeviceInfo> list)
        {
            return list.Find(d => IsPreferredHeadset(d.Name));
        }

        static DeviceInfo FindPreferredSpeaker(List<DeviceInfo> list)
        {
            EnsureConfigLoaded();
            if (SpeakerKeywords!=null) {
                foreach (var kw in SpeakerKeywords) {
                    var dev = list.Find(d => ContainsIgnore(d.Name, kw));
                    // 排除项已在 IsPreferredSpeaker 中处理，这里再过滤一次
                    if (dev != null && IsPreferredSpeaker(dev.Name)) return dev;
                }
            }
            return list.Find(d => IsPreferredSpeaker(d.Name));
        }

        public static List<DeviceInfo> GetDevices(out string defaultId)
        {
            return GetDevices(DeviceStateActive, out defaultId);
        }

        public static List<DeviceInfo> GetDevices(int stateMask, out string defaultId)
        {
            var list = new List<DeviceInfo>();
            defaultId = "";
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumerator();

            try {
                IMMDevice defDev;
                if (enumerator.GetDefaultAudioEndpoint(DataFlowRender, 1, out defDev) == 0 && defDev != null) {
                    defDev.GetId(out defaultId);
                }
            } catch {}

            IMMDeviceCollection coll;
            if (enumerator.EnumAudioEndpoints(DataFlowRender, stateMask, out coll) != 0 || coll == null)
                return list;

            int count;
            if (coll.GetCount(out count) != 0)
                return list;

            for (int i = 0; i < count; i++) {
                // 未插入的蓝牙终点在枚举“全部状态”时仍可能出现，读属性会抛 0xE000020B。
                try {
                    IMMDevice dev;
                    if (coll.Item(i, out dev) != 0 || dev == null)
                        continue;

                    int state = 0;
                    try { dev.GetState(out state); } catch { continue; }

                    string id;
                    if (dev.GetId(out id) != 0 || string.IsNullOrEmpty(id))
                        continue;

                    string name = "Unknown";
                    IPropertyStore props;
                    if (dev.OpenPropertyStore(0, out props) == 0 && props != null) {
                        PropVariant pv;
                        if (props.GetValue(ref PKEY_Device_FriendlyName, out pv) == 0 && pv.pwszVal != IntPtr.Zero) {
                            name = Marshal.PtrToStringUni(pv.pwszVal);
                        }
                        // 蓝点未点“连接”时，立体声终点常只有 DeviceDesc。
                        if (string.IsNullOrEmpty(name) || name == "Unknown") {
                            PropVariant desc;
                            if (props.GetValue(ref PKEY_Device_DeviceDesc, out desc) == 0 && desc.pwszVal != IntPtr.Zero) {
                                name = Marshal.PtrToStringUni(desc.pwszVal);
                            }
                        }
                    }

                    list.Add(new DeviceInfo {
                        Id = id,
                        Name = name,
                        IsDefault = (!string.IsNullOrEmpty(defaultId) && id == defaultId),
                        State = state
                    });
                } catch {
                    continue;
                }
            }
            return list;
        }

        public static bool SetDefault(string deviceId)
        {
            if (string.IsNullOrEmpty(deviceId))
                return false;

            Guid clsid = new Guid("294935CE-F637-4E7C-A41B-AB255460B862");
            Guid iidUnknown = new Guid("00000000-0000-0000-C000-000000000046");
            IntPtr pUnk = IntPtr.Zero;
            int hr = CoCreateInstance(ref clsid, IntPtr.Zero, 1, ref iidUnknown, out pUnk);
            if (hr != 0 || pUnk == IntPtr.Zero) return false;

            try {
                IntPtr vtable = Marshal.ReadIntPtr(pUnk);
                // Index 12 is SetDefaultEndpoint on Win10/11
                IntPtr funcPtr = Marshal.ReadIntPtr(vtable, 12 * IntPtr.Size);
                var setDef = (SetDefaultEndpointDelegate)Marshal.GetDelegateForFunctionPointer(funcPtr, typeof(SetDefaultEndpointDelegate));

                int r1 = setDef(pUnk, deviceId, ERole.eConsole);
                int r2 = setDef(pUnk, deviceId, ERole.eMultimedia);
                int r3 = setDef(pUnk, deviceId, ERole.eCommunications);
                if (r1 == unchecked((int)CrNoSuchDevinst) || r2 == unchecked((int)CrNoSuchDevinst) || r3 == unchecked((int)CrNoSuchDevinst))
                    return false;
                return (r1 == 0 || r2 == 0);
            } catch {
                // 不能写 Console.Error：AHK 把 stdout/stderr 写进同一文件，会污染协议行。
                return false;
            } finally {
                Marshal.Release(pUnk);
            }
        }

        // 只对已配对 AirPods 启用 A2DP，绝不 Disable，因此不会断开蓝牙。
        static bool EnableAirPodsA2dp()
        {
            try {
                var radioParams = new BluetoothFindRadioParams();
                radioParams.dwSize = Marshal.SizeOf(typeof(BluetoothFindRadioParams));
                IntPtr radio;
                IntPtr findRadio = BluetoothFindFirstRadio(ref radioParams, out radio);
                if (findRadio == IntPtr.Zero || radio == IntPtr.Zero)
                    return false;

                bool enabled = false;
                try {
                    do {
                        if (EnableAirPodsA2dpOnRadio(radio))
                            enabled = true;
                        CloseHandle(radio);
                        radio = IntPtr.Zero;
                    } while (BluetoothFindNextRadio(findRadio, out radio) && radio != IntPtr.Zero);
                } finally {
                    if (radio != IntPtr.Zero)
                        CloseHandle(radio);
                    BluetoothFindRadioClose(findRadio);
                }
                return enabled;
            } catch {
                return false;
            }
        }

        static bool EnableAirPodsA2dpOnRadio(IntPtr radio)
        {
            var search = new BluetoothDeviceSearchParams();
            search.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceSearchParams));
            search.fReturnAuthenticated = 1;
            search.fReturnRemembered = 1;
            search.fReturnUnknown = 0;
            search.fReturnConnected = 1;
            // 不发起扫描，只处理已配对设备，避免拖慢热键。
            search.fIssueInquiry = 0;
            search.cTimeoutMultiplier = 0;
            search.hRadio = radio;

            var info = new BluetoothDeviceInfo();
            info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
            IntPtr findDevice = BluetoothFindFirstDevice(ref search, ref info);
            if (findDevice == IntPtr.Zero)
                return false;

            bool enabled = false;
            try {
                do {
                    if (info.Address == 0) {
                        info = new BluetoothDeviceInfo();
                        info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                        continue;
                    }
                    // Find 返回的名可能为空，先用地址刷新完整信息再判
                    string nameCheck = info.szName;
                    var freshProbe = new BluetoothDeviceInfo();
                    freshProbe.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                    freshProbe.Address = info.Address;
                    uint qp = BluetoothGetDeviceInfo(radio, ref freshProbe);
                    if (qp == 0 && !string.IsNullOrEmpty(freshProbe.szName))
                        nameCheck = freshProbe.szName;

                    if (IsPreferredHeadset(nameCheck)) {
                        // 设服务前必须用地址刷新完整 DEVICE_INFO
                        var fresh = (qp == 0) ? freshProbe : new BluetoothDeviceInfo();
                        if (qp != 0) {
                            fresh.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                            fresh.Address = info.Address;
                            qp = BluetoothGetDeviceInfo(radio, ref fresh);
                        }
                        if (qp == 0)
                            info = fresh;

                        LogInstalledServicesForDevice(radio, info);
                        // 只 Enable A2DP / Advanced Audio，绝不 Disable，避免把已连耳机踢掉。
                        // 0=已改状态；87=参数无效/已是该状态，不能当成“刚建链成功”。
                        Guid svcA = A2dpSinkUuid;
                        uint errA = BluetoothSetServiceState(radio, ref info, ref svcA, BluetoothServiceEnable);
                        Guid svcB = AdvancedAudioUuid;
                        uint errB = BluetoothSetServiceState(radio, ref info, ref svcB, BluetoothServiceEnable);
                        LogDebug("  BluetoothSetServiceState A2DP err=" + errA + " Adv err=" + errB + " for " + nameCheck + " addr=" + FormatBtAddress(info.Address));
                        if (errA == 0 || errB == 0)
                            enabled = true;
                    }
                    info = new BluetoothDeviceInfo();
                    info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                } while (BluetoothFindNextDevice(findDevice, ref info));
            } finally {
                BluetoothFindDeviceClose(findDevice);
            }
            return enabled;
        }

        static bool EnableViaPnpFallback() {
            // 先尝试普通权限，失败再尝试 sudo 提权
            if (TryEnablePnp(false)) return true;
            LogDebug(" EnableViaPnpFallback normal failed, try sudo elevation");
            if (TryEnablePnp(true)) return true;
            return false;
        }
        static bool IsGsuedoAvailable() {
            try {
                var psi = new System.Diagnostics.ProcessStartInfo();
                psi.FileName = "where";
                psi.Arguments = "gsudo";
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                var p = System.Diagnostics.Process.Start(psi);
                p.WaitForExit(2000);
                return p.ExitCode == 0;
            } catch { return false; }
        }
        static bool TryEnablePnp(bool elevated) {
            try {
                string psCmd = "Get-PnpDevice -FriendlyName '*AirPods*' | ForEach-Object { try { Enable-PnpDevice -InstanceId $_.InstanceId -Confirm:$false -ErrorAction SilentlyContinue } catch {} }";
                var psi = new System.Diagnostics.ProcessStartInfo();
                if (elevated && System.IO.File.Exists(Environment.ExpandEnvironmentVariables(@"%WINDIR%\System32\sudo.exe"))) {
                    psi.FileName = Environment.ExpandEnvironmentVariables(@"%WINDIR%\System32\sudo.exe");
                    psi.Arguments = "--inline powershell.exe -NoProfile -Command \"" + psCmd.Replace("\"", "\\\"") + "\"";
                    LogDebug(" TryEnablePnp elevated via sudo --inline");
                } else if (elevated && IsGsuedoAvailable()) {
                    psi.FileName = "gsudo";
                    psi.Arguments = "--wait powershell.exe -NoProfile -Command \"" + psCmd.Replace("\"", "\\\"") + "\"";
                    LogDebug(" TryEnablePnp elevated via gsudo --wait");
                } else if (elevated) {
                    psCmd = "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile','-Command','" + psCmd.Replace("'", "''") + "' -Wait";
                    psi.FileName = "powershell.exe";
                    psi.Arguments = "-NoProfile -Command \"" + psCmd.Replace("\"", "\\\"") + "\"";
                    LogDebug(" TryEnablePnp elevated via Start-Process RunAs");
                } else {
                    psi.FileName = "powershell.exe";
                    psi.Arguments = "-NoProfile -Command \"" + psCmd.Replace("\"", "\\\"") + "\"";
                    LogDebug(" TryEnablePnp normal");
                }
                psi.UseShellExecute = false;
                psi.CreateNoWindow = !elevated;
                psi.WindowStyle = System.Diagnostics.ProcessWindowStyle.Hidden;
                var p = System.Diagnostics.Process.Start(psi);
                if (p.WaitForExit(elevated ? 15000 : 8000)) {
                    LogDebug(" TryEnablePnp elevated=" + elevated + " exit=" + p.ExitCode);
                    return p.ExitCode == 0;
                } else {
                    try { p.Kill(); } catch {}
                    LogDebug(" TryEnablePnp elevated=" + elevated + " timeout");
                    return false;
                }
            } catch (Exception ex) { LogDebug(" TryEnablePnp elevated=" + elevated + " ex " + ex.Message); return false; }
        }

        static DeviceInfo WaitForActiveHeadset()
        {
            int waited = 0;
            LogDebug("WaitForActiveHeadset start waitMs=" + ConnectWaitMs);
            while (waited <= ConnectWaitMs) {
                string ignored;
                DeviceInfo headset = FindPreferredHeadset(GetDevices(DeviceStateActive, out ignored));
                if (headset != null) {
                    LogDebug(" Wait found headset " + headset.Name + " after " + waited + "ms");
                    return headset;
                }
                if (waited % 1000 == 0) LogDebug(" Wait poll " + waited + "ms no headset");
                Thread.Sleep(ConnectPollMs);
                waited += ConnectPollMs;
            }
            LogDebug("WaitForActiveHeadset timeout");
            return null;
        }

        static int HeadsetConnectPriority(DeviceInfo device)
        {
            if (device == null)
                return 100;
            if ((device.State & DeviceStateActive) != 0)
                return 0;
            if ((device.State & DeviceStateUnplugged) != 0)
                return 1;
            return 2;
        }

        // WASAPI 读不到未建链终点时，从 MMDevices 注册表找回已记住的 AirPods 立体声 ID。
        static void AddRememberedHeadsetIds(List<DeviceInfo> candidates)
        {
            const int KeyRead = 0x20019;
            IntPtr hklm = new IntPtr(unchecked((int)0x80000002));
            IntPtr renderKey;
            if (RegOpenKeyEx(hklm, "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\MMDevices\\Audio\\Render", 0, KeyRead, out renderKey) != 0)
                return;

            try {
                var name = new System.Text.StringBuilder(256);
                for (int i = 0; i < 256; i++) {
                    int nameLen = name.Capacity;
                    name.Length = 0;
                    if (RegEnumKeyEx(renderKey, i, name, ref nameLen, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero) != 0)
                        break;

                    string guid = name.ToString();
                    IntPtr propsKey;
                    if (RegOpenKeyEx(renderKey, guid + "\\Properties", 0, KeyRead, out propsKey) != 0)
                        continue;
                    try {
                        string desc = ReadRegString(propsKey, "{b3f8fa53-0004-438e-9003-51a46e139bfc},6");
                        string iface = ReadRegString(propsKey, "{b3f8fa53-0004-438e-9003-51a46e139bfc},2");
                        string friendly = ReadRegString(propsKey, "{a45c254e-df1c-4efd-8020-67d146a850e0},14");
                        string label = !string.IsNullOrEmpty(friendly) ? friendly : desc;
                        if (!IsPreferredHeadset(label) && !IsPreferredHeadset(desc))
                            continue;
                        // 只要 A2DP，排除 Hands-Free / HFP 音频节点。
                        if (ContainsIgnore(iface, "BTHHF") || ContainsIgnore(label, "Hands-Free") || ContainsIgnore(desc, "Hands-Free"))
                            continue;
                        string id = "{0.0.0.00000000}." + guid;
                        if (candidates.Exists(d => string.Equals(d.Id, id, StringComparison.OrdinalIgnoreCase)))
                            continue;
                        candidates.Add(new DeviceInfo {
                            Id = id,
                            Name = string.IsNullOrEmpty(label) ? "Jie’s AirPods" : label,
                            IsDefault = false,
                            State = 0
                        });
                    } finally {
                        RegCloseKey(propsKey);
                    }
                }
            } finally {
                RegCloseKey(renderKey);
            }
        }

        static string ReadRegString(IntPtr key, string valueName)
        {
            int type;
            int size = 0;
            if (RegQueryValueEx(key, valueName, IntPtr.Zero, out type, null, ref size) != 0 || size <= 0)
                return "";
            var data = new byte[size];
            if (RegQueryValueEx(key, valueName, IntPtr.Zero, out type, data, ref size) != 0)
                return "";
            if (type != 1)
                return "";
            return System.Text.Encoding.Unicode.GetString(data, 0, size).TrimEnd('\0');
        }

        static string FormatBtAddress(ulong address)
        {
            return string.Format(
                "({0:X2}:{1:X2}:{2:X2}:{3:X2}:{4:X2}:{5:X2})",
                (address >> 40) & 0xFF,
                (address >> 32) & 0xFF,
                (address >> 24) & 0xFF,
                (address >> 16) & 0xFF,
                (address >> 8) & 0xFF,
                address & 0xFF);
        }

        // 已配对耳机当前是否已在蓝牙层连接（HFP / A2DP 都算）。
        // 只用来区分「盒子在但没立体声」和「未取出」，不再作为空等 ACTIVE 的理由。
        static bool PreferredHeadsetBluetoothConnected()
        {
            try {
                var radioParams = new BluetoothFindRadioParams();
                radioParams.dwSize = Marshal.SizeOf(typeof(BluetoothFindRadioParams));
                IntPtr radio;
                IntPtr findRadio = BluetoothFindFirstRadio(ref radioParams, out radio);
                if (findRadio == IntPtr.Zero || radio == IntPtr.Zero)
                    return false;

                try {
                    do {
                        var search = new BluetoothDeviceSearchParams();
                        search.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceSearchParams));
                        search.fReturnAuthenticated = 1;
                        search.fReturnRemembered = 1;
                        search.fReturnUnknown = 0;
                        search.fReturnConnected = 1;
                        search.fIssueInquiry = 0;
                        search.cTimeoutMultiplier = 0;
                        search.hRadio = radio;

                        var info = new BluetoothDeviceInfo();
                        info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                        IntPtr findDevice = BluetoothFindFirstDevice(ref search, ref info);
                        if (findDevice != IntPtr.Zero) {
                            try {
                                do {
                                    if (info.Address == 0) {
                                        info = new BluetoothDeviceInfo();
                                        info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                                        continue;
                                    }
                                    string nameCheck = info.szName;
                                    var fresh = new BluetoothDeviceInfo();
                                    fresh.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                                    fresh.Address = info.Address;
                                    uint q = BluetoothGetDeviceInfo(radio, ref fresh);
                                    if (q == 0 && !string.IsNullOrEmpty(fresh.szName))
                                        nameCheck = fresh.szName;
                                    int connected = (q == 0) ? fresh.fConnected : info.fConnected;
                                    if (IsPreferredHeadset(nameCheck) && connected != 0) {
                                        LogDebug(" PreferredHeadsetBluetoothConnected name=" + nameCheck);
                                        return true;
                                    }
                                    info = new BluetoothDeviceInfo();
                                    info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                                } while (BluetoothFindNextDevice(findDevice, ref info));
                            } finally {
                                BluetoothFindDeviceClose(findDevice);
                            }
                        }
                        CloseHandle(radio);
                        radio = IntPtr.Zero;
                    } while (BluetoothFindNextRadio(findRadio, out radio) && radio != IntPtr.Zero);
                } finally {
                    if (radio != IntPtr.Zero)
                        CloseHandle(radio);
                    BluetoothFindRadioClose(findRadio);
                }
            } catch {
            }
            return false;
        }

        static bool TryFindAirPodsAddress(out ulong address)
        {
            address = 0;
            try {
                var radioParams = new BluetoothFindRadioParams();
                radioParams.dwSize = Marshal.SizeOf(typeof(BluetoothFindRadioParams));
                IntPtr radio;
                IntPtr findRadio = BluetoothFindFirstRadio(ref radioParams, out radio);
                if (findRadio == IntPtr.Zero || radio == IntPtr.Zero)
                    return false;

                try {
                    do {
                        var search = new BluetoothDeviceSearchParams();
                        search.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceSearchParams));
                        search.fReturnAuthenticated = 1;
                        search.fReturnRemembered = 1;
                        search.fReturnUnknown = 0;
                        search.fReturnConnected = 1;
                        search.fIssueInquiry = 0;
                        search.cTimeoutMultiplier = 0;
                        search.hRadio = radio;

                        var info = new BluetoothDeviceInfo();
                        info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                        IntPtr findDevice = BluetoothFindFirstDevice(ref search, ref info);
                        if (findDevice != IntPtr.Zero) {
                            try {
                                do {
                                    if (info.Address == 0) {
                                        info = new BluetoothDeviceInfo();
                                        info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                                        continue;
                                    }
                                    string nameCheckA = info.szName;
                                    var freshA = new BluetoothDeviceInfo();
                                    freshA.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                                    freshA.Address = info.Address;
                                    uint qa = BluetoothGetDeviceInfo(radio, ref freshA);
                                    if (qa == 0 && !string.IsNullOrEmpty(freshA.szName))
                                        nameCheckA = freshA.szName;
                                    if (IsPreferredHeadset(nameCheckA) && info.Address != 0) {
                                        address = info.Address;
                                        return true;
                                    }
                                    info = new BluetoothDeviceInfo();
                                    info.dwSize = Marshal.SizeOf(typeof(BluetoothDeviceInfo));
                                } while (BluetoothFindNextDevice(findDevice, ref info));
                            } finally {
                                BluetoothFindDeviceClose(findDevice);
                            }
                        }
                        CloseHandle(radio);
                        radio = IntPtr.Zero;
                    } while (BluetoothFindNextRadio(findRadio, out radio) && radio != IntPtr.Zero);
                } finally {
                    if (radio != IntPtr.Zero)
                        CloseHandle(radio);
                    BluetoothFindRadioClose(findRadio);
                }
            } catch {
            }
            return address != 0;
        }

        static bool RegisterBtService(ulong address, Guid service, int socketType, int protocol)
        {
            IntPtr guidPtr = Marshal.AllocHGlobal(16);
            IntPtr remotePtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(SockAddrBth)));
            IntPtr csaPtr = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(CsAddrInfo)));
            try {
                Marshal.StructureToPtr(service, guidPtr, false);

                var remote = new SockAddrBth();
                remote.addressFamily = AfBth;
                remote.btAddr = address;
                remote.serviceClassId = service;
                remote.port = 0;
                Marshal.StructureToPtr(remote, remotePtr, false);

                var csa = new CsAddrInfo();
                csa.RemoteAddr.lpSockaddr = remotePtr;
                csa.RemoteAddr.iSockaddrLength = Marshal.SizeOf(typeof(SockAddrBth));
                csa.iSocketType = socketType;
                csa.iProtocol = protocol;
                Marshal.StructureToPtr(csa, csaPtr, false);

                var qs = new WsaQuerySet();
                qs.dwSize = Marshal.SizeOf(typeof(WsaQuerySet));
                qs.lpServiceClassId = guidPtr;
                qs.dwNameSpace = NsBth;
                qs.dwNumberOfCsAddrs = 1;
                qs.lpcsaBuffer = csaPtr;
                return WSASetService(ref qs, RnrServiceRegister, 0) == 0;
            } catch {
                return false;
            } finally {
                Marshal.FreeHGlobal(guidPtr);
                Marshal.FreeHGlobal(remotePtr);
                Marshal.FreeHGlobal(csaPtr);
            }
        }

        static bool RegisterLookedUpService(ulong address, Guid service)
        {
            IntPtr guidPtr = Marshal.AllocHGlobal(16);
            IntPtr ctxPtr = Marshal.StringToHGlobalUni(FormatBtAddress(address));
            try {
                Marshal.StructureToPtr(service, guidPtr, false);
                var qs = new WsaQuerySet();
                qs.dwSize = Marshal.SizeOf(typeof(WsaQuerySet));
                qs.dwNameSpace = NsBth;
                qs.lpServiceClassId = guidPtr;
                qs.lpszContext = ctxPtr;

                IntPtr lookup;
                int flags = LupReturnName | LupReturnAddr | LupFlushCache;
                if (WSALookupServiceBegin(ref qs, flags, out lookup) != 0 || lookup == IntPtr.Zero)
                    return false;

                try {
                    int len = 8192;
                    IntPtr buf = Marshal.AllocHGlobal(len);
                    try {
                        if (WSALookupServiceNext(lookup, LupReturnName | LupReturnAddr, ref len, buf) != 0)
                            return false;
                        var found = (WsaQuerySet)Marshal.PtrToStructure(buf, typeof(WsaQuerySet));
                        found.dwSize = Marshal.SizeOf(typeof(WsaQuerySet));
                        found.dwNameSpace = NsBth;
                        if (found.lpServiceClassId == IntPtr.Zero)
                            found.lpServiceClassId = guidPtr;
                        if (found.dwNumberOfCsAddrs <= 0 || found.lpcsaBuffer == IntPtr.Zero)
                            return false;
                        return WSASetService(ref found, RnrServiceRegister, 0) == 0;
                    } finally {
                        Marshal.FreeHGlobal(buf);
                    }
                } finally {
                    WSALookupServiceEnd(lookup);
                }
            } catch {
                return false;
            } finally {
                Marshal.FreeHGlobal(guidPtr);
                Marshal.FreeHGlobal(ctxPtr);
            }
        }

        // 复现蓝点“连接”：查出 A2DP 服务地址并 WSASetService 建链。
        static bool ConnectAirPodsAudioProfile()
        {
            ulong address;
            if (!TryFindAirPodsAddress(out address)) {
                LogDebug(" ConnectAirPods: TryFindAirPodsAddress failed");
                return false;
            }
            LogDebug(" ConnectAirPods: TryFind address=" + FormatBtAddress(address));

            var wsa = new WsaData();
            int ws = WSAStartup((ushort)WsaDataVersion, ref wsa);
            if (ws != 0) {
                LogDebug(" WSAStartup failed " + ws + " err=" + WSAGetLastError());
                return false;
            }

            try {
                LogDebug(" Try RegisterLookedUp A2DP " + A2dpSinkUuid);
                if (RegisterLookedUpService(address, A2dpSinkUuid)) { LogDebug("  RegisterLookedUp A2DP success"); return true; }
                LogDebug("  RegisterLookedUp A2DP failed err=" + WSAGetLastError());
                LogDebug(" Try RegisterLookedUp AdvancedAudio " + AdvancedAudioUuid);
                if (RegisterLookedUpService(address, AdvancedAudioUuid)) { LogDebug("  RegisterLookedUp Adv success"); return true; }
                LogDebug("  RegisterLookedUp Adv failed err=" + WSAGetLastError());
                LogDebug(" Try RegisterBtService A2DP Seqpacket L2cap");
                if (RegisterBtService(address, A2dpSinkUuid, SockSeqpacket, BthProtoL2cap)) { LogDebug("  RegisterBtService A2DP L2cap success"); return true; }
                LogDebug("  RegisterBtService A2DP L2cap failed err=" + WSAGetLastError());
                LogDebug(" Try RegisterBtService Adv Seqpacket L2cap");
                if (RegisterBtService(address, AdvancedAudioUuid, SockSeqpacket, BthProtoL2cap)) { LogDebug("  RegisterBtService Adv L2cap success"); return true; }
                LogDebug("  RegisterBtService Adv L2cap failed err=" + WSAGetLastError());
                LogDebug(" Try RegisterBtService A2DP Stream Rfcomm");
                if (RegisterBtService(address, A2dpSinkUuid, SockStream, BthProtoRfcomm)) { LogDebug("  RegisterBtService A2DP Rfcomm success"); return true; }
                LogDebug("  RegisterBtService A2DP Rfcomm failed err=" + WSAGetLastError());
                LogDebug(" ConnectAirPods all WSASetService failed final err=" + WSAGetLastError());
                return false;
            } finally {
                WSACleanup();
            }
        }

        static bool HasRememberedHeadset()
        {
            string ignored;
            List<DeviceInfo> candidates = GetDevices(DeviceStateMaskAll, out ignored)
                .FindAll(d => IsPreferredHeadset(d.Name));
            AddRememberedHeadsetIds(candidates);
            return candidates.Count > 0;
        }

        // 未连接时只做安全尝试：启用已存在的 A2DP 节点，并注册音频配置文件。
        // 不对 UNPLUGGED 终点 SetDefault（会 0xE000020B，也不会建链）。
        static HeadsetConnectAttempt ConnectPreferredHeadset()
        {
            LogDebug("ConnectPreferredHeadset start Enable+WSASet");
            bool e1 = EnableAirPodsA2dp();
            LogDebug(" EnableAirPodsA2dp=" + e1);
            bool e2 = ConnectAirPodsAudioProfile();
            LogDebug(" ConnectAirPodsAudioProfile=" + e2);
            bool e3 = false;
            if (PnpFallbackEnabled) {
                LogDebug(" ConnectPreferredHeadset try Pnp fallback");
                try { e3 = EnableViaPnpFallback(); } catch {}
            } else {
                LogDebug(" ConnectPreferredHeadset skip Pnp fallback");
            }

            var attempt = new HeadsetConnectAttempt();
            // err=87 / WSA 10022 都不是成功；只有 API 返回 0 才算真正改了链路。
            attempt.LinkActionSucceeded = e1 || e2 || e3;

            string ignored;
            List<DeviceInfo> candidates = GetDevices(DeviceStateMaskAll, out ignored)
                .FindAll(d => IsPreferredHeadset(d.Name));
            AddRememberedHeadsetIds(candidates);
            attempt.Remembered = candidates.Count > 0;

            for (int i = 0; i < candidates.Count; i++) {
                if ((candidates[i].State & DeviceStateActive) != 0) {
                    attempt.ActiveHeadset = candidates[i];
                    LogDebug(" ConnectPreferredHeadset already ACTIVE " + candidates[i].Name);
                    return attempt;
                }
            }

            attempt.BluetoothConnected = PreferredHeadsetBluetoothConnected();
            LogDebug(" PreferredHeadsetBluetoothConnected=" + attempt.BluetoothConnected
                + " link=" + attempt.LinkActionSucceeded
                + " remembered=" + attempt.Remembered);
            return attempt;
        }

        static int FinishHeadsetConnect(HeadsetConnectAttempt attempt, int activeCount)
        {
            if (attempt.ActiveHeadset != null)
                return SwitchToDevice(attempt.ActiveHeadset, "音频切换失败");

            // 只有 Enable/WSA/PNP 真正成功才等 ACTIVE；蓝牙已连但没立体声立即失败。
            if (attempt.LinkActionSucceeded) {
                DeviceInfo connected = WaitForActiveHeadset();
                if (connected != null)
                    return SwitchToDevice(connected, "音频切换失败");
                Console.WriteLine("ERROR|连接超时");
                return 1;
            }
            if (attempt.BluetoothConnected) {
                Console.WriteLine("ERROR|蓝牙已连但立体声未就绪");
                return 1;
            }
            if (activeCount == 0 && !attempt.Remembered) {
                Console.WriteLine("NO_DEVICE|无可用音频播放设备");
                return 1;
            }
            if (attempt.Remembered) {
                Console.WriteLine("ERROR|耳机未取出或不在附近");
                return 1;
            }
            Console.WriteLine("ERROR|耳机未就绪");
            return 1;
        }

        static int SwitchToDevice(DeviceInfo device, string failText)
        {
            if (device == null) {
                Console.WriteLine("ERROR|" + failText);
                return 1;
            }
            // 只对当前 ACTIVE 终点设默认。未建链的 MMDevice ID 会触发 0xE000020B。
            if ((device.State & DeviceStateActive) == 0) {
                Console.WriteLine("ERROR|耳机未激活");
                return 1;
            }
            if (SetDefault(device.Id)) {
                Console.WriteLine("SWITCHED|" + device.Name);
                return 0;
            }
            Console.WriteLine("ERROR|音频切换失败");
            return 1;
        }

        // TTS 预热：确保耳机为默认，不做 Toggle 回切
        static int EnsureHeadsetActive()
        {
            EnsureConfigLoaded();
            LogDebug("EnsureHeadsetActive start");
            string defaultId;
            List<DeviceInfo> active = GetDevices(DeviceStateActive, out defaultId);
            DeviceInfo headset = FindPreferredHeadset(active);
            DeviceInfo current = active.Find(d => d.IsDefault);
            LogDebug(" Ensure active=" + active.Count + " headset=" + (headset!=null?headset.Name:"null") + " current=" + (current!=null?current.Name:"null"));
            if (headset != null && current != null && current.Id == headset.Id) {
                Console.WriteLine("SWITCHED|" + headset.Name);
                return 0;
            }
            if (headset != null) return SwitchToDevice(headset, "音频切换失败");
            return FinishHeadsetConnect(ConnectPreferredHeadset(), active.Count);
        }

        // Caps+D：G27Q2 <-> AirPods 立体声。只改默认输出。
        // 未连接时先尝试连立体声；只有立体声真正变成 ACTIVE 才 SetDefault。
        static int TogglePreferredOutputs()
        {
            EnsureConfigLoaded();
            LogDebug("Toggle start");
            string defaultId;
            List<DeviceInfo> active = GetDevices(DeviceStateActive, out defaultId);
            DeviceInfo speaker = FindPreferredSpeaker(active);
            DeviceInfo headset = FindPreferredHeadset(active);
            DeviceInfo current = active.Find(d => d.IsDefault);
            LogDebug(" Toggle active=" + active.Count + " headset=" + (headset!=null?headset.Name:"null") + " speaker=" + (speaker!=null?speaker.Name:"null") + " current=" + (current!=null?current.Name:"null") + " defaultId=" + defaultId);

            // 默认已是 AirPods 立体声：切回显示器，不断开蓝牙。
            if (headset != null && current != null && current.Id == headset.Id) {
                if (speaker == null) {
                    Console.WriteLine("ONLY_ONE|" + headset.Name);
                    return 0;
                }
                return SwitchToDevice(speaker, "没有可回退设备");
            }

            // 耳机已激活但不是默认：只切默认输出。
            if (headset != null)
                return SwitchToDevice(headset, "音频切换失败");

            return FinishHeadsetConnect(ConnectPreferredHeadset(), active.Count);
        }

        public static int Main(string[] args)
        {
            try {
                try { Console.OutputEncoding = System.Text.Encoding.UTF8; } catch {}
                // 调试模式：任意位置出现 --debug 即开启，过滤后不影响原有命令解析
                var argList = new List<string>(args);
                if (argList.Contains("--debug") || argList.Contains("-d") || argList.Contains("--verbose")) {
                    DebugMode = true;
                    argList.RemoveAll(a => a == "--debug" || a == "-d" || a == "--verbose");
                    args = argList.ToArray();
                    try { System.IO.File.WriteAllText(DebugLog, "=== " + DateTime.Now + " args=" + string.Join(" ", args) + " ===" + Environment.NewLine, System.Text.Encoding.UTF8); } catch {}
                    LogDebug("ConnectWaitMs=" + ConnectWaitMs + " headsetKeywords=" + string.Join(",", HeadsetKeywords));
                }
                string defId;
                var list = GetDevices(out defId);

                // 纯调试：转储蓝牙/WASAPI 状态，不做切换
                if (args.Length>0 && (args[0]=="--debug-dump" || args[0]=="--dump")) {
                    DumpDebugInfo();
                    return 0;
                }

                if (args.Length == 0 || args[0] == "--toggle" || args[0] == "-t") {
                    return TogglePreferredOutputs();
                }

                if (args[0] == "--ensure-headset" || args[0] == "--ensure" || args[0] == "-e") {
                    return EnsureHeadsetActive();
                }

                if (args[0] == "--list" || args[0] == "-l") {
                    foreach (var d in list) {
                        Console.WriteLine((d.IsDefault ? "*" : " ") + "|" + d.Id + "|" + d.Name);
                    }
                    return 0;
                }

                if (args[0] == "--get" || args[0] == "-g") {
                    var def = list.Find(d => d.IsDefault);
                    if (def != null) {
                        Console.WriteLine("DEFAULT|" + def.Name);
                    } else {
                        Console.WriteLine("NO_DEFAULT");
                    }
                    return 0;
                }

                if ((args[0] == "--set" || args[0] == "-s") && args.Length > 1) {
                    string target = args[1];
                    var dev = list.Find(d => d.Id.Equals(target, StringComparison.OrdinalIgnoreCase) || d.Name.IndexOf(target, StringComparison.OrdinalIgnoreCase) >= 0);
                    if (dev == null) {
                        Console.WriteLine("NOT_FOUND|" + target);
                        return 1;
                    }
                    if (SetDefault(dev.Id)) {
                        Console.WriteLine("SWITCHED|" + dev.Name);
                        return 0;
                    }
                    Console.WriteLine("ERROR|音频切换失败");
                    return 1;
                }

                Console.WriteLine("Usage: audio-switcher.exe [--toggle | --ensure-headset | --list | --get | --set <name/id> | --debug-dump]");
                return 0;
            } catch (Exception ex) {
                if (IsNoSuchDevinst(ex)) {
                    Console.WriteLine("ERROR|设备节点不存在");
                    return 1;
                }
                Console.WriteLine("ERROR|音频切换失败");
                return 1;
            }
        }
    }
}
