using System;
using System.IO;
using System.Collections.Generic;
using System.Web.Script.Serialization;
public class T3FakeCodex {
    static JavaScriptSerializer json = new JavaScriptSerializer();
    static void Send(object value) { Console.WriteLine(json.Serialize(value)); Console.Out.Flush(); }
    public static int Main(string[] args) {
        Console.InputEncoding = new System.Text.UTF8Encoding(false);
        Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        if(args.Length == 1 && args[0] == "--version") { Console.WriteLine("codex-cli fixture"); return 0; }
        string home = Environment.GetEnvironmentVariable("CODEX_HOME");
        if(args[0] == "exec") {
            File.WriteAllText(Environment.GetEnvironmentVariable("HOTPL8_TEST_LAUNCH"), json.Serialize(new {args=args,home=home,input=Console.In.ReadToEnd()}));
            File.AppendAllText(Environment.GetEnvironmentVariable("HOTPL8_TEST_LAUNCH")+".runs","1\n");
            return 7;
        }
        string account = Path.GetFileName(home), line;
        bool active = false; int toolExecutions = 0;
        while((line=Console.ReadLine()) != null) {
            var message = json.Deserialize<Dictionary<string,object>>(line);
            if(!message.ContainsKey("id") || !message.ContainsKey("method")) continue;
            var id=message["id"]; string method=(string)message["method"];
            var p=message.ContainsKey("params") ? message["params"] as Dictionary<string,object> : null;
            object result=new {};
            if(method=="initialize") result=new {userAgent="codex/fixture"};
            if(method=="account/login/start") { account=(string)p["chatgptAccountId"]; result=new {type="chatgptAuthTokens"}; }
            if(method=="account/read") result=new {account=new {type="chatgpt",email=account+"@example.invalid",planType="plus"},requiresOpenaiAuth=true};
            if(method=="account/rateLimits/read") {
                string gate=Path.Combine(home,"quota-gate");
                if(File.Exists(gate)) {
                    File.WriteAllText(Path.Combine(home,"quota-entered"),"fixture");
                    while(File.Exists(gate)) System.Threading.Thread.Sleep(10);
                }
                int used=File.Exists(Path.Combine(home,"exhausted"))?100:10;
                if(File.Exists(Path.Combine(home,"used-percent"))) used=Int32.Parse(File.ReadAllText(Path.Combine(home,"used-percent")));
                result=new {rateLimits=new {limitId="codex",primary=new {usedPercent=used,windowDurationMins=10080,resetsAt=DateTimeOffset.UtcNow.ToUnixTimeSeconds()+3600},secondary=(object)null,spendControlReached=false,rateLimitReachedType=(object)null}};
            }
            if(method=="config/read") result=new {config=new {model="fixture-model",model_provider="openai",cli_auth_credentials_store="ephemeral"}};
            if(method=="thread/start" || method=="thread/resume") result=new {thread=new {id="thread-fixture"}};
            if(method=="turn/start") {
                if(!active) { active=true; toolExecutions++; Send(new {method="turn/started",@params=new {threadId="thread-fixture",turn=new {id="turn-fixture"}}}); }
                Send(new {id=id,result=new {turn=new {id="turn-fixture"},account=account,toolExecutions=toolExecutions}});
                if(!File.Exists(Path.Combine(home,"keep-active"))) { active=false; Send(new {method="turn/completed",@params=new {threadId="thread-fixture",turn=new {id="turn-fixture",status="completed"}}}); }
                continue;
            }
            Send(new {id=id,result=result});
        }
        return 0;
    }
}
