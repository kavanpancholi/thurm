use std::os::unix::net::UnixListener;
use std::process::Command;
use std::time::Duration;

use thurm_proto::{Envelope, Request, Response, ServerMessage, UiCommand, codec};

fn requests(name: &str, args: &[&str], old_ui: bool) -> Vec<Request> {
    let dir = std::env::temp_dir().join(format!("thtab-{}-{name}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut requests = Vec::new();
        while let Ok(Some(env)) = codec::read_message::<_, Envelope>(&mut stream) {
            let result = match &env.request {
                Request::Hello { .. } => Ok(Response::Hello {
                    version: thurm_proto::PROTOCOL_VERSION,
                    daemon_pid: std::process::id(),
                    restored: false,
                    build: thurm_proto::BUILD.into(),
                    capabilities: thurm_proto::CAPABILITIES
                        .iter()
                        .map(|s| (*s).into())
                        .collect(),
                }),
                Request::CreatePane(_) => Ok(Response::PaneCreated { pane: 100 }),
                Request::PaneInfo { .. } => Err("no pane info".into()),
                Request::Ui(UiCommand::Open { .. }) if old_ui => {
                    Err(thurm_proto::UI_TOO_OLD.into())
                }
                _ => Ok(Response::Ok),
            };
            requests.push(env.request);
            codec::write_message(&mut stream, &ServerMessage::Response { id: env.id, result })
                .unwrap();
        }
        requests
    });
    let output = Command::new(env!("CARGO_BIN_EXE_thurm"))
        .env("THURM_SOCKET", socket)
        .env("THURM_PANE_ID", "7")
        .args(args)
        .output()
        .unwrap();
    let requests = server.join().unwrap();
    let _ = std::fs::remove_dir_all(dir);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "100");
    requests
}

#[test]
fn tab_commands_send_the_source_pane() {
    for (name, args, target, background) in [
        ("default", vec!["new-tab"], 7, false),
        ("background", vec!["new-tab", "--background"], 7, true),
        ("explicit", vec!["new-tab", "--pane", "42"], 42, false),
        ("launch", vec!["launch", "claude"], 7, false),
        ("fork", vec!["fork", "--pane", "42"], 42, false),
    ] {
        let requests = requests(name, &args, false);
        assert!(requests.iter().any(|r| matches!(r, Request::CreatePane(p)
            if p.inherit_cwd_from == Some(target) || p.fork_from == Some(target))));
        let commands: Vec<_> = requests
            .iter()
            .filter_map(|r| match r {
                Request::Ui(cmd) => Some(cmd),
                _ => None,
            })
            .collect();
        assert_eq!(
            commands,
            [&UiCommand::Open {
                pane: 100,
                split: None,
                target: Some(target),
                new_window: false,
                percent: None,
                background,
            }]
        );
    }
}

#[test]
fn an_old_app_gets_the_same_pane_without_creating_another() {
    let requests = requests("old", &["new-tab", "--background"], true);
    assert_eq!(
        requests
            .iter()
            .filter(|r| matches!(r, Request::CreatePane(_)))
            .count(),
        1
    );
    assert!(matches!(
        requests.last(),
        Some(Request::Ui(UiCommand::NewTab {
            pane: 100,
            new_window: false,
        }))
    ));
}
