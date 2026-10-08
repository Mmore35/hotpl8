# The referee for the compiled reader. `hotpl8 status`, `hotpl8 explain`, the dashboard and
# the tray's view are the reader's, but the rules they show are still computed twice: the
# agent interface and account management read the state through PowerShell
# (Read-Hotpl8Snapshot). Until those ask the reader too, this holds the two to each other.
# It computes, in this process and at a pinned instant, what PowerShell's rules give for the
# files the reader is shown.
#
# It holds no rule of its own: it calls what the product calls, in the order
# hotpl8.ps1 called it when these commands were PowerShell's.
#
# An answer is one of:
#   kind='value'  dump   - the typed form of the value -AsJson serialises (see below);
#                 json   - PowerShell's own JSON text for it
#   kind='text'   text   - what the command prints, each line ended by a line feed
#   kind='error'  message - PowerShell's rules refuse the files
function Get-Hotpl8ParityAnswers([string]$StateDirectory,[string]$PreviewPolicy,[datetimeoffset]$Now) {
    $answers=@{}
    try {
        $policy = Read-Hotpl8Json $(if($PreviewPolicy){$PreviewPolicy}else{Join-Path $StateDirectory 'policy.json'})
        if (-not $policy) { throw 'No valid policy.json. Run hotpl8 setup or see docs/install.md.' }
        Assert-Hotpl8Policy $policy
        $status = Read-Hotpl8Snapshot $StateDirectory $(if($PreviewPolicy){$policy}) -Now $Now
    } catch {
        $failed=@{kind='error';message=$_.Exception.Message}
        foreach($mode in 'status-json','explain-json'){$answers[$mode]=$failed}
        return $answers
    }
    if (-not $status -or -not $status.generatedAt) {
        $answers['status-json']=@{kind='text';text="No cached status. Run hotpl8 refresh.`n"}
    } else {
        try { $answers['status-json']=@{kind='value';json=($status | ConvertTo-Json -Depth 24)} } catch { $answers['status-json']=@{kind='error';message=$_.Exception.Message} }
        # Typed before the pause is added to the snapshot. A failure here is the suite's own.
        if($answers['status-json'].kind -eq 'value'){$answers['status-json'].dump=ConvertTo-Hotpl8ParityDump $status}
    }
    try {
        if($status){$status|Add-Member NoteProperty automationPause (Get-Hotpl8Pause $StateDirectory $Now) -Force}
    } catch {
        $answers['explain-json']=@{kind='error';message=$_.Exception.Message}
        return $answers
    }
    try {
        # The five members `explain -AsJson` has always had.
        $shown=[pscustomobject]@{generatedAt=$status.generatedAt;claude=$status.decision;codex=$status.providers.codex.decisions;pause=$status.automationPause;providerOverview=$status.providerOverview}
        $answers['explain-json']=@{kind='value';json=($shown|ConvertTo-Json -Depth 16)}
    } catch { $answers['explain-json']=@{kind='error';message=$_.Exception.Message} }
    if($answers['explain-json'].kind -eq 'value'){$answers['explain-json'].dump=ConvertTo-Hotpl8ParityDump $shown}
    $answers
}

# A typed dump of a value: one node per line, so two values are equal exactly when their
# dumps are. It records what ConvertTo-Json hides -- whether a number is a 32-bit or 64-bit
# integer, a decimal (with its scale) or a double (by its bits).
#
#   n  null        b:true  boolean      i:5  Int32      l:5  Int64
#   m:4.50  decimal        d:<16 hex digits>  double    s:text  string
#   [ ... ]  array         { ... }  object, in property order
#   h{ ... }  hash table, keys in ordinal order (a hash table has no defined order)
#   v  a property holding "no value" rather than null     ?:Type  anything else
# The walk is compiled: in PowerShell it took longer than the rules it checks.
if(-not ('HotPl8.ParityDump' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Internal;
using System.Text;
namespace HotPl8 {
    public static class ParityDump {
        public static string Write(object value) {
            StringBuilder text = new StringBuilder();
            Node(text, "", null, value);
            return text.ToString();
        }
        static void Quote(StringBuilder text, string value) {
            foreach (char c in value) {
                if (c == '\\') text.Append("\\\\");
                else if (c < 32 || c > 126) text.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                else text.Append(c);
            }
        }
        static void Node(StringBuilder text, string indent, string name, object value) {
            CultureInfo invariant = CultureInfo.InvariantCulture;
            text.Append(indent);
            if (name != null) { Quote(text, name); text.Append(": "); }
            if (value == null || value == AutomationNull.Value) { text.Append("n\n"); return; }
            // PowerShell wraps some values; only an object it built itself has no value underneath.
            PSObject wrapped = value as PSObject;
            bool custom = wrapped != null && wrapped.BaseObject is PSCustomObject;
            if (wrapped != null && !custom) value = wrapped.BaseObject;
            if (value is bool) { text.Append((bool)value ? "b:true\n" : "b:false\n"); return; }
            if (value is int) { text.Append("i:").Append(((int)value).ToString(invariant)).Append('\n'); return; }
            if (value is long) { text.Append("l:").Append(((long)value).ToString(invariant)).Append('\n'); return; }
            if (value is decimal) { text.Append("m:").Append(((decimal)value).ToString(invariant)).Append('\n'); return; }
            if (value is double) { text.Append("d:").Append(BitConverter.DoubleToInt64Bits((double)value).ToString("x16", invariant)).Append('\n'); return; }
            string plain = value as string;
            if (plain != null) { text.Append("s:"); Quote(text, plain); text.Append('\n'); return; }
            string inner = indent + " ";
            Array items = value as Array;
            if (items != null) {
                text.Append("[\n");
                foreach (object item in items) Node(text, inner, null, item);
                text.Append(indent).Append("]\n");
                return;
            }
            IDictionary table = value as IDictionary;
            if (table != null) {
                text.Append("h{\n");
                List<KeyValuePair<string, object>> entries = new List<KeyValuePair<string, object>>();
                foreach (DictionaryEntry entry in table) entries.Add(new KeyValuePair<string, object>(Convert.ToString(entry.Key, invariant), entry.Value));
                entries.Sort(delegate(KeyValuePair<string, object> a, KeyValuePair<string, object> b) { return string.CompareOrdinal(a.Key, b.Key); });
                foreach (KeyValuePair<string, object> entry in entries) Node(text, inner, entry.Key, entry.Value);
                text.Append(indent).Append("}\n");
                return;
            }
            if (custom) {
                text.Append("{\n");
                foreach (PSPropertyInfo property in wrapped.Properties) {
                    object held = property.Value;
                    // "No value" is not null: it is what a command that wrote nothing leaves behind.
                    if (held == AutomationNull.Value) { text.Append(inner); Quote(text, property.Name); text.Append(": v\n"); }
                    else Node(text, inner, property.Name, held);
                }
                text.Append(indent).Append("}\n");
                return;
            }
            text.Append("?:").Append(value.GetType().FullName).Append('\n');
        }
    }
}
'@
}
function ConvertTo-Hotpl8ParityDump($Value) { [HotPl8.ParityDump]::Write($Value) }
