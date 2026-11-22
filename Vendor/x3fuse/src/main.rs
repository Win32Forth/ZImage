// CPU-only sensor decode for ZImager.
// Calls unmodified x3f-core 0.5.0 and writes one 16-bit sRGB TIFF.
// Denoising is off. The source file is not modified.

use std::path::PathBuf;
use std::process::ExitCode;
use std::sync::atomic::AtomicBool;

fn main() -> ExitCode {
    let mut args = std::env::args_os().skip(1);
    let (Some(input), Some(output)) = (args.next(), args.next()) else {
        eprintln!("usage: zimager-x3f <input.x3f> <output.tiff>");
        return ExitCode::from(2);
    };
    if args.next().is_some() {
        eprintln!("usage: zimager-x3f <input.x3f> <output.tiff>");
        return ExitCode::from(2);
    }

    let options = x3f_core::ProcessOptions {
        color_encoding: x3f_core::ColorEncoding::Srgb,
        denoise_intensity: 0,
        denoise_backend: x3f_core::DenoiseBackend::Cpu,
        compress: false,
        ..Default::default()
    };
    let cancel = AtomicBool::new(false);
    match x3f_core::convert_file(
        PathBuf::from(input).as_path(),
        PathBuf::from(output).as_path(),
        x3f_core::OutputFormat::Tiff,
        &options,
        &cancel,
        |_| {},
    ) {
        Ok(_) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("zimager-x3f: {err}");
            ExitCode::from(1)
        }
    }
}
