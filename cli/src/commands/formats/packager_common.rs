use std::collections::HashMap;
use std::path::Path;
use std::str::FromStr;

use anyhow::{Context, Result};
use cargo_packager::PackageFormat;
use cargo_packager::config::{
    AppCategory, Binary, BundleTypeRole, Config as PackagerConfig, FileAssociation, Resource,
};
use quick_xml::Writer;
use quick_xml::events::{BytesDecl, BytesText, Event};
use trolley_config::{
    ArtifactNaming, Config, FileAssociationRole, Format, LinuxFileAssociation, LinuxMimeInfo,
    Target,
};

use super::super::common::{BundleManifest, BundleVariant, anchored_glob_pattern};

/// Resolve `[linux] category` against cargo-packager's `AppCategory` names,
/// ignoring case, spaces and hyphens. A near miss is an error carrying the
/// closest accepted spelling as a suggestion.
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

/// Map the target platform's file associations onto cargo-packager's, or
/// `None` when it has none. Each backend reads only the fields set here.
///
/// The handler name is always `<slug>.<first extension>`: NSIS derives the
/// ProgID from it, and a bare extension would be a globally shared registry
/// class. The same string is macOS's `CFBundleTypeName`, where it is harmless;
/// `macos_info_plist` replaces it with the definition's `description` for
/// types it exports.
pub fn packager_file_associations(config: &Config, target: Target) -> Option<Vec<FileAssociation>> {
    let mapped: Vec<FileAssociation> = if target.is_linux() {
        config
            .linux_file_associations()
            .iter()
            .map(|a| {
                FileAssociation::new(a.extensions.iter().cloned()).mime_type(a.mime_type.clone())
            })
            .collect()
    } else if target.is_macos() {
        macos_packager_associations(config)
    } else {
        // NSIS splices the description into a quoted string unescaped.
        config
            .windows_file_associations()
            .iter()
            .map(|a| {
                named_association(config, &a.extensions).description(nsis_escape(&a.description))
            })
            .collect()
    };
    (!mapped.is_empty()).then_some(mapped)
}

fn macos_packager_associations(config: &Config) -> Vec<FileAssociation> {
    config
        .macos_file_associations()
        .iter()
        .map(|a| named_association(config, &a.extensions).role(bundle_type_role(a.role)))
        .collect()
}

fn named_association(config: &Config, extensions: &[String]) -> FileAssociation {
    let mapped = FileAssociation::new(extensions.iter().cloned());
    match extensions.first() {
        Some(first) => mapped.name(format!("{}.{first}", config.app.slug)),
        None => mapped,
    }
}

/// Render the `shared-mime-info` XML defining every `[linux]` type that has
/// `mime_info`, or `None` when none has.
///
/// Installed to `/usr/share/mime/packages/<slug>.xml`, where the distro's own
/// file trigger recompiles the mime database — the same mechanism the `.desktop`
/// entry relies on, so no post-install script.
pub fn mime_info_xml(config: &Config) -> Option<String> {
    let defined: Vec<(&LinuxFileAssociation, &LinuxMimeInfo)> = config
        .linux_file_associations()
        .iter()
        .filter_map(|a| Some((a, a.mime_info.as_ref()?)))
        .collect();
    if defined.is_empty() {
        return None;
    }

    let mut writer = Writer::new_with_indent(Vec::new(), b' ', 2);
    // Writing to a Vec cannot fail.
    write_mime_info(&mut writer, &defined).expect("writing XML to memory");
    let mut xml = String::from_utf8(writer.into_inner()).expect("XML from str input is UTF-8");
    xml.push('\n');
    Some(xml)
}

fn write_mime_info(
    writer: &mut Writer<Vec<u8>>,
    defined: &[(&LinuxFileAssociation, &LinuxMimeInfo)],
) -> std::io::Result<()> {
    writer.write_event(Event::Decl(BytesDecl::new("1.0", Some("UTF-8"), None)))?;
    writer
        .create_element("mime-info")
        .with_attribute((
            "xmlns",
            "http://www.freedesktop.org/standards/shared-mime-info",
        ))
        .write_inner_content(|writer| {
            for (association, mime_info) in defined {
                writer
                    .create_element("mime-type")
                    .with_attribute(("type", association.mime_type.as_str()))
                    .write_inner_content(|writer| {
                        write_mime_type(writer, association, mime_info)
                    })?;
            }
            Ok(())
        })?;
    Ok(())
}

fn write_mime_type(
    writer: &mut Writer<Vec<u8>>,
    association: &LinuxFileAssociation,
    mime_info: &LinuxMimeInfo,
) -> std::io::Result<()> {
    writer
        .create_element("comment")
        .write_text_content(BytesText::new(&mime_info.comment))?;
    for parent in &mime_info.sub_class_of {
        writer
            .create_element("sub-class-of")
            .with_attribute(("type", parent.as_str()))
            .write_empty()?;
    }
    for extension in &association.extensions {
        let pattern = format!("*.{extension}");
        writer
            .create_element("glob")
            .with_attribute(("pattern", pattern.as_str()))
            .write_empty()?;
    }
    Ok(())
}

/// Build the Info.plist overlay listing every `[macos]` association, or `None`
/// when there are none.
///
/// cargo-packager inserts the overlay's top-level keys over its own, replacing
/// rather than merging, so `CFBundleDocumentTypes` lists every association:
/// the defined ones by type identifier, the rest as cargo-packager would have
/// written them. Every entry also has macOS draw the document icon from the
/// app icon, which cargo-packager has no field for.
pub fn macos_info_plist(config: &Config) -> Option<plist::Value> {
    let associations = config.macos_file_associations();
    if associations.is_empty() {
        return None;
    }
    let mapped = macos_packager_associations(config);
    let strings =
        |values: &[String]| plist::Value::Array(values.iter().map(|v| v.clone().into()).collect());

    let mut exported = Vec::new();
    let mut document_types = Vec::new();
    for (association, mapped) in associations.iter().zip(&mapped) {
        let mut document = plist::Dictionary::new();
        match &association.exported_type {
            Some(exported_type) => {
                let conforms_to = if exported_type.conforms_to.is_empty() {
                    vec!["public.data".to_string()]
                } else {
                    exported_type.conforms_to.clone()
                };
                let mut tags = plist::Dictionary::new();
                tags.insert(
                    "public.filename-extension".into(),
                    strings(&association.extensions),
                );
                if let Some(mime) = &exported_type.mime_type {
                    tags.insert(
                        "public.mime-type".into(),
                        strings(std::slice::from_ref(mime)),
                    );
                }
                let mut declaration = plist::Dictionary::new();
                declaration.insert(
                    "UTTypeIdentifier".into(),
                    exported_type.identifier.clone().into(),
                );
                declaration.insert(
                    "UTTypeDescription".into(),
                    exported_type.description.clone().into(),
                );
                declaration.insert("UTTypeConformsTo".into(), strings(&conforms_to));
                declaration.insert("UTTypeTagSpecification".into(), tags.into());
                exported.push(declaration.into());

                document.insert(
                    "LSItemContentTypes".into(),
                    strings(std::slice::from_ref(&exported_type.identifier)),
                );
                document.insert(
                    "CFBundleTypeName".into(),
                    exported_type.description.clone().into(),
                );
                document.insert("CFBundleTypeRole".into(), mapped.role.to_string().into());
                document.insert("LSHandlerRank".into(), "Owner".into());
            }
            // Mirrors cargo-packager's own entry (package/app/mod.rs).
            None => {
                document.insert("CFBundleTypeExtensions".into(), strings(&mapped.extensions));
                document.insert(
                    "CFBundleTypeName".into(),
                    mapped
                        .name
                        .clone()
                        .unwrap_or_else(|| mapped.extensions[0].clone())
                        .into(),
                );
                document.insert("CFBundleTypeRole".into(), mapped.role.to_string().into());
            }
        }
        document.insert("CFBundleTypeIconSystemGenerated".into(), 1.into());
        document_types.push(document.into());
    }

    let mut root = plist::Dictionary::new();
    if !exported.is_empty() {
        root.insert(
            "UTExportedTypeDeclarations".into(),
            plist::Value::Array(exported),
        );
    }
    root.insert(
        "CFBundleDocumentTypes".into(),
        plist::Value::Array(document_types),
    );
    Some(root.into())
}

/// Escape a value for an NSIS string literal, as cargo-packager's own escape
/// function does for the template values it does escape.
fn nsis_escape(value: &str) -> String {
    let mut escaped = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '"' => escaped.push_str("$\\\""),
            '`' => escaped.push_str("$\\`"),
            '$' => escaped.push_str("$$"),
            _ => escaped.push(c),
        }
    }
    escaped
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

    packager_config.file_associations = packager_file_associations(config, manifest.target);

    if let BundleVariant::Linux { .. } = manifest.variant {
        // `files` copies from a real path, so the XML is written into the
        // packager staging dir first. AppImage carries it too: running
        // one installs nothing, but integration tools may install its files.
        let mime_files = match mime_info_xml(config) {
            Some(xml) => {
                let src = out_dir.join(format!("{}.xml", config.app.slug));
                std::fs::write(&src, xml).with_context(|| format!("writing {}", src.display()))?;
                Some(HashMap::from([(
                    src.display().to_string(),
                    format!("/usr/share/mime/packages/{}.xml", config.app.slug),
                )]))
            }
            None => None,
        };

        let mut deb = cargo_packager::config::DebianConfig::default();
        deb.package_name = Some(config.app.slug.clone());
        deb.files = mime_files.clone();
        packager_config.deb = Some(deb);

        if mime_files.is_some() {
            let mut pacman = cargo_packager::config::PacmanConfig::default();
            pacman.files = mime_files.clone();
            packager_config.pacman = Some(pacman);

            let mut appimage = cargo_packager::config::AppImageConfig::default();
            appimage.files = mime_files;
            packager_config.appimage = Some(appimage);
        }

        // Linux only: on macOS this field is LSApplicationCategoryType, which
        // [linux] category has no business setting.
        packager_config.category = parse_linux_category(config)?;
    }

    // Code-signing: only the matching platform's config is applied. The signing structs hold
    // non-secret selectors; cargo-packager reads cert material / notarization / Azure creds
    // from the environment itself.
    match manifest.variant {
        BundleVariant::MacOs => {
            let mut macos: Option<cargo_packager::config::MacOsConfig> = None;
            if let Some(plist) = macos_info_plist(config) {
                // cargo-packager reads the overlay from a real path.
                let src = out_dir.join(format!("{}-Info.plist", config.app.slug));
                plist
                    .to_file_xml(&src)
                    .with_context(|| format!("writing {}", src.display()))?;
                macos.get_or_insert_default().info_plist_path = Some(src);
            }
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
                let macos = macos.get_or_insert_default();
                macos.signing_identity = Some(identity);
                macos.entitlements = signing.entitlements.clone();
                // notarization_credentials + cert material left unset on purpose:
                // cargo-packager reads APPLE_* / APPLE_CERTIFICATE* from the environment.
            }
            packager_config.macos = macos;
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

    let packager_config = build_packager_config(
        config,
        project_dir,
        bundle_dir,
        &work_dir,
        manifest,
        formats,
    )
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
        App, Arch, Embeds, Environment, Fonts, Gui, Linux, Macos, MacosExportedType,
        MacosFileAssociation, MacosSigning, Windows, WindowsFileAssociation,
    };

    fn test_config(category: Option<&str>) -> Config {
        Config {
            app: App {
                identifier: "com.example.myapp".into(),
                display_name: "MyApp".into(),
                slug: "myapp".into(),
                version: "1.0.0".into(),
                icons: vec![],
            },
            linux: Some(Linux {
                binaries: BTreeMap::from([(Arch::X86_64, "my-app".into())]),
                args: Vec::new(),
                category: category.map(Into::into),
                file_associations: Vec::new(),
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

    fn macos_section(file_associations: Vec<MacosFileAssociation>) -> Macos {
        Macos {
            binaries: BTreeMap::from([(Arch::X86_64, "my-app".into())]),
            args: Vec::new(),
            signing: None,
            file_associations,
        }
    }

    fn windows_section(file_associations: Vec<WindowsFileAssociation>) -> Windows {
        Windows {
            binaries: BTreeMap::from([(Arch::X86_64, "my-app.exe".into())]),
            args: Vec::new(),
            precise_timer: None,
            signing: None,
            file_associations,
        }
    }

    fn with_linux(associations: Vec<LinuxFileAssociation>) -> Config {
        let mut config = test_config(None);
        config.linux.as_mut().unwrap().file_associations = associations;
        config
    }

    fn with_macos(associations: Vec<MacosFileAssociation>) -> Config {
        let mut config = test_config(None);
        config.macos = Some(macos_section(associations));
        config
    }

    fn with_windows(associations: Vec<WindowsFileAssociation>) -> Config {
        let mut config = test_config(None);
        config.windows = Some(windows_section(associations));
        config
    }

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| (*v).into()).collect()
    }

    fn linux_association(extensions: &[&str], mime_type: &str) -> LinuxFileAssociation {
        LinuxFileAssociation {
            extensions: strings(extensions),
            mime_type: mime_type.into(),
            unique: false,
            mime_info: None,
        }
    }

    fn macos_association(extensions: &[&str], role: FileAssociationRole) -> MacosFileAssociation {
        MacosFileAssociation {
            extensions: strings(extensions),
            role,
            unique: false,
            exported_type: None,
        }
    }

    fn windows_association(extensions: &[&str], description: &str) -> WindowsFileAssociation {
        WindowsFileAssociation {
            extensions: strings(extensions),
            description: description.into(),
            unique: false,
        }
    }

    // A bare `md` ProgID is a globally shared registry class, so the name must
    // always be slug-namespaced even though trolley has no `name` field.
    #[test]
    fn association_name_defaults_to_slug_dot_first_extension() {
        let mut config = with_windows(vec![windows_association(
            &["md", "markdown"],
            "Markdown document",
        )]);
        config.macos = Some(macos_section(vec![macos_association(
            &["md", "markdown"],
            FileAssociationRole::Editor,
        )]));
        for target in [Target::X86_64Windows, Target::X86_64Macos] {
            let mapped = packager_file_associations(&config, target).unwrap();
            assert_eq!(mapped.len(), 1);
            assert_eq!(mapped[0].name.as_deref(), Some("myapp.md"), "{target}");
            assert_eq!(mapped[0].extensions, vec!["md", "markdown"]);
        }
    }

    // Each backend reads only its own platform's list, and only the fields
    // that platform has.
    #[test]
    fn each_platform_maps_only_its_own_list() {
        let mut config = with_linux(vec![
            linux_association(&["md"], "text/markdown"),
            linux_association(&["csv"], "text/csv"),
        ]);
        config.macos = Some(macos_section(vec![macos_association(
            &["mac"],
            FileAssociationRole::Viewer,
        )]));
        config.windows = Some(windows_section(vec![windows_association(
            &["win"],
            "Windows document",
        )]));
        config.validate().unwrap();

        let linux = packager_file_associations(&config, Target::X86_64Linux).unwrap();
        assert_eq!(
            linux
                .iter()
                .map(|a| (a.extensions.clone(), a.mime_type.as_deref()))
                .collect::<Vec<_>>(),
            [
                (strings(&["md"]), Some("text/markdown")),
                (strings(&["csv"]), Some("text/csv")),
            ]
        );
        assert!(
            linux
                .iter()
                .all(|a| a.name.is_none() && a.description.is_none())
        );

        let macos = packager_file_associations(&config, Target::Aarch64Macos).unwrap();
        assert_eq!(macos.len(), 1);
        assert_eq!(macos[0].extensions, ["mac"]);
        assert_eq!(macos[0].role, BundleTypeRole::Viewer);
        assert_eq!(macos[0].mime_type, None);
        assert_eq!(macos[0].description, None);

        let windows = packager_file_associations(&config, Target::X86_64Windows).unwrap();
        assert_eq!(windows.len(), 1);
        assert_eq!(windows[0].extensions, ["win"]);
        assert_eq!(windows[0].description.as_deref(), Some("Windows document"));
        assert_eq!(windows[0].mime_type, None);
    }

    #[test]
    fn no_associations_maps_to_none() {
        // Another platform's list does not leak in.
        let config = with_linux(vec![linux_association(&["md"], "text/markdown")]);
        for target in [Target::X86_64Macos, Target::X86_64Windows] {
            assert!(packager_file_associations(&config, target).is_none());
        }
        assert!(packager_file_associations(&test_config(None), Target::X86_64Linux).is_none());
    }

    #[test]
    fn association_roles_map_onto_bundle_type_roles() {
        let config = with_macos(vec![
            macos_association(&["a"], FileAssociationRole::Editor),
            macos_association(&["b"], FileAssociationRole::Viewer),
            macos_association(&["c"], FileAssociationRole::Shell),
            macos_association(&["d"], FileAssociationRole::QlGenerator),
            macos_association(&["e"], FileAssociationRole::None),
        ]);
        config.validate().unwrap();
        let roles: Vec<BundleTypeRole> = packager_file_associations(&config, Target::X86_64Macos)
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

    /// `sub_class_of` of `None` leaves `mime_info` out.
    fn defining(
        extensions: &[&str],
        mime_type: &str,
        comment: &str,
        sub_class_of: Option<&[&str]>,
    ) -> LinuxFileAssociation {
        let mut a = linux_association(extensions, mime_type);
        a.mime_info = sub_class_of.map(|sub_class_of| LinuxMimeInfo {
            comment: comment.into(),
            sub_class_of: strings(sub_class_of),
        });
        a
    }

    // Validated first, so every input is one a manifest can carry.
    fn validated_mime_xml(associations: Vec<LinuxFileAssociation>) -> Option<String> {
        let config = with_linux(associations);
        config.validate().unwrap();
        mime_info_xml(&config)
    }

    #[test]
    fn mime_xml_defines_a_type_without_sub_class_of() {
        let xml = validated_mime_xml(vec![defining(
            &["snty"],
            "application/x-sanity",
            "Sanity document",
            Some(&[]),
        )]);
        assert_eq!(
            xml.as_deref(),
            Some(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-sanity">
    <comment>Sanity document</comment>
    <glob pattern="*.snty"/>
  </mime-type>
</mime-info>
"#
            )
        );
    }

    #[test]
    fn mime_xml_subclasses_one_parent() {
        let xml = validated_mime_xml(vec![defining(
            &["snty"],
            "text/x-sanity",
            "Sanity document",
            Some(&["text/plain"]),
        )]);
        assert_eq!(
            xml.as_deref(),
            Some(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="text/x-sanity">
    <comment>Sanity document</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="*.snty"/>
  </mime-type>
</mime-info>
"#
            )
        );
    }

    #[test]
    fn mime_xml_globs_every_extension_in_order() {
        let xml = validated_mime_xml(vec![defining(
            &["md", "markdown", "mdown"],
            "text/markdown",
            "Markdown document",
            Some(&["text/plain"]),
        )]);
        assert_eq!(
            xml.as_deref(),
            Some(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="text/markdown">
    <comment>Markdown document</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="*.md"/>
    <glob pattern="*.markdown"/>
    <glob pattern="*.mdown"/>
  </mime-type>
</mime-info>
"#
            )
        );
    }

    // Types with `mime_info` are listed against alphabetical order, so the
    // output can only match by keeping manifest order.
    #[test]
    fn mime_xml_defines_only_types_with_mime_info_in_order() {
        let xml = validated_mime_xml(vec![
            defining(&["unset"], "application/x-unset", "Unset document", None),
            defining(
                &["zeta"],
                "text/x-zeta",
                "Zeta document",
                Some(&["text/plain"]),
            ),
            defining(&["off"], "application/x-off", "Off document", None),
            defining(
                &["alpha"],
                "application/x-alpha",
                "Alpha document",
                Some(&[]),
            ),
        ]);
        assert_eq!(
            xml.as_deref(),
            Some(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="text/x-zeta">
    <comment>Zeta document</comment>
    <sub-class-of type="text/plain"/>
    <glob pattern="*.zeta"/>
  </mime-type>
  <mime-type type="application/x-alpha">
    <comment>Alpha document</comment>
    <glob pattern="*.alpha"/>
  </mime-type>
</mime-info>
"#
            )
        );
    }

    #[test]
    fn mime_xml_subclasses_every_parent_in_order() {
        let xml = validated_mime_xml(vec![defining(
            &["snty"],
            "text/x-sanity",
            "Sanity document",
            Some(&["text/plain", "application/x-foo"]),
        )]);
        assert_eq!(
            xml.as_deref(),
            Some(
                r#"<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="text/x-sanity">
    <comment>Sanity document</comment>
    <sub-class-of type="text/plain"/>
    <sub-class-of type="application/x-foo"/>
    <glob pattern="*.snty"/>
  </mime-type>
</mime-info>
"#
            )
        );
    }

    // Text and attribute values read back from the XML, in document order.
    fn xml_values(xml: &str) -> Vec<String> {
        use quick_xml::escape::resolve_predefined_entity;
        let mut reader = quick_xml::Reader::from_str(xml);
        let mut values = Vec::new();
        let mut text: Option<String> = None;
        loop {
            match reader.read_event().unwrap() {
                Event::Start(e) | Event::Empty(e) => {
                    for attr in e.attributes() {
                        values.push(attr.unwrap().unescape_value().unwrap().into_owned());
                    }
                    text = Some(String::new());
                }
                Event::Text(e) => {
                    if let Some(t) = text.as_mut() {
                        t.push_str(&e.decode().unwrap());
                    }
                }
                Event::GeneralRef(e) => {
                    let name = e.decode().unwrap();
                    text.as_mut()
                        .unwrap()
                        .push_str(resolve_predefined_entity(&name).unwrap());
                }
                Event::End(_) => {
                    if let Some(t) = text.take().filter(|t| !t.trim().is_empty()) {
                        values.push(t);
                    }
                }
                Event::Eof => break,
                _ => {}
            }
        }
        values
    }

    #[test]
    fn mime_xml_escapes_text_and_attributes() {
        let description = r#"Notes & "Tasks" <C++> 'n' stuff"#;
        let xml = validated_mime_xml(vec![defining(
            &["snty"],
            "application/x-a&b",
            description,
            Some(&["text/x-c&d"]),
        )])
        .unwrap();
        assert_eq!(
            xml,
            r#"<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-a&amp;b">
    <comment>Notes &amp; &quot;Tasks&quot; &lt;C++&gt; &apos;n&apos; stuff</comment>
    <sub-class-of type="text/x-c&amp;d"/>
    <glob pattern="*.snty"/>
  </mime-type>
</mime-info>
"#
        );
        assert_eq!(
            xml_values(&xml),
            [
                "http://www.freedesktop.org/standards/shared-mime-info",
                "application/x-a&b",
                description,
                "text/x-c&d",
                "*.snty",
            ]
        );
    }

    // -- macOS Info.plist overlay --

    fn exporting(
        extensions: &[&str],
        description: &str,
        role: FileAssociationRole,
        exported_type: Option<(&str, &[&str])>,
    ) -> MacosFileAssociation {
        let mut a = macos_association(extensions, role);
        a.exported_type = exported_type.map(|(identifier, conforms_to)| MacosExportedType {
            identifier: identifier.into(),
            description: description.into(),
            conforms_to: strings(conforms_to),
            mime_type: None,
        });
        a
    }

    fn with_mime(mut a: MacosFileAssociation, mime_type: &str) -> MacosFileAssociation {
        a.exported_type.as_mut().unwrap().mime_type = Some(mime_type.into());
        a
    }

    fn validated_plist(associations: Vec<MacosFileAssociation>) -> Option<plist::Value> {
        let config = with_macos(associations);
        config.validate().unwrap();
        macos_info_plist(&config)
    }

    // Round-trips through XML, the form cargo-packager reads back.
    fn reparsed(value: &plist::Value) -> plist::Value {
        let mut xml = Vec::new();
        value.to_writer_xml(&mut xml).unwrap();
        plist::Value::from_reader(std::io::Cursor::new(xml)).unwrap()
    }

    fn strs(values: &[&str]) -> plist::Value {
        plist::Value::Array(values.iter().map(|v| (*v).into()).collect())
    }

    fn dict(entries: Vec<(&str, plist::Value)>) -> plist::Value {
        plist::Value::Dictionary(
            entries
                .into_iter()
                .map(|(k, v)| (String::from(k), v))
                .collect(),
        )
    }

    fn keys(value: &plist::Value) -> Vec<&str> {
        value
            .as_dictionary()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect()
    }

    #[test]
    fn macos_plist_absent_without_associations() {
        assert_eq!(validated_plist(vec![]), None);
        // Another platform's list does not reach the overlay.
        let config = with_linux(vec![defining(
            &["l"],
            "application/x-l",
            "L document",
            Some(&[]),
        )]);
        assert_eq!(macos_info_plist(&config), None);
    }

    #[test]
    fn macos_plist_exports_nothing_without_an_exported_type() {
        let plist = validated_plist(vec![
            exporting(&["a"], "A document", FileAssociationRole::Editor, None),
            exporting(&["b"], "B document", FileAssociationRole::Editor, None),
        ])
        .unwrap();
        assert_eq!(keys(&plist), ["CFBundleDocumentTypes"]);
        assert_eq!(
            plist.as_dictionary().unwrap()["CFBundleDocumentTypes"]
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }

    // Defined and undefined associations interleave, listed against
    // alphabetical order, so only keeping manifest order matches.
    #[test]
    fn macos_plist_exports_defined_types_and_lists_every_association() {
        let plist = validated_plist(vec![
            exporting(
                &["md", "markdown"],
                "Markdown document",
                FileAssociationRole::Viewer,
                None,
            ),
            with_mime(
                exporting(
                    &["snty", "sanity"],
                    "Sanity document",
                    FileAssociationRole::Editor,
                    Some((
                        "com.example.myapp.snty",
                        &["public.plain-text", "public.utf8-plain-text"],
                    )),
                ),
                "text/x-sanity",
            ),
            exporting(
                &["off"],
                "Off document",
                FileAssociationRole::QlGenerator,
                None,
            ),
            exporting(
                &["bin"],
                "MyApp binary",
                FileAssociationRole::Shell,
                Some(("com.example.myapp.bin", &[])),
            ),
        ])
        .unwrap();
        let parsed = reparsed(&plist);
        assert_eq!(parsed, plist);
        assert_eq!(
            keys(&parsed),
            ["UTExportedTypeDeclarations", "CFBundleDocumentTypes"]
        );
        assert_eq!(
            parsed,
            dict(vec![
                (
                    "UTExportedTypeDeclarations",
                    plist::Value::Array(vec![
                        dict(vec![
                            ("UTTypeIdentifier", "com.example.myapp.snty".into()),
                            ("UTTypeDescription", "Sanity document".into()),
                            (
                                "UTTypeConformsTo",
                                strs(&["public.plain-text", "public.utf8-plain-text"]),
                            ),
                            (
                                "UTTypeTagSpecification",
                                dict(vec![
                                    ("public.filename-extension", strs(&["snty", "sanity"])),
                                    ("public.mime-type", strs(&["text/x-sanity"])),
                                ]),
                            ),
                        ]),
                        dict(vec![
                            ("UTTypeIdentifier", "com.example.myapp.bin".into()),
                            ("UTTypeDescription", "MyApp binary".into()),
                            ("UTTypeConformsTo", strs(&["public.data"])),
                            (
                                "UTTypeTagSpecification",
                                dict(vec![("public.filename-extension", strs(&["bin"]))]),
                            ),
                        ]),
                    ]),
                ),
                (
                    "CFBundleDocumentTypes",
                    plist::Value::Array(vec![
                        dict(vec![
                            ("CFBundleTypeExtensions", strs(&["md", "markdown"])),
                            ("CFBundleTypeName", "myapp.md".into()),
                            ("CFBundleTypeRole", "Viewer".into()),
                            ("CFBundleTypeIconSystemGenerated", 1.into()),
                        ]),
                        dict(vec![
                            ("LSItemContentTypes", strs(&["com.example.myapp.snty"])),
                            ("CFBundleTypeName", "Sanity document".into()),
                            ("CFBundleTypeRole", "Editor".into()),
                            ("LSHandlerRank", "Owner".into()),
                            ("CFBundleTypeIconSystemGenerated", 1.into()),
                        ]),
                        dict(vec![
                            ("CFBundleTypeExtensions", strs(&["off"])),
                            ("CFBundleTypeName", "myapp.off".into()),
                            ("CFBundleTypeRole", "QLGenerator".into()),
                            ("CFBundleTypeIconSystemGenerated", 1.into()),
                        ]),
                        dict(vec![
                            ("LSItemContentTypes", strs(&["com.example.myapp.bin"])),
                            ("CFBundleTypeName", "MyApp binary".into()),
                            ("CFBundleTypeRole", "Shell".into()),
                            ("LSHandlerRank", "Owner".into()),
                            ("CFBundleTypeIconSystemGenerated", 1.into()),
                        ]),
                    ]),
                ),
            ])
        );
    }

    // The overlay replaces cargo-packager's whole CFBundleDocumentTypes, so an
    // association without a definition must keep the entry cargo-packager
    // writes: extensions, `name` (falling back to the first extension) and the
    // role's Display form, plus only the icon key.
    #[test]
    fn macos_plist_keeps_cargo_packagers_shape_for_undefined_associations() {
        let config = with_macos(vec![
            exporting(
                &["md", "markdown"],
                "Markdown document",
                FileAssociationRole::None,
                None,
            ),
            exporting(
                &["snty"],
                "Sanity document",
                FileAssociationRole::Editor,
                Some(("com.example.myapp.snty", &[])),
            ),
        ]);
        config.validate().unwrap();
        let mapped = packager_file_associations(&config, Target::Aarch64Macos).unwrap();
        let parsed = reparsed(&macos_info_plist(&config).unwrap());
        let entry = &parsed.as_dictionary().unwrap()["CFBundleDocumentTypes"]
            .as_array()
            .unwrap()[0];
        assert_eq!(
            keys(entry),
            [
                "CFBundleTypeExtensions",
                "CFBundleTypeName",
                "CFBundleTypeRole",
                "CFBundleTypeIconSystemGenerated"
            ]
        );
        assert_eq!(
            entry,
            &dict(vec![
                ("CFBundleTypeExtensions", strs(&["md", "markdown"])),
                (
                    "CFBundleTypeName",
                    mapped[0]
                        .name
                        .clone()
                        .unwrap_or(mapped[0].extensions[0].clone())
                        .into()
                ),
                ("CFBundleTypeRole", mapped[0].role.to_string().into()),
                ("CFBundleTypeIconSystemGenerated", 1.into()),
            ])
        );
        assert_eq!(mapped[0].role.to_string(), "None");
    }

    #[test]
    fn macos_plist_xml() {
        let plist = validated_plist(vec![
            exporting(
                &["md"],
                "Markdown document",
                FileAssociationRole::Editor,
                None,
            ),
            with_mime(
                exporting(
                    &["snty"],
                    "Sanity document",
                    FileAssociationRole::Editor,
                    Some(("com.example.myapp.snty", &["public.plain-text"])),
                ),
                "application/x-sanity",
            ),
        ])
        .unwrap();
        let mut xml = Vec::new();
        plist.to_writer_xml(&mut xml).unwrap();
        // Tabs shown as four spaces to keep the expectation readable.
        assert_eq!(
            String::from_utf8(xml).unwrap().replace('\t', "    "),
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key>
            <string>com.example.myapp.snty</string>
            <key>UTTypeDescription</key>
            <string>Sanity document</string>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.plain-text</string>
            </array>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>snty</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/x-sanity</string>
                </array>
            </dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeExtensions</key>
            <array>
                <string>md</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>myapp.md</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleTypeIconSystemGenerated</key>
            <integer>1</integer>
        </dict>
        <dict>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.example.myapp.snty</string>
            </array>
            <key>CFBundleTypeName</key>
            <string>Sanity document</string>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>LSHandlerRank</key>
            <string>Owner</string>
            <key>CFBundleTypeIconSystemGenerated</key>
            <integer>1</integer>
        </dict>
    </array>
</dict>
</plist>"#
        );
    }

    fn built_for(config: &Config, target: Target, out_dir: &Path) -> PackagerConfig {
        let manifest = BundleManifest::new(config, &target);
        build_packager_config(
            config,
            Path::new("/project"),
            Path::new("/project/bundle"),
            out_dir,
            &manifest,
            &[],
        )
        .unwrap()
    }

    fn defined_config() -> Config {
        with_macos(vec![exporting(
            &["snty"],
            "Sanity document",
            FileAssociationRole::Editor,
            Some(("com.example.myapp.snty", &["public.plain-text"])),
        )])
    }

    #[test]
    fn info_plist_path_is_set_for_macos_only() {
        let config = defined_config();
        config.validate().unwrap();
        let out = tempfile::tempdir().unwrap();

        let macos = built_for(&config, Target::X86_64Macos, out.path()).macos;
        let path = macos.and_then(|m| m.info_plist_path).unwrap();
        assert_eq!(path, out.path().join("myapp-Info.plist"));
        assert_eq!(
            plist::Value::from_file(&path).unwrap(),
            macos_info_plist(&config).unwrap()
        );

        std::fs::remove_file(&path).unwrap();
        for target in [Target::X86_64Linux, Target::X86_64Windows] {
            assert!(built_for(&config, target, out.path()).macos.is_none());
        }
        assert!(!path.exists());
    }

    #[test]
    fn macos_plist_round_trips_free_text_description() {
        let plist = validated_plist(vec![exporting(
            &["snty"],
            r#"Notes & "Tasks" <C++> $HOME"#,
            FileAssociationRole::Editor,
            Some(("com.example.myapp.snty", &[])),
        )])
        .unwrap();
        let mut xml = Vec::new();
        plist.to_writer_xml(&mut xml).unwrap();
        let xml = String::from_utf8(xml).unwrap();
        assert!(
            xml.contains("<string>Notes &amp; &quot;Tasks&quot; &lt;C++&gt; $HOME</string>"),
            "{xml}"
        );
        assert_eq!(reparsed(&plist), plist);
    }

    // Each target's packager config carries only its own platform's list.
    #[test]
    fn packager_config_takes_the_targets_list() {
        let description = r#"Notes & "Tasks" $INSTDIR `x` <C++>"#;
        let mut config = with_linux(vec![linux_association(&["md"], "text/markdown")]);
        config.macos = Some(macos_section(vec![macos_association(
            &["mac"],
            FileAssociationRole::Editor,
        )]));
        config.windows = Some(windows_section(vec![windows_association(
            &["win"],
            description,
        )]));
        config.validate().unwrap();
        let out = tempfile::tempdir().unwrap();
        let built = |target| {
            built_for(&config, target, out.path())
                .file_associations
                .unwrap()
                .remove(0)
        };

        let windows = built(Target::X86_64Windows);
        assert_eq!(windows.extensions, ["win"]);
        assert_eq!(
            windows.description.as_deref(),
            Some(r#"Notes & $\"Tasks$\" $$INSTDIR $\`x$\` <C++>"#)
        );
        let linux = built(Target::X86_64Linux);
        assert_eq!(linux.extensions, ["md"]);
        assert_eq!(linux.mime_type.as_deref(), Some("text/markdown"));
        assert_eq!(built(Target::X86_64Macos).extensions, ["mac"]);
    }

    #[test]
    fn info_plist_path_unset_without_associations() {
        let config = with_macos(vec![]);
        let out = tempfile::tempdir().unwrap();
        assert!(
            built_for(&config, Target::X86_64Macos, out.path())
                .macos
                .is_none()
        );
        assert_eq!(std::fs::read_dir(out.path()).unwrap().count(), 0);
    }

    #[test]
    fn info_plist_path_and_signing_coexist() {
        let mut config = defined_config();
        config.macos.as_mut().unwrap().signing = Some(MacosSigning {
            identity: Some("Developer ID Application: Example (TEAMID)".into()),
            entitlements: Some("entitlements.plist".into()),
        });
        let out = tempfile::tempdir().unwrap();
        let macos = built_for(&config, Target::X86_64Macos, out.path())
            .macos
            .unwrap();
        assert_eq!(
            macos.info_plist_path,
            Some(out.path().join("myapp-Info.plist"))
        );
        assert_eq!(
            macos.signing_identity.as_deref(),
            Some("Developer ID Application: Example (TEAMID)")
        );
        assert_eq!(macos.entitlements.as_deref(), Some("entitlements.plist"));
    }

    #[test]
    fn category_ignores_case_spaces_and_hyphens() {
        let config = test_config(Some("developer-tool"));
        assert_eq!(
            parse_linux_category(&config).unwrap(),
            Some(AppCategory::DeveloperTool)
        );
        assert_eq!(parse_linux_category(&test_config(None)).unwrap(), None);
    }

    #[test]
    fn category_error_carries_the_suggestion() {
        let err = parse_linux_category(&test_config(Some("gaming")))
            .unwrap_err()
            .to_string();
        assert_eq!(
            err,
            "[linux] category: unknown category \"gaming\" (did you mean \"Game\"?)"
        );
    }

    #[test]
    fn category_error_without_suggestion_points_at_the_list() {
        let err = parse_linux_category(&test_config(Some("fhqwhgads")))
            .unwrap_err()
            .to_string();
        assert!(err.contains("unknown category \"fhqwhgads\""));
        assert!(err.contains("accepted list"));
    }

    // The same packager field is LSApplicationCategoryType on macOS, so it must
    // never leave the Linux branch.
    #[test]
    fn category_reaches_the_packager_config_for_linux_only() {
        let config = test_config(Some("Utility"));
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
        let mut config = test_config(Some("gaming"));
        config.linux = None;
        config.windows = Some(windows_section(vec![]));
        assert_eq!(parse_linux_category(&config).unwrap(), None);
    }
}
