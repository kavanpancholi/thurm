//! Which client's size a pane takes. A pane has one PTY size; with the phone and the Mac
//! showing it, the client that used it last wins, and gets its size back after the other one
//! had it. Clients without [`thurm_proto::CAP_ACTIVE_SIZE`] keep the last `Resize` winning.
//!
//! The phone shows one pane at a time and holds the one it shows
//! ([`thurm_proto::CAP_PANE_PAGER`]): a `Resize` from another client (the Mac laying its window
//! out again) waits until the phone lets go, by leaving the pane or the host, or until that
//! client really uses the pane. Other mobile clients (the web client, showing splits) don't hold.
//!
//! A client can also hold panes by claiming them ([`thurm_proto::CAP_PANE_OWNER`]): the iPad
//! claims every pane of the tab it shows, and lets go with `DisownPanes`. Clients with that
//! capability hear whose size their subscribed panes have ([`Event::SizeOwner`]).

use std::sync::atomic::AtomicU64;

use thurm_proto::OwnMode;

use super::*;

/// Orders uses of panes across clients.
static TICK: AtomicU64 = AtomicU64::new(1);

/// The size a client shows a pane at, and when it last used the pane.
#[derive(Clone, Copy, Debug)]
pub struct Wanted {
    pub size: PaneSize,
    pub used: u64,
}

impl Daemon {
    /// A `Resize` from `client`: shown at that size now, it uses the pane.
    pub(super) fn resize_for(
        &self,
        client: &Client,
        pane: PaneId,
        size: PaneSize,
    ) -> Result<(), String> {
        let size = sanitize_size(size);
        self.with_input_pane(client.id, pane, |_, st| {
            if client.active_size.load(Ordering::Relaxed) {
                let used = TICK.fetch_add(1, Ordering::Relaxed);
                st.wanted.insert(client.id, Wanted { size, used });
                // A claim holds before the claimant's first `Resize`.
                if let Some(holder) = st.size_held_by
                    && holder != client.id
                    && (st.wanted.contains_key(&holder) || st.size_claimed_by == Some(holder))
                {
                    log::info!(
                        "pane {pane}: client {} wants {}x{}; client {holder} holds it",
                        client.id,
                        size.cols,
                        size.rows
                    );
                    return;
                }
            }
            self.take_size(st, client);
            log::info!(
                "pane {pane}: client {} wants {}x{}",
                client.id,
                size.cols,
                size.rows
            );
            self.set_size(st, size);
        })
    }

    /// `client` typed into, focused or answered in the pane: its size applies again.
    pub(super) fn used_by(&self, client: &Client, st: &mut PaneState) {
        if !client.active_size.load(Ordering::Relaxed) {
            return;
        }
        let Some(w) = st.wanted.get_mut(&client.id) else {
            return;
        };
        w.used = TICK.fetch_add(1, Ordering::Relaxed);
        let size = w.size;
        self.take_size(st, client);
        self.set_size(st, size);
    }

    /// `client` claims `panes` (`OwnPanes`): each takes its size now, or, when it has not sized
    /// the pane yet, holds it and takes its size with its first `Resize`. With
    /// [`OwnMode::Request`], a pane another client holds stays with it, and goes to `client`
    /// when that one lets go.
    pub(super) fn own_panes(&self, client: &Client, panes: &[PaneId], mode: OwnMode) {
        for &pane in panes {
            let _ = self.with_input_pane(client.id, pane, |_, st| {
                if mode == OwnMode::Request
                    && let Some(holder) = st.size_held_by
                    && holder != client.id
                {
                    if !st.size_requested_by.contains(&client.id) {
                        st.size_requested_by.push(client.id);
                    }
                    log::info!(
                        "pane {pane}: client {} asks for it; client {holder} holds it",
                        client.id
                    );
                    return;
                }
                st.size_requested_by.retain(|c| *c != client.id);
                st.size_held_by = Some(client.id);
                st.size_claimed_by = Some(client.id);
                match self.claimed_size(st, client.id) {
                    Some(size) => log::info!(
                        "pane {pane}: client {} owns it at {}x{}",
                        client.id,
                        size.cols,
                        size.rows
                    ),
                    None => log::info!(
                        "pane {pane}: client {} holds it; its size comes with its resize",
                        client.id
                    ),
                }
            });
        }
    }

    /// `client` lets go of `panes` (`DisownPanes`; every pane it holds when empty). It still
    /// shows them: its size stays wanted, and the pane goes to the client that asked for it, or
    /// else the one that used it last.
    pub(super) fn disown_panes(&self, client: &Client, panes: &[PaneId]) {
        if panes.is_empty() {
            for p in self.all_panes() {
                self.disown(&mut p.state.lock(), client.id);
            }
            return;
        }
        for &pane in panes {
            let _ = self.with_pane(pane, |_, st| self.disown(st, client.id));
        }
    }

    /// Only a pane `client` holds changes hands; elsewhere it just stops asking for the pane.
    fn disown(&self, st: &mut PaneState, client: u64) {
        if st.size_held_by != Some(client) {
            st.size_requested_by.retain(|c| *c != client);
            return;
        }
        self.release_hold(st, client);
        if self.pass_claim(st, client, "let go") {
            return;
        }
        if st.terminal_attachment.is_some() || st.size_owner != Some(client) {
            return;
        }
        if !self.hand_off(st, client, "let go") {
            log::info!(
                "pane {}: client {client} let go; nobody else wants a size",
                st.info.id
            );
        }
    }

    /// `client` is gone, or no longer shows the pane: when the pane had its size, the client
    /// that asked for it, or else the last user left, takes over.
    pub(super) fn forget_size(&self, st: &mut PaneState, client: u64) {
        let claimed = st.size_claimed_by == Some(client);
        let held = self.release_hold(st, client);
        let wanted = st.wanted.remove(&client).is_some();
        if held && self.pass_claim(st, client, "left") {
            return;
        }
        if !wanted && !claimed {
            return;
        }
        // Another client wanting the same size does not make it the owner.
        if st.terminal_attachment.is_some() || st.size_owner != Some(client) {
            log::info!(
                "pane {}: client {client} left; it did not set the current {}x{}",
                st.info.id,
                st.info.size.cols,
                st.info.size.rows
            );
            return;
        }
        if !self.hand_off(st, client, "left") {
            log::info!(
                "pane {}: client {client} left; size goes to (nobody else wants one)",
                st.info.id
            );
            self.set_owner(st, None);
        }
    }

    /// The holder `from` let go: the first client still connected that asked for the pane
    /// claims it. True when that client's size applies; without one yet, it holds the pane and
    /// its first `Resize` sizes it.
    fn pass_claim(&self, st: &mut PaneState, from: u64, why: &str) -> bool {
        let next = {
            let clients = self.clients.lock();
            st.size_requested_by.retain(|c| clients.contains_key(c));
            (!st.size_requested_by.is_empty()).then(|| st.size_requested_by.remove(0))
        };
        let Some(next) = next else {
            return false;
        };
        st.size_held_by = Some(next);
        st.size_claimed_by = Some(next);
        if st.terminal_attachment.is_some() {
            return false;
        }
        match self.claimed_size(st, next) {
            Some(size) => {
                log::info!(
                    "pane {}: client {from} {why}; client {next} asked for it, size goes to {}x{}",
                    st.info.id,
                    size.cols,
                    size.rows
                );
                true
            }
            None => {
                log::info!(
                    "pane {}: client {from} {why}; client {next} asked for it, its size comes with its resize",
                    st.info.id
                );
                false
            }
        }
    }

    /// The claimant `client` uses the pane: when it has sized the pane, it becomes the owner and
    /// its size applies. Its size, if it has one.
    fn claimed_size(&self, st: &mut PaneState, client: u64) -> Option<PaneSize> {
        let w = st.wanted.get_mut(&client)?;
        w.used = TICK.fetch_add(1, Ordering::Relaxed);
        let size = w.size;
        self.set_owner(st, Some(client));
        self.set_size(st, size);
        Some(size)
    }

    /// The size `from` gave the pane goes to the client that used the pane last, other than
    /// `from`. False when no other client wants a size.
    fn hand_off(&self, st: &mut PaneState, from: u64, why: &str) -> bool {
        let Some((next, w)) = st
            .wanted
            .iter()
            .filter(|(id, _)| **id != from)
            .max_by_key(|(_, w)| w.used)
            .map(|(id, w)| (*id, *w))
        else {
            return false;
        };
        log::info!(
            "pane {}: client {from} {why}; size goes to {}x{}",
            st.info.id,
            w.size.cols,
            w.size.rows
        );
        self.set_owner(st, Some(next));
        self.set_size(st, w.size);
        true
    }

    /// `client` takes the pane's size: it holds it when it pages (the phone) or claimed it, and
    /// no longer asks for it.
    fn take_size(&self, st: &mut PaneState, client: &Client) {
        st.size_requested_by.retain(|c| *c != client.id);
        let claimed = st.size_claimed_by == Some(client.id);
        st.size_claimed_by = claimed.then_some(client.id);
        st.size_held_by = (holds(client) || claimed).then_some(client.id);
        self.set_owner(st, Some(client.id));
    }

    /// Drops `client`'s hold, claim and request on the pane. Whether it held the pane.
    fn release_hold(&self, st: &mut PaneState, client: u64) -> bool {
        st.size_requested_by.retain(|c| *c != client);
        if st.size_claimed_by == Some(client) {
            st.size_claimed_by = None;
        }
        let held = st.size_held_by == Some(client);
        if held {
            st.size_held_by = None;
        }
        held
    }

    /// Records whose size the pane has, telling the subscribers it changed for that care
    /// ([`thurm_proto::CAP_PANE_OWNER`]): the old owner and the new one.
    fn set_owner(&self, st: &mut PaneState, owner: Option<u64>) {
        let old = std::mem::replace(&mut st.size_owner, owner);
        if old == owner {
            return;
        }
        let clients = self.clients.lock();
        for cid in [old, owner].into_iter().flatten() {
            if !st.subscribers.contains_key(&cid) {
                continue;
            }
            if let Some(c) = clients.get(&cid)
                && c.pane_owner.load(Ordering::Relaxed)
            {
                c.send(ServerMessage::Event(Event::SizeOwner {
                    pane: st.info.id,
                    yours: owner == Some(cid),
                }));
            }
        }
    }
}

/// Whether the pane `client` sizes stays its size until it lets go (the phone).
fn holds(client: &Client) -> bool {
    client.pane_pager.load(Ordering::Relaxed)
}

impl Daemon {
    pub(super) fn set_size(&self, st: &mut PaneState, size: PaneSize) {
        if st.info.size == size {
            return;
        }
        if let Err(e) = st.pty.resize(size) {
            log::warn!(
                "pane {}: resize to {}x{}: {e}",
                st.info.id,
                size.cols,
                size.rows
            );
        }
        st.term.resize(size);
        st.info.size = size;
        self.send_subscribers(
            st,
            Event::Resized {
                pane: st.info.id,
                size,
            },
        );
    }
}
