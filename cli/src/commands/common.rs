use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use trolley_config::{Config, ENVIRONMENT_DEFAULTS, FontFamily, Target};

pub const VERSION: &str = env!("TROLLEY_VERSION");

pub const CONFIG_FILENAME: &str = "trolley.toml";
pub const GHOSTTY_CONFIG_FILENAME: &str = "ghostty.conf";
pub const ENVIRONMENT_FILENAME: &str = "environment";
pub const FONTS_CONFIG_FILENAME: &str = "fonts.conf";
pub const WINDOWS_ICON_FILENAME: &str = "app.ico";

// ---------------------------------------------------------------------------
// ProjectContext — resolved config, paths, ready for commands
// ---------------------------------------------------------------------------

pub struct ProjectContext {
    pub config_path: PathBuf,
    pub project_dir: PathBuf,
    pub output_dir: PathBuf,
    pub config: Config,
}

impl ProjectContext {
    pub fn load(config: Option<String>, output: Option<String>) -> Result<Self> {
        let config_path = match config {
            Some(p) => PathBuf::from(p),
            None => std::env::current_dir()
                .context("getting current directory")?
                .join(CONFIG_FILENAME),
        };
        let config_path = config_path
            .canonicalize()
            .with_context(|| format!("config file not found: {}", config_path.display()))?;
        let project_dir = config_path
            .parent()
            .context("config file has no parent directory")?
            .to_path_buf();
        let config = Config::load(&config_path)?;
        let output_dir = match output {
            Some(p) => PathBuf::from(p),
            None => project_dir.join("trolley"),
        };
        Ok(Self {
            config_path,
            project_dir,
            output_dir,
            config,
        })
    }
}

// ---------------------------------------------------------------------------
// BundleManifest — describes the complete bundle contents for a target
// ---------------------------------------------------------------------------

pub enum BundleVariant {
    Linux {
        wrapper_name: String,
        install_prefix: String,
    },
    MacOs,
    Windows,
}

pub struct BundleManifest {
    pub runtime_name: String,
    pub core_name: String,
    pub target: Target,
    pub variant: BundleVariant,
    pub resources: Vec<PathBuf>,
}

impl BundleManifest {
    pub fn new(config: &Config, target: &Target) -> Self {
        let slug = config.app.slug.clone();
        let is_windows = target.is_windows();
        let runtime_name = if is_windows {
            format!("{slug}_runtime.exe")
        } else {
            format!("{slug}_runtime")
        };
        let core_name = if is_windows {
            format!("{slug}_core.exe")
        } else {
            format!("{slug}_core")
        };
        let layout = if target.is_linux() {
            BundleVariant::Linux {
                wrapper_name: slug.clone(),
                install_prefix: format!("/usr/lib/{slug}"),
            }
        } else if target.is_macos() {
            BundleVariant::MacOs
        } else {
            BundleVariant::Windows
        };
        Self {
            runtime_name,
            core_name,
            target: *target,
            variant: layout,
            resources: vec![
                PathBuf::from(GHOSTTY_CONFIG_FILENAME),
                PathBuf::from(ENVIRONMENT_FILENAME),
                PathBuf::from(CONFIG_FILENAME),
            ],
        }
    }

    /// All files in the bundle that need executable permissions.
    pub fn executables(&self) -> Vec<&str> {
        let mut exes = vec![self.runtime_name.as_str(), self.core_name.as_str()];
        if let BundleVariant::Linux { wrapper_name, .. } = &self.variant {
            exes.push(wrapper_name.as_str());
        }
        exes
    }
}
pub const GHOSTTY_DEFAULTS: &str = include_str!("ghostty_defaults.conf");

const DEFAULT_RUNTIME_SOURCE: &str = env!("TROLLEY_RUNTIME_SOURCE");

pub fn resolve_tui_binary(project_dir: &Path, config: &Config, target: &Target) -> Result<PathBuf> {
    let rel_path = config.binary_for(target).context(format!(
        "no binary path specified for {target} in trolley.toml"
    ))?;

    let abs_path = project_dir.join(rel_path);
    abs_path.canonicalize().with_context(|| {
        format!(
            "TUI binary not found at {}. Build it first (e.g. zig build or cargo build).",
            abs_path.display()
        )
    })
}

/// Compute the build output directory: `<output_dir>/build/<identifier>/<target>/`
pub fn build_output_dir(output_dir: &Path, config: &Config, target: &Target) -> PathBuf {
    output_dir
        .join("build")
        .join(&config.app.identifier)
        .join(target.to_string())
}

/// Compute the font cache directory: `<output_dir>/cache/fonts/`
pub fn font_cache_dir(output_dir: &Path) -> PathBuf {
    output_dir.join("cache").join("fonts")
}

/// Resolve all fonts from the manifest's `[fonts]` section.
///
/// For `nerdfont` entries: downloads from Nerd Fonts GitHub releases into the
/// cache directory (skips if already cached), extracts `.ttf` files.
///
/// For `path` entries: resolves relative to the project directory.
///
/// Returns the list of absolute paths to `.ttf`/`.otf` font files.
pub fn resolve_fonts(
    project_dir: &Path,
    output_dir: &Path,
    config: &Config,
) -> Result<Vec<PathBuf>> {
    let mut font_files: Vec<PathBuf> = Vec::new();

    if config.fonts.families.is_empty() {
        return Ok(font_files);
    }

    let cache_dir = font_cache_dir(output_dir);

    for family in &config.fonts.families {
        match family {
            FontFamily::NerdFont(name) => {
                let extracted_dir = cache_dir.join(name);
                if !extracted_dir.exists() {
                    download_nerdfont(name, &cache_dir)?;
                }
                // Collect all .ttf files from the extracted directory
                for entry in std::fs::read_dir(&extracted_dir).with_context(|| {
                    format!(
                        "reading extracted nerd font directory {}",
                        extracted_dir.display()
                    )
                })? {
                    let entry = entry?;
                    let path = entry.path();
                    if path.extension().and_then(|e| e.to_str()) == Some("ttf") {
                        font_files.push(path);
                    }
                }
            }
            FontFamily::Path(rel_path) => {
                let abs_path = project_dir.join(rel_path);
                if !abs_path.exists() {
                    bail!(
                        "font file not found: {} (resolved to {})",
                        rel_path,
                        abs_path.display()
                    );
                }
                font_files.push(abs_path);
            }
        }
    }

    Ok(font_files)
}

/// Download a Nerd Font from GitHub releases and extract `.ttf` files.
fn download_nerdfont(name: &str, cache_dir: &Path) -> Result<()> {
    let url =
        format!("https://github.com/ryanoasis/nerd-fonts/releases/latest/download/{name}.tar.xz");
    let archive_path = cache_dir.join(format!("{name}.tar.xz"));
    let extracted_dir = cache_dir.join(name);

    std::fs::create_dir_all(cache_dir)
        .with_context(|| format!("creating font cache directory {}", cache_dir.display()))?;

    // Download
    eprintln!("Downloading Nerd Font: {name}...");
    let response = ureq::get(&url)
        .call()
        .with_context(|| format!("downloading nerd font from {url}"))?;

    let mut archive_bytes = Vec::new();
    response
        .into_body()
        .into_reader()
        .read_to_end(&mut archive_bytes)
        .with_context(|| format!("reading nerd font response from {url}"))?;

    std::fs::write(&archive_path, &archive_bytes)
        .with_context(|| format!("writing {}", archive_path.display()))?;

    // Extract .ttf files from the .tar.xz archive
    eprintln!("Extracting {name}...");
    std::fs::create_dir_all(&extracted_dir)
        .with_context(|| format!("creating {}", extracted_dir.display()))?;

    let archive_file = std::fs::File::open(&archive_path)
        .with_context(|| format!("opening {}", archive_path.display()))?;
    let xz_reader = xz2::read::XzDecoder::new(archive_file);
    let mut tar_archive = tar::Archive::new(xz_reader);

    for entry in tar_archive.entries().context("reading tar entries")? {
        let mut entry = entry.context("reading tar entry")?;
        let path = entry.path().context("reading tar entry path")?.into_owned();

        // Only extract .ttf files, skip directories and other files
        let is_ttf = path
            .extension()
            .and_then(|e| e.to_str())
            .map(|e| e.eq_ignore_ascii_case("ttf"))
            .unwrap_or(false);

        if !is_ttf {
            continue;
        }

        // Extract to flat directory (ignore subdirectories in archive)
        let file_name = match path.file_name() {
            Some(name) => name.to_owned(),
            None => continue,
        };
        let dest = extracted_dir.join(&file_name);
        let mut out_file =
            std::fs::File::create(&dest).with_context(|| format!("creating {}", dest.display()))?;
        std::io::copy(&mut entry, &mut out_file)
            .with_context(|| format!("extracting {}", dest.display()))?;
    }

    // Remove the archive now that we've extracted
    let _ = std::fs::remove_file(&archive_path);

    Ok(())
}

/// Read font family names from `.ttf`/`.otf` files using the OpenType name table.
/// Returns deduplicated family names in the order they first appear.
pub fn read_font_family_names(font_files: &[PathBuf]) -> Result<Vec<String>> {
    let mut names: Vec<String> = Vec::new();
    let mut seen = std::collections::HashSet::new();

    for path in font_files {
        let data =
            std::fs::read(path).with_context(|| format!("reading font file {}", path.display()))?;
        let face = match ttf_parser::Face::parse(&data, 0) {
            Ok(f) => f,
            Err(e) => {
                eprintln!("warning: could not parse font {}: {e}", path.display());
                continue;
            }
        };

        // Name ID 1 = Font Family Name
        for name in face.names() {
            if name.name_id == ttf_parser::name_id::FAMILY {
                if let Some(family) = name.to_string() {
                    if seen.insert(family.clone()) {
                        names.push(family);
                    }
                    break;
                }
            }
        }
    }

    Ok(names)
}

/// Copy resolved font files into the bundle's `fonts/` directory and write
/// a `fonts.conf` for fontconfig so the runtime can point FONTCONFIG_FILE at it.
pub fn copy_fonts_to_bundle(font_files: &[PathBuf], output_dir: &Path) -> Result<()> {
    if font_files.is_empty() {
        return Ok(());
    }

    let fonts_dir = output_dir.join("fonts");
    std::fs::create_dir_all(&fonts_dir)
        .with_context(|| format!("creating fonts directory {}", fonts_dir.display()))?;

    for src in font_files {
        let file_name = src.file_name().context("font file has no filename")?;
        let dest = fonts_dir.join(file_name);
        std::fs::copy(src, &dest)
            .with_context(|| format!("copying {} to {}", src.display(), dest.display()))?;
    }

    // Write a fontconfig config that includes the system config and adds the
    // bundled fonts/ directory. The <dir> path is relative to this file's
    // location (the bundle root).
    let fonts_conf = output_dir.join(FONTS_CONFIG_FILENAME);
    std::fs::write(&fonts_conf, FONTCONFIG_TEMPLATE)
        .with_context(|| format!("writing {}", fonts_conf.display()))?;

    Ok(())
}

/// Resolve the first Windows `.ico` declared by `[app].icons`.
///
/// The chosen icon is bundled under a fixed filename so the Windows runtime can
/// load it without depending on source-tree-relative manifest paths.
pub fn resolve_windows_icon(project_dir: &Path, config: &Config) -> Result<Option<PathBuf>> {
    for pattern in &config.app.icons {
        let pattern_path = project_dir.join(pattern);
        let pattern = pattern_path.to_string_lossy().into_owned();
        let mut matches = Vec::new();

        for entry in
            glob::glob(&pattern).with_context(|| format!("invalid icon glob: {pattern}"))?
        {
            let path = entry.with_context(|| format!("reading icon glob: {pattern}"))?;
            let is_ico = path
                .extension()
                .and_then(|ext| ext.to_str())
                .map(|ext| ext.eq_ignore_ascii_case("ico"))
                .unwrap_or(false);
            if !is_ico {
                continue;
            }

            matches.push(
                path.canonicalize()
                    .with_context(|| format!("resolving icon {}", path.display()))?,
            );
        }

        matches.sort();
        if let Some(path) = matches.into_iter().next() {
            return Ok(Some(path));
        }
    }

    Ok(None)
}

pub fn copy_windows_icon_to_bundle(icon_path: &Path, output_dir: &Path) -> Result<()> {
    let dest = output_dir.join(WINDOWS_ICON_FILENAME);
    std::fs::copy(icon_path, &dest).with_context(|| {
        format!(
            "copying Windows icon {} to {}",
            icon_path.display(),
            dest.display()
        )
    })?;
    Ok(())
}

pub struct BundledPath {
    pub relative_path: PathBuf,
    pub absolute_path: PathBuf,
}

pub fn resolve_shaders(project_dir: &Path, config: &Config) -> Result<Vec<BundledPath>> {
    config
        .embeds
        .shaders
        .iter()
        .map(|shader| {
            let relative_path = PathBuf::from(shader);
            let absolute_path = project_dir.join(&relative_path);
            let absolute_path = absolute_path
                .canonicalize()
                .with_context(|| format!("shader file not found at {}", absolute_path.display()))?;

            Ok(BundledPath {
                relative_path,
                absolute_path,
            })
        })
        .collect()
}

pub fn resolve_data_paths(project_dir: &Path, config: &Config) -> Result<Vec<BundledPath>> {
    config
        .embeds
        .data
        .iter()
        .map(|data_path| {
            let relative_path = PathBuf::from(data_path);
            let absolute_path = project_dir.join(&relative_path);
            let absolute_path = absolute_path
                .canonicalize()
                .with_context(|| format!("data path not found at {}", absolute_path.display()))?;

            Ok(BundledPath {
                relative_path,
                absolute_path,
            })
        })
        .collect()
}

pub fn copy_shader_to_bundle(shader: &BundledPath, output_dir: &Path) -> Result<()> {
    let dest = output_dir.join(&shader.relative_path);
    if let Some(parent) = dest.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("creating shader directory {}", parent.display()))?;
    }
    std::fs::copy(&shader.absolute_path, &dest).with_context(|| {
        format!(
            "copying shader {} to {}",
            shader.absolute_path.display(),
            dest.display()
        )
    })?;

    Ok(())
}

pub fn copy_data_path_to_bundle(data_path: &BundledPath, output_dir: &Path) -> Result<Vec<PathBuf>> {
    let dest = output_dir.join(&data_path.relative_path);
    if data_path.absolute_path.is_dir() {
        let mut copied_files = Vec::new();
        copy_directory_contents(
            &data_path.absolute_path,
            &dest,
            &data_path.relative_path,
            &mut copied_files,
        )?;
        Ok(copied_files)
    } else {
        if let Some(parent) = dest.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating data directory {}", parent.display()))?;
        }
        std::fs::copy(&data_path.absolute_path, &dest).with_context(|| {
            format!(
                "copying data file {} to {}",
                data_path.absolute_path.display(),
                dest.display()
            )
        })?;
        Ok(vec![data_path.relative_path.clone()])
    }
}

fn copy_directory_contents(
    src_dir: &Path,
    dest_dir: &Path,
    relative_root: &Path,
    copied_files: &mut Vec<PathBuf>,
) -> Result<()> {
    std::fs::create_dir_all(dest_dir)
        .with_context(|| format!("creating data directory {}", dest_dir.display()))?;

    for entry in std::fs::read_dir(src_dir)
        .with_context(|| format!("reading data directory {}", src_dir.display()))?
    {
        let entry = entry?;
        let src_path = entry.path();
        let dest_path = dest_dir.join(entry.file_name());
        let relative_path = relative_root.join(entry.file_name());

        if src_path.is_dir() {
            copy_directory_contents(&src_path, &dest_path, &relative_path, copied_files)?;
        } else {
            if let Some(parent) = dest_path.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("creating data directory {}", parent.display()))?;
            }
            std::fs::copy(&src_path, &dest_path).with_context(|| {
                format!(
                    "copying data file {} to {}",
                    src_path.display(),
                    dest_path.display()
                )
            })?;
            copied_files.push(relative_path);
        }
    }

    Ok(())
}

const FONTCONFIG_TEMPLATE: &str = r#"<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <include ignore_missing="yes">/etc/fonts/fonts.conf</include>
  <dir prefix="default">fonts</dir>
</fontconfig>
"#;

// ---------------------------------------------------------------------------
// Runtime resolution
// ---------------------------------------------------------------------------

fn runtime_exe_name(target: &Target) -> &'static str {
    if target.as_str().contains("windows") {
        "trolley.exe"
    } else {
        "trolley"
    }
}

/// Directory where a runtime binary is cached locally.
fn runtime_cache_dir(target: &Target) -> Result<PathBuf> {
    let dirs = directories::ProjectDirs::from("", "", "trolley")
        .context("could not determine data directory")?;
    Ok(dirs
        .data_local_dir()
        .join("runtimes")
        .join(VERSION)
        .join(target.to_string()))
}

/// Resolve the runtime binary for a given target.
///
/// The runtime source is a template string (URL or local file path) with
/// `{version}` and `{target}` placeholders. Resolution order:
///
/// 1. `TROLLEY_RUNTIME_SOURCE` env var (runtime override)
/// 2. `TROLLEY_RUNTIME_SOURCE` compile-time value (set at `cargo build` time)
///
/// After substitution:
/// - URLs (`https://` or `http://`): check cache → download `.tar.xz` → extract → return cached path
/// - Local file paths: return directly (file must exist)
pub fn resolve_runtime(target: &Target) -> Result<PathBuf> {
    let template = std::env::var("TROLLEY_RUNTIME_SOURCE")
        .unwrap_or_else(|_| DEFAULT_RUNTIME_SOURCE.to_string());

    let source = template
        .replace("{version}", VERSION)
        .replace("{target}", target.as_str());

    match url::Url::parse(&source) {
        Ok(url) if url.scheme() == "http" || url.scheme() == "https" => {
            resolve_runtime_from_url(url, target)
        }
        _ => resolve_runtime_from_path(&source),
    }
}

fn resolve_runtime_from_path(path: &str) -> Result<PathBuf> {
    let path = PathBuf::from(path);
    if !path.exists() {
        bail!(
            "runtime not found at {}. Build it first (just build-runtime).",
            path.display()
        );
    }
    Ok(path)
}

fn resolve_runtime_from_url(url: url::Url, target: &Target) -> Result<PathBuf> {
    let cache_dir = runtime_cache_dir(target)?;
    let exe_name = runtime_exe_name(target);
    let cache_path = cache_dir.join(exe_name);

    if cache_path.exists() {
        return Ok(cache_path);
    }

    std::fs::create_dir_all(&cache_dir)
        .with_context(|| format!("creating runtime cache directory {}", cache_dir.display()))?;

    eprintln!("Downloading trolley runtime for {target}...");
    eprintln!("  {url}");

    let response = ureq::get(url.as_str())
        .call()
        .with_context(|| format!("downloading runtime from {url}"))?;

    let mut archive_bytes = Vec::new();
    response
        .into_body()
        .into_reader()
        .read_to_end(&mut archive_bytes)
        .with_context(|| format!("reading runtime response from {url}"))?;

    let xz_reader = xz2::read::XzDecoder::new(io::Cursor::new(archive_bytes));
    let mut tar_archive = tar::Archive::new(xz_reader);

    for entry in tar_archive.entries().context("reading tar entries")? {
        let mut entry = entry.context("reading tar entry")?;
        let path = entry.path().context("reading tar entry path")?.into_owned();
        let file_name = match path.file_name() {
            Some(name) => name.to_owned(),
            None => continue,
        };
        let dest = cache_dir.join(&file_name);
        let mut out_file =
            std::fs::File::create(&dest).with_context(|| format!("creating {}", dest.display()))?;
        io::copy(&mut entry, &mut out_file)
            .with_context(|| format!("extracting {}", dest.display()))?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755))?;
        }
    }

    eprintln!("Runtime installed to {}", cache_dir.display());

    if cache_path.exists() {
        Ok(cache_path)
    } else {
        bail!(
            "downloaded runtime but file not found at {}",
            cache_path.display()
        );
    }
}

// ---------------------------------------------------------------------------
// Environment assembly
// ---------------------------------------------------------------------------

/// Assemble the bundled `environment` file from defaults, env_file, and manifest variables.
///
/// Layering order (later overrides earlier):
/// 1. Trolley defaults (LANG=C.UTF-8, LC_ALL=C.UTF-8)
/// 2. env_file contents (parsed by dotenvy)
/// 3. Inline `[environment] variables` from manifest
pub fn assemble_environment(project_dir: &Path, config: &Config) -> Result<Vec<u8>> {
    let mut vars: std::collections::BTreeMap<String, String> = std::collections::BTreeMap::new();

    // 1. Defaults
    for (key, value) in ENVIRONMENT_DEFAULTS {
        vars.insert((*key).into(), (*value).into());
    }

    // 2. env_file (parsed and validated by dotenvy)
    if let Some(ref env_file) = config.environment.env_file {
        let env_path = project_dir.join(env_file);
        for item in dotenvy::from_path_iter(&env_path)
            .with_context(|| format!("reading env_file {}", env_path.display()))?
        {
            let (key, value) =
                item.with_context(|| format!("parsing env_file {}", env_path.display()))?;
            vars.insert(key, value);
        }
    }

    // 3. Manifest variables (validated by dotenvy — serialize then parse)
    if !config.environment.variables.is_empty() {
        let inline: String = config
            .environment
            .variables
            .iter()
            .map(|(k, v)| format!("{k}={v}"))
            .collect::<Vec<_>>()
            .join("\n");
        for item in dotenvy::from_read_iter(inline.as_bytes()) {
            let (key, value) = item.context("parsing [environment] variables")?;
            vars.insert(key, value);
        }
    }

    let mut buf = Vec::new();
    for (key, value) in &vars {
        write!(buf, "{key}={value}\n")?;
    }
    Ok(buf)
}

// ---------------------------------------------------------------------------
// Config assembly
// ---------------------------------------------------------------------------

pub fn assemble_config(
    project_dir: &Path,
    config: &Config,
    target: &Target,
    command_target: &str,
    font_family_names: &[String],
) -> Result<Vec<u8>> {
    let mut buf = Vec::new();

    // 1. Ghostty defaults (embedded at compile time)
    buf.write_all(GHOSTTY_DEFAULTS.as_bytes())?;
    buf.write_all(b"\n")?;

    // 2. Font family names from bundled fonts (when config_ghostty is true)
    if config.fonts.config_ghostty && !font_family_names.is_empty() {
        for name in font_family_names {
            write!(buf, "font-family = {name}\n")?;
        }
        buf.write_all(b"\n")?;
    }

    // 3. Project theme file (optional) — inlined so packaged apps do not
    // depend on Ghostty's external theme catalog being present.
    if let Some(theme) = &config.embeds.theme {
        let theme_path = PathBuf::from(theme);
        let theme_path = if theme_path.is_absolute() {
            theme_path
        } else {
            project_dir.join(theme_path)
        };
        let content = std::fs::read(&theme_path)
            .with_context(|| format!("reading theme file {}", theme_path.display()))?;
        buf.write_all(&content)?;
        buf.write_all(b"\n")?;
    }

    // 4. Developer's ghostty.conf (optional)
    let dev_config = project_dir.join(GHOSTTY_CONFIG_FILENAME);
    if dev_config.exists() {
        let content = std::fs::read(&dev_config)
            .with_context(|| format!("reading {}", dev_config.display()))?;
        buf.write_all(&content)?;
        buf.write_all(b"\n")?;
    }

    // 5. Bundled custom shader paths (optional)
    for shader in &config.embeds.shaders {
        write!(buf, "custom-shader = {shader}\n")?;
    }
    if !config.embeds.shaders.is_empty() {
        buf.write_all(b"\n")?;
    }

    // 6. [ghostty] section from manifest (overrides theme, shaders, and ghostty.conf)
    let ghostty_config = trolley_config::ghostty_config_string(config);
    if !ghostty_config.is_empty() {
        buf.write_all(ghostty_config.as_bytes())?;
        buf.write_all(b"\n")?;
    }

    // 7. Command to run the TUI binary, unless explicitly overridden.
    // Some apps need custom Ghostty startup semantics (for example `shell:`
    // commands paired with explicit working-directory behavior), so a manifest
    // `command` must take precedence over this default.
    // Use ./ prefix so ghostty resolves the binary relative to CWD
    // (the runtime chdirs to its own directory at startup).
    if !config.ghostty.contains_key("command") {
        let mut command = format!("command = direct:./{command_target}");
        if let Some(args) = config.args_for(target) {
            for arg in args {
                command.push(' ');
                command.push_str(arg);
            }
        }
        command.push('\n');
        buf.write_all(command.as_bytes())?;
    }

    Ok(buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use trolley_config::{App, Arch, Embeds, Environment, Fonts, Gui, Linux, Target};

    fn test_manifest() -> Config {
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
            embeds: Embeds::default(),
            ghostty: BTreeMap::new(),
        }
    }

    #[test]
    fn environment_defaults_only() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = test_manifest();
        let result = assemble_environment(dir.path(), &manifest).unwrap();
        insta::assert_snapshot!(String::from_utf8(result).unwrap());
    }

    #[test]
    fn environment_with_variables() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = test_manifest();
        manifest
            .environment
            .variables
            .insert("FOO".into(), "bar".into());
        manifest
            .environment
            .variables
            .insert("BAZ".into(), "qux".into());
        let result = assemble_environment(dir.path(), &manifest).unwrap();
        insta::assert_snapshot!(String::from_utf8(result).unwrap());
    }

    #[test]
    fn environment_variables_override_defaults() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = test_manifest();
        manifest
            .environment
            .variables
            .insert("LANG".into(), "en_US.UTF-8".into());
        let result = assemble_environment(dir.path(), &manifest).unwrap();
        insta::assert_snapshot!(String::from_utf8(result).unwrap());
    }

    #[test]
    fn environment_with_env_file() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(".env"), "MY_VAR=hello\nOTHER=world\n").unwrap();
        let mut manifest = test_manifest();
        manifest.environment.env_file = Some(".env".into());
        let result = assemble_environment(dir.path(), &manifest).unwrap();
        insta::assert_snapshot!(String::from_utf8(result).unwrap());
    }

    #[test]
    fn environment_env_file_overridden_by_variables() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(".env"), "FOO=from_file\n").unwrap();
        let mut manifest = test_manifest();
        manifest.environment.env_file = Some(".env".into());
        manifest
            .environment
            .variables
            .insert("FOO".into(), "from_manifest".into());
        let result = assemble_environment(dir.path(), &manifest).unwrap();
        insta::assert_snapshot!(String::from_utf8(result).unwrap());
    }

    #[test]
    fn environment_env_file_overrides_defaults() {
        let dir = tempfile::tempdir().unwrap();
        std::fs::write(dir.path().join(".env"), "LANG=en_GB.UTF-8\n").unwrap();
        let mut manifest = test_manifest();
        manifest.environment.env_file = Some(".env".into());
        let result = assemble_environment(dir.path(), &manifest).unwrap();
        insta::assert_snapshot!(String::from_utf8(result).unwrap());
    }

    #[test]
    fn environment_missing_env_file_errors() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = test_manifest();
        manifest.environment.env_file = Some("nonexistent.env".into());
        let result = assemble_environment(dir.path(), &manifest);
        assert!(result.is_err());
    }

    #[test]
    fn resolve_windows_icon_prefers_ico_matches() {
        let dir = tempfile::tempdir().unwrap();
        let assets_dir = dir.path().join("assets");
        std::fs::create_dir_all(&assets_dir).unwrap();
        std::fs::write(assets_dir.join("icon.png"), b"png").unwrap();
        std::fs::write(assets_dir.join("icon.ico"), b"ico").unwrap();

        let mut manifest = test_manifest();
        manifest.app.icons = vec!["assets/icon.*".into()];

        let resolved = resolve_windows_icon(dir.path(), &manifest).unwrap();
        assert_eq!(
            resolved,
            Some(assets_dir.join("icon.ico").canonicalize().unwrap())
        );
    }

    #[test]
    fn resolve_windows_icon_uses_first_pattern_with_ico() {
        let dir = tempfile::tempdir().unwrap();
        let assets_dir = dir.path().join("assets");
        let icons_dir = dir.path().join("icons");
        std::fs::create_dir_all(&assets_dir).unwrap();
        std::fs::create_dir_all(&icons_dir).unwrap();
        std::fs::write(assets_dir.join("icon.png"), b"png").unwrap();
        std::fs::write(icons_dir.join("app.ico"), b"ico").unwrap();

        let mut manifest = test_manifest();
        manifest.app.icons = vec!["assets/*".into(), "icons/*".into()];

        let resolved = resolve_windows_icon(dir.path(), &manifest).unwrap();
        assert_eq!(
            resolved,
            Some(icons_dir.join("app.ico").canonicalize().unwrap())
        );
    }

    #[test]
    fn assemble_config_adds_default_command_when_not_overridden() {
        let dir = tempfile::tempdir().unwrap();
        let manifest = test_manifest();
        let bytes =
            assemble_config(dir.path(), &manifest, &Target::X86_64Linux, "app_core", &[]).unwrap();
        let rendered = String::from_utf8(bytes).unwrap();

        assert!(rendered.contains("working-directory = inherit\n"));
        assert!(rendered.contains("command = direct:./app_core\n"));
    }

    #[test]
    fn assemble_config_respects_manifest_command_override() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = test_manifest();
        manifest.ghostty.insert(
            "command".into(),
            toml::Value::String("shell:./app_core".into()),
        );
        let bytes =
            assemble_config(dir.path(), &manifest, &Target::X86_64Linux, "app_core", &[]).unwrap();
        let rendered = String::from_utf8(bytes).unwrap();

        assert!(rendered.contains("command = shell:./app_core\n"));
        assert!(!rendered.contains("command = direct:./app_core\n"));
    }

    #[test]
    fn assemble_config_inlines_theme_file_before_manifest_overrides() {
        let dir = tempfile::tempdir().unwrap();
        let theme_dir = dir.path().join("themes");
        std::fs::create_dir_all(&theme_dir).unwrap();
        std::fs::write(
            theme_dir.join("custom"),
            "background = 000000\nforeground = ffffff\n",
        )
        .unwrap();

        let mut manifest = test_manifest();
        manifest.embeds.theme = Some("themes/custom".into());
        manifest
            .ghostty
            .insert("background".into(), toml::Value::String("111111".into()));

        let bytes =
            assemble_config(dir.path(), &manifest, &Target::X86_64Linux, "app_core", &[]).unwrap();
        let rendered = String::from_utf8(bytes).unwrap();

        let theme_idx = rendered.find("background = 000000\n").unwrap();
        let override_idx = rendered.find("background = 111111\n").unwrap();
        assert!(theme_idx < override_idx);
        assert!(rendered.contains("foreground = ffffff\n"));
    }

    #[test]
    fn assemble_config_includes_custom_shader_when_configured() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = test_manifest();
        manifest.embeds.shaders = vec!["shaders/crt.glsl".into(), "shaders/bloom.glsl".into()];

        let bytes =
            assemble_config(dir.path(), &manifest, &Target::X86_64Linux, "app_core", &[]).unwrap();
        let rendered = String::from_utf8(bytes).unwrap();
        assert!(rendered.contains("custom-shader = shaders/crt.glsl\n"));
        assert!(rendered.contains("custom-shader = shaders/bloom.glsl\n"));
    }

    #[test]
    fn assemble_config_appends_platform_args_to_default_command() {
        let dir = tempfile::tempdir().unwrap();
        let mut manifest = test_manifest();
        manifest.linux.as_mut().unwrap().args = vec!["--verbose".into(), "--port=9000".into()];

        let bytes =
            assemble_config(dir.path(), &manifest, &Target::X86_64Linux, "app_core", &[]).unwrap();
        let rendered = String::from_utf8(bytes).unwrap();
        assert!(rendered.contains("command = direct:./app_core --verbose --port=9000\n"));
    }

    #[test]
    fn resolve_shaders_resolve_relative_paths() {
        let dir = tempfile::tempdir().unwrap();
        let shader_dir = dir.path().join("shaders");
        std::fs::create_dir_all(&shader_dir).unwrap();
        std::fs::write(shader_dir.join("crt.glsl"), "void mainImage() {}").unwrap();
        std::fs::write(shader_dir.join("bloom.glsl"), "void mainImage() {}").unwrap();

        let mut manifest = test_manifest();
        manifest.embeds.shaders = vec!["shaders/crt.glsl".into(), "shaders/bloom.glsl".into()];

        let shaders = resolve_shaders(dir.path(), &manifest).unwrap();
        assert_eq!(shaders.len(), 2);
        assert_eq!(shaders[0].relative_path, PathBuf::from("shaders/crt.glsl"));
        assert_eq!(shaders[1].relative_path, PathBuf::from("shaders/bloom.glsl"));
        assert!(shaders.iter().all(|shader| shader.absolute_path.is_absolute()));
    }

    #[test]
    fn copy_shader_to_bundle_preserves_relative_path() {
        let dir = tempfile::tempdir().unwrap();
        let bundle_dir = tempfile::tempdir().unwrap();
        let shader_dir = dir.path().join("shaders");
        std::fs::create_dir_all(&shader_dir).unwrap();
        std::fs::write(shader_dir.join("crt.glsl"), "void mainImage() {}").unwrap();
        std::fs::write(shader_dir.join("bloom.glsl"), "void mainImage() {}").unwrap();

        let mut manifest = test_manifest();
        manifest.embeds.shaders = vec!["shaders/crt.glsl".into(), "shaders/bloom.glsl".into()];

        let shaders = resolve_shaders(dir.path(), &manifest).unwrap();
        for shader in &shaders {
            copy_shader_to_bundle(shader, bundle_dir.path()).unwrap();
        }

        assert!(bundle_dir.path().join("shaders/crt.glsl").exists());
        assert!(bundle_dir.path().join("shaders/bloom.glsl").exists());
    }

    #[test]
    fn resolve_data_paths_resolves_file_and_directory_paths() {
        let dir = tempfile::tempdir().unwrap();
        let assets_dir = dir.path().join("assets");
        std::fs::create_dir_all(assets_dir.join("nested")).unwrap();
        std::fs::write(assets_dir.join("nested/info.txt"), "hello").unwrap();
        std::fs::create_dir_all(dir.path().join("config")).unwrap();
        std::fs::write(dir.path().join("config/defaults.json"), "{}").unwrap();

        let mut manifest = test_manifest();
        manifest.embeds.data = vec!["assets".into(), "config/defaults.json".into()];

        let data_paths = resolve_data_paths(dir.path(), &manifest).unwrap();
        assert_eq!(data_paths.len(), 2);
        assert_eq!(data_paths[0].relative_path, PathBuf::from("assets"));
        assert_eq!(data_paths[1].relative_path, PathBuf::from("config/defaults.json"));
        assert!(data_paths[0].absolute_path.is_dir());
        assert!(data_paths[1].absolute_path.is_file());
    }

    #[test]
    fn copy_data_path_to_bundle_preserves_relative_layout() {
        let dir = tempfile::tempdir().unwrap();
        let bundle_dir = tempfile::tempdir().unwrap();
        let assets_dir = dir.path().join("assets");
        std::fs::create_dir_all(assets_dir.join("nested")).unwrap();
        std::fs::write(assets_dir.join("nested/info.txt"), "hello").unwrap();
        std::fs::create_dir_all(dir.path().join("config")).unwrap();
        std::fs::write(dir.path().join("config/defaults.json"), "{}").unwrap();

        let mut manifest = test_manifest();
        manifest.embeds.data = vec!["assets".into(), "config/defaults.json".into()];

        let data_paths = resolve_data_paths(dir.path(), &manifest).unwrap();
        let mut copied_files = Vec::new();
        for data_path in &data_paths {
            copied_files.extend(copy_data_path_to_bundle(data_path, bundle_dir.path()).unwrap());
        }

        assert!(bundle_dir.path().join("assets/nested/info.txt").exists());
        assert!(bundle_dir.path().join("config/defaults.json").exists());
        assert!(copied_files.contains(&PathBuf::from("assets/nested/info.txt")));
        assert!(copied_files.contains(&PathBuf::from("config/defaults.json")));
    }
}
