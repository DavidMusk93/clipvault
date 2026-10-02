//! Layer 2: `mine_rows` — per-event extraction into counters and turns.
//!
//! Ports `mine.py::mine_rows`. Exclusive second accounting: a call is charged to
//! at most one loss (priority fail > retry > reread > locate), so loss seconds
//! never double count.

use std::collections::{HashMap, HashSet};

use serde_json::{json, Map, Value};

use super::analysis::{
    block, build_losses, build_metrics, fv, g, insights, iv, metrics_analysis, round1, round4, sv,
    table, LossInput,
};
use super::primitives::*;
use super::{dir_ids, rank, Counter};

#[derive(Clone, Debug)]
pub struct Turn {
    pub ts: String,
    pub event_id: Value,
    pub prompt: String,
    pub phase: String,
    pub wall_s: f64,
    pub work_s: f64,
    pub wait_s: f64,
    pub retry_s: f64,
    pub locate_s: f64,
    pub locate_n: i64,
    pub tools: i64,
    pub fails: i64,
    pub retries: i64,
    pub fail_fams: HashSet<String>,
    pub has_path: bool,
    pub has_repo: bool,
    pub nudge: bool,
    pub correction: bool,
    pub push: bool,
    pub cost_usd: f64,
    pub tokens_out: i64,
    pub cache_read: i64,
    pub cache_write: i64,
    pub ctx_total: f64,
    pub skill_tokens: i64,
    pub reread_n: i64,
    pub index: i64,
}

#[derive(Default, Clone)]
pub struct Refs {
    pub fail: Vec<Value>,
    pub wait: Vec<Value>,
    pub read: Vec<Value>,
    pub locate: Vec<Value>,
}

fn path_parent(p: &str) -> String {
    std::path::Path::new(p)
        .parent()
        .map(|x| x.to_string_lossy().to_string())
        .unwrap_or_default()
}
fn path_suffix(p: &str) -> String {
    std::path::Path::new(p)
        .extension()
        .map(|e| format!(".{}", e.to_string_lossy()))
        .unwrap_or_default()
}

pub fn mine_rows(
    rows: &[Value],
    dirs: Option<&[String]>,
    session_id: Option<&str>,
    scope: &str,
    usage_rows: &[Value],
    ctx_rows: &[Value],
) -> Value {
    let want: Vec<String> = match dirs {
        Some(d) if !d.is_empty() => d
            .iter()
            .filter(|x| dir_ids().contains(&x.as_str()))
            .cloned()
            .collect(),
        _ => dir_ids().iter().map(|s| s.to_string()).collect(),
    };
    let want: Vec<String> = if want.is_empty() {
        dir_ids().iter().map(|s| s.to_string()).collect()
    } else {
        want
    };
    let has = |id: &str| want.iter().any(|w| w == id);

    let mut cwd_n = Counter::default();
    let mut git_n = Counter::default();
    let mut git_branch: HashMap<String, Counter> = HashMap::new();
    let mut file_n = Counter::default();
    let mut file_read = Counter::default();
    let mut file_write = Counter::default();
    let mut dir_n = Counter::default();
    let mut ext_n = Counter::default();
    let mut cmd_norm = Counter::default();
    let mut slow_cmds: Vec<(f64, String)> = Vec::new();
    let mut tool_n = Counter::default();
    let mut tool_s: HashMap<String, f64> = HashMap::new();
    let mut tool_fail = Counter::default();
    let mut fail_tool = Counter::default();
    let mut fail_family = Counter::default();
    let mut family_n = Counter::default();
    let mut family_s: HashMap<String, f64> = HashMap::new();
    let mut mcp_n = Counter::default();
    let mut mcp_tool = Counter::default();
    let mut taste_n = Counter::default();
    let mut inst_n = Counter::default();
    let mut phase_n = Counter::default();
    let mut phase_s: HashMap<String, f64> = HashMap::new();
    let mut phase_work: HashMap<String, f64> = HashMap::new();
    let mut ts_vals: Vec<f64> = Vec::new();
    let mut prompt_n = 0i64;
    let mut prompt_chars: Vec<i64> = Vec::new();
    let mut reminder_n = Counter::default();
    let mut reminder_samples: HashMap<String, Vec<String>> = HashMap::new();
    let mut nudge_n = 0i64;
    let mut structured_n = 0i64;
    let mut wait_s = 0.0f64;
    let mut work_s = 0.0f64;
    let mut fail_s = 0.0f64;
    let mut fail_n = 0i64;

    // Ordered pass: stable by (ts, event_id).
    let mut idx: Vec<usize> = (0..rows.len()).collect();
    idx.sort_by(|&a, &b| {
        sv(g(&rows[a], "ts"))
            .cmp(&sv(g(&rows[b], "ts")))
            .then_with(|| sv(g(&rows[a], "event_id")).cmp(&sv(g(&rows[b], "event_id"))))
    });
    let ordered: Vec<&Value> = idx.iter().map(|&i| &rows[i]).collect();

    for raw in &ordered {
        if let Some(tv) = parse_ts(&sv(g(raw, "ts"))) {
            ts_vals.push(tv);
        }
        let hook = sv(g(raw, "hook_event"));
        let inst = sv(g(raw, "instance_id"));
        if !inst.is_empty() {
            inst_n.bump(&inst);
        }
        let mut cwd = sv(g(raw, "cwd"));
        while cwd.ends_with('/') {
            cwd.pop();
        }
        if !cwd.is_empty() {
            cwd_n.bump(&cwd);
            if let Some((repo, branch)) = git_from_path(&cwd) {
                git_n.bump(&repo);
                if !branch.is_empty() {
                    git_branch.entry(repo).or_default().bump(&branch);
                }
            }
        }
        if hook != "PostToolUse" {
            let prompt = sv(g(raw, "prompt"));
            if hook == "UserPromptSubmit" && !prompt.trim().is_empty() {
                let text = prompt.trim().to_string();
                prompt_n += 1;
                prompt_chars.push(text.chars().count() as i64);
                for theme in reminder_hits(&text) {
                    reminder_n.bump(theme);
                    let e = reminder_samples.entry(theme.to_string()).or_default();
                    if e.len() < 3 {
                        e.push(first_line(&text, 140));
                    }
                }
                if prompt_is_nudge(&text) {
                    nudge_n += 1;
                }
                if prompt_is_structured(&text) {
                    structured_n += 1;
                }
            }
            for key in taste_keys(&[&prompt, &cwd]) {
                taste_n.bump(&key);
            }
            if prompt_mentions_taste(&prompt) && taste_keys(&[&prompt, &cwd]).is_empty() {
                taste_n.bump("taste-mention");
            }
            continue;
        }
        let name = {
            let n = sv(g(raw, "tool_name"));
            if n.is_empty() {
                let l = sv(g(raw, "llm_tool_name"));
                if l.is_empty() {
                    "tool".to_string()
                } else {
                    l
                }
            } else {
                n
            }
        };
        tool_n.bump(&name);
        let mut parsed = parse_head(&sv(g(raw, "input_head")));
        parsed.merge(&parse_head(&sv(g(raw, "resp_head"))));
        let wall = parsed.wall_s.unwrap_or(0.0);
        *tool_s.entry(name.clone()).or_insert(0.0) += wall;
        if is_wait_tool(&name) {
            wait_s += wall;
        } else {
            work_s += wall;
        }
        if matches!(parsed.exit_code, Some(c) if c != 0) {
            tool_fail.bump(&name);
            fail_tool.bump(&name);
            fail_n += 1;
            fail_s += wall;
        }
        let mut wd = parsed.workdir.clone().unwrap_or_else(|| cwd.clone());
        while wd.ends_with('/') {
            wd.pop();
        }
        if !wd.is_empty() {
            cwd_n.bump(&wd);
            if let Some((repo, branch)) = git_from_path(&wd) {
                git_n.bump(&repo);
                if !branch.is_empty() {
                    git_branch.entry(repo).or_default().bump(&branch);
                }
            }
        }
        let write_hit = is_write_tool(&name, Some(&sv(g(raw, "llm_tool_name"))));
        let fp_raw = parsed.file_path.clone().unwrap_or_default();
        let base = if wd.is_empty() {
            cwd.clone()
        } else {
            wd.clone()
        };
        let fp = norm_path(Some(&fp_raw), Some(&base));
        if !fp.is_empty() {
            file_n.bump(&fp);
            if write_hit {
                file_write.bump(&fp);
            } else {
                file_read.bump(&fp);
            }
            dir_n.bump(&path_parent(&fp));
            let sfx = path_suffix(&fp);
            if !sfx.is_empty() {
                ext_n.bump(&sfx);
            }
        }
        let cmd = parsed.cmd.clone().unwrap_or_default();
        let fam = if cmd.is_empty() {
            String::new()
        } else {
            cmd_family(&cmd).to_string()
        };
        if !fam.is_empty() {
            family_n.bump(&fam);
            *family_s.entry(fam.clone()).or_insert(0.0) += wall;
            if matches!(parsed.exit_code, Some(c) if c != 0) {
                fail_family.bump(&fam);
            }
        }
        if !cmd.is_empty() {
            let label = cmd_label(&cmd);
            if !label.is_empty() {
                cmd_norm.bump(&norm_cmd(&label));
                slow_cmds.push((wall, first_line(&label, 120)));
            }
        }
        let cmd_paths = paths_from_cmd(&cmd);
        for p_raw in &cmd_paths {
            let p = norm_path(Some(p_raw), Some(&base));
            file_n.bump(&p);
            if fam == "read" || fam == "search" {
                file_read.bump(&p);
            }
            dir_n.bump(&path_parent(&p));
            let sfx = path_suffix(&p);
            if !sfx.is_empty() {
                ext_n.bump(&sfx);
            }
        }
        {
            let mut parts: Vec<&str> = vec![&fp_raw, &wd, &cwd, &cmd];
            for cp in &cmd_paths {
                parts.push(cp);
            }
            for key in taste_keys(&parts) {
                taste_n.bump(&key);
            }
        }
        let mcp = mcp_parts(&name).or_else(|| mcp_parts(&sv(g(raw, "llm_tool_name"))));
        if let Some((server, tool)) = mcp {
            mcp_n.bump(&server);
            mcp_tool.bump(&format!("{server}/{tool}"));
        }
        if cmd.contains("git") && cmd_family(&cmd) == "git" {
            if let Some((repo, _)) = git_from_path(&wd) {
                git_n.add(&repo, 2);
            }
        }
    }

    // --- turns ---
    let mut turns: Vec<Turn> = Vec::new();
    let mut pending: Option<Turn> = None;
    let mut refs = Refs::default();
    let mut sec_fail = 0.0f64;
    let mut sec_retry = 0.0f64;
    let mut sec_locate = 0.0f64;
    let mut sec_reread = 0.0f64;
    let mut reread_n = 0i64;
    let mut seen_reads: HashMap<String, i64> = HashMap::new();
    let mut reread_files = Counter::default();
    let mut reread_s_files: HashMap<String, f64> = HashMap::new();

    for raw in &ordered {
        let hook = sv(g(raw, "hook_event"));
        if hook == "UserPromptSubmit" {
            if let Some(p) = pending.take() {
                turns.push(p);
            }
            let prompt_text = sv(g(raw, "prompt"));
            let hits: HashSet<String> = reminder_hits(&prompt_text)
                .iter()
                .map(|s| s.to_string())
                .collect();
            pending = Some(Turn {
                ts: sv(g(raw, "ts")),
                event_id: g(raw, "event_id").clone(),
                prompt: first_line(&prompt_text, 200),
                phase: classify_phase(&prompt_text).to_string(),
                wall_s: 0.0,
                work_s: 0.0,
                wait_s: 0.0,
                retry_s: 0.0,
                locate_s: 0.0,
                locate_n: 0,
                tools: 0,
                fails: 0,
                retries: 0,
                fail_fams: HashSet::new(),
                has_path: prompt_has_path(&prompt_text),
                has_repo: prompt_has_repo(&prompt_text),
                nudge: prompt_is_nudge(&prompt_text),
                correction: hits.contains("纠正"),
                push: hits.contains("催促"),
                cost_usd: 0.0,
                tokens_out: 0,
                cache_read: 0,
                cache_write: 0,
                ctx_total: 0.0,
                skill_tokens: 0,
                reread_n: 0,
                index: 0,
            });
            continue;
        }
        if let (Some(t), true) = (pending.as_mut(), hook == "PostToolUse") {
            let name = sv(g(raw, "tool_name"));
            let inp = parse_head(&sv(g(raw, "input_head")));
            let resp = parse_head(&sv(g(raw, "resp_head")));
            let wall = resp.wall_s.unwrap_or(0.0);
            let exit_code = resp.exit_code;
            let fam = cmd_family(&inp.cmd.clone().unwrap_or_default()).to_string();
            let label = {
                let l = cmd_label(&inp.cmd.clone().unwrap_or_default());
                if l.is_empty() {
                    inp.file_path.clone().unwrap_or_else(|| name.clone())
                } else {
                    l
                }
            };
            let tidx = (turns.len() + 1) as i64;
            let wait_hit = is_wait_tool(&name);
            let is_fail = matches!(exit_code, Some(c) if c != 0);
            let is_retry = !is_fail && !fam.is_empty() && t.fail_fams.contains(&fam);
            let vague = !t.has_path && !t.has_repo;
            let fp2 = inp.file_path.clone().unwrap_or_default();
            let write_hit = is_write_tool(&name, Some(&sv(g(raw, "llm_tool_name"))));
            let read_key = if write_hit || fp2.is_empty() {
                String::new()
            } else {
                norm_path(Some(&fp2), inp.workdir.as_deref())
            };
            let mut read_keys: Vec<String> = if read_key.is_empty() {
                vec![]
            } else {
                vec![read_key.clone()]
            };
            if fam == "read" {
                for p in paths_from_cmd(&inp.cmd.clone().unwrap_or_default()) {
                    let k = norm_path(Some(&p), inp.workdir.as_deref());
                    if !k.is_empty() && !read_keys.contains(&k) {
                        read_keys.push(k);
                    }
                }
            }
            let is_locate0 = !is_fail && !is_retry && !wait_hit && fam == "search" && vague;
            let repeat_key = read_keys
                .iter()
                .find(|k| seen_reads.contains_key(*k))
                .cloned()
                .unwrap_or_default();
            let is_reread = !repeat_key.is_empty() && !is_fail && !is_retry && !wait_hit;
            let is_locate = is_locate0 && !is_reread;
            for k in &read_keys {
                *seen_reads.entry(k.clone()).or_insert(0) += 1;
            }
            t.tools += 1;
            t.wall_s += wall;
            if wait_hit {
                t.wait_s += wall;
                if refs.wait.len() < 20 {
                    refs.wait
                        .push(mkref(tidx, raw, &name, wall, Some(json!({"tool": name}))));
                }
            } else {
                t.work_s += wall;
            }
            if is_fail {
                t.fails += 1;
                sec_fail += wall;
                if !fam.is_empty() {
                    t.fail_fams.insert(fam.clone());
                }
                if refs.fail.len() < 40 {
                    refs.fail.push(mkref(
                        tidx,
                        raw,
                        &label,
                        wall,
                        Some(json!({"exit_code": exit_code, "family": if fam.is_empty() { "?" } else { &fam }})),
                    ));
                }
            } else if is_retry {
                t.retries += 1;
                t.retry_s += wall;
                sec_retry += wall;
                t.fail_fams.remove(&fam);
            } else if is_locate {
                t.locate_s += wall;
                t.locate_n += 1;
                sec_locate += wall;
                if refs.locate.len() < 20 {
                    refs.locate.push(mkref(tidx, raw, &label, wall, None));
                }
            } else if is_reread {
                sec_reread += wall;
                reread_n += 1;
                reread_files.bump(&repeat_key);
                *reread_s_files.entry(repeat_key.clone()).or_insert(0.0) += wall;
                t.reread_n += 1;
            }
            if !read_key.is_empty() && refs.read.len() < 60 {
                refs.read.push(mkref(
                    tidx,
                    raw,
                    &label,
                    wall,
                    Some(json!({"path": read_key})),
                ));
            }
        }
        if hook == "Stop" {
            if let Some(p) = pending.take() {
                turns.push(p);
            }
        }
    }
    if let Some(p) = pending.take() {
        turns.push(p);
    }

    let mut retry_n = 0i64;
    for (i, t) in turns.iter_mut().enumerate() {
        t.index = (i + 1) as i64;
        retry_n += t.retries;
        phase_n.bump(&t.phase);
        *phase_s.entry(t.phase.clone()).or_insert(0.0) += t.wall_s;
        *phase_work.entry(t.phase.clone()).or_insert(0.0) += t.work_s;
    }
    let _ = &turns;

    // --- L1 attribution: bucket usage/ctx onto the turn that spent them ---
    let starts: Vec<f64> = turns
        .iter()
        .map(|t| parse_ts(&t.ts).unwrap_or(0.0))
        .collect();
    let mut cache_write_tokens = 0i64;
    let mut cache_write_n = 0i64;
    let mut cold_turns = 0i64;
    let mut total_cost_usd = 0.0f64;
    let mut token_total = 0i64;
    let mut input_uncached_total = 0i64;

    for ur in usage_rows {
        let Some(tv) = parse_ts(&sv(g(ur, "ts"))) else {
            continue;
        };
        if starts.is_empty() {
            continue;
        }
        let mut i = starts.partition_point(|&s| s <= tv) as i64 - 1;
        if i < 0 {
            i = 0;
        }
        let t = &mut turns[i as usize];
        let cost = fv(g(ur, "cost_total"));
        let tin = iv(g(ur, "input_tokens"));
        let tout = iv(g(ur, "output_tokens"));
        let cr = iv(g(ur, "cache_read_tokens"));
        let cw = iv(g(ur, "cache_write_tokens"));
        t.cost_usd += cost;
        t.tokens_out += tout;
        t.cache_read += cr;
        t.cache_write += cw;
        total_cost_usd += cost;
        token_total += tin + tout + cr + cw;
        input_uncached_total += tin;
        cache_write_tokens += cw;
        if cw > 0 {
            cache_write_n += 1;
        }
        if cr == 0 {
            cold_turns += 1;
        }
    }
    for cr in ctx_rows {
        let Some(tv) = parse_ts(&sv(g(cr, "ts"))) else {
            continue;
        };
        if starts.is_empty() {
            continue;
        }
        let mut i = starts.partition_point(|&s| s <= tv) as i64 - 1;
        if i < 0 {
            i = 0;
        }
        let t = &mut turns[i as usize];
        t.ctx_total += fv(g(cr, "prompt_total_tokens"));
        t.skill_tokens += analysis_skill_tokens(g(cr, "skill_loaded_tokens"));
    }

    let unit_usd = if token_total != 0 {
        total_cost_usd / token_total as f64
    } else {
        0.0
    };
    let tokens_out_total: i64 = turns.iter().map(|t| t.tokens_out).sum();
    let cache_read_total: i64 = turns.iter().map(|t| t.cache_read).sum();
    let cache_write_total: i64 = turns.iter().map(|t| t.cache_write).sum();
    let locate_s: f64 = turns.iter().map(|t| t.locate_s).sum();
    let locate_n: i64 = turns.iter().map(|t| t.locate_n).sum();
    let mut skill_resend = 0i64;
    for (i, t) in turns.iter().enumerate() {
        if t.skill_tokens != 0 {
            skill_resend += t.skill_tokens * ((turns.len() - i).max(1) as i64);
        }
    }
    let read_total: u64 = file_read.values().sum();
    let read_distinct = file_read.values().filter(|n| *n > 0).count() as u64;
    let reread_ratio = if read_distinct != 0 {
        ((read_total as f64 / read_distinct as f64) * 100.0).round() / 100.0
    } else {
        0.0
    };

    let redundant_reads: u64 = file_read.values().map(|n| n.saturating_sub(1)).sum();
    let distinct_cwd = cwd_n.len();
    let distinct_repo = git_n.len();
    let total_tools_n: u64 = tool_n.values().sum();
    let fail_rate = if total_tools_n != 0 {
        fail_n as f64 / total_tools_n as f64
    } else {
        0.0
    };
    let waste_s = wait_s + fail_s;
    let spend_s = work_s + wait_s;
    let waste_pct = if spend_s != 0.0 {
        round1(100.0 * waste_s / spend_s)
    } else {
        0.0
    };
    let mut idle_s = 0.0f64;
    let mut duration_s = 0.0f64;
    if ts_vals.len() >= 2 {
        let mut span = ts_vals.clone();
        span.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
        idle_s = round1(
            span.windows(2)
                .map(|w| w[1] - w[0])
                .filter(|g| *g > 600.0)
                .sum::<f64>(),
        );
        duration_s = round1(span[span.len() - 1] - span[0]);
    }
    let tools_per_turn = if !turns.is_empty() {
        round1(total_tools_n as f64 / turns.len() as f64)
    } else {
        0.0
    };

    let mut score = 100.0f64;
    score -= (30.0f64).min(fail_rate * 150.0);
    score -= (25.0f64).min(waste_pct * 0.5);
    score -= (15.0f64).min(redundant_reads as f64 * 0.05);
    score -= (10.0f64).min((distinct_repo as f64 - 1.0).max(0.0) * 3.0);
    let score = score.round().clamp(0.0, 100.0) as i64;
    let grade = if score >= 85 {
        "稳"
    } else if score >= 70 {
        "尚可"
    } else if score >= 50 {
        "有损耗"
    } else {
        "低效"
    };
    let health = json!({
        "score": score, "grade": grade,
        "fail_rate": round1(100.0 * fail_rate), "waste_pct": waste_pct,
        "redundant_reads": redundant_reads,
    });

    let total_s = if wait_s + work_s == 0.0 {
        1.0
    } else {
        wait_s + work_s
    };
    let mut blocks: Vec<(&str, Value)> = Vec::new();
    let bounded = |counter: &Counter, n: usize| rank(counter, n);

    if has("user.cwd") {
        blocks.push((
            "user.cwd",
            block(
                "工作目录",
                "user",
                "cwd / workdir 出现次数。主目录应写进 prompt，避免 agent 在邻近树里乱走。",
                vec![table(
                    bounded(&cwd_n, 20)
                        .iter()
                        .map(|(k, n)| json!({"path": k, "n": n}))
                        .collect(),
                    &[("path", "目录"), ("n", "次")],
                    "",
                    Some(json!({"kind": "bars", "label": "path", "value": "n"})),
                )],
            ),
        ));
    }
    if has("user.git") {
        let rows_g: Vec<Value> = bounded(&git_n, 20)
            .iter()
            .map(|(k, n)| {
                let br = git_branch
                    .get(k)
                    .map(|c| c.most_common(3))
                    .unwrap_or_default()
                    .iter()
                    .map(|(b, _)| b.clone())
                    .collect::<Vec<_>>()
                    .join(", ");
                json!({"repo": k, "branch": br, "n": n})
            })
            .collect();
        blocks.push((
            "user.git",
            block(
                "Git 库",
                "user",
                "只认 `.tmp/repos/<name>@branch` 或 `--branch` 工作树，不用目录名猜库。",
                vec![table(
                    rows_g,
                    &[("repo", "库"), ("branch", "分支"), ("n", "次")],
                    "",
                    Some(json!({"kind": "bars", "label": "repo", "value": "n"})),
                )],
            ),
        ));
    }
    if has("user.taste") {
        blocks.push((
            "user.taste",
            block(
                "Taste / 规范",
                "user",
                "线索必须带项目或技能名（`clipvault/AGENTS.md`、`skill:ce-code-review`），禁止只记 SKILL.md 文件名。",
                vec![table(
                    bounded(&taste_n, 20).iter().map(|(k, n)| json!({"doc": k, "n": n})).collect(),
                    &[("doc", "线索"), ("n", "次")],
                    "",
                    Some(json!({"kind": "bars", "label": "doc", "value": "n"})),
                )],
            ),
        ));
    }
    if has("agent.files") {
        blocks.push((
            "agent.files",
            block(
                "读写文件",
                "agent",
                "file_path 来自 Write 族才算写入；RunCommand 里的路径算读取。读多写 0 = 上下文在反复重建。",
                vec![
                    table(
                        bounded(&file_n, 20)
                            .iter()
                            .map(|(k, n)| json!({"path": k, "n": n, "writes": file_write.get(k)}))
                            .collect(),
                        &[("path", "文件"), ("n", "次"), ("writes", "写入")],
                        "文件",
                        None,
                    ),
                    table(
                        bounded(&dir_n, 12).iter().map(|(k, n)| json!({"path": k, "n": n})).collect(),
                        &[("path", "目录"), ("n", "次")],
                        "目录簇",
                        None,
                    ),
                    table(
                        bounded(&ext_n, 10).iter().map(|(k, n)| json!({"ext": k, "n": n})).collect(),
                        &[("ext", "后缀"), ("n", "次")],
                        "语言/后缀",
                        None,
                    ),
                ],
            ),
        ));
    }
    if has("agent.tools") {
        let rows_t: Vec<Value> = bounded(&tool_n, 20)
            .iter()
            .map(|(k, n)| {
                let sec = tool_s.get(k).copied().unwrap_or(0.0);
                json!({
                    "tool": k, "n": n, "sec": round1(sec),
                    "share": round1(100.0 * sec / total_s),
                    "fail": tool_fail.get(k),
                    "kind": if is_wait_tool(k) { "等待" } else { "工作" },
                })
            })
            .collect();
        let rows_f: Vec<Value> = bounded(&family_n, 20)
            .iter()
            .map(|(k, n)| json!({"family": k, "n": n, "sec": round1(family_s.get(k).copied().unwrap_or(0.0))}))
            .collect();
        blocks.push((
            "agent.tools",
            block(
                "工具调用",
                "agent",
                &format!(
                    "墙钟合计 {}s，其中工作 {}s、等待（CheckCommandStatus 等）{}s。等待不是任务阶段。",
                    round1(total_s), round1(work_s), round1(wait_s)
                ),
                vec![
                    table(rows_t, &[("tool", "工具"), ("kind", "类"), ("n", "次"), ("sec", "秒"), ("share", "%"), ("fail", "失败")], "工具",
                        Some(json!({"kind": "bars", "label": "tool", "value": "sec", "unit": "s"}))),
                    table(rows_f, &[("family", "shell 族"), ("n", "次"), ("sec", "秒")], "RunCommand 族（git / rg / read / build / test）",
                        Some(json!({"kind": "bars", "label": "family", "value": "sec", "unit": "s"}))),
                ],
            ),
        ));
    }
    if has("agent.mcp") {
        let rows_m: Vec<Value> = bounded(&mcp_tool, 20)
            .iter()
            .map(|(k, n)| {
                let kind = if k.contains("search") {
                    "search"
                } else if k.ends_with("add") || k.contains("memory_add") {
                    "write"
                } else {
                    "other"
                };
                json!({"mcp": k, "kind": kind, "n": n})
            })
            .collect();
        blocks.push((
            "agent.mcp",
            block(
                "MCP",
                "agent",
                "search 远多于 add = 知识只读不沉淀。",
                vec![table(
                    rows_m,
                    &[("mcp", "调用"), ("kind", "类"), ("n", "次")],
                    "",
                    Some(json!({"kind": "bars", "label": "mcp", "value": "n"})),
                )],
            ),
        ));
    }
    if has("agent.phases") {
        let work_total = {
            let s: f64 = phase_work.values().sum();
            if s == 0.0 {
                1.0
            } else {
                s
            }
        };
        let rows_p: Vec<Value> = phase_n
            .most_common(usize::MAX)
            .iter()
            .map(|(name, n)| {
                json!({
                    "phase": name, "n": n,
                    "sec": round1(phase_s.get(name).copied().unwrap_or(0.0)),
                    "work": round1(phase_work.get(name).copied().unwrap_or(0.0)),
                    "share": round1(100.0 * phase_work.get(name).copied().unwrap_or(0.0) / work_total),
                })
            })
            .collect();
        let rows_turn: Vec<Value> = turns
            .iter()
            .map(|t| {
                json!({
                    "index": t.index, "ts": t.ts, "phase": t.phase, "tools": t.tools,
                    "work": round1(t.work_s), "wait": round1(t.wait_s), "prompt": t.prompt,
                })
            })
            .collect();
        blocks.push((
            "agent.phases",
            block(
                "任务阶段",
                "agent",
                "阶段按用户 prompt 分类；占比用工作秒，不含 CheckCommandStatus 空等。每回合 prompt 全文首行。",
                vec![
                    table(rows_p, &[("phase", "阶段"), ("n", "回合"), ("work", "工作秒"), ("sec", "墙钟秒"), ("share", "工作%")], "阶段占比",
                        Some(json!({"kind": "donut", "label": "phase", "value": "work", "unit": "s"}))),
                    table(rows_turn, &[("ts", "时间"), ("phase", "阶段"), ("tools", "工具"), ("work", "工作秒"), ("wait", "等待秒"), ("prompt", "用户首行")], "回合时间线",
                        Some(json!({"kind": "columns", "label": "ts", "value": "work", "unit": "s"}))),
                ],
            ),
        ));
    }
    if has("agent.failures") {
        let rows_ft: Vec<Value> = bounded(&fail_tool, 20)
            .iter()
            .map(|(k, n)| {
                let calls = tool_n.get(k);
                json!({"tool": k, "n": calls, "fail": n, "rate": round1(100.0 * *n as f64 / calls.max(1) as f64)})
            })
            .collect();
        let rows_ff: Vec<Value> = bounded(&fail_family, 20)
            .iter()
            .map(|(k, n)| json!({"family": k, "n": family_n.get(k), "fail": n}))
            .collect();
        blocks.push((
            "agent.failures",
            block(
                "失败与重试",
                "agent",
                &format!(
                    "失败 {fail_n} 次（{}% of {total_tools_n}），同回合重试 {retry_n} 次。失败先读 stderr；同一族连续失败两次必须换策略。",
                    round1(100.0 * fail_rate)
                ),
                vec![
                    table(rows_ft, &[("tool", "工具"), ("n", "调用"), ("fail", "失败"), ("rate", "失败%")], "失败工具",
                        Some(json!({"kind": "bars", "label": "tool", "value": "fail"}))),
                    table(rows_ff, &[("family", "命令族"), ("n", "调用"), ("fail", "失败")], "失败命令族",
                        Some(json!({"kind": "bars", "label": "family", "value": "fail"}))),
                ],
            ),
        ));
    }
    if has("agent.hot") {
        let rows_read: Vec<Value> = bounded(&file_read, 20)
            .iter()
            .map(|(k, n)| json!({"path": k, "reads": n, "writes": file_write.get(k)}))
            .collect();
        let rows_cmd: Vec<Value> = bounded(&cmd_norm, 15)
            .iter()
            .map(|(k, n)| json!({"cmd": k, "n": n}))
            .collect();
        let mut slow = slow_cmds.clone();
        slow.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        let rows_slow: Vec<Value> = slow
            .iter()
            .take(12)
            .map(|(w, c)| json!({"sec": round1(*w), "cmd": c}))
            .collect();
        blocks.push((
            "agent.hot",
            block(
                "热点与冗余",
                "agent",
                &format!(
                    "冗余读 {redundant_reads} 次；重复命令与最慢命令是下一轮 prompt 应点名的对象。"
                ),
                vec![
                    table(
                        rows_read,
                        &[("path", "文件"), ("reads", "读"), ("writes", "写")],
                        "重复读取（与写入对比）",
                        Some(json!({"kind": "bars", "label": "path", "value": "reads"})),
                    ),
                    table(
                        rows_cmd,
                        &[("cmd", "命令（数字归一）"), ("n", "次")],
                        "重复命令",
                        Some(json!({"kind": "bars", "label": "cmd", "value": "n"})),
                    ),
                    table(
                        rows_slow,
                        &[("sec", "秒"), ("cmd", "命令")],
                        "最慢命令",
                        Some(json!({"kind": "bars", "label": "cmd", "value": "sec", "unit": "s"})),
                    ),
                ],
            ),
        ));
    }
    if has("user.prompt") {
        let rows_pr: Vec<Value> = turns
            .iter()
            .map(|t| {
                json!({
                    "ts": t.ts, "phase": t.phase, "tools": t.tools,
                    "path": if t.has_path { "有" } else { "无" },
                    "repo": if t.has_repo { "有" } else { "无" },
                    "prompt": t.prompt,
                })
            })
            .collect();
        let vague = turns.iter().filter(|t| !t.has_path && !t.has_repo).count();
        let note = if turns.is_empty() {
            "还没有 prompt。".to_string()
        } else {
            format!("{vague}/{} 个 prompt 没有路径/仓库线索。", turns.len())
        };
        blocks.push((
            "user.prompt",
            block(
                "任务描述",
                "user",
                &(note + " 下一轮开头写死 cwd、仓库根、分支、目标文件。"),
                vec![table(
                    rows_pr,
                    &[
                        ("ts", "时间"),
                        ("phase", "阶段"),
                        ("tools", "工具"),
                        ("path", "路径"),
                        ("repo", "仓库"),
                        ("prompt", "首行"),
                    ],
                    "回合 prompt 质量",
                    None,
                )],
            ),
        ));
    }

    let avg_prompt = if prompt_n != 0 {
        round1(prompt_chars.iter().sum::<i64>() as f64 / prompt_n as f64)
    } else {
        0.0
    };
    let correction_n = reminder_n.get("纠正") as i64;
    let push_n = reminder_n.get("催促") as i64;
    let sink_n = reminder_n.get("沉淀提醒") as i64;
    let reminder_total = reminder_n.sum() as i64;
    let extra_trips = nudge_n + correction_n + push_n;
    if has("user.reminders") {
        let rows_rem: Vec<Value> = reminder_n
            .most_common(usize::MAX)
            .iter()
            .map(|(k, v)| json!({"theme": k, "n": v, "share": round1(100.0 * *v as f64 / prompt_n.max(1) as f64)}))
            .collect();
        let mut sample_rows: Vec<Value> = Vec::new();
        for (k, _) in reminder_n.most_common(6) {
            for s in reminder_samples
                .get(&k)
                .map(|v| v.as_slice())
                .unwrap_or(&[])
                .iter()
                .take(2)
            {
                sample_rows.push(json!({"theme": k, "prompt": s}));
            }
        }
        blocks.push((
            "user.reminders",
            block(
                "用户提醒",
                "user",
                &format!("{prompt_n} 条 prompt 出现 {reminder_total} 处提醒/纠正信号。反复出现的主题要变成 AGENTS 闸门，而不是每次口头重申。"),
                vec![
                    table(rows_rem, &[("theme", "主题"), ("n", "次"), ("share", "占比%")], "提醒主题",
                        Some(json!({"kind": "bars", "label": "theme", "value": "n"}))),
                    table(sample_rows, &[("theme", "主题"), ("prompt", "样本首行")], "重复提醒样本", None),
                ],
            ),
        ));
    }
    if has("user.flow") {
        let metrics = vec![
            json!({"metric": "prompt 数", "value": prompt_n}),
            json!({"metric": "平均字数", "value": avg_prompt}),
            json!({"metric": "≤8 字短催", "value": nudge_n}),
            json!({"metric": "结构化(多行/列表)", "value": structured_n}),
            json!({"metric": "纠正", "value": correction_n}),
            json!({"metric": "催促", "value": push_n}),
            json!({"metric": "沉淀提醒", "value": sink_n}),
            json!({"metric": "额外往返(短催+纠正+催促)", "value": extra_trips}),
        ];
        let bucket_ranges: [(i64, i64); 5] =
            [(0, 8), (9, 40), (41, 120), (121, 400), (401, i64::MAX)];
        let bucket_rows: Vec<Value> = bucket_ranges
            .iter()
            .map(|(lo, hi)| {
                let label = if *lo == 0 {
                    format!("≤{hi}")
                } else if *hi < i64::MAX {
                    format!("{lo}-{hi}")
                } else {
                    format!(">{}", lo - 1)
                };
                let n = prompt_chars
                    .iter()
                    .filter(|c| **c >= *lo && **c <= *hi)
                    .count();
                json!({"bucket": label, "n": n})
            })
            .collect();
        blocks.push((
            "user.flow",
            block(
                "操作流程",
                "user",
                &format!("额外往返 {extra_trips} 次（短催 {nudge_n} + 纠正 {correction_n} + 催促 {push_n}）。首条 prompt 给全 cwd/仓库/目标/验收，并要求「阶段结论再停」，能直接砍掉这些往返。"),
                vec![
                    table(metrics, &[("metric", "指标"), ("value", "值")], "流程摩擦", None),
                    table(bucket_rows, &[("bucket", "字数"), ("n", "条")], "prompt 长度分布",
                        Some(json!({"kind": "columns", "label": "bucket", "value": "n"}))),
                ],
            ),
        ));
    }

    let instances: Vec<Value> = inst_n
        .most_common(usize::MAX)
        .iter()
        .map(|(k, v)| json!({"id": k, "n": v}))
        .collect();
    let span = format!(
        "{} → {}",
        ordered.first().map(|r| sv(g(r, "ts"))).unwrap_or_default(),
        ordered.last().map(|r| sv(g(r, "ts"))).unwrap_or_default()
    );
    let mut summary = json!({
        "n_rows": rows.len(), "n_turns": turns.len(), "n_tools": total_tools_n,
        "work_s": round1(work_s), "wait_s": round1(wait_s),
        "fail_n": fail_n, "fail_s": round1(fail_s), "waste_s": round1(waste_s),
        "waste_pct": waste_pct, "redundant_reads": redundant_reads,
        "reread_ratio": reread_ratio, "reread_extra": reread_n, "retry_n": retry_n,
        "locate_s": round1(locate_s), "cache_write_n": cache_write_n,
        "skill_resend_tokens": skill_resend, "tokens_out": tokens_out_total,
        "cache_read": cache_read_total, "cache_write": cache_write_total,
        "distinct_cwd": distinct_cwd, "distinct_repo": distinct_repo,
        "tools_per_turn": tools_per_turn, "duration_s": duration_s, "idle_s": idle_s,
        "health": health,
        "flow": {
            "prompt_n": prompt_n, "avg_chars": avg_prompt, "nudge_n": nudge_n,
            "correction_n": correction_n, "push_n": push_n, "sink_n": sink_n,
            "structured_n": structured_n, "reminder_total": reminder_total,
            "extra_roundtrips": extra_trips,
            "reminders": reminder_n.most_common(usize::MAX).into_iter().collect::<HashMap<_,_>>(),
        },
        "instances": instances,
        "span": span,
    });

    if has("agent.metrics") {
        if let Some(mblk) = metrics_analysis(usage_rows, ctx_rows) {
            blocks.push(("agent.metrics", mblk));
        }
        if !usage_rows.is_empty() {
            let mcost: f64 = usage_rows.iter().map(|r| fv(g(r, "cost_total"))).sum();
            let mcr: i64 = usage_rows
                .iter()
                .map(|r| iv(g(r, "cache_read_tokens")))
                .sum();
            let minp: i64 = usage_rows.iter().map(|r| iv(g(r, "input_tokens"))).sum();
            if let Some(o) = summary.as_object_mut() {
                o.insert("cost_usd".into(), json!(round4(mcost)));
                o.insert(
                    "cache_hit_pct".into(),
                    json!(if (mcr + minp) != 0 {
                        round1(100.0 * mcr as f64 / (mcr + minp) as f64)
                    } else {
                        0.0
                    }),
                );
                o.insert("usage_turns".into(), json!(usage_rows.len()));
            }
        }
    }

    if total_cost_usd == 0.0 {
        total_cost_usd = fv(g(&summary, "cost_usd"));
    }
    let total_wall = round1(work_s + wait_s);
    let plane = json!({
        "cache_write_n": cache_write_n, "cache_write_tokens": cache_write_tokens,
        "cold_turns": cold_turns, "skill_tokens": skill_resend,
    });
    let reread_detail: Vec<Value> = {
        let mut v: Vec<Value> = reread_files
            .keys()
            .iter()
            .map(|p| json!({"path": p, "reads": reread_files.get(p), "s": round1(reread_s_files.get(p).copied().unwrap_or(0.0))}))
            .collect();
        v.sort_by(|a, b| {
            fv(g(b, "s"))
                .partial_cmp(&fv(g(a, "s")))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        v
    };
    let losses = build_losses(
        &turns,
        &refs,
        &LossInput {
            fail_n,
            sec_fail,
            sec_retry,
            retry_n,
            wait_s,
            sec_locate,
            locate_n,
            sec_reread,
            reread_n,
            reread_detail,
            cache_write_tokens,
            cache_write_n,
            unit_usd,
            cost_usd: total_cost_usd,
            idle_s,
            skill_resend_tokens: skill_resend,
            total_wall,
        },
    );
    let metrics = build_metrics(&summary, &losses, &plane);
    let feedback = insights(&losses, &metrics, &summary, &plane);

    let turn_rows: Vec<Value> = turns
        .iter()
        .take(400)
        .map(|t| {
            json!({
                "index": t.index, "ts": t.ts, "phase": t.phase, "tools": t.tools,
                "fails": t.fails, "retries": t.retries,
                "work_s": round1(t.work_s), "wait_s": round1(t.wait_s), "wall_s": round1(t.wall_s),
                "cost_usd": round4(t.cost_usd), "tokens_out": t.tokens_out,
                "cache_write": t.cache_write, "prompt": t.prompt, "nudge": t.nudge,
            })
        })
        .collect();

    let directions: Vec<Value> = DIRECTIONS
        .iter()
        .map(|d| json!({"id": d.id, "axis": d.axis, "title": d.title}))
        .collect();
    let mut blocks_map = Map::new();
    for (k, v) in blocks {
        blocks_map.insert(k.to_string(), v);
    }
    let draft = feedback
        .iter()
        .filter_map(|f| {
            let d = sv(g(f, "draft"));
            if d.is_empty() {
                None
            } else {
                Some(d)
            }
        })
        .collect::<Vec<_>>()
        .join("\n");
    json!({
        "ok": true,
        "scope": scope,
        "session_id": session_id.unwrap_or(""),
        "n_rows": rows.len(),
        "n_turns": turns.len(),
        "window": {
            "from": ordered.first().map(|r| sv(g(r, "ts"))).unwrap_or_default(),
            "to": ordered.last().map(|r| sv(g(r, "ts"))).unwrap_or_default(),
            "turns": turns.len(),
            "tools": total_tools_n,
            "instances": inst_n.most_common(usize::MAX).iter().map(|(k, _)| k.clone()).collect::<Vec<_>>(),
            "truncated": rows.len() >= 12000,
        },
        "summary": summary,
        "metrics": metrics,
        "losses": losses,
        "findings": feedback.clone(),
        "turns": turn_rows,
        "series": {
            "cache": {
                "hit_pct": g(&summary, "cache_hit_pct"),
                "read": cache_read_total,
                "uncached": input_uncached_total,
                "write": cache_write_total,
            },
        },
        "directions": directions,
        "active": want,
        "blocks": Value::Object(blocks_map),
        "feedback": feedback,
        "draft": draft,
        "rerun": "",
    })
}

fn mkref(tidx: i64, raw: &Value, label: &str, wall: f64, extra: Option<Value>) -> Value {
    let mut m = Map::new();
    m.insert("turn".into(), json!(tidx));
    m.insert("ts".into(), json!(sv(g(raw, "ts"))));
    m.insert("event_id".into(), g(raw, "event_id").clone());
    m.insert("label".into(), json!(first_line(label, 100)));
    m.insert("s".into(), json!(round1(wall)));
    if let Some(Value::Object(e)) = extra {
        for (k, v) in e {
            m.insert(k, v);
        }
    }
    Value::Object(m)
}

fn analysis_skill_tokens(raw: &Value) -> i64 {
    let data = match raw {
        Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(Value::Null),
        Value::Null => return 0,
        other => other.clone(),
    };
    match data {
        Value::Object(o) => o.values().map(iv).sum(),
        _ => 0,
    }
}
