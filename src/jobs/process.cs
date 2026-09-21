// Native containment boundary. Windows assigns the job AT process creation;
// macOS atomically creates a process group and starts a parent-death guardian.
using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Collections.Generic;

namespace UltraAgent.Jobs {
 public sealed class Child : IDisposable {
  IntPtr job, process; int pid; bool unix, reaped; int code;
  public int Id { get { return pid; } }
  public static string Quote(string s) {
   var b=new StringBuilder("\""); int n=0;
   foreach(char c in s) { if(c=='\\') { n++; continue; }
    if(c=='"') b.Append('\\',n*2+1); else b.Append('\\',n);
    b.Append(c); n=0;
   }
   return b.Append('\\',n*2).Append('"').ToString();
  }
  public static Child Start(string exe,string[] args,string cwd,string input,string stdout,string stderr,string guardian) {
   var c=new Child(); c.unix=Environment.OSVersion.Platform!=PlatformID.Win32NT;
   try { if(c.unix) c.StartUnix(exe,args,cwd,input,stdout,stderr,guardian);
    else c.StartWindows(exe,args,cwd,input,stdout,stderr); return c;
   } catch { c.Dispose(); throw; }
  }
  public bool HasExited {
   get { if(unix) { if(!reaped) { int s; int r=waitpid(pid,out s,1); if(r==pid) { reaped=true; code=(s&127)==0 ? (s>>8)&255 : 128+(s&127); }
      else if(r<0) throw new Win32Exception(Marshal.GetLastWin32Error()); } return reaped; }
    return WaitForSingleObject(process,0)==0; }
  }
  public int ExitCode { get { if(!HasExited) throw new InvalidOperationException("Still running"); if(unix) return code; uint n; Check(GetExitCodeProcess(process,out n)); return unchecked((int)n); } }
  public void Dispose() {
   if(unix) { if(pid>0) { kill(-pid,9); if(!reaped) { int s; waitpid(pid,out s,0); reaped=true; } pid=0; } }
   else { if(job!=IntPtr.Zero) { CloseHandle(job); job=IntPtr.Zero; } if(process!=IntPtr.Zero) { CloseHandle(process); process=IntPtr.Zero; } }
  }
  static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
  void StartWindows(string exe,string[] args,string cwd,string input,string stdout,string stderr) {
   job=CreateJobObject(IntPtr.Zero,null); if(job==IntPtr.Zero) throw new Win32Exception();
   var limits=new Extended(); limits.Basic.LimitFlags=0x2000; // KILL_ON_JOB_CLOSE
   int size=Marshal.SizeOf(limits); IntPtr lp=Marshal.AllocHGlobal(size);
   try { Marshal.StructureToPtr(limits,lp,false); Check(SetInformationJobObject(job,9,lp,(uint)size)); } finally { Marshal.FreeHGlobal(lp); }
   var sa=new Security(); sa.Length=Marshal.SizeOf(sa); sa.Inherit=true;
   var handles=new List<IntPtr>(); IntPtr attrs=IntPtr.Zero, jobs=IntPtr.Zero, hs=IntPtr.Zero;
   bool initialized=false;
   try {
    foreach(string path in new[]{input,stdout,stderr}) {
     IntPtr h=CreateFile(path,handles.Count==0?0x80000000u:0x40000000u,3,ref sa,handles.Count==0?3u:2u,0x80,IntPtr.Zero);
     if(h==new IntPtr(-1)) throw new Win32Exception(); handles.Add(h);
    }
    IntPtr len=IntPtr.Zero; InitializeProcThreadAttributeList(IntPtr.Zero,2,0,ref len);
    attrs=Marshal.AllocHGlobal(len); Check(InitializeProcThreadAttributeList(attrs,2,0,ref len)); initialized=true;
    jobs=Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobs,job);
    // PROC_THREAD_ATTRIBUTE_JOB_LIST: a failed association fails creation; no unowned startup interval.
    Check(UpdateProcThreadAttribute(attrs,0,new IntPtr(0x2000D),jobs,new IntPtr(IntPtr.Size),IntPtr.Zero,IntPtr.Zero));
    hs=Marshal.AllocHGlobal(IntPtr.Size*3); for(int i=0;i<3;i++) Marshal.WriteIntPtr(hs,i*IntPtr.Size,handles[i]);
    Check(UpdateProcThreadAttribute(attrs,0,new IntPtr(0x20002),hs,new IntPtr(IntPtr.Size*3),IntPtr.Zero,IntPtr.Zero));
    var si=new StartupEx(); si.Startup.Size=Marshal.SizeOf(si); si.Attributes=attrs; si.Startup.Flags=0x100;
    si.Startup.In=handles[0]; si.Startup.Out=handles[1]; si.Startup.Err=handles[2];
    var command=new StringBuilder(Quote(exe)); foreach(string a in args) command.Append(' ').Append(Quote(a));
    Info pi; Check(CreateProcess(exe,command,IntPtr.Zero,IntPtr.Zero,true,0x08080000,IntPtr.Zero,cwd,ref si,out pi));
    process=pi.Process; pid=pi.Pid; CloseHandle(pi.Thread);
   } finally {
    foreach(IntPtr h in handles) CloseHandle(h);
    if(initialized) DeleteProcThreadAttributeList(attrs);
    if(attrs!=IntPtr.Zero) Marshal.FreeHGlobal(attrs); if(jobs!=IntPtr.Zero) Marshal.FreeHGlobal(jobs); if(hs!=IntPtr.Zero) Marshal.FreeHGlobal(hs);
   }
  }
  void StartUnix(string exe,string[] args,string cwd,string input,string stdout,string stderr,string guardian) {
   // Darwin's opaque spawn objects are pointer-sized. Only macOS is supported.
   if(!File.Exists("/System/Library/CoreServices/SystemVersion.plist")) throw new PlatformNotSupportedException("macOS required");
   IntPtr attr=IntPtr.Zero, actions=IntPtr.Zero; var allocated=new List<IntPtr>();
   try {
    Native(posix_spawnattr_init(ref attr)); Native(posix_spawn_file_actions_init(ref actions));
    Native(posix_spawnattr_setflags(ref attr,2)); Native(posix_spawnattr_setpgroup(ref attr,0));
    Native(posix_spawn_file_actions_addopen(ref actions,0,input,0,0));
    Native(posix_spawn_file_actions_addopen(ref actions,1,stdout,0x601,384));
    Native(posix_spawn_file_actions_addopen(ref actions,2,stderr,0x601,384));
    var argv=new List<string>{"/bin/sh",guardian,Process.GetCurrentProcess().Id.ToString(),cwd,exe}; argv.AddRange(args);
    var env=new List<string>(); foreach(System.Collections.DictionaryEntry e in Environment.GetEnvironmentVariables()) env.Add(e.Key+"="+e.Value);
    IntPtr ap=Vector(argv,allocated), ep=Vector(env,allocated);
    Native(posix_spawn(out pid,"/bin/sh",ref actions,ref attr,ap,ep));
   } finally { if(attr!=IntPtr.Zero) posix_spawnattr_destroy(ref attr); if(actions!=IntPtr.Zero) posix_spawn_file_actions_destroy(ref actions); foreach(IntPtr p in allocated) Marshal.FreeHGlobal(p); }
  }
  static void Native(int n) { if(n!=0) throw new Win32Exception(n); }
  static IntPtr Vector(List<string> ss,List<IntPtr> allocated) {
   IntPtr p=Marshal.AllocHGlobal((ss.Count+1)*IntPtr.Size); allocated.Add(p);
   for(int i=0;i<ss.Count;i++) { byte[] b=Encoding.UTF8.GetBytes(ss[i]+"\0"); IntPtr s=Marshal.AllocHGlobal(b.Length); allocated.Add(s); Marshal.Copy(b,0,s,b.Length); Marshal.WriteIntPtr(p,i*IntPtr.Size,s); }
   Marshal.WriteIntPtr(p,ss.Count*IntPtr.Size,IntPtr.Zero); return p;
  }
  [StructLayout(LayoutKind.Sequential)] struct Security { public int Length; public IntPtr Descriptor; [MarshalAs(UnmanagedType.Bool)] public bool Inherit; }
  [StructLayout(LayoutKind.Sequential)] struct Basic { public long PerProcess,PerJob; public uint LimitFlags; public UIntPtr Min,Max; public uint Active; public UIntPtr Affinity; public uint Priority,Scheduling; }
  [StructLayout(LayoutKind.Sequential)] struct Io { public ulong A,B,C,D,E,F; }
  [StructLayout(LayoutKind.Sequential)] struct Extended { public Basic Basic; public Io Io; public UIntPtr A,B,C,D; }
  [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct Startup { public int Size; public string Reserved,Desktop,Title; public int X,Y,XSize,YSize,XChars,YChars,Fill,Flags; public short Show,ReservedSize; public IntPtr Reserved2,In,Out,Err; }
  [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup Startup; public IntPtr Attributes; }
  [StructLayout(LayoutKind.Sequential)] struct Info { public IntPtr Process,Thread; public int Pid,Tid; }
  [DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr CreateJobObject(IntPtr a,string b);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool SetInformationJobObject(IntPtr j,int c,IntPtr p,uint n);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool InitializeProcThreadAttributeList(IntPtr p,int n,int f,ref IntPtr s);
  [DllImport("kernel32.dll",SetLastError=true)] static extern bool UpdateProcThreadAttribute(IntPtr p,uint f,IntPtr a,IntPtr v,IntPtr s,IntPtr x,IntPtr y);
  [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr p);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateFile(string p,uint a,uint s,ref Security sa,uint d,uint f,IntPtr t);
  [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool CreateProcess(string a,StringBuilder b,IntPtr c,IntPtr d,bool e,uint f,IntPtr g,string h,ref StartupEx i,out Info j);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h,uint n);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h,out uint n);
  [DllImport("libc",SetLastError=true)] static extern int waitpid(int pid,out int status,int options);
  [DllImport("libc")] static extern int kill(int pid,int signal);
  [DllImport("libc")] static extern int posix_spawnattr_init(ref IntPtr p);
  [DllImport("libc")] static extern int posix_spawnattr_destroy(ref IntPtr p);
  [DllImport("libc")] static extern int posix_spawnattr_setflags(ref IntPtr p,short f);
  [DllImport("libc")] static extern int posix_spawnattr_setpgroup(ref IntPtr p,int g);
  [DllImport("libc")] static extern int posix_spawn_file_actions_init(ref IntPtr p);
  [DllImport("libc")] static extern int posix_spawn_file_actions_destroy(ref IntPtr p);
  [DllImport("libc")] static extern int posix_spawn_file_actions_addopen(ref IntPtr p,int fd,string path,int flags,int mode);
  [DllImport("libc")] static extern int posix_spawn(out int pid,string path,ref IntPtr actions,ref IntPtr attr,IntPtr argv,IntPtr env);
 }
}
