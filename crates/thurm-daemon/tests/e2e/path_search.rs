use super::*;

#[test]
fn path_search_uses_the_requested_panes_folder_without_terminal_input() {
    let env = Env::new("path-search");
    let first_dir = env.dir.join("first");
    let second_dir = env.dir.join("second");
    std::fs::create_dir_all(first_dir.join("folder name")).unwrap();
    std::fs::create_dir_all(&second_dir).unwrap();
    std::fs::write(first_dir.join("a 'quote\".txt"), "").unwrap();
    std::fs::write(second_dir.join("only-second.txt"), "").unwrap();
    let _daemon = env.start();
    let (client, _) = env.connect();
    let first = create(&client, &first_dir);
    let second = create(&client, &second_dir);
    wait_match(&client, first, r"\$");
    wait_match(&client, second, r"\$");
    let before = capture(&client, first);
    for (pane, cwd, expected) in [
        (first, &first_dir, vec!["a 'quote\".txt", "folder name/"]),
        (second, &second_dir, vec!["only-second.txt"]),
    ] {
        let Response::PathMatches(result) = client
            .request(Request::SearchPaths {
                pane,
                query: "".into(),
            })
            .unwrap()
        else {
            panic!("expected path matches");
        };
        assert_eq!(
            Path::new(&result.cwd).canonicalize().unwrap(),
            cwd.canonicalize().unwrap()
        );
        assert_eq!(
            result
                .items
                .iter()
                .map(|i| i.text.as_str())
                .collect::<Vec<_>>(),
            expected
        );
    }
    assert_eq!(capture(&client, first), before);
    assert!(
        client
            .request(Request::SearchPaths {
                pane: u64::MAX,
                query: "".into()
            })
            .is_err()
    );
    let Response::Completions(_) = client.request(Request::Complete { pane: first }).unwrap()
    else {
        panic!("normal completion must still work");
    };
}
