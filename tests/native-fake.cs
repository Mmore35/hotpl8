using System;
using System.IO;
using System.Text;
// Stand-in for a candidate's compiled reader. Environment variables choose its answer, so the
// live preview can be tested against a reader that has a dashboard, which no build has yet.
public class NativeFake {
 public static int Main(string[] args) {
  var log = Environment.GetEnvironmentVariable("HOTPL8_TEST_NATIVE_LOG");
  if (!string.IsNullOrEmpty(log)) File.AppendAllText(log, string.Join("|", args) + "\n");
  // Raw bytes: the console encoder would otherwise translate the answer.
  var bytes = new UTF8Encoding(false).GetBytes(Environment.GetEnvironmentVariable("HOTPL8_TEST_NATIVE_OUTPUT") ?? "");
  using (var stdout = Console.OpenStandardOutput()) stdout.Write(bytes, 0, bytes.Length);
  Console.Error.Write("fixture diagnostic");
  int code;
  return int.TryParse(Environment.GetEnvironmentVariable("HOTPL8_TEST_NATIVE_EXIT"), out code) ? code : 0;
 }
}
