use std::path::Path;
use std::str::FromStr;

use anyhow::{Context, Result};
use cargo_packager::PackageFormat;
use cargo_packager::config::{
    AppCategory, Binary, BundleTypeRole, Config as PackagerConfig, FileAssociation, Resource,
};
use trolley_config::{ArtifactNaming, Config, FileAssociationRole, Format};

use super::super::common::{BundleManifest, BundleVariant, anchored_glob_pattern};

/// Resolve `[linux] category` against cargo-packager's fuzzy `AppCategory`
/// matcher, which returns the closest accepted spelling as a suggestion.
pub fn parse_linux_category(config: &Config) -> Result<Option<AppCategory>> {
    let Some(input) = config.linux.as_ref().and_then(|l| l.category.as_deref()) else {
        return Ok(None);
    };
    match AppCategory::from_str(input) {
        Ok(category) => Ok(Some(category)),
        Err(Some(suggestion)) => anyhow::bail!(
            "[linux] category: unknown category \"{input}\" (did you mean \"{suggestion}\"?)"
        ),
        Err(None) => anyhow::bail!(
            "[linux] category: unknown category \"{input}\" (see the accepted list in the \
             trolley README, e.g. \"Utility\", \"Developer Tool\", \"Education\")"
        ),
    }
}

/// Map trolley's file associations onto cargo-packager's.
///
/// The handler name is always `<slug>.<first extension>`: NSIS derives the
/// ProgID from it, and a bare extension would be a globally shared registry
/// class. The same string is macOS's `CFBundleTypeName`, where it is harmless.
pub fn packager_file_associations(config: &Config) -> Option<Vec<FileAssociation>> {
    if config.app.file_associations.is_empty() {
        return None;
    }
    Some(
        config
            .app
            .file_associations
            .iter()
            .map(|a| {
                let mut mapped = FileAssociation::new(a.extensions.iter().cloned());
                mapped = mapped.mime_type(a.mime_type.clone());
                if let Some(description) = &a.description {
                    mapped = mapped.description(description.clone());
                }
                mapped = mapped.role(bundle_type_role(a.role));
                if let Some(first) = a.extensions.first() {
                    mapped = mapped.name(format!("{}.{first}", config.app.slug));
                }
                mapped
            })
            .collect(),
    )
}

fn bundle_type_role(role: FileAssociationRole) -> BundleTypeRole {
    match role {
        FileAssociationRole::Editor => BundleTypeRole::Editor,
        FileAssociationRole::Viewer => BundleTypeRole::Viewer,
        FileAssociationRole::Shell => BundleTypeRole::Shell,
        FileAssociationRole::QlGenerator => BundleTypeRole::QLGenerator,
        FileAssociationRole::None => BundleTypeRole::None,
    }
}

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
    project_dir: &Path,
    bundle_dir: &Path,
    out_dir: &Path,
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
    packager_config.out_dir = out_dir.to_path_buf();
    packager_config.binaries_dir = Some(bundle_dir.to_path_buf());
    packager_config.target_triple = Some(manifest.target.target_triple().to_string());
    packager_config.description = Some(config.app.display_name.clone());
    packager_config.resources = Some(resource_files);
    // Icon patterns are project-relative in trolley.toml (same semantics as
    // resolve_windows_icon); cargo-packager globs them relative to the CWD,
    // so anchor them to the project dir first, escaping glob metacharacters
    // in the directory prefix.
    packager_config.icons = if config.app.icons.is_empty() {
        None
    } else {
        Some(
            config
                .app
                .icons
                .iter()
                .map(|pattern| anchored_glob_pattern(project_dir, pattern))
                .collect(),
        )
    };

    // Every backend ignores the fields that do not apply to it.
    packager_config.file_associations = packager_file_associations(config);

    if let BundleVariant::Linux { .. } = manifest.variant {
        let mut deb = cargo_packager::config::DebianConfig::default();
        deb.package_name = Some(config.app.slug.clone());
        packager_config.deb = Some(deb);
        // Linux only: on macOS this field is LSApplicationCategoryType, which
        // [linux] category has no business setting.
        packager_config.category = parse_linux_category(config)?;
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

/// Map a cargo-packager output format back to the trolley `Format` it was
/// registered for, to look up our composed artifact name.
fn trolley_format(format: &PackageFormat) -> Option<Format> {
    match format {
        PackageFormat::Deb => Some(Format::Deb),
        PackageFormat::AppImage => Some(Format::AppImage),
        PackageFormat::Pacman => Some(Format::Pacman),
        PackageFormat::Nsis => Some(Format::Nsis),
        PackageFormat::App => Some(Format::MacApp),
        PackageFormat::Dmg => Some(Format::Dmg),
        _ => None,
    }
}

/// Create a `Resource::Mapped` pointing from a bundle file to its target name.
fn resource_mapped(bundle_dir: &Path, src_name: &str, target_name: &str) -> Resource {
    Resource::Mapped {
        src: bundle_dir.join(src_name).display().to_string(),
        target: target_name.into(),
    }
}

/// Move a packager output from the staging dir into dist. The output dir is
/// wiped at the start of every run, so the destination never exists.
fn move_into_dist(src: &Path, dist_dir: &Path, name: &str) -> Result<()> {
    let dest = dist_dir.join(name);
    std::fs::rename(src, &dest)
        .with_context(|| format!("moving {} to {}", src.display(), dest.display()))
}

/// Package the bundle using cargo-packager for the given formats.
///
/// cargo-packager is pointed at a staging dir (a sibling of dist) because it
/// unconditionally drops its `.cargo-packager` intermediates dir into its
/// out_dir; finished artifacts are then moved into dist under their final
/// names, keeping dist free of build droppings.
pub fn run_packager(
    config: &Config,
    project_dir: &Path,
    bundle_dir: &Path,
    dist_dir: &Path,
    manifest: &BundleManifest,
    formats: &[PackagerFormat],
) -> Result<()> {
    let work_dir = dist_dir
        .parent()
        .context("dist dir has no parent")?
        .join("packager");
    std::fs::create_dir_all(&work_dir)
        .with_context(|| format!("creating packager staging dir {}", work_dir.display()))?;

    let packager_config =
        build_packager_config(config, project_dir, bundle_dir, &work_dir, manifest, formats)
            .context("building cargo-packager config")?;

    let outputs =
        cargo_packager::package(&packager_config).context("cargo-packager packaging failed")?;

    for output in &outputs {
        let naming = trolley_format(&output.format)
            .map(|f| f.for_target(manifest.target))
            .transpose()
            .context("cargo-packager emitted an output for a format invalid for this target")?
            .map(|p| p.artifact_name(&config.app));

        match naming {
            Some(ArtifactNaming::Composed(new_name)) => {
                let [path] = output.paths.as_slice() else {
                    anyhow::bail!(
                        "expected exactly one artifact for {:?}, got {}",
                        output.format,
                        output.paths.len()
                    );
                };
                move_into_dist(path, dist_dir, &new_name)?;
                println!("  {new_name}  ({:?} package)", output.format);
            }
            Some(ArtifactNaming::KeepProducerName) | None => {
                for path in &output.paths {
                    let filename = path
                        .file_name()
                        .with_context(|| format!("artifact {} has no filename", path.display()))?
                        .to_string_lossy()
                        .into_owned();
                    move_into_dist(path, dist_dir, &filename)?;
                    println!("  {filename}  ({:?} package)", output.format);
                }
                // Pacman writes a PKGBUILD next to its tarball but does not
                // report it as an output; its source=() references the tarball
                // by filename, so the pair must travel together.
                if matches!(output.format, PackageFormat::Pacman) {
                    move_into_dist(&work_dir.join("PKGBUILD"), dist_dir, "PKGBUILD")?;
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use trolley_config::{
        App, Arch, Embeds, Environment, FileAssociation, Fonts, Gui, Linux, Target, Windows,
    };

    fn test_config(associations: Vec<FileAssociation>, category: Option<&str>) -> Config {
        Config {
            app: App {
                identifier: "com.example.myapp".into(),
                display_name: "MyApp".into(),
                slug: "myapp".into(),
                version: "1.0.0".into(),
                icons: vec![],
                file_associations: associations,
            },
            linux: Some(Linux {
                binaries: BTreeMap::from([(Arch::X86_64, "my-app".into())]),
                args: Vec::new(),
                category: category.map(Into::into),
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

    fn association(extensions: &[&str], role: FileAssociationRole) -> FileAssociation {
        FileAssociation {
            extensions: extensions.iter().map(|e| (*e).into()).collect(),
            mime_type: "text/markdown".into(),
            description: Some("Markdown document".into()),
            role,
        }
    }

    // A bare `md` ProgID is a globally shared registry class, so the name must
    // always be slug-namespaced even though trolley has no `name` field.
    #[test]
    fn association_name_defaults_to_slug_dot_first_extension() {
        let config = test_config(
            vec![association(&["md", "markdown"], FileAssociationRole::Editor)],
            None,
        );
        let mapped = packager_file_associations(&config).unwrap();
        assert_eq!(mapped.len(), 1);
        assert_eq!(mapped[0].name.as_deref(), Some("myapp.md"));
        assert_eq!(mapped[0].extensions, vec!["md", "markdown"]);
        assert_eq!(mapped[0].mime_type.as_deref(), Some("text/markdown"));
        assert_eq!(mapped[0].description.as_deref(), Some("Markdown document"));
    }

    #[test]
    fn no_associations_maps_to_none() {
        assert!(packager_file_associations(&test_config(vec![], None)).is_none());
    }

    #[test]
    fn association_roles_map_onto_bundle_type_roles() {
        let config = test_config(
            vec![
                association(&["a"], FileAssociationRole::Editor),
                association(&["b"], FileAssociationRole::Viewer),
                association(&["c"], FileAssociationRole::Shell),
                association(&["d"], FileAssociationRole::QlGenerator),
                association(&["e"], FileAssociationRole::None),
            ],
            None,
        );
        let roles: Vec<BundleTypeRole> = packager_file_associations(&config)
            .unwrap()
            .iter()
            .map(|a| a.role.clone())
            .collect();
        assert_eq!(
            roles,
            vec![
                BundleTypeRole::Editor,
                BundleTypeRole::Viewer,
                BundleTypeRole::Shell,
                BundleTypeRole::QLGenerator,
                BundleTypeRole::None,
            ]
        );
    }

    #[test]
    fn category_is_fuzzy_matched() {
        let config = test_config(vec![], Some("developer-tool"));
        assert_eq!(
            parse_linux_category(&config).unwrap(),
            Some(AppCategory::DeveloperTool)
        );
        assert_eq!(
            parse_linux_category(&test_config(vec![], None)).unwrap(),
            None
        );
    }

    #[test]
    fn category_error_carries_the_suggestion() {
        let err = parse_linux_category(&test_config(vec![], Some("gaming")))
            .unwrap_err()
            .to_string();
        assert_eq!(
            err,
            "[linux] category: unknown category \"gaming\" (did you mean \"Game\"?)"
        );
    }

    #[test]
    fn category_error_without_suggestion_points_at_the_list() {
        let err = parse_linux_category(&test_config(vec![], Some("fhqwhgads")))
            .unwrap_err()
            .to_string();
        assert!(err.contains("unknown category \"fhqwhgads\""));
        assert!(err.contains("accepted list"));
    }

    // The same packager field is LSApplicationCategoryType on macOS, so it must
    // never leave the Linux branch.
    #[test]
    fn category_reaches_the_packager_config_for_linux_only() {
        let config = test_config(vec![], Some("Utility"));
        let built = |target| {
            let manifest = BundleManifest::new(&config, &target);
            build_packager_config(
                &config,
                Path::new("/project"),
                Path::new("/project/bundle"),
                Path::new("/project/out"),
                &manifest,
                &[],
            )
            .unwrap()
        };
        assert_eq!(
            built(Target::X86_64Linux).category,
            Some(AppCategory::Utility)
        );
        assert_eq!(built(Target::X86_64Macos).category, None);
        assert_eq!(built(Target::X86_64Windows).category, None);
    }

    #[test]
    fn category_is_ignored_without_a_linux_section() {
        let mut config = test_config(vec![], Some("gaming"));
        config.linux = None;
        config.windows = Some(Windows {
            binaries: BTreeMap::from([(Arch::X86_64, "my-app.exe".into())]),
            args: Vec::new(),
            precise_timer: None,
            signing: None,
        });
        assert_eq!(parse_linux_category(&config).unwrap(), None);
    }
}
