use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use trolley_config::{Format, Target};

use super::common;
use common::ProjectContext;

/// Assemble a bundle directory and optionally build packages.
///
/// Returns the bundle directory path (for `trolley run` to exec from).
pub fn run(
    ctx: &ProjectContext,
    target: Target,
    tui_binary: &Path,
    runtime: &Path,
    bundle_only: bool,
    formats: Option<Vec<Format>>,
    skip_failed_formats: bool,
) -> Result<PathBuf> {
    let formats = match formats {
        Some(formats) => formats,
        None => {
            if target.is_linux() {
                Format::LINUX_DEFAULT.to_vec()
            } else if target.is_macos() {
                Format::macos_default(cfg!(target_os = "macos"))
            } else if target.is_windows() {
                Format::WINDOWS_DEFAULT.to_vec()
            } else {
                vec![]
            }
        }
    };

    // Validate: each format must be valid for the target
    let invalid: Vec<_> = formats.iter().filter(|f| !f.valid_for(&target)).collect();
    if !invalid.is_empty() {
        bail!(
            "formats {} are not valid for target {}",
            invalid
                .iter()
                .map(|f| f.as_str())
                .collect::<Vec<_>>()
                .join(", "),
            target
        );
    }

    let mut manifest = common::BundleManifest::new(&ctx.config, &target);

    let base_output_dir = common::build_output_dir(&ctx.output_dir, &ctx.config, &target);

    let bundle_dir = base_output_dir.join("bundle");
    let dist_dir = base_output_dir.join("dist");

    // Clean and recreate the output directory
    if base_output_dir.exists() {
        fs::remove_dir_all(&base_output_dir)
            .with_context(|| format!("cleaning output directory {}", base_output_dir.display()))?;
    }
    fs::create_dir_all(&bundle_dir)
        .with_context(|| format!("creating bundle directory {}", bundle_dir.display()))?;
    fs::create_dir_all(&dist_dir)
        .with_context(|| format!("creating dist directory {}", dist_dir.display()))?;

    // Resolve and copy fonts
    let font_files = common::resolve_fonts(&ctx.project_dir, &ctx.output_dir, &ctx.config)?;
    common::copy_fonts_to_bundle(&font_files, &bundle_dir)?;

    if !font_files.is_empty() {
        for font in &font_files {
            if let Some(name) = font.file_name() {
                manifest.resources.push(PathBuf::from("fonts").join(name));
            }
        }
        manifest
            .resources
            .push(PathBuf::from(common::FONTS_CONFIG_FILENAME));
    }

    // Read font family names for config assembly
    let font_family_names = common::read_font_family_names(&font_files)?;
    let shaders = common::resolve_shaders(&ctx.project_dir, &ctx.config)?;
    let data_paths = common::resolve_data_paths(&ctx.project_dir, &ctx.config)?;
    let windows_icon = if target.is_windows() {
        common::resolve_windows_icon(&ctx.project_dir, &ctx.config)?
    } else {
        None
    };

    for shader in &shaders {
        common::copy_shader_to_bundle(shader, &bundle_dir)?;
        manifest.resources.push(shader.relative_path.clone());
    }
    for data_path in &data_paths {
        manifest
            .resources
            .extend(common::copy_data_path_to_bundle(data_path, &bundle_dir)?);
    }
    if target.is_windows() && let Some(icon_path) = &windows_icon {
        common::copy_windows_icon_to_bundle(icon_path, &bundle_dir)?;
        manifest
            .resources
            .push(PathBuf::from(common::WINDOWS_ICON_FILENAME));
    }

    // Assemble ghostty.conf — command references the renamed TUI binary
    let config_bytes = common::assemble_config(
        &ctx.project_dir,
        &ctx.config,
        &target,
        &manifest.core_name,
        &font_family_names,
    )?;

    // Copy runtime and TUI binary into bundle with renamed filenames
    let bundled_runtime = bundle_dir.join(&manifest.runtime_name);
    fs::copy(&runtime, &bundled_runtime)
        .with_context(|| format!("copying runtime to {}", bundle_dir.display()))?;
    fs::copy(&tui_binary, bundle_dir.join(&manifest.core_name))
        .with_context(|| format!("copying TUI binary to {}", bundle_dir.display()))?;
    let stamped_runtime_icon = if target.is_windows() && let Some(icon_path) = &windows_icon {
        super::windows_exe_icon::stamp_exe_icon(&bundled_runtime, icon_path).with_context(|| {
            format!(
                "stamping Windows app icon into {}",
                bundled_runtime.display()
            )
        })?
    } else {
        false
    };
    fs::write(
        bundle_dir.join(common::GHOSTTY_CONFIG_FILENAME),
        &config_bytes,
    )
    .with_context(|| format!("writing config to {}", bundle_dir.display()))?;

    let env_bytes = common::assemble_environment(&ctx.project_dir, &ctx.config)?;
    fs::write(bundle_dir.join(common::ENVIRONMENT_FILENAME), &env_bytes)
        .with_context(|| format!("writing environment to {}", bundle_dir.display()))?;

    // Copy manifest into bundle (runtime needs it for [gui] config)
    fs::copy(&ctx.config_path, bundle_dir.join(common::CONFIG_FILENAME))
        .with_context(|| format!("copying manifest to {}", bundle_dir.display()))?;

    // Generate wrapper script for Linux
    if let common::BundleVariant::Linux {
        ref wrapper_name,
        ref install_prefix,
    } = manifest.variant
    {
        let wrapper_content = format!(
            "#!/usr/bin/env sh\nexec {install_prefix}/{} \"$@\"\n",
            manifest.runtime_name
        );
        let wrapper_path = bundle_dir.join(wrapper_name);
        fs::write(&wrapper_path, &wrapper_content)
            .with_context(|| format!("writing wrapper script to {}", wrapper_path.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&wrapper_path, fs::Permissions::from_mode(0o755))?;
        }
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::Permissions::from_mode(0o755);
        fs::set_permissions(bundle_dir.join(&manifest.runtime_name), mode.clone())?;
        fs::set_permissions(bundle_dir.join(&manifest.core_name), mode)?;
    }

    println!("Bundle written to {}", bundle_dir.display());
    println!("  {}  (runtime)", manifest.runtime_name);
    println!("  {}  (TUI binary)", manifest.core_name);
    println!("  ghostty.conf  (terminal config)");
    println!("  environment  (environment variables)");
    println!("  trolley.toml  (manifest)");
    if let common::BundleVariant::Linux {
        ref wrapper_name, ..
    } = manifest.variant
    {
        println!("  {wrapper_name}  (wrapper script)");
    }
    if !font_files.is_empty() {
        println!("  fonts/  ({} font files)", font_files.len());
    }
    for shader in &shaders {
        println!("  {}  (custom shader)", shader.relative_path.display());
    }
    for data_path in &data_paths {
        println!("  {}  (embedded data)", data_path.relative_path.display());
    }
    if target.is_windows() && windows_icon.is_some() {
        println!("  {}  (Windows app icon)", common::WINDOWS_ICON_FILENAME);
        if stamped_runtime_icon {
            println!("  {}  (Windows exe icon stamped)", manifest.runtime_name);
        } else {
            eprintln!(
                "Warning: Windows exe icon stamping is only available when packaging on Windows."
            );
        }
    }

    // Build packages unless bundle-only
    if !bundle_only && !formats.is_empty() {
        println!();
        super::formats::build_formats(&formats, &bundle_dir, &dist_dir, &ctx.config, &manifest, skip_failed_formats)?;
    }

    Ok(bundle_dir)
}
