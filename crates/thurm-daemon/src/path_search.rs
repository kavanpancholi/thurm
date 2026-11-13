//! File search for Insert Path. All paths belong to the pane's daemon.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use thurm_proto::{CompletionItem, CompletionKind, PathMatches};

const MAX_ITEMS: usize = 100;
const MAX_ENTRIES: usize = 10_000;
const MAX_DEPTH: usize = 8;

pub fn search(query: &str, cwd: &Path, home: Option<&str>) -> Result<PathMatches, String> {
    if query.len() > 4096 || query.chars().any(char::is_control) {
        return Err("Use a path without control characters, with at most 4096 bytes.".into());
    }
    let expanded;
    let query = if query == "~" || query.starts_with("~/") {
        let home = home
            .filter(|h| Path::new(h).is_absolute())
            .ok_or("The terminal's home folder is not available.")?;
        expanded = format!(
            "{}/{}",
            home.trim_end_matches('/'),
            query.strip_prefix("~/").unwrap_or("")
        );
        expanded.as_str()
    } else {
        query
    };
    let (prefix, name) = query
        .rfind('/')
        .map_or(("", query), |i| (&query[..=i], &query[i + 1..]));
    let root = cwd.join(prefix);
    let mut pending = VecDeque::from([(PathBuf::new(), 0)]);
    let needle = name.to_lowercase();
    let started = Instant::now();
    let mut visited = 0;
    let mut result = PathMatches {
        cwd: cwd.to_string_lossy().into_owned(),
        ..Default::default()
    };
    'search: while let Some((relative, depth)) = pending.pop_front() {
        let entries = match std::fs::read_dir(root.join(&relative)) {
            Ok(entries) => entries,
            Err(e) if relative.as_os_str().is_empty() => {
                return Err(format!("Cannot read this folder: {e}"));
            }
            Err(_) => {
                result.truncated = true;
                continue;
            }
        };
        for entry in entries {
            visited += 1;
            if visited > MAX_ENTRIES || started.elapsed() > Duration::from_millis(250) {
                result.truncated = true;
                break 'search;
            }
            let Ok(entry) = entry else { continue };
            let Ok(filename) = entry.file_name().into_string() else {
                continue;
            };
            if filename.chars().any(char::is_control)
                || (filename.starts_with('.') && !name.starts_with('.'))
            {
                continue;
            }
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let is_dir = kind.is_dir() || (kind.is_symlink() && entry.path().is_dir());
            let relative = relative.join(&filename);
            if filename.to_lowercase().contains(&needle) {
                if result.items.len() == MAX_ITEMS {
                    result.truncated = true;
                    break 'search;
                }
                result.items.push(CompletionItem {
                    text: format!(
                        "{prefix}{}{}",
                        relative.display(),
                        if is_dir { "/" } else { "" }
                    ),
                    kind: if is_dir {
                        CompletionKind::Directory
                    } else {
                        CompletionKind::File
                    },
                    description: None,
                });
            }
            // Empty searches list one folder. Do not follow links during a recursive search.
            if !name.is_empty() && kind.is_dir() {
                if depth == MAX_DEPTH {
                    result.truncated = true;
                } else {
                    pending.push_back((relative, depth + 1));
                }
            }
        }
    }
    result.items.sort_by(|a, b| a.text.cmp(&b.text));
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let dir = std::env::temp_dir().join(format!(
                "thurm-paths-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir_all(dir.join("folder name/nested")).unwrap();
            for file in [
                "a 'quote\".txt",
                "folder name/nested/match.txt",
                ".hidden",
                "line\nbreak",
            ] {
                std::fs::write(dir.join(file), "").unwrap();
            }
            Self(dir)
        }
        fn paths(&self, query: &str) -> Vec<String> {
            search(query, &self.0, self.0.to_str())
                .unwrap()
                .items
                .into_iter()
                .map(|i| i.text)
                .collect()
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn files_folders_quotes_and_hidden_names() {
        let f = Fixture::new();
        assert_eq!(f.paths(""), ["a 'quote\".txt", "folder name/"]);
        assert_eq!(f.paths(".h"), [".hidden"]);
        assert_eq!(f.paths("MATCH"), ["folder name/nested/match.txt"]);
        assert_eq!(f.paths("folder name/"), ["folder name/nested/"]);
        assert!(search("\n", &f.0, None).is_err());
        assert!(search("missing/", &f.0, None).is_err());
    }

    #[test]
    fn relative_absolute_and_home_paths() {
        let f = Fixture::new();
        assert_eq!(
            f.paths("./folder name/../a 'quote"),
            ["./folder name/../a 'quote\".txt"]
        );
        let expected = format!("{}/folder name/", f.0.display());
        assert_eq!(f.paths("~/folder"), std::slice::from_ref(&expected));
        assert_eq!(f.paths(&format!("{}/folder", f.0.display())), [expected]);
        assert!(search("~/", &f.0, None).is_err());
    }

    #[test]
    fn links_do_not_cause_recursive_loops_and_results_are_bounded() {
        let f = Fixture::new();
        std::os::unix::fs::symlink(&f.0, f.0.join("loop")).unwrap();
        assert_eq!(f.paths("match"), ["folder name/nested/match.txt"]);
        assert!(f.paths("").contains(&"loop/".into()));
        for i in 0..150 {
            std::fs::write(f.0.join(format!("item-{i}")), "").unwrap();
        }
        let result = search("item-", &f.0, None).unwrap();
        assert!(result.truncated);
        assert_eq!(result.items.len(), MAX_ITEMS);
        assert_eq!(Some(result.cwd.as_str()), f.0.to_str());
    }
}
