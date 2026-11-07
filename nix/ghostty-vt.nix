# The prebuilt libghostty-vt the Nix package links: ghostty-vt-rs-sys's Ghostty commit and, for
# each system the flake builds, the archive's target and SHA-256 (the crate's prebuilt.rs). CI
# checks that they agree; update them with the crate.
{
  commit = "0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec";
  targets = {
    aarch64-darwin = {
      triple = "aarch64-apple-darwin";
      sha256 = "9ad9a7e52b2ddd389c01315a31d4ef5d212dfca95617559dd95a9de8b898cc86";
    };
    x86_64-linux = {
      triple = "x86_64-unknown-linux-gnu";
      sha256 = "84021c0d0944e38883eb5ffda6241653d24aa9b533af4fbc0e64c1433ea0e5ef";
    };
    aarch64-linux = {
      triple = "aarch64-unknown-linux-gnu";
      sha256 = "7075b6638d0d20e715fa10835a1764d3f9ccc21a08fe3c82dfd498a656782a18";
    };
  };
}
