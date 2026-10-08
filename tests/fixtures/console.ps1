# Opens the dashboard on this process's own console, presses its keys and records what the
# screen showed. tests/test-dashboard.ps1 starts it with a hidden console of its own, so no
# window is shown and no other console is read. Fictional state only.
param(
    [Parameter(Mandatory)][string]$Program,
    [Parameter(Mandatory)][string]$ArgumentsFile,
    [Parameter(Mandatory)][string]$Status,
    [Parameter(Mandatory)][string]$NextStatus,
    [Parameter(Mandatory)][string]$Changed,
    [Parameter(Mandatory)][string]$Report
)
$ErrorActionPreference='Stop'
$seen=[ordered]@{}
try{
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class Hotpl8TestConsole {
    [StructLayout(LayoutKind.Sequential)] public struct Coord { public short X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public short Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct Info { public Coord Size; public Coord Cursor; public ushort Attributes; public Rect Window; public Coord Largest; }
    [StructLayout(LayoutKind.Sequential)] public struct CursorInfo { public uint Size; public int Visible; }
    [StructLayout(LayoutKind.Explicit, CharSet=CharSet.Unicode)] public struct Input {
        [FieldOffset(0)] public ushort Type; [FieldOffset(4)] public int Down; [FieldOffset(8)] public ushort Repeat;
        [FieldOffset(10)] public ushort Key; [FieldOffset(12)] public ushort Scan; [FieldOffset(14)] public char Character; [FieldOffset(16)] public uint Control; }
    [DllImport("kernel32", CharSet=CharSet.Unicode)] static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32")] static extern bool GetConsoleScreenBufferInfo(IntPtr handle, out Info info);
    [DllImport("kernel32")] static extern bool GetConsoleCursorInfo(IntPtr handle, out CursorInfo info);
    [DllImport("kernel32", CharSet=CharSet.Unicode)] static extern bool ReadConsoleOutputCharacterW(IntPtr handle, StringBuilder text, uint length, Coord at, out uint read);
    [DllImport("kernel32", CharSet=CharSet.Unicode)] static extern bool WriteConsoleInputW(IntPtr handle, Input[] records, uint length, out uint written);
    [DllImport("kernel32")] static extern bool GetConsoleMode(IntPtr handle, out uint mode);
    // The screen in use: the dashboard's own while it is open, the console's first one after.
    static IntPtr Open(string name) { return CreateFileW(name, 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero); }
    public static string Screen() {
        IntPtr handle = Open("CONOUT$"); Info info;
        try {
            if (!GetConsoleScreenBufferInfo(handle, out info)) return null;
            int width = info.Window.Right - info.Window.Left + 1, height = info.Window.Bottom - info.Window.Top + 1;
            StringBuilder screen = new StringBuilder();
            for (int row = 0; row < height; row++) {
                StringBuilder text = new StringBuilder(width + 1); uint read;
                Coord at; at.X = info.Window.Left; at.Y = (short)(info.Window.Top + row);
                ReadConsoleOutputCharacterW(handle, text, (uint)width, at, out read);
                screen.Append(text.ToString(0, (int)read).TrimEnd()).Append('\n');
            }
            return screen.ToString();
        } finally { CloseHandle(handle); }
    }
    public static string Modes() {
        IntPtr input = Open("CONIN$"), output = Open("CONOUT$");
        try { uint read, written; GetConsoleMode(input, out read); GetConsoleMode(output, out written); return read + "/" + written; }
        finally { CloseHandle(input); CloseHandle(output); }
    }
    public static bool CursorShown() {
        IntPtr handle = Open("CONOUT$");
        try { CursorInfo info; return GetConsoleCursorInfo(handle, out info) && info.Visible != 0; } finally { CloseHandle(handle); }
    }
    public static bool Press(ushort key, char character, uint control) {
        IntPtr handle = Open("CONIN$");
        try {
            Input[] records = new Input[2];
            for (int i = 0; i < 2; i++) { records[i].Type = 1; records[i].Down = i == 0 ? 1 : 0; records[i].Repeat = 1; records[i].Key = key; records[i].Character = character; records[i].Control = control; }
            uint written; return WriteConsoleInputW(handle, records, 2, out written) && written == 2;
        } finally { CloseHandle(handle); }
    }
}
'@
    # The screen once it shows what is waited for, or as it is when the wait runs out.
    function Wait-Screen([scriptblock]$Shown,[int]$Milliseconds=10000){
        $clock=[Diagnostics.Stopwatch]::StartNew()
        do{$screen=[Hotpl8TestConsole]::Screen();if(& $Shown $screen){return $screen};Start-Sleep -Milliseconds 50}while($clock.ElapsedMilliseconds -lt $Milliseconds)
        $screen
    }
    function Press([int]$Key,[char]$Character=[char]0,[int]$Control=0){if(-not [Hotpl8TestConsole]::Press($Key,$Character,$Control)){throw 'The console took no key.'}}
    $space=0x20;$end=0x23;$homeKey=0x24;$shift=0x10;$extended=0x100
    # Too short for every account, so there is somewhere to scroll to.
    [Console]::SetWindowSize(100,24)
    [Console]::Title='a test console'
    [Console]::WriteLine('THE SCREEN BEFORE')
    $seen.before=[ordered]@{modes=[Hotpl8TestConsole]::Modes();title=[Console]::Title;cursor=[Hotpl8TestConsole]::CursorShown()}
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Program;$start.Arguments=[IO.File]::ReadAllText($ArgumentsFile);$start.UseShellExecute=$false
    $process=[Diagnostics.Process]::Start($start)
    try{
        $seen.opened=Wait-Screen {param($screen) $screen -and $screen -match 'hotpl8\s+\S\s+nyan' -and $screen.Contains('q quit')}
        $seen.during=[ordered]@{modes=[Hotpl8TestConsole]::Modes();title=[Console]::Title;cursor=[Hotpl8TestConsole]::CursorShown()}
        $first=$seen.opened
        $seen.moved=Wait-Screen {param($screen) $screen -cne $first} 3000
        Press $space ' '
        $seen.frozen=Wait-Screen {param($screen) $screen.Contains('FROZEN')}
        # The state changes under a frozen dashboard, which reads its files again every second.
        [IO.File]::Copy($NextStatus,$Status,$true)
        Start-Sleep -Milliseconds 2500
        $seen.held=[Hotpl8TestConsole]::Screen()
        Start-Sleep -Milliseconds 500
        $seen.heldLater=[Hotpl8TestConsole]::Screen()
        $held=$seen.heldLater
        Press $end ([char]0) $extended
        $seen.scrolled=Wait-Screen {param($screen) $screen -cne $held} 3000
        Press $homeKey ([char]0) $extended
        $seen.returned=Wait-Screen {param($screen) $screen -ceq $held} 3000
        Press $space ' '
        $seen.resumed=Wait-Screen {param($screen) $screen.Contains($Changed) -and -not $screen.Contains('FROZEN')}
        # A key that is no key of the dashboard's, and one that only modifies others.
        Press 0x58 'x';Press $shift ([char]0) 0x10
        Start-Sleep -Milliseconds 400
        $seen.openAfterOtherKeys=-not $process.HasExited
        Press 0x51 'q'
        $seen.closedInTime=$process.WaitForExit(5000)
        $seen.exit=if($process.HasExited){$process.ExitCode}else{$null}
    }finally{if(-not $process.HasExited){$process.Kill()}}
    $seen.closed=Wait-Screen {param($screen) $screen.Contains('THE SCREEN BEFORE')} 3000
    $seen.after=[ordered]@{modes=[Hotpl8TestConsole]::Modes();title=[Console]::Title;cursor=[Hotpl8TestConsole]::CursorShown()}
}catch{$seen.error=$_.Exception.Message+' at '+$_.ScriptStackTrace}
[IO.File]::WriteAllText($Report,($seen|ConvertTo-Json -Depth 4),[Text.UTF8Encoding]::new($false))
