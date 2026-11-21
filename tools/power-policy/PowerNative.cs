using System;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace ToolboxPower {
    public sealed class Snapshot {
        public int Lid; // -1 unknown; never infer current lid state from historical logs.
        public long LidVersion, ResetVersion;
        public int LidCallbacks, PowerCallbacks, DisplayCallbacks, DisplayState;
        public uint LidRegistrationError, PowerRegistrationError, ResumeRegistrationError, DisplayRegistrationError;
    }

    public static class Native {
        static readonly object Gate = new object();
        static readonly ConcurrentQueue<string> Events = new ConcurrentQueue<string>();
        static readonly Guid LidGuid = new Guid("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
        static readonly Guid PowerGuid = new Guid("5D3E9A59-E9D5-4B00-A6BD-FF34FF516548");
        static readonly Guid DisplayGuid = new Guid("6FE69556-704A-47A0-8F24-C28D936FDA47");
        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate uint Notify(IntPtr context, uint type, IntPtr setting);
        [StructLayout(LayoutKind.Sequential)]
        struct Subscription { public Notify Callback; public IntPtr Context; }
        // Root both delegate and subscription for the entire native registration lifetime.
        static readonly Notify Callback = OnNotify;
        static Subscription Recipient = new Subscription { Callback = Callback };
        static IntPtr LidHandle, PowerHandle, ResumeHandle, DisplayHandle;
        static int Lid = -1, LidCallbacks, PowerCallbacks, DisplayState = -1, DisplayCallbacks;
        static long LidVersion, ResetVersion;
        static uint LidError, PowerError, ResumeError, DisplayError;
        static IntPtr Request;
        static bool Held;
        public static int RequestBalance { get { return Held ? 1 : 0; } }

        [DllImport("powrprof.dll")] static extern uint PowerSettingRegisterNotification(ref Guid guid, uint flags, ref Subscription recipient, out IntPtr registration);
        [DllImport("powrprof.dll")] static extern uint PowerSettingUnregisterNotification(IntPtr registration);
        [DllImport("powrprof.dll")] static extern uint PowerRegisterSuspendResumeNotification(uint flags, ref Subscription recipient, out IntPtr registration);
        [DllImport("powrprof.dll")] static extern uint PowerUnregisterSuspendResumeNotification(IntPtr registration);
        [DllImport("powrprof.dll")] static extern uint PowerGetActiveScheme(IntPtr root, out IntPtr scheme);
        [DllImport("powrprof.dll")] static extern uint PowerReadACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
        [DllImport("powrprof.dll")] static extern uint PowerReadDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, out uint value);
        [DllImport("powrprof.dll")] static extern uint PowerWriteACValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, uint value);
        [DllImport("powrprof.dll")] static extern uint PowerWriteDCValueIndex(IntPtr root, ref Guid scheme, ref Guid subgroup, ref Guid setting, uint value);
        [DllImport("powrprof.dll")] static extern uint PowerSetActiveScheme(IntPtr root, ref Guid scheme);
        [DllImport("kernel32.dll")] static extern IntPtr LocalFree(IntPtr memory);
        [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr PowerCreateRequest(IntPtr reason);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool PowerSetRequest(IntPtr request, int type);
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool PowerClearRequest(IntPtr request, int type);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
        [StructLayout(LayoutKind.Sequential)]
        struct PowerStatus { public byte AC, BatteryFlag, Percent, Flag; public int Life, FullLife; }
        [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetSystemPowerStatus(out PowerStatus status);

        static void Check(uint error) { if (error != 0) throw new Win32Exception((int)error); }
        public static int PowerSource() {
            PowerStatus status;
            if (!GetSystemPowerStatus(out status)) throw new Win32Exception(Marshal.GetLastWin32Error());
            return status.AC; // 0 battery, 1 AC, 255 unknown.
        }
        public static Guid ActiveScheme() {
            IntPtr pointer; Check(PowerGetActiveScheme(IntPtr.Zero, out pointer));
            try { return (Guid)Marshal.PtrToStructure(pointer, typeof(Guid)); }
            finally { LocalFree(pointer); }
        }
        public static uint Read(Guid scheme, Guid subgroup, Guid setting, bool ac) {
            uint value; Check(ac ? PowerReadACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value)
                                : PowerReadDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, out value));
            return value;
        }
        public static void Write(Guid scheme, Guid subgroup, Guid setting, bool ac, uint value) {
            Check(ac ? PowerWriteACValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, value)
                     : PowerWriteDCValueIndex(IntPtr.Zero, ref scheme, ref subgroup, ref setting, value));
        }
        public static void Activate(Guid scheme) { Check(PowerSetActiveScheme(IntPtr.Zero, ref scheme)); }

        public static void StartNotifications() {
            // 每路独立判重：旧实现「Lid 或 Power 成功就整体 return」，其它几路失败后
            // 再调也补不上，而日志里只报了 lid/power/resume。
            Guid lid = LidGuid, power = PowerGuid, display = DisplayGuid;
            if (LidHandle == IntPtr.Zero)
                LidError = PowerSettingRegisterNotification(ref lid, 2, ref Recipient, out LidHandle);
            if (PowerHandle == IntPtr.Zero)
                PowerError = PowerSettingRegisterNotification(ref power, 2, ref Recipient, out PowerHandle);
            if (DisplayHandle == IntPtr.Zero)
                DisplayError = PowerSettingRegisterNotification(ref display, 2, ref Recipient, out DisplayHandle);
            if (ResumeHandle == IntPtr.Zero)
                ResumeError = PowerRegisterSuspendResumeNotification(2, ref Recipient, out ResumeHandle);
        }
        static uint OnNotify(IntPtr context, uint type, IntPtr setting) {
            try {
                lock (Gate) {
                    if (type == 0x8013 && setting != IntPtr.Zero) {
                        Guid guid = (Guid)Marshal.PtrToStructure(setting, typeof(Guid));
                        if (Marshal.ReadInt32(setting, 16) < 4) return 0;
                        int value = Marshal.ReadInt32(setting, 20);
                        if (guid == LidGuid && (value == 0 || value == 1)) {
                            Lid = value; LidCallbacks++; LidVersion++;
                            Events.Enqueue("lid=" + (value == 1 ? "open" : "closed") + " utc=" + DateTime.UtcNow.ToString("o"));
                        } else if (guid == PowerGuid) {
                            PowerCallbacks++; ResetVersion++;
                            Events.Enqueue("power=" + value + " utc=" + DateTime.UtcNow.ToString("o"));
                        } else if (guid == DisplayGuid) {
                            DisplayState = value; DisplayCallbacks++;
                            Events.Enqueue("display=" + value + " utc=" + DateTime.UtcNow.ToString("o"));
                        }
                    } else if (type == 7 || type == 0x12) {
                        ResetVersion++;
                        Events.Enqueue("resume=" + type + " utc=" + DateTime.UtcNow.ToString("o"));
                    }
                }
            } catch (Exception ex) { Events.Enqueue("callback-error=" + ex.Message); }
            return 0;
        }
        public static Snapshot GetSnapshot() {
            lock (Gate) { return new Snapshot { Lid=Lid, LidVersion=LidVersion, ResetVersion=ResetVersion,
                LidCallbacks=LidCallbacks, PowerCallbacks=PowerCallbacks, LidRegistrationError=LidError,
                PowerRegistrationError=PowerError, ResumeRegistrationError=ResumeError,
                DisplayState=DisplayState, DisplayCallbacks=DisplayCallbacks, DisplayRegistrationError=DisplayError }; }
        }
        public static string[] DrainEvents() {
            var list = new System.Collections.Generic.List<string>(); string item;
            while (Events.TryDequeue(out item)) list.Add(item);
            return list.ToArray();
        }
        public static void StopNotifications() {
            if (LidHandle != IntPtr.Zero) PowerSettingUnregisterNotification(LidHandle);
            if (PowerHandle != IntPtr.Zero) PowerSettingUnregisterNotification(PowerHandle);
            if (ResumeHandle != IntPtr.Zero) PowerUnregisterSuspendResumeNotification(ResumeHandle);
            if (DisplayHandle != IntPtr.Zero) PowerSettingUnregisterNotification(DisplayHandle);
            LidHandle = PowerHandle = ResumeHandle = DisplayHandle = IntPtr.Zero;
        }

        // One request per handle: repeated polls never increment the native reference count.
        // Recreate after resume/power changes rather than trusting a possibly terminated request.
        public static bool Hold(bool recreate) {
            if (recreate) Release();
            if (Held) return true;
            if (Request == IntPtr.Zero) {
                IntPtr reason = Marshal.AllocHGlobal(IntPtr.Size == 8 ? 32 : 24);
                IntPtr text = Marshal.StringToHGlobalUni("Lat3ncy PowerPolicy: Caffeine keep-awake");
                try {
                    for (int i=0; i<(IntPtr.Size == 8 ? 32 : 24); i++) Marshal.WriteByte(reason, i, 0);
                    Marshal.WriteInt32(reason, 4, 1); Marshal.WriteIntPtr(reason, 8, text);
                    Request = PowerCreateRequest(reason);
                    if (Request == IntPtr.Zero || Request == new IntPtr(-1)) {
                        Request = IntPtr.Zero; throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                } finally { Marshal.FreeHGlobal(reason); Marshal.FreeHGlobal(text); }
            }
            if (!PowerSetRequest(Request, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            Held = true; return true;
        }
        public static void Release() {
            if (Request != IntPtr.Zero) {
                if (Held) PowerClearRequest(Request, 1);
                CloseHandle(Request); Request = IntPtr.Zero;
            }
            Held = false;
        }
    }
}
