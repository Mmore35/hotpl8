# Native process boundaries shared by the durable operation and provider handoff.
function Initialize-Hotpl8LoginReader {
    if('HotPl8.NativeLoginReader' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Concurrent;
using System.Threading;
namespace HotPl8 {
    public sealed class NativeLoginReader {
        private readonly ConcurrentQueue<byte[]> chunks = new ConcurrentQueue<byte[]>();
        public volatile bool LimitExceeded;
        public NativeLoginReader(Stream stream) {
            var thread = new Thread(() => {
                try {
                    var buffer = new byte[4096]; int total = 0; int count;
                    while ((count = stream.Read(buffer, 0, buffer.Length)) > 0) {
                        total += count;
                        if (total > 1048576) { LimitExceeded = true; return; }
                        var chunk = new byte[count]; Array.Copy(buffer, chunk, count); chunks.Enqueue(chunk);
                    }
                } catch (IOException) { } catch (ObjectDisposedException) { }
            });
            thread.IsBackground = true; thread.Start();
        }
        public byte[] Take() { byte[] value; return chunks.TryDequeue(out value) ? value : null; }
    }
}
'@
}
function Start-Hotpl8WindowsWorker([string]$Executable,[string]$Arguments) {
    if(-not ('HotPl8.OnboardingLauncher' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace HotPl8 {
    public static class OnboardingLauncher {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct Startup {
            public int cb; public IntPtr reserved, desktop, title;
            public int x, y, width, height, charsX, charsY, fill, flags;
            public short show, reservedSize; public IntPtr reservedBytes, input, output, error;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct ProcessInfo { public IntPtr process, thread; public int processId, threadId; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool CreateProcessW(string app, StringBuilder command, IntPtr processAttributes,
            IntPtr threadAttributes, [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint flags,
            IntPtr environment, string directory, ref Startup startup, out ProcessInfo info);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr handle);
        public static void Start(string executable, string command) {
            var startup = new Startup(); startup.cb = Marshal.SizeOf(typeof(Startup)); ProcessInfo info;
            startup.flags = 1; startup.show = 0; // STARTF_USESHOWWINDOW, SW_HIDE
            // .NET Framework Process.Start can inherit unrelated response-pipe handles.
            // A private hidden console supports Framework UTF-8 code-page setup without
            // sharing the caller's console or inheriting any of its response pipes.
            if (!CreateProcessW(executable, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false,
                    0x00000010, IntPtr.Zero, null, ref startup, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            CloseHandle(info.thread); CloseHandle(info.process);
        }
    }
}
'@
    }
    [HotPl8.OnboardingLauncher]::Start($Executable,((ConvertTo-NativeArgument $Executable)+' '+$Arguments))
}
