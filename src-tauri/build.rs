fn main() {
  let is_windows_msvc = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows")
    && std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc");
  let mut attributes = tauri_build::Attributes::new();

  if is_windows_msvc {
    attributes =
      attributes.windows_attributes(tauri_build::WindowsAttributes::new_without_app_manifest());
  }

  tauri_build::try_build(attributes).expect("failed to run tauri-build");

  if is_windows_msvc {
    embed_windows_test_manifest();
  }
}

fn embed_windows_test_manifest() {
  let manifest = std::path::Path::new(&std::env::var("CARGO_MANIFEST_DIR").unwrap())
    .join("windows-app-manifest.xml");

  println!("cargo:rerun-if-changed={}", manifest.display());
  println!("cargo:rustc-link-arg=/MANIFEST:EMBED");
  println!(
    "cargo:rustc-link-arg=/MANIFESTINPUT:{}",
    manifest.display()
  );
}
