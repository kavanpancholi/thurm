//! CPU and memory of pane processes and of the system (`Request::Usage`).

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use thurm_proto::{AgentUsage, PaneId, PaneUsage, ProcUsage, Usage};

const WINDOW: Duration = Duration::from_millis(500);
const FRESH: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct ProcSample {
    /// Start time, which tells a reused pid from its previous process.
    start: u64,
    cpu_ns: u64,
    memory: u64,
}

/// Raw `host_cpu_load_info` counters: 32 bits each, so they wrap on a long-running Mac.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct CpuTicks {
    user: u32,
    system: u32,
    idle: u32,
    nice: u32,
}

struct Sample {
    at: Instant,
    procs: HashMap<u32, ProcSample>,
    cpu: Option<CpuTicks>,
}

pub struct PaneRoot {
    pub pane: PaneId,
    pub pid: u32,
    pub agent: Option<(String, String)>,
}

pub const BUSY: &str = "the daemon is busy measuring usage; try again";
const MAX_IN_FLIGHT: usize = 4;

#[derive(Default)]
pub struct Sampler {
    last: Mutex<Option<Sample>>,
    in_flight: Arc<AtomicUsize>,
}

pub struct Permit(Arc<AtomicUsize>);

impl Drop for Permit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

impl Sampler {
    pub fn permit(&self) -> Option<Permit> {
        self.in_flight
            .try_update(Ordering::AcqRel, Ordering::Acquire, |n| {
                (n < MAX_IN_FLIGHT).then_some(n + 1)
            })
            .ok()
            .map(|_| Permit(self.in_flight.clone()))
    }

    /// Usage of every pane in `roots`, then kept to `only` when given. Every pane is measured
    /// either way, so the sample kept for the next request covers them all.
    pub fn usage(&self, roots: &[PaneRoot], only: Option<PaneId>) -> Result<Usage, String> {
        os::supported()?;
        let mut last = self.last.lock();
        let prev = match last.take() {
            Some(s) if s.at.elapsed() <= FRESH => s,
            _ => take_sample(&pids(&trees(roots))),
        };
        let age = prev.at.elapsed();
        if age < WINDOW {
            std::thread::sleep(WINDOW - age);
        }
        let trees = trees(roots);
        let now = take_sample(&pids(&trees));
        let window = now.at.duration_since(prev.at);
        let procs: HashMap<u32, ProcUsage> = now
            .procs
            .iter()
            .map(|(&pid, s)| {
                let cpu = cpu_percent(prev.procs.get(&pid), s, window);
                (
                    pid,
                    ProcUsage {
                        pid,
                        cpu,
                        memory: s.memory,
                    },
                )
            })
            .collect();
        let cpu = prev.cpu.zip(now.cpu).map(|(a, b)| system_cpu_percent(a, b));
        *last = Some(now);
        drop(last);

        let panes: Vec<PaneUsage> = roots
            .iter()
            .zip(trees)
            .filter(|(r, _)| only.is_none_or(|id| id == r.pane))
            .map(|(r, pids)| {
                pane_usage(
                    r.pane,
                    r.agent.as_ref().map(|a| a.0.clone()),
                    pids.iter()
                        .filter_map(|pid| procs.get(pid).cloned())
                        .collect(),
                )
            })
            .collect();
        let names: HashMap<&str, &str> = roots
            .iter()
            .filter_map(|r| r.agent.as_ref())
            .map(|(kind, name)| (kind.as_str(), name.as_str()))
            .collect();
        let agents = agent_totals(&panes, |kind| names.get(kind).map(|n| n.to_string()));
        let mut system = os::system();
        system.cpu = cpu.unwrap_or_default();
        Ok(Usage {
            interval_ms: window.as_millis() as u64,
            panes,
            agents,
            system,
        })
    }
}

fn trees(roots: &[PaneRoot]) -> Vec<Vec<u32>> {
    let table = crate::procinfo::process_table();
    roots
        .iter()
        .map(|r| {
            crate::procinfo::descendants(&table, r.pid)
                .into_iter()
                .map(|p| p.0)
                .collect()
        })
        .collect()
}

fn pids(trees: &[Vec<u32>]) -> Vec<u32> {
    trees.iter().flatten().copied().collect()
}

fn take_sample(pids: &[u32]) -> Sample {
    Sample {
        procs: pids
            .iter()
            .filter_map(|&pid| Some((pid, os::proc_sample(pid)?)))
            .collect(),
        cpu: os::cpu_ticks(),
        at: Instant::now(),
    }
}

/// Percent of one core `now` used since `prev`. A process missing from `prev`, or one that
/// reuses its pid, started within the window: all its CPU time counts.
fn cpu_percent(prev: Option<&ProcSample>, now: &ProcSample, window: Duration) -> f32 {
    let before = prev
        .filter(|p| p.start == now.start)
        .map_or(0, |p| p.cpu_ns);
    let window_ns = window.as_nanos();
    if window_ns == 0 {
        return 0.0;
    }
    (now.cpu_ns.saturating_sub(before) as f64 * 100.0 / window_ns as f64) as f32
}

fn system_cpu_percent(prev: CpuTicks, now: CpuTicks) -> f32 {
    let delta = |a: u32, b: u32| u64::from(b.wrapping_sub(a));
    let busy =
        delta(prev.user, now.user) + delta(prev.system, now.system) + delta(prev.nice, now.nice);
    let total = busy + delta(prev.idle, now.idle);
    if total == 0 {
        return 0.0;
    }
    (busy as f64 * 100.0 / total as f64) as f32
}

fn pane_usage(pane: PaneId, agent: Option<String>, processes: Vec<ProcUsage>) -> PaneUsage {
    PaneUsage {
        pane,
        agent,
        cpu: processes.iter().map(|p| p.cpu).sum(),
        memory: processes.iter().map(|p| p.memory).sum(),
        processes,
    }
}

fn agent_totals(panes: &[PaneUsage], name: impl Fn(&str) -> Option<String>) -> Vec<AgentUsage> {
    let mut out: Vec<AgentUsage> = Vec::new();
    for p in panes {
        let Some(kind) = &p.agent else { continue };
        let i = match out.iter().position(|a| &a.kind == kind) {
            Some(i) => i,
            None => {
                out.push(AgentUsage {
                    kind: kind.clone(),
                    name: name(kind).unwrap_or_else(|| kind.clone()),
                    ..Default::default()
                });
                out.len() - 1
            }
        };
        let a = &mut out[i];
        a.panes.push(p.pane);
        a.cpu += p.cpu;
        a.memory += p.memory;
    }
    out
}

/// Nanoseconds in `ticks` of the mach clock (`ri_user_time` and `ri_system_time` count in it:
/// 1 ns per tick on Intel, 125/3 ns on Apple silicon).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn ticks_to_ns(ticks: u64, numer: u32, denom: u32) -> u64 {
    if denom == 0 {
        return ticks;
    }
    (ticks as u128 * numer as u128 / denom as u128) as u64
}

#[cfg(target_os = "macos")]
mod os {
    use super::{CpuTicks, ProcSample, ticks_to_ns};
    use std::sync::OnceLock;
    use thurm_proto::{MemoryPressure, SystemUsage};

    pub fn supported() -> Result<(), String> {
        Ok(())
    }

    #[allow(deprecated)]
    fn timebase() -> (u32, u32) {
        static TIMEBASE: OnceLock<(u32, u32)> = OnceLock::new();
        *TIMEBASE.get_or_init(|| {
            let mut info = libc::mach_timebase_info { numer: 0, denom: 0 };
            let ok = unsafe { libc::mach_timebase_info(&mut info) } == 0;
            if ok { (info.numer, info.denom) } else { (1, 1) }
        })
    }

    #[allow(deprecated)]
    fn host() -> libc::mach_port_t {
        static HOST: OnceLock<libc::mach_port_t> = OnceLock::new();
        *HOST.get_or_init(|| unsafe { libc::mach_host_self() })
    }

    pub fn proc_sample(pid: u32) -> Option<ProcSample> {
        let mut info: libc::rusage_info_v4 = unsafe { std::mem::zeroed() };
        let rc = unsafe {
            libc::proc_pid_rusage(
                pid as i32,
                libc::RUSAGE_INFO_V4,
                (&mut info as *mut libc::rusage_info_v4).cast(),
            )
        };
        if rc != 0 {
            return None;
        }
        let (numer, denom) = timebase();
        Some(ProcSample {
            start: info.ri_proc_start_abstime,
            cpu_ns: ticks_to_ns(
                info.ri_user_time.saturating_add(info.ri_system_time),
                numer,
                denom,
            ),
            memory: info.ri_phys_footprint,
        })
    }

    pub fn cpu_ticks() -> Option<CpuTicks> {
        let mut info: libc::host_cpu_load_info = unsafe { std::mem::zeroed() };
        let mut count = libc::HOST_CPU_LOAD_INFO_COUNT;
        let rc = unsafe {
            libc::host_statistics(
                host(),
                libc::HOST_CPU_LOAD_INFO,
                (&mut info as *mut libc::host_cpu_load_info).cast(),
                &mut count,
            )
        };
        if rc != libc::KERN_SUCCESS {
            return None;
        }
        let t = info.cpu_ticks;
        Some(CpuTicks {
            user: t[libc::CPU_STATE_USER as usize],
            system: t[libc::CPU_STATE_SYSTEM as usize],
            idle: t[libc::CPU_STATE_IDLE as usize],
            nice: t[libc::CPU_STATE_NICE as usize],
        })
    }

    fn sysctl<T: Copy>(name: &str) -> Option<T> {
        let name = std::ffi::CString::new(name).ok()?;
        let mut value: T = unsafe { std::mem::zeroed() };
        let mut size = std::mem::size_of::<T>();
        let rc = unsafe {
            libc::sysctlbyname(
                name.as_ptr(),
                (&mut value as *mut T).cast(),
                &mut size,
                std::ptr::null_mut(),
                0,
            )
        };
        (rc == 0 && size == std::mem::size_of::<T>()).then_some(value)
    }

    /// Memory Activity Monitor counts as used: app memory (anonymous pages that can't be
    /// purged), wired and compressed.
    fn memory_used() -> Option<u64> {
        let mut vm: libc::vm_statistics64 = unsafe { std::mem::zeroed() };
        let mut count = libc::HOST_VM_INFO64_COUNT;
        let rc = unsafe {
            libc::host_statistics64(
                host(),
                libc::HOST_VM_INFO64,
                (&mut vm as *mut libc::vm_statistics64).cast(),
                &mut count,
            )
        };
        if rc != libc::KERN_SUCCESS {
            return None;
        }
        let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
        let pages = u64::from(vm.internal_page_count.saturating_sub(vm.purgeable_count))
            + u64::from(vm.wire_count)
            + u64::from(vm.compressor_page_count);
        Some(pages * u64::try_from(page).ok()?)
    }

    fn pressure() -> MemoryPressure {
        match sysctl::<i32>("kern.memorystatus_vm_pressure_level") {
            Some(1) => MemoryPressure::Normal,
            Some(2) => MemoryPressure::Warning,
            Some(4) => MemoryPressure::Critical,
            _ => MemoryPressure::Unknown,
        }
    }

    fn disk() -> Option<(u64, u64)> {
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c"/".as_ptr(), &mut st) } != 0 {
            return None;
        }
        let block = st.f_frsize as u64;
        Some((st.f_blocks as u64 * block, st.f_bavail as u64 * block))
    }

    pub fn system() -> SystemUsage {
        let swap = sysctl::<libc::xsw_usage>("vm.swapusage");
        let (disk_total, disk_free) = disk().unwrap_or_default();
        SystemUsage {
            cpu: 0.0,
            cpus: sysctl::<i32>("hw.logicalcpu")
                .and_then(|n| u32::try_from(n).ok())
                .unwrap_or(0),
            memory_total: sysctl::<u64>("hw.memsize").unwrap_or(0),
            memory_used: memory_used().unwrap_or(0),
            pressure: pressure(),
            swap_total: swap.map_or(0, |s| s.xsu_total),
            swap_used: swap.map_or(0, |s| s.xsu_used),
            disk_total,
            disk_free,
        }
    }
}

#[cfg(not(target_os = "macos"))]
mod os {
    use super::{CpuTicks, ProcSample};
    use thurm_proto::SystemUsage;

    pub fn supported() -> Result<(), String> {
        Err("resource usage is not available on this host".into())
    }

    pub fn proc_sample(_pid: u32) -> Option<ProcSample> {
        None
    }

    pub fn cpu_ticks() -> Option<CpuTicks> {
        None
    }

    pub fn system() -> SystemUsage {
        SystemUsage::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(start: u64, cpu_ns: u64) -> ProcSample {
        ProcSample {
            start,
            cpu_ns,
            memory: 0,
        }
    }

    fn proc(pid: u32, cpu: f32, memory: u64) -> ProcUsage {
        ProcUsage { pid, cpu, memory }
    }

    #[test]
    fn ticks_to_ns_uses_timebase() {
        assert_eq!(ticks_to_ns(24_000_000, 125, 3), 1_000_000_000);
        assert_eq!(ticks_to_ns(1_000, 1, 1), 1_000);
        assert_eq!(ticks_to_ns(u64::MAX, 1, 1), u64::MAX);
        assert_eq!(ticks_to_ns(7, 1, 0), 7);
    }

    #[test]
    fn cpu_percent_over_window() {
        let window = Duration::from_millis(500);
        let prev = sample(10, 1_000_000_000);
        assert_eq!(
            cpu_percent(Some(&prev), &sample(10, 1_250_000_000), window),
            50.0
        );
        assert_eq!(
            cpu_percent(Some(&prev), &sample(10, 1_900_000_000), window),
            180.0
        );
        assert_eq!(cpu_percent(Some(&prev), &prev, window), 0.0);
        assert_eq!(cpu_percent(Some(&prev), &sample(10, 0), window), 0.0);
        assert_eq!(cpu_percent(Some(&prev), &prev, Duration::ZERO), 0.0);
    }

    #[test]
    fn cpu_percent_new_and_reused_pid() {
        let window = Duration::from_secs(1);
        let now = sample(20, 300_000_000);
        assert_eq!(cpu_percent(None, &now, window), 30.0);
        let old = sample(10, 5_000_000_000);
        assert_eq!(cpu_percent(Some(&old), &now, window), 30.0);
    }

    #[test]
    fn pane_totals_sum_tree() {
        let p = pane_usage(
            3,
            Some("claude".into()),
            vec![
                proc(10, 1.5, 100),
                proc(11, 120.0, 2_000),
                proc(12, 0.0, 50),
            ],
        );
        assert_eq!(p.pane, 3);
        assert_eq!(p.cpu, 121.5);
        assert_eq!(p.memory, 2_150);
        assert_eq!(p.processes.len(), 3);
        let empty = pane_usage(4, None, vec![]);
        assert_eq!((empty.cpu, empty.memory), (0.0, 0));
    }

    #[test]
    fn agent_totals_group_by_kind() {
        let panes = vec![
            pane_usage(1, Some("claude".into()), vec![proc(10, 20.0, 1_000)]),
            pane_usage(2, None, vec![proc(20, 99.0, 9_000)]),
            pane_usage(3, Some("codex".into()), vec![proc(30, 5.0, 500)]),
            pane_usage(4, Some("claude".into()), vec![proc(40, 30.0, 3_000)]),
        ];
        let agents = agent_totals(&panes, |k| (k == "claude").then(|| "Claude Code".into()));
        assert_eq!(agents.len(), 2);
        assert_eq!(agents[0].kind, "claude");
        assert_eq!(agents[0].name, "Claude Code");
        assert_eq!(agents[0].panes, vec![1, 4]);
        assert_eq!(agents[0].cpu, 50.0);
        assert_eq!(agents[0].memory, 4_000);
        assert_eq!(agents[1].kind, "codex");
        assert_eq!(agents[1].name, "codex");
        assert_eq!(agents[1].panes, vec![3]);
    }

    fn ticks(user: u32, system: u32, idle: u32, nice: u32) -> CpuTicks {
        CpuTicks {
            user,
            system,
            idle,
            nice,
        }
    }

    #[test]
    fn system_cpu_from_ticks() {
        let a = ticks(60, 30, 900, 10);
        let b = ticks(260, 70, 1650, 20);
        assert_eq!(system_cpu_percent(a, b), 25.0);
        assert_eq!(system_cpu_percent(b, b), 0.0);
    }

    #[test]
    fn system_cpu_across_counter_wrap() {
        let a = ticks(u32::MAX - 99, 0, u32::MAX - 299, 0);
        let b = ticks(100, 0, 300, 0);
        assert_eq!(system_cpu_percent(a, b), 25.0);
    }

    #[test]
    fn permits_are_bounded_and_released() {
        let sampler = Sampler::default();
        let held: Vec<Permit> = (0..MAX_IN_FLIGHT)
            .filter_map(|_| sampler.permit())
            .collect();
        assert_eq!(held.len(), MAX_IN_FLIGHT);
        assert!(sampler.permit().is_none());
        drop(held);
        assert!(sampler.permit().is_some());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn samples_own_process() {
        let me = std::process::id();
        let before = os::proc_sample(me).expect("own rusage");
        assert!(before.memory > 0);
        let t = Instant::now();
        let mut x = 0u64;
        while t.elapsed() < Duration::from_millis(50) {
            x = std::hint::black_box(x.wrapping_add(1));
        }
        let after = os::proc_sample(me).expect("own rusage");
        assert_eq!(after.start, before.start);
        assert!(after.cpu_ns >= before.cpu_ns + 20_000_000);
        let system = os::system();
        assert!(system.memory_total > 0 && system.memory_used > 0);
        assert!(system.cpus > 0);
        assert!(system.disk_total >= system.disk_free && system.disk_total > 0);
        assert!(os::cpu_ticks().is_some());
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn busy_child_uses_at_most_one_core() {
        let mut child = std::process::Command::new("/bin/sh")
            .args(["-c", "while :; do :; done"])
            .spawn()
            .expect("spawn busy loop");
        std::thread::sleep(Duration::from_millis(100));
        let a = os::proc_sample(child.id()).expect("child rusage");
        let t = Instant::now();
        std::thread::sleep(Duration::from_millis(400));
        let b = os::proc_sample(child.id()).expect("child rusage");
        let wall_ns = t.elapsed().as_nanos() as u64;
        let _ = child.kill();
        let _ = child.wait();
        let used = b.cpu_ns - a.cpu_ns;
        assert!(
            used <= wall_ns + wall_ns / 20,
            "{used} ns of CPU in {wall_ns} ns"
        );
        assert!(used >= wall_ns / 10, "{used} ns of CPU in {wall_ns} ns");
    }

    #[cfg(not(target_os = "macos"))]
    #[test]
    fn refused_off_macos() {
        let err = Sampler::default().usage(&[], None).unwrap_err();
        assert!(err.contains("not available"));
    }
}
