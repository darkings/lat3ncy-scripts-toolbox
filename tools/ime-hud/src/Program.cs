using System.IO;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;

namespace Lat3ncyToolbox.ImeHud;

/// <summary>
/// 驻留进程入口。单实例：第二个进程把命令转给已有 HWND 后立刻退出。
/// AHK 用 WM_COPYDATA；命令行负责冷启动第一条消息；命名管道只作调试通道。
/// </summary>
internal static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        Native.TryEnablePerMonitorV2();

        if (HasFlag(args, "--self-test"))
            return Protocol.SelfTest();

        string? command = ExtractCommand(args);
        if (HasFlag(args, "--quit"))
            command = "QUIT";

        using Mutex mutex = new(true, Protocol.MutexName, out bool created);
        if (!created)
        {
            IntPtr existing = Native.FindWindow(null, Protocol.WindowTitle);
            if (existing != IntPtr.Zero && !string.IsNullOrWhiteSpace(command))
                SendCopyData(existing, command);
            return 0;
        }

        var app = new Application
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown
        };

        HudWindow? hud = null;
        app.Startup += (_, _) =>
        {
            hud = new HudWindow();
            StartPipeServer(hud);
            if (!string.IsNullOrWhiteSpace(command))
                Dispatch(hud, command);
        };

        app.Run();
        return 0;
    }

    static void Dispatch(HudWindow hud, string command)
    {
        Protocol.Message message = Protocol.Parse(command);
        switch (message.Kind)
        {
            case Protocol.Kind.State:
                hud.ShowState(message);
                break;
            case Protocol.Kind.Hide:
                hud.HideNow();
                break;
            case Protocol.Kind.Quit:
                Application.Current?.Shutdown();
                break;
        }
    }

    static void StartPipeServer(HudWindow hud)
    {
        // 命名管道只给调试和未来扩展；生产路径是 WM_COPYDATA。
        Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    using var server = new NamedPipeServerStream(
                        "Lat3ncyImeHud",
                        PipeDirection.In,
                        1,
                        PipeTransmissionMode.Byte,
                        PipeOptions.Asynchronous);
                    await server.WaitForConnectionAsync().ConfigureAwait(false);
                    using var reader = new StreamReader(
                        server,
                        Encoding.Unicode,
                        detectEncodingFromByteOrderMarks: true,
                        bufferSize: 256,
                        leaveOpen: true);
                    string? line = await reader.ReadLineAsync().ConfigureAwait(false);
                    if (string.IsNullOrWhiteSpace(line))
                        continue;

                    Application.Current?.Dispatcher.Invoke(() => Dispatch(hud, line));
                }
                catch
                {
                    await Task.Delay(200).ConfigureAwait(false);
                }
            }
        });
    }

    static string? ExtractCommand(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            string token = args[i];
            if (token.Equals("--self-test", StringComparison.OrdinalIgnoreCase)
                || token.Equals("--quit", StringComparison.OrdinalIgnoreCase))
                continue;
            if (token.Equals("--state", StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length)
                return "STATE|" + args[i + 1];
            if (token.StartsWith("STATE", StringComparison.OrdinalIgnoreCase)
                || token.Equals("HIDE", StringComparison.OrdinalIgnoreCase)
                || token.Equals("PING", StringComparison.OrdinalIgnoreCase)
                || token.Equals("QUIT", StringComparison.OrdinalIgnoreCase))
                return token;
        }
        return null;
    }

    static bool HasFlag(string[] args, string flag)
    {
        foreach (string arg in args)
        {
            if (arg.Equals(flag, StringComparison.OrdinalIgnoreCase))
                return true;
        }
        return false;
    }

    static void SendCopyData(IntPtr hwnd, string text)
    {
        byte[] bytes = Encoding.Unicode.GetBytes(text + "\0");
        IntPtr buffer = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, buffer, bytes.Length);
            var cds = new Native.COPYDATASTRUCT
            {
                dwData = new IntPtr(Protocol.CopyDataId),
                cbData = bytes.Length,
                lpData = buffer
            };
            Native.SendMessage(hwnd, Native.WM_COPYDATA, IntPtr.Zero, ref cds);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }
}
