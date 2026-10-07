//! src/lane.ps1 as the collector uses it: the three pieces of a wake PowerShell still does.
//! Each is a program of its own, started only when the wake has that work for it, and it
//! answers with one line of JSON: what it produced, or the failure it met.

use crate::files;
use crate::json;
use crate::obj;
use crate::process;
use crate::ps::*;
use crate::sha256;
use std::path::{Path, PathBuf};

/// A lane that takes longer is given up on. Reading Codex accounts keeps a budget of its
/// own well inside this.
const TIMEOUT_MS: u64 = 90_000;

/// The PowerShell files an event may name as the place of a failure.
const SOURCES: [&str; 7] = ["common.ps1", "claude.ps1", "codex.ps1", "warming.ps1", "insights.ps1", "collection.ps1", "claude-plans.ps1"];

pub struct Lanes<'a> {
    /// The release whose src/lane.ps1 is run.
    pub root: &'a Path,
    pub directory: &'a Path,
    pub powershell: &'a str,
}

/// The PowerShell lanes run in: the one named, and otherwise Windows PowerShell, which the
/// scheduler has always started, or `pwsh` wherever PATH has it.
pub fn powershell(named: Option<&str>) -> String {
    if let Some(named) = named.filter(|named| !named.is_empty()) {
        return named.to_string();
    }
    if cfg!(windows) {
        let root = std::env::var_os("SystemRoot").unwrap_or_default();
        return Path::new(&root).join("System32").join("WindowsPowerShell").join("v1.0").join("powershell.exe").to_string_lossy().into_owned();
    }
    "pwsh".to_string()
}

/// Get-Hotpl8ClaudeSettingsPath
fn claude_settings(home: &Path) -> PathBuf {
    let named = std::env::var_os("CLAUDE_CONFIG_DIR").filter(|value| !value.is_empty());
    named.map_or_else(|| home.join(".claude"), PathBuf::from).join("settings.json")
}

impl Lanes<'_> {
    /// One start of the lane file. A lane that could not be started, overstayed, or
    /// answered with anything but its one line has no answer: nothing it printed is used.
    fn ask(&self, lane: &str, words: &[&str]) -> R<V> {
        let script = self.root.join("src").join("lane.ps1");
        let (Some(script), Some(directory)) = (script.to_str(), self.directory.to_str()) else { return fail("lane_unavailable") };
        let mut arguments = vec!["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", script, "-Lane", lane, "-StateDirectory", directory];
        arguments.extend_from_slice(words);
        let Ok(finished) = process::run(self.powershell, &arguments, TIMEOUT_MS) else { return fail("lane_unavailable") };
        if finished.exit_code != 0 {
            return fail("lane_unavailable");
        }
        let Ok(answer) = json::parse(finished.output.trim(), "lane") else { return fail("lane_unavailable") };
        let failure = answer.g("failure")?;
        if !failure.t()? {
            return Ok(answer);
        }
        let text = |name: &str| -> R<Option<String>> { Ok(failure.g(name)?.as_str().map(str::to_string)) };
        let file = match text("stateFile")? {
            Some(name) => Some((name, failure.g("ioCode")?.to_int()?)),
            None => None,
        };
        let source = match text("source")? {
            Some(name) if SOURCES.contains(&name.as_str()) => Some((name, u32::try_from(failure.g("line")?.to_int()?).unwrap_or(0))),
            _ => None,
        };
        Stop::reported(&failure.g("code")?.s()?, text("said")?, file, source)
    }

    /// Invoke-CodexCollection for one registered provider: what its accounts read.
    pub fn codex(&self, provider: &str, executable: Option<&str>) -> R<V> {
        let mut words = vec!["-Provider", provider];
        if let Some(executable) = executable.filter(|executable| !executable.is_empty()) {
            words.extend(["-CodexExecutable", executable]);
        }
        let payload = self.ask("codex", &words)?.g("payload")?;
        if !payload.is_obj() {
            return fail("lane_unavailable");
        }
        Ok(payload)
    }

    /// Everything Set-Hotpl8ContinueHook reads, as one value. Given the same of these it
    /// does the same, and once it has run it has nothing left to do.
    fn hook_inputs(&self, remove: bool, settings: &Path) -> String {
        let mut all = Vec::new();
        let mut part = |bytes: Option<&[u8]>| match bytes {
            Some(bytes) => {
                all.extend((bytes.len() as u64).to_le_bytes());
                all.extend(bytes);
            }
            None => all.extend(u64::MAX.to_le_bytes()),
        };
        let mut file = |path: &Path| part(std::fs::read(path).ok().as_deref());
        file(settings);
        file(&self.directory.join("continue").join("hook.json"));
        file(&self.root.join("build-info.json"));
        if let Some(parent) = self.root.parent() {
            file(&parent.join("installation.json"));
        }
        let install = std::env::var_os("HOTPL8_INSTALL_DIRECTORY").filter(|value| !value.is_empty()).map(PathBuf::from);
        if let Some(install) = &install {
            file(&install.join("delivery.json"));
            part(Some(&[u8::from(install.join("current.json").exists())]));
        }
        // A checkout has no build to name: the file that holds the rule stands for it.
        let rule = std::fs::metadata(self.root.join("src").join("lifecycle.ps1")).ok();
        let changed = rule.as_ref().and_then(|file| file.modified().ok()).and_then(|at| at.duration_since(std::time::UNIX_EPOCH).ok());
        part(Some(format!("{:?} {:?}", rule.map(|file| file.len()), changed.map(|at| at.as_nanos())).as_bytes()));
        let search = if cfg!(windows) { None } else { std::env::var_os("PATH") };
        for text in [Some(settings.as_os_str()), install.as_ref().map(|path| path.as_os_str()), Some(self.root.as_os_str()), Some(self.directory.as_os_str()), search.as_deref()] {
            part(text.map(|text| text.to_string_lossy().into_owned()).as_deref().map(str::as_bytes));
        }
        part(Some(self.powershell.as_bytes()));
        part(Some(&[u8::from(remove)]));
        sha256::hex(&sha256::digest(&all), false)
    }

    /// Set-Hotpl8ContinueHook: Claude's settings hold the continue hook exactly when the
    /// policy says so. PowerShell is started for it only when something it reads has
    /// changed since it last finished; a run that failed is tried again at every wake.
    pub fn continue_hook(&self, remove: bool, home: &Path) -> R<()> {
        let settings = claude_settings(home);
        if !settings.parent().is_some_and(Path::is_dir) {
            return Ok(());
        }
        let memo = self.directory.join("continue").join("upkeep.json");
        let known = json::read_or_null(&memo).g("inputs").ok().and_then(|inputs| inputs.as_str().map(str::to_string));
        if known.is_some_and(|known| known == self.hook_inputs(remove, &settings)) {
            return Ok(());
        }
        self.ask("continue", if remove { &["-Remove"] } else { &[] })?;
        // What the lane left behind is what the next wake finds.
        let inputs = self.hook_inputs(remove, &settings);
        if std::fs::create_dir_all(self.directory.join("continue")).is_ok() {
            let _ = files::write_json(&memo, &obj! {"schemaVersion" => 1, "inputs" => inputs}, 4);
        }
        Ok(())
    }

    /// Whether a saved account addition is waiting to be seen in a snapshot. Which of them
    /// the snapshot now shows is the lane's to say.
    fn onboarding_waits(&self) -> bool {
        let Ok(entries) = std::fs::read_dir(self.directory.join("onboarding")) else { return false };
        entries.flatten().any(|entry| {
            let path = entry.path();
            if !path.extension().is_some_and(|extension| extension.eq_ignore_ascii_case("json")) {
                return false;
            }
            let saved = json::read_or_null(&path);
            let waits = || -> R<bool> { Ok(saved.g("phase")?.eq_s("pending")? && saved.path(&["result", "enrolled"])?.t()?) };
            waits().unwrap_or(true)
        })
    }

    /// Complete-Hotpl8ObservedOnboarding
    pub fn onboarding(&self) -> R<()> {
        if self.onboarding_waits() {
            self.ask("onboarding", &[])?;
        }
        Ok(())
    }
}
