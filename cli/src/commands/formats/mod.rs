pub mod archive;
pub mod packager_common;
pub mod rpm;

use std::path::Path;

use anyhow::Result;
use indicatif::ProgressBar;
use trolley_config::{Config, Format};

use super::common::BundleManifest;

fn spinner(msg: &str) -> ProgressBar {
    let pb = ProgressBar::new_spinner();
    // Windows Command Prompt can't render the default Unicode braille spinner,
    // causing a new line per frame instead of animating in-place.
    if !console::Term::stderr().features().wants_emoji() {
        pb.set_style(
            indicatif::ProgressStyle::default_spinner()
                .tick_chars("-\\|/ "),
        );
    }
    pb.enable_steady_tick(std::time::Duration::from_millis(80));
    pb.set_message(msg.to_string());
    pb
}

/// Build all requested formats from the assembled bundle directory.
pub fn build_formats(
    formats: &[Format],
    project_dir: &Path,
    bundle_dir: &Path,
    dist_dir: &Path,
    config: &Config,
    manifest: &BundleManifest,
    skip_failed: bool,
) -> Result<()> {
    let mut failed: Vec<&str> = Vec::new();

    for format in formats {
        let (name, result) = match format {
            Format::Archive => {
                let pb = spinner("Building archive...");
                let r = archive::build(bundle_dir, dist_dir, config, manifest);
                pb.finish_and_clear();
                ("archive", r)
            }
            Format::Rpm => {
                let pb = spinner("Building RPM...");
                let r = rpm::build(project_dir, bundle_dir, dist_dir, config, manifest);
                pb.finish_and_clear();
                ("RPM", r)
            }
            Format::Deb => {
                let pb = spinner("Building deb...");
                let r = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::Deb]);
                pb.finish_and_clear();
                ("deb", r)
            }
            Format::AppImage => {
                let pb = spinner("Building AppImage...");
                let r = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::AppImage]);
                pb.finish_and_clear();
                ("AppImage", r)
            }
            Format::Pacman => {
                let pb = spinner("Building pacman...");
                let r = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::Pacman]);
                pb.finish_and_clear();
                ("pacman", r)
            }
            Format::Nsis => {
                let pb = spinner("Building NSIS...");
                let r = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::Nsis]);
                pb.finish_and_clear();
                ("NSIS", r)
            }
            Format::MacApp => {
                let pb = spinner("Building app...");
                let r = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::MacApp]);
                pb.finish_and_clear();
                ("app", r)
            }
            Format::Dmg => {
                let pb = spinner("Building dmg...");
                let r = packager_common::run_packager(config, project_dir, bundle_dir, dist_dir, manifest, &[packager_common::PackagerFormat::Dmg]);
                pb.finish_and_clear();
                ("dmg", r)
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
