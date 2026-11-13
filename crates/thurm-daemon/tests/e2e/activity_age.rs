use super::*;

#[test]
fn activity_snapshots_are_opt_in_and_keep_the_original_time() {
    let env = Env::new("activity-age");
    let _daemon = env.start();
    let (old, old_events) = env.connect();
    let pane = create(&old, &env.dir);
    let (tx, events) = unbounded();
    let current = Client::connect_with(
        ConnectOptions {
            socket: env.socket.clone(),
            spawn_daemon: None,
            client_name: "activity-test",
            ui: true,
        },
        &[CAP_AGENT_ACTIVITY],
        move |event| {
            let _ = tx.send(event);
        },
        || {},
    )
    .unwrap();
    old.request(Request::Input {
        pane,
        data: b"printf '\\033]7501;state=working:app=test\\033\\\\'; echo activity-ready\r"
            .to_vec(),
    })
    .unwrap();
    wait_match(&old, pane, "activity-ready");
    let deadline = Instant::now() + Duration::from_secs(10);
    let stamp = loop {
        let event = events
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .unwrap();
        if let Event::PaneActivity(a) = event
            && a.info.id == pane
            && let Some(stamp) = a.updated_at_ms
        {
            break stamp;
        }
    };
    assert!(stamp > 0);
    // A second Hello without capabilities must keep the first negotiation.
    current
        .request(Request::Hello {
            client: "activity-test".into(),
            version: PROTOCOL_VERSION,
            ui: true,
            capabilities: vec![],
        })
        .unwrap();
    for _ in 0..2 {
        let Response::PaneActivity(a) = current.request(Request::PaneInfo { pane }).unwrap() else {
            panic!("expected activity snapshot");
        };
        assert_eq!(a.updated_at_ms, Some(stamp));
    }
    let Response::PanesWithActivity(panes) = current.request(Request::ListPanes).unwrap() else {
        panic!("expected activity list");
    };
    assert_eq!(
        panes
            .iter()
            .find(|a| a.info.id == pane)
            .unwrap()
            .updated_at_ms,
        Some(stamp)
    );
    assert!(matches!(
        old.request(Request::PaneInfo { pane }).unwrap(),
        Response::PaneInfo(_)
    ));
    assert!(matches!(
        old.request(Request::ListPanes).unwrap(),
        Response::Panes(_)
    ));
    assert!(
        old_events
            .try_iter()
            .any(|e| matches!(e, Event::PaneInfo(i) if i.id == pane && i.agent.is_some()))
    );
}
