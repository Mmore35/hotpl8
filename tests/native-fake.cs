using System;
using System.IO;
using System.Text;
using System.Threading;
// Stand-in for the compiled reader. Environment variables choose every answer, so the routing
// in hotpl8.ps1 can be tested against answers and failures a real build cannot produce.
public class NativeFake {
 public static int Main(string[] args) {
  var log = Environment.GetEnvironmentVariable("HOTPL8_TEST_NATIVE_LOG");
  if (!string.IsNullOrEmpty(log)) File.AppendAllText(log, string.Join("|", args) + "\n");
  if (Environment.GetEnvironmentVariable("HOTPL8_TEST_NATIVE_HANG") == "1") Thread.Sleep(30000);
  // Raw bytes: the console encoder would otherwise translate the answer.
  var bytes = new UTF8Encoding(false).GetBytes(Environment.GetEnvironmentVariable("HOTPL8_TEST_NATIVE_OUTPUT") ?? "");
  using (var stdout = Console.OpenStandardOutput()) stdout.Write(bytes, 0, bytes.Length);
  Console.Error.Write("fixture diagnostic");
  int code;
  return int.TryParse(Environment.GetEnvironmentVariable("HOTPL8_TEST_NATIVE_EXIT"), out code) ? code : 0;
 }
}
