use std::path::Path;
use std::process::{Command, Output};

fn thurm(home: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_thurm"))
        .env("THURM_CONFIG_DIR", home.join("config"))
        .env("THURM_SOCKET", home.join("s"))
        .args(args)
        .output()
        .unwrap()
}

fn repo(dir: &Path, file: &str) {
    std::fs::create_dir_all(dir).unwrap();
    std::fs::write(dir.join(file), "thurm.log('hi')").unwrap();
    for args in [
        &["init", "-q"][..],
        &["add", "."],
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "commit",
            "-qm",
            "x",
        ],
    ] {
        assert!(
            Command::new("git")
                .args(args)
                .current_dir(dir)
                .status()
                .unwrap()
                .success()
        );
    }
}

/// Only what the plugins directory should have stays: an installed plugin; nothing of an
/// install that failed (no half clone, no name taken).
#[test]
fn an_install_leaves_the_plugin_or_nothing() {
    let home = std::env::temp_dir().join(format!("thurm-install-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    let plugins = home.join("config/plugins");
    let names = || {
        let mut n: Vec<String> = std::fs::read_dir(&plugins)
            .map(|d| {
                d.map(|e| e.unwrap().file_name().to_string_lossy().into())
                    .collect()
            })
            .unwrap_or_default();
        n.sort();
        n
    };

    repo(&home.join("good"), "init.lua");
    let out = thurm(
        &home,
        &[
            "plugin",
            "install",
            home.join("good").to_str().unwrap(),
            "--name",
            "good",
        ],
    );
    assert!(out.status.success(), "{out:?}");
    assert!(plugins.join("good/init.lua").is_file());
    assert_eq!(names(), ["good"]);

    // The name is taken now.
    let out = thurm(
        &home,
        &[
            "plugin",
            "install",
            home.join("good").to_str().unwrap(),
            "--name",
            "good",
        ],
    );
    assert!(!out.status.success());
    assert!(plugins.join("good/init.lua").is_file());

    // Not a plugin, and a clone that fails: both leave nothing.
    repo(&home.join("notes"), "README");
    let out = thurm(
        &home,
        &[
            "plugin",
            "install",
            home.join("notes").to_str().unwrap(),
            "--name",
            "notes",
        ],
    );
    assert!(!out.status.success());
    let out = thurm(
        &home,
        &[
            "plugin",
            "install",
            home.join("missing").to_str().unwrap(),
            "--name",
            "gone",
        ],
    );
    assert!(!out.status.success());
    assert_eq!(names(), ["good"]);
    let _ = std::fs::remove_dir_all(&home);
}
