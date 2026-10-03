mod commands;

use anyhow::Result;
use clap::{Parser, Subcommand};
use trolley_config::{Format, Target};

#[derive(Parser)]
#[command(name = "trolley", about = "Run terminal apps anywhere", version = concat!("version ", env!("TROLLEY_VERSION")))]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Scaffold a new trolley project
    Init {
        /// Directory to initialize (default: current directory)
        path: Option<String>,
    },
    /// Package a trolley project
    Package {
        /// Path to trolley.toml (default: ./trolley.toml)
        #[arg(long)]
        config: Option<String>,
        /// Target platform and arch (default: host)
        #[arg(long, value_enum)]
        target: Option<Target>,
        /// Output directory (default: trolley/<app-id> in project dir)
        #[arg(long)]
        output: Option<String>,
        /// Only assemble the bundle directory, skip packaging.
        #[arg(long, conflicts_with = "formats")]
        bundle_only: bool,
        /// Package formats to build (default: all for target). Comma-separated.
        #[arg(long, value_enum, value_delimiter = ',')]
        formats: Option<Vec<Format>>,
        /// Continue building remaining formats if one fails.
        #[arg(long)]
        skip_failed_formats: bool,
    },
    /// Bundle then run the result
    Run {
        /// Path to trolley.toml (default: ./trolley.toml)
        #[arg(long)]
        config: Option<String>,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Command::Init { path } => commands::init::run(path),
        Command::Package {
            config,
            target,
            output,
            bundle_only,
            formats,
            skip_failed_formats,
        } => {
            let ctx = commands::common::ProjectContext::load(config, output)?;
            for warning in ctx.config.file_association_warnings() {
                eprintln!("warning: {warning}");
            }
            let target = target.unwrap_or_else(Target::host);
            let tui_binary =
                commands::common::resolve_tui_binary(&ctx.project_dir, &ctx.config, &target)?;
            let runtime = commands::common::resolve_runtime(&target)?;
            commands::package::run(
                &ctx,
                target,
                &tui_binary,
                &runtime,
                bundle_only,
                formats,
                skip_failed_formats,
            )?;
            Ok(())
        }
        Command::Run { config } => {
            let ctx = commands::common::ProjectContext::load(config, None)?;
            let target = Target::host();
            let tui_binary =
                commands::common::resolve_tui_binary(&ctx.project_dir, &ctx.config, &target)?;
            let runtime = commands::common::resolve_runtime(&target)?;
            commands::run::run(ctx, tui_binary, runtime)
        }
    }
}
