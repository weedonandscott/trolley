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

    let final_content = render(&dir_name)?;

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

/// The manifest text `init` writes for a project named `dir_name`.
fn render(dir_name: &str) -> Result<String> {
    let binary_placeholder = format!("path/to/{dir_name}");
    let all_arches = BTreeMap::from([
        (Arch::X86_64, binary_placeholder.clone()),
        (Arch::Aarch64, binary_placeholder),
    ]);

    let linux = Some(Linux {
        binaries: all_arches.clone(),
        args: Vec::new(),
        category: None,
        file_associations: Vec::new(),
    });
    let macos = Some(Macos {
        binaries: all_arches.clone(),
        args: Vec::new(),
        signing: None,
        file_associations: Vec::new(),
    });
    let windows = Some(Windows {
        binaries: all_arches,
        args: Vec::new(),
        precise_timer: None,
        signing: None,
        file_associations: Vec::new(),
    });

    let manifest = Config {
        app: App {
            identifier: format!("com.example.{dir_name}"),
            display_name: dir_name.to_string(),
            slug: dir_name.to_string(),
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

    let mut content = toml::to_string_pretty(&manifest).context("serializing manifest")?;

    // The serializer emits only [<platform>.binaries], so each platform header
    // is added by hand, with its commented-out examples. Hand-written: serializing
    // would expand the inline tables into [[...]].
    let platform_blocks = [
        (
            "linux",
            "\n\
            [linux]\n\
            # Desktop menu section. See the README.\n\
            # category = \"Utility\"\n\
            # File types this app opens. See the README.\n\
            # file_associations = [\n\
            #   { extensions = [\"md\"], mime_type = \"text/markdown\" },\n\
            # ]\n",
        ),
        (
            "macos",
            "\n\
            [macos]\n\
            # file_associations = [\n\
            #   { extensions = [\"md\"], role = \"editor\" },\n\
            # ]\n",
        ),
        (
            "windows",
            "\n\
            [windows]\n\
            # file_associations = [\n\
            #   { extensions = [\"md\"], description = \"Markdown document\" },\n\
            # ]\n",
        ),
    ];
    for (platform, block) in platform_blocks {
        if let Some(index) = content.find(&format!("\n[{platform}.binaries]")) {
            content.insert_str(index, block);
        }
    }

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

    Ok(format!("{content}{fonts_block}{env_block}{embeds_block}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use trolley_config::{FileAssociationRole, FontFamily};

    /// Uncomments the example lines: TOML after `# ` (a header, a bracket or
    /// indented continuation, or `key = `). Prose comments stay commented.
    fn uncomment_examples(text: &str) -> String {
        let is_example = |rest: &str| {
            rest.starts_with(['[', ']', ' '])
                || rest.split_once(" = ").is_some_and(|(key, _)| {
                    !key.is_empty() && key.chars().all(|c| c.is_ascii_lowercase() || c == '_')
                })
        };
        text.lines()
            .map(|line| match line.strip_prefix("# ") {
                Some(rest) if is_example(rest) => rest,
                _ => line,
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    // The scaffold with every commented-out example switched on parses as a
    // Config, passes validate() and the linux category name-match, and carries
    // each example's values.
    #[test]
    fn scaffold_examples_are_valid() {
        let text = uncomment_examples(&render("my-app").unwrap());
        let config: Config = toml::from_str(&text).unwrap_or_else(|e| panic!("{e}\n{text}"));
        config.validate().unwrap();
        super::super::formats::packager_common::parse_linux_category(&config).unwrap();

        let [linux] = config.linux_file_associations() else {
            panic!("expected one [linux] file association:\n{text}");
        };
        assert_eq!(linux.extensions, ["md"]);
        assert_eq!(linux.mime_type, "text/markdown");
        let [macos] = config.macos_file_associations() else {
            panic!("expected one [macos] file association:\n{text}");
        };
        assert_eq!(macos.extensions, ["md"]);
        assert_eq!(macos.role, FileAssociationRole::Editor);
        let [windows] = config.windows_file_associations() else {
            panic!("expected one [windows] file association:\n{text}");
        };
        assert_eq!(windows.extensions, ["md"]);
        assert_eq!(windows.description, "Markdown document");
        // The examples agree across platforms, so they print no warnings.
        assert_eq!(config.file_association_warnings(), Vec::<String>::new());

        assert_eq!(config.linux.unwrap().category.as_deref(), Some("Utility"));

        assert!(matches!(
            config.fonts.families.as_slice(),
            [FontFamily::NerdFont(n), FontFamily::Path(p)]
                if n == "Inconsolata" && p == "fonts/MyCustomFont-Regular.ttf"
        ));

        assert_eq!(config.environment.env_file.as_deref(), Some(".env"));
        assert_eq!(
            config
                .environment
                .variables
                .get("MY_VAR")
                .map(String::as_str),
            Some("value")
        );

        assert_eq!(config.embeds.theme.as_deref(), Some("themes/dracula"));
        assert_eq!(config.embeds.shaders, ["shaders/crt.glsl"]);
        assert_eq!(config.embeds.data, ["assets", "config/defaults.json"]);
    }
}
