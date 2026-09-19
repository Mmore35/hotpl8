// Native argv-preserving entrypoint for T3. No cmd.exe expansion of user input.
using System;
using System.IO;
using System.Diagnostics;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Text.RegularExpressions;
public static class Hotpl8T3Launcher {
    static void Relay(Stream input, Stream output) {
        byte[] buffer = new byte[8192]; int count;
        while ((count = input.Read(buffer, 0, buffer.Length)) > 0) { output.Write(buffer, 0, count); output.Flush(); }
    }
    public static string Quote(string value) {
        if (value.Length > 0 && !Regex.IsMatch(value, "[\\s\"]")) return value;
        return "\"" + Regex.Replace(Regex.Replace(value, "(\\\\*)\"", "$1$1\\\""), "(\\\\+)$", "$1$1") + "\"";
    }
    public static int Main(string[] args) {
        try {
            string root = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
            string path = Path.Combine(root, "bridge-config.json");
            var config = new JavaScriptSerializer().Deserialize<Dictionary<string,object>>(File.ReadAllText(path));
            var argv = new List<string> { (string)config["script"], "--bridge-config", path };
            argv.AddRange(args);
            var start = new ProcessStartInfo((string)config["node"], string.Join(" ", argv.ConvertAll(Quote)));
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardInput = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            Console.InputEncoding = new System.Text.UTF8Encoding(false);
            using (var child = Process.Start(start)) {
                var output = System.Threading.Tasks.Task.Run(() => Relay(child.StandardOutput.BaseStream, Console.OpenStandardOutput()));
                var errors = System.Threading.Tasks.Task.Run(() => Relay(child.StandardError.BaseStream, Console.OpenStandardError()));
                // Console pipes on .NET Framework can block before ReadAsync
                // returns. Keep stdin off the thread waiting for a --version exit.
                System.Threading.Tasks.Task.Run(() => {
                    try { Relay(Console.OpenStandardInput(), child.StandardInput.BaseStream); child.StandardInput.Close(); } catch {}
                });
                child.WaitForExit();
                output.Wait(); errors.Wait();
                return child.ExitCode;
            }
        } catch {
            Console.Error.WriteLine("HotPl8: routing_launcher_failed");
            return 1;
        }
    }
}
