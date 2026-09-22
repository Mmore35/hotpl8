// Product-native finite launcher. Registration/triggers stay with HotPl8.
using System;
using System.IO;
using System.Threading;
using System.Diagnostics;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using UltraAgent.Jobs;
public static class FiniteHost {
 static void Record(string file, Dictionary<string, object> value) {
  string stage=file+".tmp"; File.WriteAllText(stage,new JavaScriptSerializer().Serialize(value));
  if(File.Exists(file)) File.Replace(stage,file,null); else File.Move(stage,file);
 }
 [STAThread] public static int Main(string[] args) {
  if(args.Length<4) return 2;
  string dir=null; int code=2; Child child=null;
  var receipt=new Dictionary<string,object>();
  try {
   int seconds=int.Parse(args[0]); if(seconds<1 || seconds>3600) return 2;
   string id=Guid.NewGuid().ToString("N");
   dir=Path.Combine(args[1],id); Directory.CreateDirectory(dir);
   string input=Path.Combine(dir,"stdin.txt"); File.WriteAllText(input,"");
   receipt["schemaVersion"]=1; receipt["runId"]=id; receipt["startedAt"]=DateTime.UtcNow.ToString("o");
   receipt["host"]=System.Reflection.Assembly.GetExecutingAssembly().Location;
   receipt["hostPid"]=Process.GetCurrentProcess().Id;
   receipt["hostCreatedAt"]=Process.GetCurrentProcess().StartTime.ToUniversalTime().ToString("o");
   receipt["status"]="running"; Record(Path.Combine(dir,"run.json"),receipt);
   var argv=new string[args.Length-4]; Array.Copy(args,4,argv,0,argv.Length);
   child=Child.Start(args[3],argv,args[2],input,Path.Combine(dir,"stdout.txt"),Path.Combine(dir,"stderr.txt"),"");
   receipt["childPid"]=child.Id; Record(Path.Combine(dir,"run.json"),receipt);
   var watch=Stopwatch.StartNew();
   bool outputLimit=false;
   while(!child.HasExited && watch.Elapsed.TotalSeconds<seconds) {
    if(new FileInfo(Path.Combine(dir,"stdout.txt")).Length+new FileInfo(Path.Combine(dir,"stderr.txt")).Length>4194304) { outputLimit=true; break; }
    Thread.Sleep(100);
   }
   bool timeout=!child.HasExited; code=outputLimit?125:(timeout?124:child.ExitCode);
   receipt["status"]=outputLimit?"output-limit":(timeout?"timed-out":(code==0?"complete":"failed"));
  } catch(Exception e) { receipt["status"]="failed"; receipt["errorType"]=e.GetType().Name; }
  finally {
   if(child!=null) child.Dispose();
   if(dir!=null) { try { receipt["completedAt"]=DateTime.UtcNow.ToString("o"); receipt["exitCode"]=code; Record(Path.Combine(dir,"run.json"),receipt); } catch {} }
  }
  return code;
 }
}
