use std::ffi::OsStr;
use std::fs::{self, File};
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use rpm::{FileMode, FileOptions};
use trolley_config::{Config, rpm_arch};
use walkdir::WalkDir;

use super::super::common::{BundleManifest, BundleVariant};

/// Resolve PNG icon paths from the config's icon globs.
fn resolve_png_icons(config: &Config) -> Result<Vec<PathBuf>> {
    let mut pngs = Vec::new();
    for pattern in &config.app.icons {
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
    bundle_dir: &Path,
    dist_dir: &Path,
    config: &Config,
    manifest: &BundleManifest,
) -> Result<()> {
    let BundleVariant::Linux {
        ref wrapper_name,
        ref install_prefix,
    } = manifest.variant
    else {
        unreachable!("RPM build called for non-Linux target");
    };

    let arch = rpm_arch(&manifest.target);
    let filename = format!(
        "{slug}-{version}-1.{arch}.rpm",
        slug = config.app.slug,
        version = config.app.version
    );
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
        &config.app.version,
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

    // Install PNG icons into /usr/share/icons/hicolor/<WxH>/apps/<slug>.png
    for icon_path in resolve_png_icons(config)? {
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
