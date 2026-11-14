//! The questions the daemon sends the app (`ui.request`) and the answers it takes back
//! (`ui.reply`), as `ui_contract.json` has them: the macOS app's tests read the same file.

use serde_json::Value;
use thurm_proto::ext::{Reply, UiRequest};

fn contract() -> Value {
    serde_json::from_str(include_str!("ui_contract.json")).unwrap()
}

#[test]
fn the_daemon_sends_the_requests_the_app_reads() {
    for req in contract()["requests"].as_array().unwrap() {
        let parsed: UiRequest = serde_json::from_value(req.clone()).unwrap();
        assert_eq!(&serde_json::to_value(&parsed).unwrap(), req);
    }
}

#[test]
fn the_daemon_takes_the_replies_the_app_sends() {
    let replies: Vec<Reply> = serde_json::from_value(contract()["replies"].clone()).unwrap();
    assert_eq!(replies[0].result["index"], 1);
    assert_eq!(replies[0].result["id"], 7);
    assert_eq!(replies[1].result, "typed");
    assert_eq!(replies[2].result.as_bool(), Some(true));
    assert!(replies[3].result.is_null());
    assert!(replies.iter().all(|r| r.error.is_none()));
}
