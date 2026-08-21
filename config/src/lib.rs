use std::collections::BTreeMap;
use std::ffi::{CStr, c_char, c_int};
use std::fmt;
use std::path::Path;
use std::str::FromStr;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

// ---------------------------------------------------------------------------
// Target — the single source of truth for supported platforms
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[cfg_attr(feature = "cli", derive(clap::ValueEnum))]
pub enum Target {
    #[cfg_attr(feature = "cli", value(name = "x86_64-linux"))]
    X86_64Linux,
    #[cfg_attr(feature = "cli", value(name = "aarch64-linux"))]
    Aarch64Linux,
    #[cfg_attr(feature = "cli", value(name = "x86_64-macos"))]
    X86_64Macos,
    #[cfg_attr(feature = "cli", value(name = "aarch64-macos"))]
    Aarch64Macos,
    #[cfg_attr(feature = "cli", value(name = "x86_64-windows"))]
    X86_64Windows,
    #[cfg_attr(feature = "cli", value(name = "aarch64-windows"))]
    Aarch64Windows,
}

impl Target {
    pub const ALL: &[Target] = &[
        Target::X86_64Linux,
        Target::Aarch64Linux,
        Target::X86_64Macos,
        Target::Aarch64Macos,
        Target::X86_64Windows,
        Target::Aarch64Windows,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            Target::X86_64Linux => "x86_64-linux",
            Target::Aarch64Linux => "aarch64-linux",
            Target::X86_64Macos => "x86_64-macos",
            Target::Aarch64Macos => "aarch64-macos",
            Target::X86_64Windows => "x86_64-windows",
            Target::Aarch64Windows => "aarch64-windows",
        }
    }

    pub fn host() -> Target {
        match (std::env::consts::ARCH, std::env::consts::OS) {
            ("x86_64", "linux") => Target::X86_64Linux,
            ("aarch64", "linux") => Target::Aarch64Linux,
            ("x86_64", "macos") => Target::X86_64Macos,
            ("aarch64", "macos") => Target::Aarch64Macos,
            ("x86_64", "windows") => Target::X86_64Windows,
            ("aarch64", "windows") => Target::Aarch64Windows,
            (arch, os) => panic!("unsupported host platform: {arch}-{os}"),
        }
    }

    pub fn is_linux(&self) -> bool {
        matches!(self, Target::X86_64Linux | Target::Aarch64Linux)
    }

    pub fn is_macos(&self) -> bool {
        matches!(self, Target::X86_64Macos | Target::Aarch64Macos)
    }

    pub fn is_windows(&self) -> bool {
        matches!(self, Target::X86_64Windows | Target::Aarch64Windows)
    }

    pub fn arch(&self) -> Arch {
        match self {
            Target::X86_64Linux | Target::X86_64Macos | Target::X86_64Windows => Arch::X86_64,
            Target::Aarch64Linux | Target::Aarch64Macos | Target::Aarch64Windows => Arch::Aarch64,
        }
    }

    /// Returns the Rust target triple for this target.
    pub fn target_triple(&self) -> &'static str {
        match self {
            Target::X86_64Linux => "x86_64-unknown-linux-gnu",
            Target::Aarch64Linux => "aarch64-unknown-linux-gnu",
            Target::X86_64Macos => "x86_64-apple-darwin",
            Target::Aarch64Macos => "aarch64-apple-darwin",
            Target::X86_64Windows => "x86_64-pc-windows-msvc",
            Target::Aarch64Windows => "aarch64-pc-windows-msvc",
        }
    }
}

impl fmt::Display for Target {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for Target {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        for target in Self::ALL {
            if target.as_str() == s {
                return Ok(*target);
            }
        }
        let valid: Vec<&str> = Self::ALL.iter().map(|t| t.as_str()).collect();
        bail!("unknown target: {s}\nValid targets: {}", valid.join(", "))
    }
}

impl<'de> Deserialize<'de> for Target {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        Target::from_str(&s).map_err(serde::de::Error::custom)
    }
}

impl Serialize for Target {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

// ---------------------------------------------------------------------------
// Arch — architecture without platform
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Arch {
    X86_64,
    Aarch64,
}

impl Arch {
    pub fn as_str(&self) -> &'static str {
        match self {
            Arch::X86_64 => "x86_64",
            Arch::Aarch64 => "aarch64",
        }
    }
}

impl fmt::Display for Arch {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

impl FromStr for Arch {
    type Err = anyhow::Error;

    fn from_str(s: &str) -> Result<Self> {
        match s {
            "x86_64" => Ok(Arch::X86_64),
            "aarch64" => Ok(Arch::Aarch64),
            _ => bail!("unknown architecture: {s}\nValid architectures: x86_64, aarch64"),
        }
    }
}

impl<'de> Deserialize<'de> for Arch {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let s = String::deserialize(deserializer)?;
        Arch::from_str(&s).map_err(serde::de::Error::custom)
    }
}

impl Serialize for Arch {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(self.as_str())
    }
}

// ---------------------------------------------------------------------------
// Format — package formats for all platforms
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
#[cfg_attr(feature = "cli", derive(clap::ValueEnum))]
pub enum Format {
    #[cfg_attr(feature = "cli", value(name = "appimage"))]
    AppImage,
    #[cfg_attr(feature = "cli", value(name = "deb"))]
    Deb,
    #[cfg_attr(feature = "cli", value(name = "rpm"))]
    Rpm,
    #[cfg_attr(feature = "cli", value(name = "pacman"))]
    Pacman,
    #[cfg_attr(feature = "cli", value(name = "archive"))]
    Archive,
    #[cfg_attr(feature = "cli", value(name = "nsis"))]
    Nsis,
    #[cfg_attr(feature = "cli", value(name = "mac-app"))]
    MacApp,
    #[cfg_attr(feature = "cli", value(name = "dmg"))]
    Dmg,
}

impl Format {
    /// Default packaging formats for Linux targets.
    pub const LINUX_DEFAULT: &[Format] = &[
        Format::AppImage,
        Format::Deb,
        Format::Rpm,
        Format::Pacman,
        Format::Archive,
    ];

    /// Default packaging formats for Windows targets.
    pub const WINDOWS_DEFAULT: &[Format] = &[Format::Nsis, Format::Archive];

    /// Default packaging formats for macOS targets.
    /// Includes `Dmg` only when the host is macOS (requires `hdiutil`).
    pub fn macos_default(host_is_macos: bool) -> Vec<Format> {
        let mut fmts = vec![Format::MacApp, Format::Archive];
        if host_is_macos {
            fmts.push(Format::Dmg);
        }
        fmts
    }

    /// Returns whether this format is valid for the given target.
    pub fn valid_for(&self, target: &Target) -> bool {
        match self {
            Format::Archive => true,
            Format::AppImage | Format::Deb | Format::Rpm | Format::Pacman => target.is_linux(),
            Format::Nsis => target.is_windows(),
            Format::MacApp | Format::Dmg => target.is_macos(),
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Format::AppImage => "appimage",
            Format::Deb => "deb",
            Format::Rpm => "rpm",
            Format::Pacman => "pacman",
            Format::Archive => "archive",
            Format::Nsis => "nsis",
            Format::MacApp => "app",
            Format::Dmg => "dmg",
        }
    }

    /// Pair this format with a target, checking validity. The single validity
    /// boundary: possession of the returned `PlannedFormat` is proof the pair
    /// is valid.
    pub fn for_target(
        self,
        target: Target,
    ) -> std::result::Result<PlannedFormat, InvalidFormatForTarget> {
        if self.valid_for(&target) {
            Ok(PlannedFormat {
                format: self,
                target,
            })
        } else {
            Err(InvalidFormatForTarget {
                format: self,
                target,
            })
        }
    }
}

impl fmt::Display for Format {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Error: the format does not apply to the target.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InvalidFormatForTarget {
    pub format: Format,
    pub target: Target,
}

impl fmt::Display for InvalidFormatForTarget {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "format {} is not valid for target {}",
            self.format, self.target
        )
    }
}

impl std::error::Error for InvalidFormatForTarget {}

/// A format paired with a target it is valid for. The only constructor is
/// `Format::for_target`, so possession is proof of validity.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlannedFormat {
    format: Format,
    target: Target,
}

/// How a built artifact gets its final filename.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ArtifactNaming {
    /// Trolley-composed filename (the released contract).
    Composed(String),
    /// Keep the producer's filename. Pacman: the generated PKGBUILD
    /// references its tarball by name, so renaming would break makepkg.
    KeepProducerName,
}

impl PlannedFormat {
    pub fn format(&self) -> Format {
        self.format
    }

    pub fn target(&self) -> Target {
        self.target
    }

    /// Final artifact filename for this format, composed entirely from app
    /// config — producer filenames (cargo-packager's or our own builders') are
    /// never read, so their conventions can't drift into ours. Vocabulary per
    /// ecosystem: display name (spaces -> `_`) for direct-download artifacts,
    /// display name verbatim for the Finder-visible `.app`, slug + ecosystem
    /// arch for distro packages. `KeepProducerName` keeps the producer's name —
    /// pacman's generated PKGBUILD references its tarball by filename, so
    /// renaming would break `makepkg`.
    ///
    /// Total: naming is defined for every constructible `PlannedFormat`.
    ///
    /// The exact structure is a released contract (download URLs, CI scripts,
    /// update checks): any change is breaking and must be deliberate.
    pub fn artifact_name(&self, app: &App) -> ArtifactNaming {
        let target = self.target;
        let display = app.display_name.replace(' ', "_");
        let slug = &app.slug;
        let version = &app.version;
        let arch = target.arch();
        match self.format {
            Format::Nsis => {
                ArtifactNaming::Composed(format!("{display}_{version}_{arch}-setup.exe"))
            }
            Format::Dmg => ArtifactNaming::Composed(format!("{display}_{version}_{arch}.dmg")),
            Format::AppImage => {
                ArtifactNaming::Composed(format!("{display}_{version}_{arch}.AppImage"))
            }
            Format::MacApp => ArtifactNaming::Composed(format!("{}.app", app.display_name)),
            Format::Deb => {
                ArtifactNaming::Composed(format!("{slug}_{version}_{}.deb", deb_arch(&target)))
            }
            Format::Rpm => {
                ArtifactNaming::Composed(format!("{slug}-{version}.{}.rpm", rpm_arch(&target)))
            }
            Format::Archive => {
                ArtifactNaming::Composed(format!("{slug}-{version}-{target}.tar.gz"))
            }
            Format::Pacman => ArtifactNaming::KeepProducerName,
        }
    }
}

/// Map a Linux target to the Debian architecture string. Only reachable via
/// `PlannedFormat::artifact_name`, where `Deb` is provably paired with a Linux
/// target.
fn deb_arch(target: &Target) -> &'static str {
    match target {
        Target::X86_64Linux => "amd64",
        Target::Aarch64Linux => "arm64",
        _ => unreachable!("deb_arch called with non-Linux target"),
    }
}

/// Map a Linux target to the RPM architecture string.
///
/// Precondition: `target` is Linux — panics otherwise. Public because the RPM
/// builder needs the arch string for the package metadata field (not just the
/// filename), under its own Linux-variant guard.
pub fn rpm_arch(target: &Target) -> &'static str {
    match target {
        Target::X86_64Linux => "x86_64",
        Target::Aarch64Linux => "aarch64",
        _ => unreachable!("rpm_arch called with non-Linux target"),
    }
}

/// Encode a version for the RPM Version header field. RPM reserves `-` as the
/// version-release delimiter, so a semver prerelease like `1.2.3-beta.1` is
/// rejected by the package builder; `~` is the RPM prerelease convention and
/// sorts before the plain version, matching semver ordering. Header-only: the
/// artifact filename keeps the verbatim configured version like every other
/// format.
pub fn rpm_version(version: &str) -> String {
    version.replace('-', "~")
}

// ---------------------------------------------------------------------------
// Rust API — used by the CLI crate
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub app: App,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub linux: Option<Linux>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub macos: Option<Macos>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub windows: Option<Windows>,
    #[serde(default, skip_serializing_if = "Fonts::is_default")]
    pub fonts: Fonts,
    #[serde(default, skip_serializing_if = "Gui::is_default")]
    pub gui: Gui,
    #[serde(default, skip_serializing_if = "Environment::is_default")]
    pub environment: Environment,
    #[serde(default, skip_serializing_if = "Embeds::is_default")]
    pub embeds: Embeds,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub ghostty: BTreeMap<String, toml::Value>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct App {
    pub identifier: String,
    pub display_name: String,
    pub slug: String,
    pub version: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub icons: Vec<String>,
}

#[derive(Debug, Deserialize, Serialize, Default)]
#[serde(deny_unknown_fields)]
pub struct Gui {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub resizable: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub maximized: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub initial_width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub initial_height: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub min_height: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_width: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_height: Option<u32>,
}

impl Gui {
    pub fn is_default(&self) -> bool {
        self.initial_width.is_none()
            && self.initial_height.is_none()
            && self.resizable.is_none()
            && self.maximized.is_none()
            && self.min_width.is_none()
            && self.min_height.is_none()
            && self.max_width.is_none()
            && self.max_height.is_none()
    }
}

fn default_true() -> bool {
    true
}

fn is_true(v: &bool) -> bool {
    *v
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Fonts {
    #[serde(default = "default_true", skip_serializing_if = "is_true")]
    pub config_ghostty: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub families: Vec<FontFamily>,
}

impl Default for Fonts {
    fn default() -> Self {
        Fonts {
            config_ghostty: true,
            families: Vec::new(),
        }
    }
}

impl Fonts {
    pub fn is_default(&self) -> bool {
        self.config_ghostty && self.families.is_empty()
    }
}

#[derive(Debug, Deserialize, Serialize, Default)]
#[serde(deny_unknown_fields)]
pub struct Environment {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub env_file: Option<String>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub variables: BTreeMap<String, String>,
}

impl Environment {
    pub fn is_default(&self) -> bool {
        self.env_file.is_none() && self.variables.is_empty()
    }
}

#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Embeds {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub theme: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub shaders: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub data: Vec<String>,
}

impl Embeds {
    pub fn is_default(&self) -> bool {
        self.theme.is_none() && self.shaders.is_empty() && self.data.is_empty()
    }
}

// ---------------------------------------------------------------------------
// Platform sections
// ---------------------------------------------------------------------------

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Linux {
    pub binaries: BTreeMap<Arch, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub appimage: Option<AppImageConfig>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Macos {
    pub binaries: BTreeMap<Arch, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signing: Option<MacosSigning>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct Windows {
    pub binaries: BTreeMap<Arch, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub args: Vec<String>,
    /// Request 1ms timer resolution via timeBeginPeriod.
    /// Reduces timer jitter from ~15.6ms to ~1ms, improving animation
    /// smoothness at the cost of slightly higher power consumption.
    /// Defaults to true; set to false to opt out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub precise_timer: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub signing: Option<WindowsSigning>,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AppImageConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub categories: Option<String>,
}

/// macOS code-signing / notarization settings (non-secret selectors only).
///
/// All secret material is read from the environment by the `cargo-packager` library at
/// build time, so it never lives in `trolley.toml`:
/// - cert on CI: `APPLE_CERTIFICATE` (+ `APPLE_CERTIFICATE_PASSWORD`) — auto-imported into a
///   temporary keychain.
/// - notarization (one set): `APPLE_KEYCHAIN_PROFILE`; or
///   `APPLE_ID` + `APPLE_PASSWORD` + `APPLE_TEAM_ID`; or
///   `APPLE_API_KEY` + `APPLE_API_ISSUER` + `APPLE_API_KEY_PATH`.
///
/// Codesigning automatically enables the hardened runtime + a secure timestamp, so a signed
/// build is notarization-eligible. Setting `identity = "-"` produces an ad-hoc signature
/// (local dev only — still Gatekeeper-warned, never notarized).
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct MacosSigning {
    /// Signing identity, e.g. `"Developer ID Application: ACME Inc (TEAMID)"`.
    ///
    /// Optional: when omitted, the `APPLE_SIGNING_IDENTITY` environment variable is used at
    /// build time instead (so CI can sign without editing config).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub identity: Option<String>,
    /// Optional path to an entitlements `.plist` (passed to `codesign --entitlements`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub entitlements: Option<String>,
}

/// Windows Authenticode signing settings (non-secret selectors only).
///
/// Provide either `thumbprint` (a cert in the Windows certificate store; requires a Windows
/// build host) or `sign_command` (a custom tool such as Azure Artifact Signing; works on any
/// host and is required when cross-compiling from Linux/macOS). The `sign_command` tool reads
/// its own secrets (e.g. `AZURE_*`) from the environment.
///
/// When signing via `thumbprint`, `timestamp_url` is **required** — a non-timestamped
/// signature stops being valid once the certificate expires, which would invalidate
/// already-released binaries. On the `sign_command` path, timestamping is the command's
/// responsibility (Azure Artifact Signing timestamps automatically).
#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub struct WindowsSigning {
    /// SHA-1 thumbprint of a certificate in the Windows certificate store.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub thumbprint: Option<String>,
    /// Custom signing command. `%1` is replaced with the file path to sign.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sign_command: Option<String>,
    /// RFC3161 timestamp server URL.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timestamp_url: Option<String>,
    /// Signature digest algorithm; cargo-packager defaults to `sha256` when unset.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub digest_algorithm: Option<String>,
    /// Use the RFC3161 Time-Stamp Protocol (`signtool /tr`+`/td`) instead of `/t`.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub tsp: bool,
}

/// Default environment variables always injected by trolley.
/// Forces UTF-8 locale so TUI binaries don't inherit broken system locale.
pub const ENVIRONMENT_DEFAULTS: &[(&str, &str)] = &[("LANG", "C.UTF-8"), ("LC_ALL", "C.UTF-8")];

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "lowercase")]
pub enum FontFamily {
    NerdFont(String),
    Path(String),
}

impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let content =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let manifest: Self =
            toml::from_str(&content).with_context(|| format!("parsing {}", path.display()))?;
        manifest
            .validate()
            .with_context(|| format!("validating {}", path.display()))?;
        Ok(manifest)
    }

    /// Look up the binary path for a given target.
    pub fn binary_for(&self, target: &Target) -> Option<&str> {
        let arch = target.arch();
        let binaries = if target.is_linux() {
            &self.linux.as_ref()?.binaries
        } else if target.is_macos() {
            &self.macos.as_ref()?.binaries
        } else {
            &self.windows.as_ref()?.binaries
        };
        binaries.get(&arch).map(|s| s.as_str())
    }

    pub fn args_for(&self, target: &Target) -> Option<&[String]> {
        let args = if target.is_linux() {
            &self.linux.as_ref()?.args
        } else if target.is_macos() {
            &self.macos.as_ref()?.args
        } else {
            &self.windows.as_ref()?.args
        };
        Some(args.as_slice())
    }

    pub fn validate(&self) -> Result<()> {
        let mut errors: Vec<String> = Vec::new();

        // app.identifier must be valid reverse-DNS
        if let Err(e) = validate_app_identifier(&self.app.identifier) {
            errors.push(format!("[app] identifier: {e}"));
        }

        // app.display_name flows into artifact filenames; it must be filename-safe
        if let Err(e) = validate_display_name(&self.app.display_name) {
            errors.push(format!("[app] display_name: {e}"));
        }

        // app.slug must be valid
        if let Err(e) = validate_slug(&self.app.slug) {
            errors.push(format!("[app] slug: {e}"));
        }

        // app.version must be non-empty
        if self.app.version.trim().is_empty() {
            errors.push("[app] version must not be empty".into());
        }

        // At least one platform section must be present
        if self.linux.is_none() && self.macos.is_none() && self.windows.is_none() {
            errors.push(
                "at least one platform section ([linux], [macos], or [windows]) must be present"
                    .into(),
            );
        }

        // Validate platform binaries
        if let Some(ref linux) = self.linux {
            if linux.binaries.is_empty() {
                errors.push("[linux] binaries must not be empty".into());
            }
            for (arch, path) in &linux.binaries {
                if path.trim().is_empty() {
                    errors.push(format!("[linux] binary path for {arch} must not be empty"));
                }
            }
            validate_platform_args("[linux]", &linux.args, &mut errors);
        }
        if let Some(ref macos) = self.macos {
            if macos.binaries.is_empty() {
                errors.push("[macos] binaries must not be empty".into());
            }
            for (arch, path) in &macos.binaries {
                if path.trim().is_empty() {
                    errors.push(format!("[macos] binary path for {arch} must not be empty"));
                }
            }
            validate_platform_args("[macos]", &macos.args, &mut errors);
            // identity is optional (falls back to APPLE_SIGNING_IDENTITY at build time), but
            // an explicitly-provided one must not be blank.
            if let Some(signing) = &macos.signing {
                if matches!(&signing.identity, Some(id) if id.trim().is_empty()) {
                    errors.push("[macos.signing] identity must not be empty".into());
                }
                if matches!(&signing.entitlements, Some(e) if e.trim().is_empty()) {
                    errors.push("[macos.signing] entitlements must not be empty".into());
                }
            }
        }
        if let Some(ref windows) = self.windows {
            if windows.binaries.is_empty() {
                errors.push("[windows] binaries must not be empty".into());
            }
            for (arch, path) in &windows.binaries {
                if path.trim().is_empty() {
                    errors.push(format!(
                        "[windows] binary path for {arch} must not be empty"
                    ));
                }
            }
            validate_platform_args("[windows]", &windows.args, &mut errors);
            // Signing needs exactly one of thumbprint / sign_command. Neither means
            // cargo-packager cannot sign (silent unsigned installer); both means one is
            // silently ignored (the library always prefers sign_command).
            if let Some(signing) = &windows.signing {
                match (&signing.thumbprint, &signing.sign_command) {
                    (None, None) => errors.push(
                        "[windows.signing] requires either `thumbprint` or `sign_command`".into(),
                    ),
                    (Some(_), Some(_)) => errors.push(
                        "[windows.signing] set only one of `thumbprint` or `sign_command` \
                         (cargo-packager silently prefers `sign_command` when both are present)"
                            .into(),
                    ),
                    _ => {}
                }
                // The custom command must receive the file to sign via a standalone `%1`
                // token; otherwise cargo-packager never passes it the file.
                if let Some(cmd) = &signing.sign_command {
                    if !cmd.split_whitespace().any(|t| t == "%1") {
                        errors.push(
                            "[windows.signing] `sign_command` must contain a `%1` token \
                             (replaced with the file path to sign)"
                                .into(),
                        );
                    }
                }
                // Always timestamp: the built-in signtool path (thumbprint, no custom command)
                // only timestamps when a URL is given. A non-timestamped signature becomes
                // invalid once the certificate expires, breaking already-released binaries.
                // The sign_command path is opaque, so its timestamping is the command's job.
                if signing.sign_command.is_none()
                    && signing.thumbprint.is_some()
                    && signing.timestamp_url.is_none()
                {
                    errors.push(
                        "[windows.signing] `timestamp_url` is required when signing with \
                         `thumbprint` (timestamped signatures stay valid after the certificate \
                         expires)"
                            .into(),
                    );
                }
            }
        }

        // Window dimension checks
        if let Some(w) = self.gui.initial_width {
            if w == 0 {
                errors.push("[window] width must be greater than 0".into());
            }
        }
        if let Some(h) = self.gui.initial_height {
            if h == 0 {
                errors.push("[window] height must be greater than 0".into());
            }
        }
        if let Some(w) = self.gui.min_width {
            if w == 0 {
                errors.push("[window] min_width must be greater than 0".into());
            }
        }
        if let Some(h) = self.gui.min_height {
            if h == 0 {
                errors.push("[window] min_height must be greater than 0".into());
            }
        }

        // min must not exceed max
        if let (Some(min), Some(max)) = (self.gui.min_width, self.gui.max_width) {
            if min > max {
                errors.push(format!(
                    "[window] min_width ({min}) must not exceed max_width ({max})"
                ));
            }
        }
        if let (Some(min), Some(max)) = (self.gui.min_height, self.gui.max_height) {
            if min > max {
                errors.push(format!(
                    "[window] min_height ({min}) must not exceed max_height ({max})"
                ));
            }
        }

        // maximized contradicts a fixed or capped window size
        if self.gui.maximized == Some(true) {
            if self.gui.resizable == Some(false) {
                errors.push("[window] maximized cannot be combined with resizable = false".into());
            }
            if self.gui.max_width.is_some() || self.gui.max_height.is_some() {
                errors.push(
                    "[window] maximized cannot be combined with max_width/max_height".into(),
                );
            }
        }

        // initial size should be within min/max bounds
        if let Some(w) = self.gui.initial_width {
            if let Some(min) = self.gui.min_width {
                if w < min {
                    errors.push(format!(
                        "[window] width ({w}) must not be less than min_width ({min})"
                    ));
                }
            }
            if let Some(max) = self.gui.max_width {
                if w > max {
                    errors.push(format!(
                        "[window] width ({w}) must not exceed max_width ({max})"
                    ));
                }
            }
        }
        if let Some(h) = self.gui.initial_height {
            if let Some(min) = self.gui.min_height {
                if h < min {
                    errors.push(format!(
                        "[window] height ({h}) must not be less than min_height ({min})"
                    ));
                }
            }
            if let Some(max) = self.gui.max_height {
                if h > max {
                    errors.push(format!(
                        "[window] height ({h}) must not exceed max_height ({max})"
                    ));
                }
            }
        }

        // [fonts] validation
        for (i, family) in self.fonts.families.iter().enumerate() {
            match family {
                FontFamily::NerdFont(name) => {
                    if name.trim().is_empty() {
                        errors.push(format!(
                            "[fonts] families[{i}]: nerdfont name must not be empty"
                        ));
                    }
                }
                FontFamily::Path(path) => {
                    if path.trim().is_empty() {
                        errors.push(format!("[fonts] families[{i}]: path must not be empty"));
                    } else if !path.ends_with(".ttf") && !path.ends_with(".otf") {
                        errors.push(format!(
                            "[fonts] families[{i}]: path \"{path}\" must end in .ttf or .otf"
                        ));
                    }
                }
            }
        }

        if let Some(theme_path) = &self.embeds.theme {
            if theme_path.trim().is_empty() {
                errors.push("[embeds] theme must not be empty".into());
            }
            if self.ghostty.contains_key("theme") {
                errors.push(
                    "[embeds] theme cannot be used together with [ghostty] theme; inline the theme via [embeds] and keep [ghostty] for overrides"
                        .into(),
                );
            }
        }

        for (index, shader_path) in self.embeds.shaders.iter().enumerate() {
            if shader_path.trim().is_empty() {
                errors.push(format!("[embeds] shaders[{index}] must not be empty"));
                continue;
            }

            let path = Path::new(shader_path);
            // has_root() too: on Windows `/tmp/x` is rooted but not absolute
            // (that needs a `C:` prefix), and it is no more relative for it.
            if path.is_absolute() || path.has_root() {
                errors.push(format!("[embeds] shaders[{index}] must be relative"));
            }
            if path.components().any(|component| {
                matches!(
                    component,
                    std::path::Component::ParentDir
                        | std::path::Component::CurDir
                        | std::path::Component::RootDir
                        | std::path::Component::Prefix(_)
                )
            }) {
                errors.push(format!(
                    "[embeds] shaders[{index}] must be a clean relative path without '.' or '..' segments"
                ));
            }
        }

        if !self.embeds.shaders.is_empty() && self.ghostty.contains_key("custom-shader") {
            errors.push(
                "[embeds] shaders cannot be used together with [ghostty] custom-shader".into(),
            );
        }

        for (index, data_path) in self.embeds.data.iter().enumerate() {
            if data_path.trim().is_empty() {
                errors.push(format!("[embeds] data[{index}] must not be empty"));
                continue;
            }

            let path = Path::new(data_path);
            // has_root() too: on Windows `/tmp/x` is rooted but not absolute
            // (that needs a `C:` prefix), and it is no more relative for it.
            if path.is_absolute() || path.has_root() {
                errors.push(format!("[embeds] data[{index}] must be relative"));
            }
            if path.components().any(|component| {
                matches!(
                    component,
                    std::path::Component::ParentDir
                        | std::path::Component::CurDir
                        | std::path::Component::RootDir
                        | std::path::Component::Prefix(_)
                )
            }) {
                errors.push(format!(
                    "[embeds] data[{index}] must be a clean relative path without '.' or '..' segments"
                ));
            }
        }

        // [ghostty] values must be scalars or arrays of scalars (no tables)
        for (key, value) in &self.ghostty {
            match value {
                toml::Value::Table(_) => {
                    errors.push(format!(
                        "[ghostty] key \"{key}\" has an unsupported type \
                         (only strings, integers, floats, booleans, and arrays of these are allowed)"
                    ));
                }
                toml::Value::Array(arr) => {
                    for (i, item) in arr.iter().enumerate() {
                        if matches!(item, toml::Value::Array(_) | toml::Value::Table(_)) {
                            errors.push(format!(
                                "[ghostty] key \"{key}\"[{i}] has an unsupported type \
                                 (array elements must be strings, integers, floats, or booleans)"
                            ));
                        }
                    }
                }
                _ => {}
            }
        }

        if self.ghostty.contains_key("command") {
            if let Some(linux) = &self.linux {
                if !linux.args.is_empty() {
                    errors
                        .push("[linux] args cannot be used together with [ghostty] command".into());
                }
            }
            if let Some(macos) = &self.macos {
                if !macos.args.is_empty() {
                    errors
                        .push("[macos] args cannot be used together with [ghostty] command".into());
                }
            }
            if let Some(windows) = &self.windows {
                if !windows.args.is_empty() {
                    errors.push(
                        "[windows] args cannot be used together with [ghostty] command".into(),
                    );
                }
            }
        }

        if errors.is_empty() {
            Ok(())
        } else {
            bail!(
                "manifest has {} error{}:\n  - {}",
                errors.len(),
                if errors.len() == 1 { "" } else { "s" },
                errors.join("\n  - ")
            );
        }
    }
}

/// Validate that an app ID is in reverse-DNS format.
///
/// Rules (matching Apple's CFBundleIdentifier):
/// - At least two segments separated by periods (e.g. "com.example")
/// - Each segment contains only alphanumeric characters and hyphens
/// - Each segment must start with a letter
fn validate_app_identifier(id: &str) -> std::result::Result<(), String> {
    if id.is_empty() {
        return Err("must not be empty".into());
    }

    let segments: Vec<&str> = id.split('.').collect();
    if segments.len() < 2 {
        return Err(format!(
            "\"{id}\" must be in reverse-DNS format (e.g. com.example.my-app)"
        ));
    }

    for segment in &segments {
        if segment.is_empty() {
            return Err(format!("\"{id}\" contains an empty segment"));
        }
        if !segment.starts_with(|c: char| c.is_ascii_alphabetic()) {
            return Err(format!(
                "\"{id}\" segment \"{segment}\" must start with a letter"
            ));
        }
        if !segment
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '-')
        {
            return Err(format!(
                "\"{id}\" segment \"{segment}\" must contain only \
                 alphanumeric characters and hyphens"
            ));
        }
    }

    Ok(())
}

/// Validate that a slug is a valid package/path identifier.
///
/// Rules:
/// - Non-empty
/// - Lowercase ASCII alphanumeric characters and hyphens only
/// - Must start with a letter
fn validate_slug(slug: &str) -> std::result::Result<(), String> {
    if slug.is_empty() {
        return Err("must not be empty".into());
    }
    if !slug.starts_with(|c: char| c.is_ascii_lowercase()) {
        return Err(format!("\"{slug}\" must start with a lowercase letter"));
    }
    if !slug
        .chars()
        .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
    {
        return Err(format!(
            "\"{slug}\" must contain only lowercase ASCII alphanumeric characters and hyphens"
        ));
    }
    Ok(())
}

/// Validate that a display name is safe to compose into artifact filenames.
///
/// Rules:
/// - Non-empty and not whitespace-only
/// - No leading/trailing whitespace
/// - No path separators (`/`, `\`) — these would redirect the artifact rename
/// - No characters invalid in Windows filenames (`:`, `*`, `?`, `"`, `<`, `>`, `|`)
/// - No control characters
fn validate_display_name(name: &str) -> std::result::Result<(), String> {
    if name.trim().is_empty() {
        return Err("must not be empty".into());
    }
    if name != name.trim() {
        return Err(format!(
            "\"{name}\" must not have leading or trailing whitespace"
        ));
    }
    if name.contains(['/', '\\']) {
        return Err(format!(
            "\"{name}\" must not contain path separators ('/' or '\\')"
        ));
    }
    if name.contains([':', '*', '?', '"', '<', '>', '|']) {
        return Err(format!(
            "\"{name}\" must not contain characters invalid in Windows filenames \
             (':', '*', '?', '\"', '<', '>', '|')"
        ));
    }
    if name.chars().any(char::is_control) {
        return Err(format!("\"{name}\" must not contain control characters"));
    }
    Ok(())
}

fn validate_platform_args(section: &str, args: &[String], errors: &mut Vec<String>) {
    for (index, arg) in args.iter().enumerate() {
        if arg.is_empty() {
            errors.push(format!("{section} args[{index}] must not be empty"));
            continue;
        }

        if arg.chars().any(char::is_control) {
            errors.push(format!(
                "{section} args[{index}] must not contain control characters"
            ));
        }

        if arg.chars().any(char::is_whitespace) {
            errors.push(format!(
                "{section} args[{index}] must not contain whitespace; Ghostty's direct command parser splits on spaces"
            ));
        }
    }
}

/// Serialize the `[ghostty]` section as ghostty config lines ("key = value\n").
///
/// Scalar values produce a single line. Array values produce one line per
/// element, allowing repeated keys (e.g. multiple `keybind` entries).
pub fn ghostty_config_string(manifest: &Config) -> String {
    let mut out = String::new();
    for (key, value) in &manifest.ghostty {
        match value {
            toml::Value::Array(arr) => {
                for item in arr {
                    write_ghostty_value(&mut out, key, item);
                }
            }
            _ => write_ghostty_value(&mut out, key, value),
        }
    }
    out
}

fn write_ghostty_value(out: &mut String, key: &str, value: &toml::Value) {
    match value {
        toml::Value::String(s) => out.push_str(&format!("{key} = {s}\n")),
        toml::Value::Integer(i) => out.push_str(&format!("{key} = {i}\n")),
        toml::Value::Float(f) => out.push_str(&format!("{key} = {f}\n")),
        toml::Value::Boolean(b) => out.push_str(&format!("{key} = {b}\n")),
        _ => {}
    }
}

// ---------------------------------------------------------------------------
// C ABI — used by the Zig/Swift runtimes
// ---------------------------------------------------------------------------

/// Single source of truth for the bundled Windows icon filename; reached only
/// through the two accessors below, so the packager and runtime can't drift.
const WINDOWS_ICON_FILENAME: &CStr = c"app.ico";

/// The bundled Windows icon filename as a Rust `&str` (no trailing NUL), used by
/// the packager to name and report the bundled icon. The Zig runtime reads the
/// same name through [`trolley_windows_icon_filename`].
pub fn windows_icon_filename_str() -> &'static str {
    WINDOWS_ICON_FILENAME
        .to_str()
        .expect("WINDOWS_ICON_FILENAME is ASCII")
}

/// C/Zig accessor: the bundled Windows icon filename as a NUL-terminated string.
/// The Rust packager reads the same name through [`windows_icon_filename_str`].
/// Zig: `std.mem.span(trolley.trolley_windows_icon_filename())`.
#[unsafe(no_mangle)]
pub extern "C" fn trolley_windows_icon_filename() -> *const c_char {
    WINDOWS_ICON_FILENAME.as_ptr()
}

#[repr(C)]
pub struct TrolleyGuiConfig {
    /// Initial width in pixels. 0 = unset.
    pub initial_width: u32,
    /// Initial height in pixels. 0 = unset.
    pub initial_height: u32,
    /// 0 = false, 1 = true (default).
    pub resizable: u8,
    /// 0 = false (default), 1 = true.
    pub maximized: u8,
    /// Minimum width in pixels. 0 = unset.
    pub min_width: u32,
    /// Minimum height in pixels. 0 = unset.
    pub min_height: u32,
    /// Maximum width in pixels. 0 = unset.
    pub max_width: u32,
    /// Maximum height in pixels. 0 = unset.
    pub max_height: u32,
    /// Windows: request 1ms timer resolution. 0 = false, 1 = true (default).
    pub win_precise_timer: u8,
}

fn windows_precise_timer_enabled(manifest: &Config) -> bool {
    manifest
        .windows
        .as_ref()
        .is_none_or(|windows| windows.precise_timer.unwrap_or(true))
}

/// Load a trolley manifest and extract the window and environment configs.
/// Also returns the length of the ghostty config string via `ghostty_len_out`.
/// Call `trolley_ghostty_config_copy` to retrieve the actual string.
///
/// Returns 0 on success, nonzero on error.
///
/// # Safety
/// - `path` must be a valid null-terminated UTF-8 string.
/// - `window_out` and `ghostty_len_out` must be valid pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn trolley_load_manifest(
    path: *const c_char,
    window_out: *mut TrolleyGuiConfig,
    ghostty_len_out: *mut usize,
) -> c_int {
    let result = (|| -> Result<()> {
        let c_str = unsafe { CStr::from_ptr(path) };
        let path_str = c_str.to_str().context("manifest path is not valid UTF-8")?;
        let manifest = Config::load(Path::new(path_str))?;

        // Fill window config.
        let window_config = unsafe { &mut *window_out };
        window_config.initial_width = manifest.gui.initial_width.unwrap_or(0);
        window_config.initial_height = manifest.gui.initial_height.unwrap_or(0);
        window_config.resizable = u8::from(manifest.gui.resizable.unwrap_or(true));
        window_config.maximized = u8::from(manifest.gui.maximized.unwrap_or(false));
        window_config.min_width = manifest.gui.min_width.unwrap_or(0);
        window_config.min_height = manifest.gui.min_height.unwrap_or(0);
        window_config.max_width = manifest.gui.max_width.unwrap_or(0);
        window_config.max_height = manifest.gui.max_height.unwrap_or(0);
        window_config.win_precise_timer = u8::from(windows_precise_timer_enabled(&manifest));

        // Report ghostty config length so the caller can allocate.
        let config_string = ghostty_config_string(&manifest);
        unsafe { *ghostty_len_out = config_string.len() };

        Ok(())
    })();

    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("trolley: failed to load manifest: {e:#}");
            1
        }
    }
}

/// Copy the ghostty config string for the given manifest into a caller-provided buffer.
///
/// Returns the number of bytes written, or -1 on error.
/// The caller must provide a buffer of at least the size reported by
/// `trolley_load_manifest` via `ghostty_len_out`.
///
/// # Safety
/// - `path` must be a valid null-terminated UTF-8 string.
/// - `buf` must point to at least `buf_len` bytes of writable memory.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn trolley_ghostty_config_copy(
    path: *const c_char,
    buffer: *mut u8,
    buffer_length: usize,
) -> isize {
    let result = (|| -> Result<usize> {
        let c_str = unsafe { CStr::from_ptr(path) };
        let path = c_str.to_str().context("manifest path is not valid UTF-8")?;
        let manifest = Config::load(Path::new(path))?;
        let config = ghostty_config_string(&manifest);
        let length = config.len();
        if length > buffer_length {
            bail!("buffer too small: need {length}, got {buffer_length}");
        }
        if length > 0 {
            unsafe { std::ptr::copy_nonoverlapping(config.as_ptr(), buffer, length) };
        }
        Ok(length)
    })();

    match result {
        Ok(n) => n as isize,
        Err(e) => {
            eprintln!("trolley: failed to copy ghostty config: {e:#}");
            -1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minimal_manifest() -> Config {
        Config {
            app: App {
                identifier: "com.example.test".into(),
                display_name: "Test".into(),
                slug: "test".into(),
                version: "1.0.0".into(),
                icons: vec![],
            },
            linux: Some(Linux {
                binaries: BTreeMap::from([(Arch::X86_64, "my-app".into())]),
                args: Vec::new(),
                appimage: None,
            }),
            macos: None,
            windows: None,
            fonts: Fonts::default(),
            gui: Gui::default(),
            environment: Environment::default(),
            embeds: Embeds {
                theme: None,
                shaders: Vec::new(),
                data: Vec::new(),
            },
            ghostty: BTreeMap::new(),
        }
    }

    // -----------------------------------------------------------------------
    // Target
    // -----------------------------------------------------------------------

    #[test]
    fn target_parse_valid() {
        for target in Target::ALL {
            let parsed: Target = target.as_str().parse().unwrap();
            assert_eq!(parsed, *target);
        }
    }

    #[test]
    fn target_parse_invalid() {
        assert!("x86_64-bsd".parse::<Target>().is_err());
        assert!("".parse::<Target>().is_err());
    }

    #[test]
    fn target_display_roundtrip() {
        for target in Target::ALL {
            assert_eq!(target.to_string(), target.as_str());
        }
    }

    #[test]
    fn target_serialize() {
        // Target serializes to its string representation
        let target = Target::Aarch64Macos;
        let value = toml::Value::try_from(target).unwrap();
        assert_eq!(value.as_str(), Some("aarch64-macos"));
    }

    #[test]
    fn parse_platform_sections() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[macos]
binaries = { aarch64 = "my-app-mac" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        let linux = manifest.linux.as_ref().unwrap();
        assert_eq!(linux.binaries.len(), 1);
        assert_eq!(linux.binaries[&Arch::X86_64], "my-app");
        assert!(linux.args.is_empty());
        let macos = manifest.macos.as_ref().unwrap();
        assert_eq!(macos.binaries.len(), 1);
        assert_eq!(macos.binaries[&Arch::Aarch64], "my-app-mac");
        assert!(macos.args.is_empty());
        assert!(manifest.windows.is_none());
    }

    #[test]
    fn windows_precise_timer_defaults_true_when_omitted() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[windows]
binaries = { x86_64 = "my-app.exe" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert!(windows_precise_timer_enabled(&manifest));
    }

    #[test]
    fn windows_precise_timer_can_be_disabled() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[windows]
binaries = { x86_64 = "my-app.exe" }
precise_timer = false
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert!(!windows_precise_timer_enabled(&manifest));
    }

    // -----------------------------------------------------------------------
    // Signing
    // -----------------------------------------------------------------------

    #[test]
    fn parse_signing_sections() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[macos]
binaries = { aarch64 = "my-app-mac" }
signing = { identity = "Developer ID Application: ACME (TEAMID)", entitlements = "app.entitlements" }

[windows]
binaries = { x86_64 = "my-app.exe" }
signing = { thumbprint = "A1B2C3", timestamp_url = "http://ts.example", tsp = true }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        manifest.validate().unwrap();

        let macos = manifest.macos.unwrap().signing.unwrap();
        assert_eq!(
            macos.identity.as_deref(),
            Some("Developer ID Application: ACME (TEAMID)")
        );
        assert_eq!(macos.entitlements.as_deref(), Some("app.entitlements"));

        let win = manifest.windows.unwrap().signing.unwrap();
        assert_eq!(win.thumbprint.as_deref(), Some("A1B2C3"));
        assert_eq!(win.sign_command, None);
        assert_eq!(win.timestamp_url.as_deref(), Some("http://ts.example"));
        assert!(win.tsp);
    }

    #[test]
    fn signing_windows_sign_command_only() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[windows]
binaries = { x86_64 = "my-app.exe" }
signing = { sign_command = "trusted-signing-cli -e https://x -a A -c C %1" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        manifest.validate().unwrap();
        let win = manifest.windows.unwrap().signing.unwrap();
        assert!(win.thumbprint.is_none());
        assert_eq!(
            win.sign_command.as_deref(),
            Some("trusted-signing-cli -e https://x -a A -c C %1")
        );
    }

    #[test]
    fn signing_macos_identity_optional() {
        // A bare `signing = {}` is valid: the identity falls back to APPLE_SIGNING_IDENTITY.
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[macos]
binaries = { aarch64 = "my-app-mac" }
signing = {}
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        manifest.validate().unwrap();
        let macos = manifest.macos.unwrap().signing.unwrap();
        assert!(macos.identity.is_none());
    }

    #[test]
    fn validate_windows_signing_requires_thumbprint_or_command() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[windows]
binaries = { x86_64 = "my-app.exe" }
signing = { timestamp_url = "http://ts.example" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        let err = manifest.validate().unwrap_err().to_string();
        assert!(err.contains("[windows.signing]"), "got: {err}");
    }

    #[test]
    fn validate_windows_thumbprint_requires_timestamp() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[windows]
binaries = { x86_64 = "my-app.exe" }
signing = { thumbprint = "A1B2C3" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        let err = manifest.validate().unwrap_err().to_string();
        assert!(err.contains("timestamp_url"), "got: {err}");
    }

    #[test]
    fn signing_sign_command_needs_no_timestamp_url() {
        // The custom-command path handles its own timestamping, so no timestamp_url is required.
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[windows]
binaries = { x86_64 = "my-app.exe" }
signing = { sign_command = "trusted-signing-cli -e https://x -a A -c C %1" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        manifest.validate().unwrap();
    }

    #[test]
    fn validate_macos_signing_empty_identity() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[macos]
binaries = { aarch64 = "my-app-mac" }
signing = { identity = "  " }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        let err = manifest.validate().unwrap_err().to_string();
        assert!(err.contains("[macos.signing]"), "got: {err}");
    }

    #[test]
    fn validate_windows_signing_rejects_both() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[windows]
binaries = { x86_64 = "my-app.exe" }
signing = { thumbprint = "A1B2C3", sign_command = "tool %1", timestamp_url = "http://ts.example" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        let err = manifest.validate().unwrap_err().to_string();
        assert!(err.contains("only one"), "got: {err}");
    }

    #[test]
    fn validate_windows_sign_command_requires_placeholder() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[windows]
binaries = { x86_64 = "my-app.exe" }
signing = { sign_command = "trusted-signing-cli -e https://x -a A -c C" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        let err = manifest.validate().unwrap_err().to_string();
        assert!(err.contains("%1"), "got: {err}");
    }

    #[test]
    fn validate_macos_signing_empty_entitlements() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[macos]
binaries = { aarch64 = "my-app-mac" }
signing = { identity = "Developer ID Application: ACME (TEAM)", entitlements = "  " }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        let err = manifest.validate().unwrap_err().to_string();
        assert!(err.contains("[macos.signing]"), "got: {err}");
    }

    // -----------------------------------------------------------------------
    // App ID validation
    // -----------------------------------------------------------------------

    #[test]
    fn app_id_valid() {
        assert!(validate_app_identifier("com.example").is_ok());
        assert!(validate_app_identifier("com.example.my-app").is_ok());
        assert!(validate_app_identifier("org.trolley.hello").is_ok());
        assert!(validate_app_identifier("io.github.user.project").is_ok());
        assert!(validate_app_identifier("com.example.app123").is_ok());
    }

    #[test]
    fn app_id_empty() {
        assert!(validate_app_identifier("").is_err());
    }

    #[test]
    fn app_id_single_segment() {
        assert!(validate_app_identifier("nope").is_err());
    }

    #[test]
    fn app_id_segment_starts_with_digit() {
        assert!(validate_app_identifier("com.123bad").is_err());
    }

    #[test]
    fn app_id_empty_segment() {
        assert!(validate_app_identifier("com..example").is_err());
        assert!(validate_app_identifier(".com.example").is_err());
        assert!(validate_app_identifier("com.example.").is_err());
    }

    #[test]
    fn app_id_invalid_characters() {
        assert!(validate_app_identifier("com.example.my_app").is_err()); // underscore
        assert!(validate_app_identifier("com.example.my app").is_err()); // space
        assert!(validate_app_identifier("com.example.my/app").is_err()); // slash
    }

    // -----------------------------------------------------------------------
    // Config validation
    // -----------------------------------------------------------------------

    #[test]
    fn validate_minimal_manifest() {
        assert!(minimal_manifest().validate().is_ok());
    }

    #[test]
    fn validate_empty_display_name() {
        for name in ["", "  "] {
            let mut m = minimal_manifest();
            m.app.display_name = name.into();
            let err = m.validate().unwrap_err().to_string();
            assert!(err.contains("[app] display_name: must not be empty"));
        }
    }

    #[test]
    fn validate_display_name_accepts_multi_word_names() {
        for name in ["Project Sanity", "Hello World"] {
            let mut m = minimal_manifest();
            m.app.display_name = name.into();
            assert!(m.validate().is_ok());
        }
    }

    #[test]
    fn validate_display_name_rejects_path_separators() {
        for name in ["a/b", "a\\b"] {
            let mut m = minimal_manifest();
            m.app.display_name = name.into();
            let err = m.validate().unwrap_err().to_string();
            assert!(err.contains("[app] display_name"));
            assert!(err.contains("path separators"));
        }
    }

    #[test]
    fn validate_display_name_rejects_windows_reserved_characters() {
        for name in ["Foo: Bar", "a*b", "a?b", "a\"b", "a<b", "a>b", "a|b"] {
            let mut m = minimal_manifest();
            m.app.display_name = name.into();
            let err = m.validate().unwrap_err().to_string();
            assert!(err.contains("[app] display_name"));
            assert!(err.contains("invalid in Windows filenames"));
        }
    }

    #[test]
    fn validate_display_name_rejects_control_characters() {
        let mut m = minimal_manifest();
        m.app.display_name = "a\tb".into();
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[app] display_name"));
        assert!(err.contains("control characters"));
    }

    #[test]
    fn validate_display_name_rejects_surrounding_whitespace() {
        for name in [" x", "x "] {
            let mut m = minimal_manifest();
            m.app.display_name = name.into();
            let err = m.validate().unwrap_err().to_string();
            assert!(err.contains("[app] display_name"));
            assert!(err.contains("leading or trailing whitespace"));
        }
    }

    #[test]
    fn validate_empty_version() {
        let mut m = minimal_manifest();
        m.app.version = "".into();
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("version must not be empty"));
    }

    #[test]
    fn validate_no_platform_sections() {
        let mut m = minimal_manifest();
        m.linux = None;
        m.macos = None;
        m.windows = None;
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("at least one platform section"));
    }

    #[test]
    fn validate_empty_binaries() {
        let mut m = minimal_manifest();
        m.linux = Some(Linux {
            binaries: BTreeMap::new(),
            args: Vec::new(),
            appimage: None,
        });
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[linux] binaries must not be empty"));
    }

    #[test]
    fn validate_empty_binary_path() {
        let mut m = minimal_manifest();
        m.linux = Some(Linux {
            binaries: BTreeMap::from([(Arch::X86_64, "  ".into())]),
            args: Vec::new(),
            appimage: None,
        });
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[linux] binary path for x86_64 must not be empty"));
    }

    #[test]
    fn validate_platform_args_reject_empty() {
        let mut m = minimal_manifest();
        m.linux.as_mut().unwrap().args = vec!["".into()];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[linux] args[0] must not be empty"));
    }

    #[test]
    fn validate_platform_args_reject_whitespace() {
        let mut m = minimal_manifest();
        m.linux.as_mut().unwrap().args = vec!["--name=Jane Doe".into()];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[linux] args[0] must not contain whitespace"));
    }

    #[test]
    fn validate_platform_args_reject_control_chars() {
        let mut m = minimal_manifest();
        m.linux.as_mut().unwrap().args = vec!["bad\narg".into()];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[linux] args[0] must not contain control characters"));
    }

    #[test]
    fn validate_platform_args_conflict_with_ghostty_command() {
        let mut m = minimal_manifest();
        m.linux.as_mut().unwrap().args = vec!["--verbose".into()];
        m.ghostty.insert(
            "command".into(),
            toml::Value::String("shell:./my-app".into()),
        );
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[linux] args cannot be used together with [ghostty] command"));
    }

    #[test]
    fn validate_bad_app_id() {
        let mut m = minimal_manifest();
        m.app.identifier = "not-reverse-dns".into();
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("reverse-DNS"));
    }

    #[test]
    fn validate_window_zero_width() {
        let mut m = minimal_manifest();
        m.gui.initial_width = Some(0);
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("width must be greater than 0"));
    }

    #[test]
    fn validate_window_min_exceeds_max() {
        let mut m = minimal_manifest();
        m.gui.min_width = Some(800);
        m.gui.max_width = Some(400);
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("min_width (800) must not exceed max_width (400)"));
    }

    #[test]
    fn validate_window_maximized_with_resizable_false() {
        let mut m = minimal_manifest();
        m.gui.maximized = Some(true);
        m.gui.resizable = Some(false);
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("maximized cannot be combined with resizable = false"));
    }

    #[test]
    fn validate_window_maximized_with_max_size() {
        let mut m = minimal_manifest();
        m.gui.maximized = Some(true);
        m.gui.max_width = Some(1024);
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("maximized cannot be combined with max_width/max_height"));
    }

    #[test]
    fn validate_window_maximized_ok() {
        let mut m = minimal_manifest();
        m.gui.maximized = Some(true);
        m.gui.initial_width = Some(800);
        m.gui.min_width = Some(400);
        assert!(m.validate().is_ok());
    }

    #[test]
    fn validate_window_width_below_min() {
        let mut m = minimal_manifest();
        m.gui.initial_width = Some(200);
        m.gui.min_width = Some(400);
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("width (200) must not be less than min_width (400)"));
    }

    #[test]
    fn validate_multiple_errors() {
        let mut m = minimal_manifest();
        m.app.identifier = "bad".into();
        m.app.version = "".into();
        m.linux = None;
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("3 errors"));
    }

    // -----------------------------------------------------------------------
    // Serialization
    // -----------------------------------------------------------------------

    #[test]
    fn serialize_minimal_manifest_no_empty_sections() {
        let m = minimal_manifest();
        let output = toml::to_string_pretty(&m).unwrap();
        assert!(output.contains("[app]"));
        assert!(output.contains("linux")); // serialized as [linux.binaries] by toml
        assert!(!output.contains("macos"));
        assert!(!output.contains("windows"));
        assert!(!output.contains("[embeds]"));
        assert!(!output.contains("[ghostty]"));
        assert!(!output.contains("[window]"));
    }

    #[test]
    fn serialize_roundtrip() {
        let m = minimal_manifest();
        let serialized = toml::to_string_pretty(&m).unwrap();
        let deserialized: Config = toml::from_str(&serialized).unwrap();
        assert_eq!(deserialized.app.identifier, m.app.identifier);
        assert_eq!(deserialized.app.display_name, m.app.display_name);
        assert_eq!(deserialized.app.slug, m.app.slug);
        assert_eq!(deserialized.app.version, m.app.version);
        let linux = deserialized.linux.as_ref().unwrap();
        assert_eq!(linux.binaries[&Arch::X86_64], "my-app");
        assert!(linux.args.is_empty());
    }

    #[test]
    fn platform_args_roundtrip() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }
args = ["--verbose", "--port=9000"]

[macos]
binaries = { aarch64 = "my-app-mac" }
args = ["--profile=dev"]

[windows]
binaries = { x86_64 = "my-app.exe" }
args = ["--flag"]
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert_eq!(
            manifest.linux.as_ref().unwrap().args,
            vec!["--verbose", "--port=9000"]
        );
        assert_eq!(manifest.macos.as_ref().unwrap().args, vec!["--profile=dev"]);
        assert_eq!(manifest.windows.as_ref().unwrap().args, vec!["--flag"]);
    }

    #[test]
    fn serialize_with_window() {
        let mut m = minimal_manifest();
        m.gui.initial_width = Some(800);
        m.gui.initial_height = Some(600);
        let output = toml::to_string_pretty(&m).unwrap();
        assert!(output.contains("[gui]"));
        assert!(output.contains("initial_width = 800"));
        assert!(output.contains("initial_height = 600"));
        assert!(!output.contains("resizable")); // None fields skipped
        assert!(!output.contains("maximized"));
    }

    #[test]
    fn embeds_theme_roundtrip() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[embeds]
theme = "themes/dracula"
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert_eq!(manifest.embeds.theme.as_deref(), Some("themes/dracula"));
    }

    #[test]
    fn embeds_shaders_roundtrip() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[embeds]
shaders = ["shaders/crt.glsl", "shaders/scanlines.glsl"]
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert_eq!(
            manifest.embeds.shaders,
            vec!["shaders/crt.glsl", "shaders/scanlines.glsl"]
        );
    }

    #[test]
    fn embeds_data_roundtrip() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[embeds]
data = ["assets", "config/defaults.json"]
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert_eq!(manifest.embeds.data, vec!["assets", "config/defaults.json"]);
    }

    // -----------------------------------------------------------------------
    // Fonts
    // -----------------------------------------------------------------------

    #[test]
    fn fonts_default_is_skipped_in_serialization() {
        let m = minimal_manifest();
        let output = toml::to_string_pretty(&m).unwrap();
        assert!(!output.contains("[fonts]"));
    }

    #[test]
    fn fonts_with_families_serialized() {
        let mut m = minimal_manifest();
        m.fonts.families = vec![
            FontFamily::NerdFont("Inconsolata".into()),
            FontFamily::Path("fonts/Custom.ttf".into()),
        ];
        let output = toml::to_string_pretty(&m).unwrap();
        assert!(output.contains("[[fonts.families]]"));
    }

    #[test]
    fn fonts_roundtrip() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[fonts]
config_ghostty = false
families = [
    { nerdfont = "Inconsolata" },
    { path = "fonts/Custom.ttf" },
]
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert!(!manifest.fonts.config_ghostty);
        assert_eq!(manifest.fonts.families.len(), 2);
        match &manifest.fonts.families[0] {
            FontFamily::NerdFont(name) => assert_eq!(name, "Inconsolata"),
            _ => panic!("expected NerdFont"),
        }
        match &manifest.fonts.families[1] {
            FontFamily::Path(path) => assert_eq!(path, "fonts/Custom.ttf"),
            _ => panic!("expected Path"),
        }
    }

    #[test]
    fn fonts_config_ghostty_defaults_true() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[fonts]
families = [
    { nerdfont = "Inconsolata" },
]
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert!(manifest.fonts.config_ghostty);
    }

    #[test]
    fn validate_fonts_empty_nerdfont() {
        let mut m = minimal_manifest();
        m.fonts.families = vec![FontFamily::NerdFont("".into())];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("nerdfont name must not be empty"));
    }

    #[test]
    fn validate_fonts_empty_path() {
        let mut m = minimal_manifest();
        m.fonts.families = vec![FontFamily::Path("".into())];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("path must not be empty"));
    }

    #[test]
    fn validate_fonts_bad_extension() {
        let mut m = minimal_manifest();
        m.fonts.families = vec![FontFamily::Path("fonts/Custom.woff".into())];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("must end in .ttf or .otf"));
    }

    #[test]
    fn validate_fonts_valid() {
        let mut m = minimal_manifest();
        m.fonts.families = vec![
            FontFamily::NerdFont("Inconsolata".into()),
            FontFamily::Path("fonts/Custom.ttf".into()),
            FontFamily::Path("fonts/Other.otf".into()),
        ];
        assert!(m.validate().is_ok());
    }

    // -----------------------------------------------------------------------
    // ghostty_config_string
    // -----------------------------------------------------------------------

    #[test]
    fn ghostty_config_empty() {
        let m = minimal_manifest();
        assert_eq!(ghostty_config_string(&m), "");
    }

    #[test]
    fn ghostty_config_values() {
        let mut m = minimal_manifest();
        m.ghostty
            .insert("font-size".into(), toml::Value::Integer(14));
        m.ghostty.insert(
            "font-family".into(),
            toml::Value::String("JetBrains Mono".into()),
        );
        let output = ghostty_config_string(&m);
        assert!(output.contains("font-family = JetBrains Mono\n"));
        assert!(output.contains("font-size = 14\n"));
    }

    // -----------------------------------------------------------------------
    // TOML parsing
    // -----------------------------------------------------------------------

    #[test]
    fn parse_unknown_field_rejected() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"
bogus = "field"

[linux]
binaries = { x86_64 = "my-app" }
"#;
        assert!(toml::from_str::<Config>(toml_str).is_err());
    }

    #[test]
    fn parse_unknown_arch_rejected() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { sparc = "my-app" }
"#;
        assert!(toml::from_str::<Config>(toml_str).is_err());
    }

    // -----------------------------------------------------------------------
    // Environment
    // -----------------------------------------------------------------------

    #[test]
    fn environment_default_is_skipped_in_serialization() {
        let m = minimal_manifest();
        let output = toml::to_string_pretty(&m).unwrap();
        assert!(!output.contains("[environment]"));
    }

    #[test]
    fn environment_roundtrip() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[environment]
env_file = ".env"
variables = { RUST_LOG = "info", MY_VAR = "value" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert_eq!(manifest.environment.env_file.as_deref(), Some(".env"));
        assert_eq!(manifest.environment.variables.len(), 2);
        assert_eq!(manifest.environment.variables["RUST_LOG"], "info");
        assert_eq!(manifest.environment.variables["MY_VAR"], "value");
    }

    #[test]
    fn environment_variables_only() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[environment]
variables = { FOO = "bar" }
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert!(manifest.environment.env_file.is_none());
        assert_eq!(manifest.environment.variables["FOO"], "bar");
    }

    #[test]
    fn environment_env_file_only() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[environment]
env_file = "config/.env"
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert_eq!(
            manifest.environment.env_file.as_deref(),
            Some("config/.env")
        );
        assert!(manifest.environment.variables.is_empty());
    }

    #[test]
    fn environment_empty_section_is_default() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[environment]
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        assert!(manifest.environment.is_default());
    }

    #[test]
    fn validate_embeds_theme_must_not_be_empty() {
        let mut m = minimal_manifest();
        m.embeds.theme = Some("  ".into());
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[embeds] theme must not be empty"));
    }

    #[test]
    fn validate_embeds_theme_and_ghostty_theme_conflict() {
        let mut m = minimal_manifest();
        m.embeds.theme = Some("themes/dracula".into());
        m.ghostty
            .insert("theme".into(), toml::Value::String("dracula".into()));
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[embeds] theme cannot be used together with [ghostty] theme"));
    }

    #[test]
    fn validate_embeds_shaders_must_not_be_empty() {
        let mut m = minimal_manifest();
        m.embeds.shaders = vec![" ".into()];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[embeds] shaders[0] must not be empty"));
    }

    #[test]
    fn validate_embeds_shaders_must_be_relative() {
        let mut m = minimal_manifest();
        m.embeds.shaders = vec!["/tmp/crt.glsl".into()];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[embeds] shaders[0] must be relative"));
    }

    #[test]
    fn validate_embeds_shaders_must_not_escape_bundle() {
        let mut m = minimal_manifest();
        m.embeds.shaders = vec!["../crt.glsl".into()];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("clean relative path"));
    }

    #[test]
    fn validate_embeds_shaders_and_ghostty_custom_shader_conflict() {
        let mut m = minimal_manifest();
        m.embeds.shaders = vec!["shaders/crt.glsl".into()];
        m.ghostty.insert(
            "custom-shader".into(),
            toml::Value::String("foo.glsl".into()),
        );
        let err = m.validate().unwrap_err().to_string();
        assert!(
            err.contains("[embeds] shaders cannot be used together with [ghostty] custom-shader")
        );
    }

    #[test]
    fn validate_embeds_data_must_not_be_empty() {
        let mut m = minimal_manifest();
        m.embeds.data = vec![" ".into()];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[embeds] data[0] must not be empty"));
    }

    #[test]
    fn validate_embeds_data_must_be_relative() {
        let mut m = minimal_manifest();
        m.embeds.data = vec!["/tmp/assets".into()];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[embeds] data[0] must be relative"));
    }

    #[test]
    fn validate_embeds_data_must_not_escape_bundle() {
        let mut m = minimal_manifest();
        m.embeds.data = vec!["../assets".into()];
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[embeds] data[0] must be a clean relative path"));
    }

    // -----------------------------------------------------------------------
    // Target::is_linux
    // -----------------------------------------------------------------------

    #[test]
    fn target_is_linux() {
        assert!(Target::X86_64Linux.is_linux());
        assert!(Target::Aarch64Linux.is_linux());
        assert!(!Target::X86_64Macos.is_linux());
        assert!(!Target::Aarch64Macos.is_linux());
        assert!(!Target::X86_64Windows.is_linux());
        assert!(!Target::Aarch64Windows.is_linux());
    }

    // -----------------------------------------------------------------------
    // Format
    // -----------------------------------------------------------------------

    #[test]
    fn format_as_str() {
        assert_eq!(Format::AppImage.as_str(), "appimage");
        assert_eq!(Format::Deb.as_str(), "deb");
        assert_eq!(Format::Rpm.as_str(), "rpm");
        assert_eq!(Format::Pacman.as_str(), "pacman");
        assert_eq!(Format::Archive.as_str(), "archive");
        assert_eq!(Format::Nsis.as_str(), "nsis");
        assert_eq!(Format::MacApp.as_str(), "app");
        assert_eq!(Format::Dmg.as_str(), "dmg");
    }

    #[test]
    fn format_display() {
        assert_eq!(Format::Deb.to_string(), "deb");
        assert_eq!(Format::Nsis.to_string(), "nsis");
        assert_eq!(Format::MacApp.to_string(), "app");
        assert_eq!(Format::Dmg.to_string(), "dmg");
    }

    #[test]
    fn format_linux_default() {
        assert!(Format::LINUX_DEFAULT.contains(&Format::AppImage));
        assert!(Format::LINUX_DEFAULT.contains(&Format::Deb));
        assert!(Format::LINUX_DEFAULT.contains(&Format::Rpm));
        assert!(Format::LINUX_DEFAULT.contains(&Format::Pacman));
        assert!(Format::LINUX_DEFAULT.contains(&Format::Archive));
    }

    #[test]
    fn format_windows_default() {
        assert!(Format::WINDOWS_DEFAULT.contains(&Format::Nsis));
        assert!(Format::WINDOWS_DEFAULT.contains(&Format::Archive));
    }

    #[test]
    fn format_macos_default_not_on_macos() {
        let fmts = Format::macos_default(false);
        assert!(fmts.contains(&Format::MacApp));
        assert!(fmts.contains(&Format::Archive));
        assert!(!fmts.contains(&Format::Dmg));
    }

    #[test]
    fn format_macos_default_on_macos() {
        let fmts = Format::macos_default(true);
        assert!(fmts.contains(&Format::MacApp));
        assert!(fmts.contains(&Format::Archive));
        assert!(fmts.contains(&Format::Dmg));
    }

    #[test]
    fn format_valid_for_target() {
        assert!(Format::Deb.valid_for(&Target::X86_64Linux));
        assert!(!Format::Deb.valid_for(&Target::X86_64Windows));
        assert!(Format::Nsis.valid_for(&Target::X86_64Windows));
        assert!(!Format::Nsis.valid_for(&Target::X86_64Linux));
        assert!(Format::Archive.valid_for(&Target::X86_64Linux));
        assert!(Format::Archive.valid_for(&Target::X86_64Windows));
        assert!(Format::MacApp.valid_for(&Target::X86_64Macos));
        assert!(Format::MacApp.valid_for(&Target::Aarch64Macos));
        assert!(!Format::MacApp.valid_for(&Target::X86_64Linux));
        assert!(!Format::MacApp.valid_for(&Target::X86_64Windows));
        assert!(Format::Dmg.valid_for(&Target::X86_64Macos));
        assert!(!Format::Dmg.valid_for(&Target::X86_64Linux));
    }

    // -----------------------------------------------------------------------
    // Architecture mapping
    // -----------------------------------------------------------------------

    #[test]
    fn deb_arch_mapping() {
        assert_eq!(deb_arch(&Target::X86_64Linux), "amd64");
        assert_eq!(deb_arch(&Target::Aarch64Linux), "arm64");
    }

    #[test]
    fn rpm_arch_mapping() {
        assert_eq!(rpm_arch(&Target::X86_64Linux), "x86_64");
        assert_eq!(rpm_arch(&Target::Aarch64Linux), "aarch64");
    }

    #[test]
    fn rpm_version_prerelease_hyphen_becomes_tilde() {
        assert_eq!(rpm_version("1.0.0"), "1.0.0");
        assert_eq!(rpm_version("1.2.3-beta.1"), "1.2.3~beta.1");
        assert_eq!(rpm_version("1.2.3-rc.1-hotfix"), "1.2.3~rc.1~hotfix");
    }

    // -----------------------------------------------------------------------
    // Arch
    // -----------------------------------------------------------------------

    #[test]
    fn arch_serde_roundtrip() {
        let arch = Arch::X86_64;
        let value = toml::Value::try_from(arch).unwrap();
        assert_eq!(value.as_str(), Some("x86_64"));

        let arch = Arch::Aarch64;
        let value = toml::Value::try_from(arch).unwrap();
        assert_eq!(value.as_str(), Some("aarch64"));
    }

    #[test]
    fn arch_parse_invalid() {
        assert!("arm32".parse::<Arch>().is_err());
        assert!("".parse::<Arch>().is_err());
    }

    #[test]
    fn arch_display() {
        assert_eq!(Arch::X86_64.to_string(), "x86_64");
        assert_eq!(Arch::Aarch64.to_string(), "aarch64");
    }

    // -----------------------------------------------------------------------
    // Target::arch, is_macos, is_windows
    // -----------------------------------------------------------------------

    #[test]
    fn target_arch() {
        assert_eq!(Target::X86_64Linux.arch(), Arch::X86_64);
        assert_eq!(Target::Aarch64Linux.arch(), Arch::Aarch64);
        assert_eq!(Target::X86_64Macos.arch(), Arch::X86_64);
        assert_eq!(Target::Aarch64Macos.arch(), Arch::Aarch64);
        assert_eq!(Target::X86_64Windows.arch(), Arch::X86_64);
        assert_eq!(Target::Aarch64Windows.arch(), Arch::Aarch64);
    }

    #[test]
    fn target_is_macos() {
        assert!(Target::X86_64Macos.is_macos());
        assert!(Target::Aarch64Macos.is_macos());
        assert!(!Target::X86_64Linux.is_macos());
        assert!(!Target::X86_64Windows.is_macos());
    }

    #[test]
    fn target_is_windows() {
        assert!(Target::X86_64Windows.is_windows());
        assert!(Target::Aarch64Windows.is_windows());
        assert!(!Target::X86_64Linux.is_windows());
        assert!(!Target::X86_64Macos.is_windows());
    }

    // -----------------------------------------------------------------------
    // binary_for
    // -----------------------------------------------------------------------

    #[test]
    fn binary_for_linux() {
        let m = minimal_manifest();
        assert_eq!(m.binary_for(&Target::X86_64Linux), Some("my-app"));
        assert_eq!(m.binary_for(&Target::Aarch64Linux), None);
    }

    #[test]
    fn binary_for_missing_platform() {
        let m = minimal_manifest();
        assert_eq!(m.binary_for(&Target::X86_64Macos), None);
        assert_eq!(m.binary_for(&Target::X86_64Windows), None);
    }

    #[test]
    fn args_for_platform() {
        let mut m = minimal_manifest();
        m.linux.as_mut().unwrap().args = vec!["--verbose".into(), "--port=9000".into()];
        let expected = vec!["--verbose".to_string(), "--port=9000".to_string()];
        assert_eq!(m.args_for(&Target::X86_64Linux), Some(expected.as_slice()));
        assert_eq!(m.args_for(&Target::X86_64Macos), None);
    }

    // -----------------------------------------------------------------------
    // AppImageConfig
    // -----------------------------------------------------------------------

    #[test]
    fn appimage_config_roundtrip() {
        let toml_str = r#"
[app]
identifier = "com.example.test"
display_name = "Test"
slug = "test"
version = "1.0.0"

[linux]
binaries = { x86_64 = "my-app" }

[linux.appimage]
categories = "Utility"
"#;
        let manifest: Config = toml::from_str(toml_str).unwrap();
        let linux = manifest.linux.as_ref().unwrap();
        let appimage = linux.appimage.as_ref().unwrap();
        assert_eq!(appimage.categories.as_deref(), Some("Utility"));
        assert!(linux.args.is_empty());
    }

    // -----------------------------------------------------------------------
    // Slug validation
    // -----------------------------------------------------------------------

    #[test]
    fn slug_valid() {
        assert!(validate_slug("hello").is_ok());
        assert!(validate_slug("my-app").is_ok());
        assert!(validate_slug("app123").is_ok());
        assert!(validate_slug("a").is_ok());
    }

    #[test]
    fn slug_empty() {
        assert!(validate_slug("").is_err());
    }

    #[test]
    fn slug_starts_with_digit() {
        assert!(validate_slug("123app").is_err());
    }

    #[test]
    fn slug_starts_with_hyphen() {
        assert!(validate_slug("-app").is_err());
    }

    #[test]
    fn slug_uppercase() {
        assert!(validate_slug("Hello").is_err());
    }

    #[test]
    fn slug_underscore() {
        assert!(validate_slug("my_app").is_err());
    }

    #[test]
    fn slug_space() {
        assert!(validate_slug("my app").is_err());
    }

    #[test]
    fn validate_bad_slug() {
        let mut m = minimal_manifest();
        m.app.slug = "Bad Slug!".into();
        let err = m.validate().unwrap_err().to_string();
        assert!(err.contains("[app] slug:"));
    }

    // Artifact naming contract. The exact strings are released structure —
    // download URLs, CI scripts, and update checks depend on them — so any
    // change here is breaking and must be deliberate.
    mod artifact_names {
        use super::*;

        /// Two-word display name so space handling is exercised.
        fn app() -> App {
            App {
                identifier: "com.example.trolley".into(),
                display_name: "Tech Trolley".into(),
                slug: "trolley".into(),
                version: "1.2.3".into(),
                icons: vec![],
            }
        }

        /// Name a valid pair through the boundary.
        fn name(f: Format, t: Target) -> ArtifactNaming {
            f.for_target(t).unwrap().artifact_name(&app())
        }

        fn composed(s: &str) -> ArtifactNaming {
            ArtifactNaming::Composed(s.into())
        }

        #[test]
        fn nsis_is_underscored_display_name_version_arch_setup() {
            assert_eq!(
                name(Format::Nsis, Target::X86_64Windows),
                composed("Tech_Trolley_1.2.3_x86_64-setup.exe")
            );
            assert_eq!(
                name(Format::Nsis, Target::Aarch64Windows),
                composed("Tech_Trolley_1.2.3_aarch64-setup.exe")
            );
        }

        #[test]
        fn dmg_is_underscored_display_name_version_arch() {
            assert_eq!(
                name(Format::Dmg, Target::X86_64Macos),
                composed("Tech_Trolley_1.2.3_x86_64.dmg")
            );
            assert_eq!(
                name(Format::Dmg, Target::Aarch64Macos),
                composed("Tech_Trolley_1.2.3_aarch64.dmg")
            );
        }

        #[test]
        fn appimage_is_underscored_display_name_version_arch() {
            assert_eq!(
                name(Format::AppImage, Target::X86_64Linux),
                composed("Tech_Trolley_1.2.3_x86_64.AppImage")
            );
            assert_eq!(
                name(Format::AppImage, Target::Aarch64Linux),
                composed("Tech_Trolley_1.2.3_aarch64.AppImage")
            );
        }

        #[test]
        fn mac_app_keeps_display_name_verbatim_including_spaces() {
            assert_eq!(
                name(Format::MacApp, Target::Aarch64Macos),
                composed("Tech Trolley.app")
            );
        }

        #[test]
        fn deb_is_slug_version_debian_arch() {
            assert_eq!(
                name(Format::Deb, Target::X86_64Linux),
                composed("trolley_1.2.3_amd64.deb")
            );
            assert_eq!(
                name(Format::Deb, Target::Aarch64Linux),
                composed("trolley_1.2.3_arm64.deb")
            );
        }

        #[test]
        fn rpm_is_slug_version_rpm_arch() {
            assert_eq!(
                name(Format::Rpm, Target::X86_64Linux),
                composed("trolley-1.2.3.x86_64.rpm")
            );
            assert_eq!(
                name(Format::Rpm, Target::Aarch64Linux),
                composed("trolley-1.2.3.aarch64.rpm")
            );
        }

        #[test]
        fn archive_is_slug_version_full_target() {
            assert_eq!(
                name(Format::Archive, Target::X86_64Linux),
                composed("trolley-1.2.3-x86_64-linux.tar.gz")
            );
            assert_eq!(
                name(Format::Archive, Target::Aarch64Macos),
                composed("trolley-1.2.3-aarch64-macos.tar.gz")
            );
            assert_eq!(
                name(Format::Archive, Target::X86_64Windows),
                composed("trolley-1.2.3-x86_64-windows.tar.gz")
            );
        }

        #[test]
        fn pacman_passes_through_because_pkgbuild_references_the_tarball() {
            assert_eq!(
                name(Format::Pacman, Target::X86_64Linux),
                ArtifactNaming::KeepProducerName
            );
        }

        #[test]
        fn invalid_pairs_are_rejected_at_the_boundary() {
            for (f, t) in [
                (Format::Deb, Target::X86_64Windows),
                (Format::Rpm, Target::Aarch64Macos),
                (Format::Nsis, Target::X86_64Linux),
                (Format::Dmg, Target::X86_64Windows),
                (Format::MacApp, Target::X86_64Windows),
            ] {
                let err = f.for_target(t).unwrap_err();
                assert_eq!(
                    err,
                    InvalidFormatForTarget {
                        format: f,
                        target: t
                    }
                );
                assert_eq!(
                    err.to_string(),
                    format!("format {f} is not valid for target {t}")
                );
                assert!(err.to_string().contains("not valid for target"));
            }
        }

        #[test]
        fn archive_is_valid_for_every_target() {
            for t in Target::ALL {
                assert!(Format::Archive.for_target(*t).is_ok());
            }
        }
    }
}
