pub mod archive;
pub mod packager_common;
pub mod rpm;

use std::path::Path;

use anyhow::Result;
use indicatif::ProgressBar;
use trolley_config::{Config, Format, PlannedFormat};

use super::common::BundleManifest;

fn spinner(msg: &str) -> ProgressBar {
    let progress = ProgressBar::new_spinner();
    // Windows Command Prompt can't render the default Unicode braille spinner,
    // causing a new line per frame instead of animating in-place.
    if !console::Term::stderr().features().wants_emoji() {
        progress.set_style(
            indicatif::ProgressStyle::default_spinner()
                .tick_chars("-\\|/ "),
        );
    }
    progress.enable_steady_tick(std::time::Duration::from_millis(80));
    progress.set_message(msg.to_string());
    progress
}

/// Build all requested formats from the assembled bundle directory.
pub fn build_formats(
    planned_formats: &[PlannedFormat],
    project_dir: &Path,
    bundle_dir: &Path,
    dist_dir: &Path,
    config: &Config,
    manifest: &BundleManifest,
    skip_failed: bool,
) -> Result<()> {
    let mut failed: Vec<&str> = Vec::new();

    for &planned in planned_formats {
        let (name, result) = match planned.format() {
            Format::Archive => {
                let progress = spinner("Building archive...");
                let result = archive::build(bundle_dir, dist_dir, config, planned);
                progress.finish_and_clear();
                ("archive", result)
            }
            Format::Rpm => {
                let progress = spinner("Building RPM...");
                let result = rpm::build(project_dir, bundle_dir, dist_dir, config, manifest, planned);
                progress.finish_and_clear();
                ("RPM", result)
            }
            Format::Deb => {
                let progress = spinner("Building deb...");
                let result = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::Deb]);
                progress.finish_and_clear();
                ("deb", result)
            }
            Format::AppImage => {
                let progress = spinner("Building AppImage...");
                let result = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::AppImage]);
                progress.finish_and_clear();
                ("AppImage", result)
            }
            Format::Pacman => {
                let progress = spinner("Building pacman...");
                let result = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::Pacman]);
                progress.finish_and_clear();
                ("pacman", result)
            }
            Format::Nsis => {
                let progress = spinner("Building NSIS...");
                let result = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::Nsis]);
                progress.finish_and_clear();
                ("NSIS", result)
            }
            Format::MacApp => {
                let progress = spinner("Building app...");
                let result = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::MacApp]);
                progress.finish_and_clear();
                ("app", result)
            }
            Format::Dmg => {
                let progress = spinner("Building dmg...");
                let result = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::Dmg]);
                progress.finish_and_clear();
                ("dmg", result)
            }
        };

        if let Err(e) = result {
            if skip_failed {
                eprintln!("Warning: {name} failed: {e}");
                failed.push(name);
            } else {
                return Err(e.context(format!("{name} packaging failed")));
            }
        }
    }

    if !failed.is_empty() {
        eprintln!(
            "\n{} format(s) failed: {}",
            failed.len(),
            failed.join(", ")
        );
    }

    Ok(())
}
