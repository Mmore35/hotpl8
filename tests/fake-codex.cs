using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
public class FakeCodex {
 public static int Main(string[] args) {
  // app-server uses UTF-8 pipes even when a hidden process has no console locale.
  Console.InputEncoding = new System.Text.UTF8Encoding(false);
  Console.OutputEncoding = new System.Text.UTF8Encoding(false);
  var json = new JavaScriptSerializer();
  var scenario = Environment.GetEnvironmentVariable("HOTPL8_TEST_SCENARIO") ?? "ok";
  if (args.Length == 0 || args[0] != "app-server") {
   var record = new { args=args, home=Environment.GetEnvironmentVariable("CODEX_HOME"), cwd=Environment.CurrentDirectory, slot=Environment.GetEnvironmentVariable("HOTPL8_SLOT") };
   File.WriteAllText(Environment.GetEnvironmentVariable("HOTPL8_TEST_LAUNCH"), json.Serialize(record));
   return 7;
  }
  if (scenario == "exit") return 8;
  if (scenario == "hang") { Thread.Sleep(30000); return 0; }
  if (scenario == "stderr") Console.Error.Write(new string('x', 100000));
  string line;
  while ((line=Console.ReadLine()) != null) {
   if (!line.Contains("\"id\"")) continue;
   var req=json.Deserialize<Dictionary<string,object>>(line);
   if (line.Contains("config/read") && Convert.ToString(((Dictionary<string,object>)req["params"])["cwd"]) != Environment.CurrentDirectory)
    throw new Exception("Fixture received a corrupted working directory.");
   var id=Convert.ToInt32(req["id"]);
   string result="{}";
   string email=(scenario!="same-account" && (Environment.GetEnvironmentVariable("CODEX_HOME")??"").EndsWith("B"))?"fixture-b@example.invalid":"fixture-a@example.invalid";
   if (scenario=="invalid") { Console.WriteLine("{invalid"); Console.Out.Flush(); continue; }
   if (scenario=="partial") { Console.Write("{\"id\":"); Console.Out.Flush(); Thread.Sleep(30000); return 0; }
   if (line.Contains("account/read")) result=scenario=="noauth" ? "{\"account\":null}" : "{\"account\":{\"type\":\"chatgpt\",\"email\":\""+email+"\"}}";
   if (line.Contains("account/rateLimits/read")) {
    if (scenario=="429" || scenario=="401" || scenario=="403") { Console.WriteLine("{\"id\":"+id+",\"error\":{\"code\":"+scenario+",\"message\":\"SECRET_DO_NOT_LOG\"}}"); Console.Out.Flush(); continue; }
    long reset=DateTimeOffset.UtcNow.ToUnixTimeSeconds()+3600;
    result="{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":10,\"windowDurationMins\":10080,\"resetsAt\":"+reset+"},\"secondary\":null,\"spendControlReached\":false,\"rateLimitReachedType\":null}}";
   }
   if (line.Contains("config/read")) result="{\"config\":{\"model\":\"fixture-model\",\"model_provider\":\"openai\"}}";
   if (line.Contains("config/read") && scenario=="custom-endpoint") result="{\"config\":{\"model\":\"fixture-model\",\"model_provider\":\"openai\",\"chatgpt_base_url\":\"https://example.invalid/backend-api\"}}";
   if (line.Contains("config/read") && scenario=="custom-provider") result="{\"config\":{\"model\":\"fixture-model\",\"model_provider\":\"other\"}}";
   if (scenario=="notify") { Console.WriteLine("{\"method\":\"notification\"}"); Console.WriteLine("{\"id\":999,\"result\":{}}"); }
   Console.WriteLine("{\"id\":"+id+",\"result\":"+result+"}"); Console.Out.Flush();
  }
  return 0;
 }
}
