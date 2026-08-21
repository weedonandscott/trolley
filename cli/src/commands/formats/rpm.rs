use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use cargo_packager::config::AppCategory;
use rpm::{FileMode, FileOptions};
use trolley_config::{ArtifactNaming, Config, PlannedFormat, rpm_arch, rpm_version};
use walkdir::WalkDir;

use super::super::common::{BundleManifest, BundleVariant, anchored_glob_pattern};
use super::packager_common::parse_linux_category;

/// Render the `.desktop` entry for the RPM.
///
/// cargo-packager writes one for deb and pacman but trolley's hand-rolled RPM
/// builder has to do it itself; the field order and values match the upstream
/// deb template so the two packages register identically.
fn desktop_entry(config: &Config, category: Option<AppCategory>) -> String {
    let slug = &config.app.slug;
    let display_name = &config.app.display_name;
    let categories = category.map(|c| c.gnome_desktop_categories()).unwrap_or("");
    // Both keys turn on together: `%F` is only meaningful once the entry
    // advertises the types it can be handed.
    let has_associations = !config.app.file_associations.is_empty();
    let exec_arg = if has_associations { "%F" } else { "" };
    let mime_types: Vec<&str> = config
        .app
        .file_associations
        .iter()
        .map(|a| a.mime_type.as_str())
        .collect();

    // The slug is validated to be space-free, so Exec needs no quoting. The
    // space before the argument code is unconditional in the deb template, so
    // it stays here too, trailing space and all.
    let mut entry = format!(
        "[Desktop Entry]\n\
         Categories={categories}\n\
         Comment={display_name}\n\
         Exec={slug} {exec_arg}\n\
         Icon={slug}\n\
         Name={display_name}\n\
         Terminal=false\n\
         Type=Application\n"
    );
    if has_associations {
        // No trailing ';', matching the deb template's `join(";")`: the two
        // packages must register identically. Costs a desktop-file-validate
        // warning, but GLib's key-file parser reads either form the same way.
        entry.push_str(&format!("MimeType={}\n", mime_types.join(";")));
    }
    entry
}

/// Resolve PNG icon paths from the config's icon globs. Patterns are
/// project-relative (same semantics as resolve_windows_icon), so anchor them
/// to the project dir rather than globbing against the process CWD.
fn resolve_png_icons(config: &Config, project_dir: &Path) -> Result<Vec<PathBuf>> {
    let mut pngs = Vec::new();
    for pattern in &config.app.icons {
        let pattern = &anchored_glob_pattern(project_dir, pattern);
        for entry in glob::glob(pattern)
            .with_context(|| format!("invalid icon glob: {pattern}"))?
        {
            let path = entry.with_context(|| format!("reading icon glob: {pattern}"))?;
            if path.extension() == Some(OsStr::new("png")) {
                pngs.push(path);
            }
        }
    }
    Ok(pngs)
}

/// Read PNG dimensions from file header.
fn png_dimensions(path: &Path) -> Result<(u32, u32)> {
    let file = File::open(path)
        .with_context(|| format!("opening icon {}", path.display()))?;
    let decoder = png::Decoder::new(std::io::BufReader::new(file));
    let reader = decoder.read_info()
        .with_context(|| format!("reading PNG header of {}", path.display()))?;
    let info = reader.info();
    Ok((info.width, info.height))
}

pub fn build(
    project_dir: &Path,
    bundle_dir: &Path,
    dist_dir: &Path,
    config: &Config,
    manifest: &BundleManifest,
    planned: PlannedFormat,
) -> Result<()> {
    let BundleVariant::Linux {
        ref wrapper_name,
        ref install_prefix,
    } = manifest.variant
    else {
        unreachable!("RPM build called for non-Linux target");
    };

    let arch = rpm_arch(&planned.target());
    let ArtifactNaming::Composed(filename) = planned.artifact_name(&config.app) else {
        anyhow::bail!(
            "bug: {} artifacts are always trolley-named",
            planned.format()
        );
    };
    let output_path = dist_dir.join(&filename);

    // Use a temp dir for files the rpm builder needs (empty dir placeholder, wrapper script)
    let staging = dist_dir.join(".rpm-staging");
    if staging.exists() {
        fs::remove_dir_all(&staging)?;
    }
    fs::create_dir_all(&staging)?;

    let executables = manifest.executables();

    let mut builder = rpm::PackageBuilder::new(
        &config.app.slug,
        &rpm_version(&config.app.version),
        "Proprietary",
        arch,
        &config.app.display_name,
    );
    builder.using_config(
        rpm::BuildConfig::default().compression(rpm::CompressionWithLevel::Gzip(6)),
    );

    // Add the install prefix directory
    builder.with_dir_entry(FileOptions::dir(install_prefix).mode(FileMode::dir(0o755)))?;

    for entry in WalkDir::new(bundle_dir) {
        let entry = entry.context("walking bundle directory")?;
        let src_path = entry.path();

        if src_path == bundle_dir {
            continue;
        }

        let rel_path = src_path
            .strip_prefix(bundle_dir)
            .context("stripping bundle prefix")?;
        let dest_path = format!("{install_prefix}/{}", rel_path.display());

        if entry.file_type().is_dir() {
            builder.with_dir_entry(FileOptions::dir(dest_path).mode(FileMode::dir(0o755)))?;
        } else {
            let file_name = rel_path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            let mode = if executables.contains(&file_name) {
                FileMode::regular(0o755)
            } else {
                FileMode::regular(0o644)
            };
            builder.with_file(src_path, FileOptions::new(dest_path).mode(mode))?;
        }
    }

    // Create /usr/bin/<slug> wrapper script
    // This for consistency with cargo-packager
    let wrapper_content = format!(
        "#!/usr/bin/env sh\nexec {install_prefix}/{} \"$@\"\n",
        manifest.runtime_name
    );
    let wrapper_path = staging.join(wrapper_name);
    fs::write(&wrapper_path, &wrapper_content)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&wrapper_path, fs::Permissions::from_mode(0o755))?;
    }
    builder.with_file(
        &wrapper_path,
        FileOptions::new(format!("/usr/bin/{}", config.app.slug))
            .mode(FileMode::regular(0o755)),
    )?;

    // Desktop entry; distro file triggers pick up the mime associations, so no
    // post-install script (deb and pacman rely on the same).
    builder.with_file_contents(
        desktop_entry(config, parse_linux_category(config)?),
        FileOptions::new(format!("/usr/share/applications/{}.desktop", config.app.slug))
            .mode(FileMode::regular(0o644)),
    )?;

    // Install PNG icons into /usr/share/icons/hicolor/<WxH>/apps/<slug>.png
    for icon_path in resolve_png_icons(config, project_dir)? {
        let (width, height) = png_dimensions(&icon_path)?;
        let dest = format!(
            "/usr/share/icons/hicolor/{width}x{height}/apps/{}.png",
            config.app.slug
        );
        builder.with_file(
            &icon_path,
            FileOptions::new(dest).mode(FileMode::regular(0o644)),
        )?;
    }

    let pkg = builder.build()?;

    let mut output_file = File::create(&output_path)
        .with_context(|| format!("creating {}", output_path.display()))?;
    pkg.write(&mut output_file)
        .with_context(|| format!("writing {}", output_path.display()))?;
    output_file.flush()?;

    // Clean up staging
    fs::remove_dir_all(&staging)?;

    println!("  {filename}  (RPM package)");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use trolley_config::{
        App, Arch, Embeds, Environment, FileAssociation, FileAssociationRole, Fonts, Gui, Linux,
    };

    fn test_config(associations: Vec<FileAssociation>) -> Config {
        Config {
            app: App {
                identifier: "com.example.myapp".into(),
                display_name: "My App".into(),
                slug: "myapp".into(),
                version: "1.0.0".into(),
                icons: vec![],
                file_associations: associations,
            },
            linux: Some(Linux {
                binaries: BTreeMap::from([(Arch::X86_64, "my-app".into())]),
                args: Vec::new(),
                category: None,
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

    fn association(extensions: &[&str], mime_type: &str) -> FileAssociation {
        FileAssociation {
            extensions: extensions.iter().map(|e| (*e).into()).collect(),
            mime_type: mime_type.into(),
            description: None,
            role: FileAssociationRole::Editor,
        }
    }

    // The trailing space on Exec= is deb-template parity, not a typo.
    #[test]
    fn desktop_entry_without_associations() {
        assert_eq!(
            desktop_entry(&test_config(vec![]), None),
            "[Desktop Entry]\n\
             Categories=\n\
             Comment=My App\n\
             Exec=myapp \n\
             Icon=myapp\n\
             Name=My App\n\
             Terminal=false\n\
             Type=Application\n"
        );
    }

    #[test]
    fn desktop_entry_with_associations() {
        let config = test_config(vec![
            association(&["md", "markdown"], "text/markdown"),
            association(&["csv"], "text/csv"),
        ]);
        assert_eq!(
            desktop_entry(&config, Some(AppCategory::Utility)),
            "[Desktop Entry]\n\
             Categories=Utility;\n\
             Comment=My App\n\
             Exec=myapp %F\n\
             Icon=myapp\n\
             Name=My App\n\
             Terminal=false\n\
             Type=Application\n\
             MimeType=text/markdown;text/csv\n"
        );
    }

    // Same call chain as build(): manifest string through the fuzzy parse.
    #[test]
    fn desktop_entry_category_from_manifest() {
        let mut config = test_config(vec![]);
        config.linux.as_mut().unwrap().category = Some("utility".into());
        let entry = desktop_entry(&config, parse_linux_category(&config).unwrap());
        assert!(entry.contains("Categories=Utility;\n"), "{entry}");
    }
}
