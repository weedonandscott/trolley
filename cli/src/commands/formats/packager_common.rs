use std::path::Path;

use anyhow::{Context, Result};
use cargo_packager::PackageFormat;
use cargo_packager::config::{Binary, Config as PackagerConfig, Resource};
use trolley_config::Config;

use super::super::common::{BundleManifest, BundleVariant};

/// Formats handled by cargo-packager. Every variant maps 1:1 to a PackageFormat.
pub enum PackagerFormat {
    Deb,
    AppImage,
    Pacman,
    Nsis,
    MacApp,
    Dmg,
}

impl PackagerFormat {
    fn to_package_format(&self) -> PackageFormat {
        match self {
            Self::Deb => PackageFormat::Deb,
            Self::AppImage => PackageFormat::AppImage,
            Self::Pacman => PackageFormat::Pacman,
            Self::Nsis => PackageFormat::Nsis,
            Self::MacApp => PackageFormat::App,
            Self::Dmg => PackageFormat::Dmg,
        }
    }
}

/// Build a cargo-packager `Config` from a trolley config and bundle manifest.
///
/// On Linux: the wrapper script (`<slug>`) is the main binary; runtime, TUI core,
/// configs, and fonts are resources that land in `/usr/lib/<slug>/`.
///
/// On macOS (.app): the runtime is the main binary, TUI core is a secondary binary;
/// configs and fonts are resources that land in `Contents/Resources/`.
///
/// On Windows (NSIS): the runtime (`<slug>_runtime.exe`) is the main binary;
/// TUI core, configs, and fonts are resources placed next to it in `$INSTDIR`.
fn build_packager_config(
    config: &Config,
    bundle_dir: &Path,
    dist_dir: &Path,
    manifest: &BundleManifest,
    formats: &[PackagerFormat],
) -> Result<PackagerConfig> {
    let packager_formats: Vec<PackageFormat> =
        formats.iter().map(|f| f.to_package_format()).collect();

    let (binary_names, extra_resource_names) = match manifest.variant {
        BundleVariant::Linux {
            ref wrapper_name, ..
        } => {
            // Linux: wrapper script is the binary, everything else is a resource
            (
                vec![wrapper_name.as_str()],
                vec![manifest.runtime_name.as_str(), manifest.core_name.as_str()],
            )
        }
        BundleVariant::MacOs => {
            // macOS .app: runtime is main binary, TUI core is secondary binary
            (
                vec![manifest.runtime_name.as_str(), manifest.core_name.as_str()],
                vec![],
            )
        }
        BundleVariant::Windows => {
            // Windows (NSIS): runtime is the binary, TUI core is a resource
            (
                vec![manifest.runtime_name.as_str()],
                vec![manifest.core_name.as_str()],
            )
        }
    };

    let binaries: Vec<Binary> = binary_names
        .iter()
        .enumerate()
        .map(|(i, name)| {
            let b = Binary::new(name);
            if i == 0 { b.main(true) } else { b }
        })
        .collect();

    let mut resource_files: Vec<Resource> = extra_resource_names
        .iter()
        .map(|name| resource_mapped(bundle_dir, name, name))
        .collect();

    for path in &manifest.resources {
        let path = path.display().to_string();
        resource_files.push(resource_mapped(bundle_dir, &path, &path));
    }

    let mut packager_config = PackagerConfig::default();
    packager_config.product_name = config.app.display_name.clone();
    packager_config.version = config.app.version.clone();
    packager_config.identifier = Some(config.app.identifier.clone());
    packager_config.binaries = binaries;
    packager_config.formats = Some(packager_formats);
    packager_config.out_dir = dist_dir.to_path_buf();
    packager_config.binaries_dir = Some(bundle_dir.to_path_buf());
    packager_config.target_triple = Some(manifest.target.target_triple().to_string());
    packager_config.description = Some(config.app.display_name.clone());
    packager_config.resources = Some(resource_files);
    packager_config.icons = if config.app.icons.is_empty() {
        None
    } else {
        Some(config.app.icons.clone())
    };

    if let BundleVariant::Linux { .. } = manifest.variant {
        let mut deb = cargo_packager::config::DebianConfig::default();
        deb.package_name = Some(config.app.slug.clone());
        packager_config.deb = Some(deb);
    }

    // Code-signing: only the matching platform's config is applied. The signing structs hold
    // non-secret selectors; cargo-packager reads cert material / notarization / Azure creds
    // from the environment itself.
    match manifest.variant {
        BundleVariant::MacOs => {
            if let Some(signing) = config.macos.as_ref().and_then(|m| m.signing.as_ref()) {
                // Identity from config, else the APPLE_SIGNING_IDENTITY env var (Tauri parity).
                // Drop an empty/whitespace env value so it falls through to the bail! below
                // instead of producing a confusing `codesign -s ""`.
                let identity = signing.identity.clone().or_else(|| {
                    std::env::var("APPLE_SIGNING_IDENTITY")
                        .ok()
                        .filter(|s| !s.trim().is_empty())
                });
                let Some(identity) = identity else {
                    anyhow::bail!(
                        "[macos.signing] is set but no signing identity was found: set \
                         `identity` in trolley.toml or the APPLE_SIGNING_IDENTITY env var"
                    );
                };
                let mut macos = cargo_packager::config::MacOsConfig::default();
                macos.signing_identity = Some(identity);
                macos.entitlements = signing.entitlements.clone();
                packager_config.macos = Some(macos);
                // notarization_credentials + cert material left unset on purpose:
                // cargo-packager reads APPLE_* / APPLE_CERTIFICATE* from the environment.
            }
        }
        BundleVariant::Windows => {
            if let Some(signing) = config.windows.as_ref().and_then(|w| w.signing.as_ref()) {
                let mut win = cargo_packager::config::WindowsConfig::default();
                win.certificate_thumbprint = signing.thumbprint.clone();
                win.sign_command = signing.sign_command.clone();
                win.timestamp_url = signing.timestamp_url.clone();
                if let Some(digest) = &signing.digest_algorithm {
                    win.digest_algorithm = Some(digest.clone());
                }
                win.tsp = signing.tsp;
                packager_config.windows = Some(win);
            }
        }
        BundleVariant::Linux { .. } => {}
    }

    Ok(packager_config)
}

/// Create a `Resource::Mapped` pointing from a bundle file to its target name.
fn resource_mapped(bundle_dir: &Path, src_name: &str, target_name: &str) -> Resource {
    Resource::Mapped {
        src: bundle_dir.join(src_name).display().to_string(),
        target: target_name.into(),
    }
}

/// Package the bundle using cargo-packager for the given formats.
pub fn run_packager(
    config: &Config,
    bundle_dir: &Path,
    dist_dir: &Path,
    manifest: &BundleManifest,
    formats: &[PackagerFormat],
) -> Result<()> {
    let packager_config = build_packager_config(config, bundle_dir, dist_dir, manifest, formats)
        .context("building cargo-packager config")?;

    let outputs =
        cargo_packager::package(&packager_config).context("cargo-packager packaging failed")?;

    for output in &outputs {
        for path in &output.paths {
            let filename = path
                .file_name()
                .map(|f| f.to_string_lossy())
                .unwrap_or_default();
            println!("  {filename}  ({:?} package)", output.format);
        }
    }

    Ok(())
}
