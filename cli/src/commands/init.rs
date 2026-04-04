use std::collections::BTreeMap;
use std::path::PathBuf;

use anyhow::{Context, Result, bail};
use trolley_config::{App, Arch, Config, Environment, Fonts, Gui, Linux, Macos, Windows};

use super::common;

pub fn run(path: Option<String>) -> Result<()> {
    let project_dir = match path {
        Some(p) => {
            let dir = PathBuf::from(p);
            std::fs::create_dir_all(&dir)
                .with_context(|| format!("creating directory {}", dir.display()))?;
            dir.canonicalize()
                .with_context(|| format!("resolving {}", dir.display()))?
        }
        None => std::env::current_dir().context("getting current directory")?,
    };

    let manifest_path = project_dir.join(common::CONFIG_FILENAME);
    if manifest_path.exists() {
        bail!(
            "{} already exists in {}",
            common::CONFIG_FILENAME,
            project_dir.display()
        );
    }

    let dir_name = project_dir
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("my-app")
        .to_string();

    let binary_placeholder = format!("path/to/{dir_name}");
    let all_arches = BTreeMap::from([
        (Arch::X86_64, binary_placeholder.clone()),
        (Arch::Aarch64, binary_placeholder),
    ]);

    let linux = Some(Linux {
        binaries: all_arches.clone(),
        args: Vec::new(),
        appimage: None,
    });
    let macos = Some(Macos {
        binaries: all_arches.clone(),
        args: Vec::new(),
    });
    let windows = Some(Windows {
        binaries: all_arches,
        args: Vec::new(),
        precise_timer: None,
    });

    let manifest = Config {
        app: App {
            identifier: format!("com.example.{dir_name}"),
            display_name: dir_name.clone(),
            slug: dir_name,
            version: "0.1.0".into(),
            icons: vec![],
        },
        linux,
        macos,
        windows,
        fonts: Fonts::default(),
        gui: Gui::default(),
        environment: Environment::default(),
        embeds: trolley_config::Embeds::default(),
        ghostty: BTreeMap::new(),
    };

    let content = toml::to_string_pretty(&manifest).context("serializing manifest")?;

    // Generate commented-out [fonts] example.
    // We write this manually rather than serializing a Fonts struct because
    // toml::to_string_pretty expands the families array into [[families]]
    // syntax, but we want the compact inline format.
    let fonts_block = "\n\
        # Fonts are loaded in order — first match per codepoint wins.\n\
        # Use nerdfont to auto-download from Nerd Fonts GitHub releases.\n\
        # Use path to bundle a local .ttf/.otf file.\n\
        # [fonts]\n\
        # families = [\n\
        #     { nerdfont = \"Inconsolata\" },\n\
        #     { path = \"fonts/MyCustomFont-Regular.ttf\" },\n\
        # ]\n";

    let env_block = "\n\
        # Environment variables injected into the TUI process.\n\
        # LANG=C.UTF-8 and LC_ALL=C.UTF-8 are always set by default.\n\
        # [environment]\n\
        # env_file = \".env\"\n\
        # variables = { MY_VAR = \"value\" }\n";

    let embeds_block = "\n\
        # Embed portable Ghostty resources into the generated bundle.\n\
        # `theme` is inlined into ghostty.conf.\n\
        # `shaders` emits repeated `custom-shader = <path>` entries.\n\
        # `data` copies files or directories into the bundle root.\n\
        # [embeds]\n\
        # theme = \"themes/dracula\"\n\
        # shaders = [\"shaders/crt.glsl\"]\n\
        # data = [\"assets\", \"config/defaults.json\"]\n";

    let final_content = format!("{content}{fonts_block}{env_block}{embeds_block}");

    std::fs::write(&manifest_path, &final_content)
        .with_context(|| format!("writing {}", manifest_path.display()))?;

    println!("Created {}", common::CONFIG_FILENAME);
    println!();
    println!("Next steps:");
    println!(
        "  1. Update app.identifier and app.display_name in {}",
        common::CONFIG_FILENAME
    );
    println!("  2. Set the binary paths in {}", common::CONFIG_FILENAME);
    println!("  3. Build your TUI binary");
    println!("  4. Run `trolley run` to test");

    Ok(())
}
