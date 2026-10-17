// Product-native finite launcher. Registration/triggers stay with HotPl8.
using System;
using System.IO;
using System.Threading;
using System.Diagnostics;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using UltraAgent.Jobs;
public static class FiniteHost {
 static void Record(string file, Dictionary<string, object> value) { Record(file,value,file+".tmp"); }
 static void Record(string file, Dictionary<string, object> value, string stage) {
  File.WriteAllText(stage,new JavaScriptSerializer().Serialize(value));
  if(File.Exists(file)) File.Replace(stage,file,null); else File.Move(stage,file);
 }
 // Status reads latest.json instead of searching every receipt. Hosts of one role can
 // overlap, so each stages under its own run id; the last receipt written wins, as the
 // newest run.json did before.
 static void Publish(string runs, string id, Dictionary<string, object> value) {
  try { Record(Path.Combine(runs,"latest.json"),value,Path.Combine(runs,"latest."+id+".tmp")); } catch {}
 }
 // Each wake leaves a folder, so a folder is removed once it is old enough: a complete run
 // after 7 days, any other after 30, judged by its own receipt. A folder whose receipt
 // cannot be read is kept. Nothing here changes the run's exit code.
 static void Prune(string runs, string current) {
  try {
   var now=DateTime.UtcNow; int removed=0;
   foreach(var folder in new DirectoryInfo(runs).EnumerateDirectories()) {
    if(removed>=500) break;
    if(folder.Name==current || folder.CreationTimeUtc>now.AddDays(-7)) continue;
    try {
     var receipt=new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(Path.Combine(folder.FullName,"run.json")));
     object stamp; if(!receipt.TryGetValue("completedAt",out stamp) && !receipt.TryGetValue("startedAt",out stamp)) continue;
     DateTime at=DateTime.Parse((string)stamp,null,System.Globalization.DateTimeStyles.RoundtripKind).ToUniversalTime();
     object status; receipt.TryGetValue("status",out status);
     if(at>now.AddDays("complete".Equals(status)?-7:-30)) continue;
     folder.Delete(true); removed++;
    } catch {}
   }
  } catch {}
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
   receipt["status"]="running"; Record(Path.Combine(dir,"run.json"),receipt); Publish(args[1],id,receipt);
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
   if(dir!=null) {
    try { receipt["completedAt"]=DateTime.UtcNow.ToString("o"); receipt["exitCode"]=code; Record(Path.Combine(dir,"run.json"),receipt); } catch {}
    Publish(args[1],Path.GetFileName(dir),receipt);
    Prune(args[1],Path.GetFileName(dir));
   }
  }
  return code;
 }
}
