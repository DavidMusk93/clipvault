//! Layer 3-6: metrics plane, loss ledger, insights, agent brief, ack attach.
//!
//! Ports `metrics_analysis`, `build_metrics`, `attach_baseline`, `build_losses`,
//! `_sev_for`, `_insights`, `agent_brief`, `agent_view`, `_agent_findings`,
//! `_fmt_s`, `_ts_str`, `fetch_acks`, `_reached`, `attach_acks`.

use serde_json::{json, Map, Value};

use super::rows::{Refs, Turn};

// ------------------------------------------------------------- helpers ----

pub fn g<'a>(v: &'a Value, k: &str) -> &'a Value {
    v.get(k).unwrap_or(&Value::Null)
}

pub fn sv(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

pub fn fv(v: &Value) -> f64 {
    v.as_f64()
        .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
        .unwrap_or(0.0)
}

pub fn iv(v: &Value) -> i64 {
    if let Some(n) = v.as_i64() {
        n
    } else if let Some(f) = v.as_f64() {
        f as i64
    } else if let Some(s) = v.as_str() {
        s.parse::<f64>().map(|f| f as i64).unwrap_or(0)
    } else {
        0
    }
}

pub fn optf(v: &Value) -> Option<f64> {
    v.as_f64()
        .or_else(|| v.as_str().and_then(|s| s.parse::<f64>().ok()))
}

/// Parse a wire timestamp value (string or epoch number).
pub fn parse_ts_v(v: &Value) -> Option<f64> {
    super::primitives::parse_ts(&sv(v))
}

fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().map(|f| f != 0.0).unwrap_or(false),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

pub(crate) fn round1(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}
pub(crate) fn round4(x: f64) -> f64 {
    (x * 10000.0).round() / 10000.0
}

fn pct(part: f64, whole: f64) -> f64 {
    if whole == 0.0 {
        0.0
    } else {
        round1(100.0 * part / whole)
    }
}

fn avg(values: &[f64]) -> f64 {
    if values.is_empty() {
        0.0
    } else {
        round1(values.iter().sum::<f64>() / values.len() as f64)
    }
}

/// A fact table, optionally annotated with the chart that fits its shape.
pub fn table(
    rows: Vec<Value>,
    cols: &[(&str, &str)],
    caption: &str,
    chart: Option<Value>,
) -> Value {
    let mut out = Map::new();
    out.insert("caption".into(), json!(caption));
    out.insert(
        "cols".into(),
        Value::Array(
            cols.iter()
                .map(|(id, title)| json!({ "id": id, "title": title }))
                .collect(),
        ),
    );
    out.insert("rows".into(), Value::Array(rows.clone()));
    if let Some(c) = chart {
        if !rows.is_empty() {
            out.insert("chart".into(), c);
        }
    }
    Value::Object(out)
}

pub fn block(title: &str, axis: &str, note: &str, tables: Vec<Value>) -> Value {
    let first = tables
        .first()
        .cloned()
        .unwrap_or_else(|| table(vec![], &[], "", None));
    json!({ "title": title, "axis": axis, "note": note, "table": first, "tables": tables })
}

fn skill_tokens_of(raw: &Value) -> i64 {
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

const CTX_SECTIONS: &[(&str, &str)] = &[
    ("system", "system 合计"),
    ("rules", "rules (AGENTS)"),
    ("project", "project_context"),
    ("tools", "工具声明"),
    ("skills", "skills 索引"),
    ("history", "history 累计"),
    ("prompt", "当前 prompt"),
    ("total", "合计"),
];

// ---------------------------------------------------- metrics_analysis ----

/// Cost / cache / context read of the metrics plane. Facts only; findings live
/// in the loss account so there is exactly one place that turns a number into a
/// claim.
pub fn metrics_analysis(usage_rows: &[Value], ctx_rows: &[Value]) -> Option<Value> {
    if usage_rows.is_empty() {
        return None;
    }
    let n = usage_rows.len();
    let cost: f64 = usage_rows.iter().map(|r| fv(g(r, "cost_total"))).sum();
    let inp: i64 = usage_rows.iter().map(|r| iv(g(r, "input_tokens"))).sum();
    let cr: i64 = usage_rows
        .iter()
        .map(|r| iv(g(r, "cache_read_tokens")))
        .sum();
    let out: i64 = usage_rows.iter().map(|r| iv(g(r, "output_tokens"))).sum();
    let reasoning: i64 = usage_rows
        .iter()
        .map(|r| iv(g(r, "reasoning_tokens")))
        .sum();
    let hit = pct(cr as f64, (inp + cr) as f64);
    let decode = avg(&usage_rows
        .iter()
        .filter(|r| truthy(g(r, "tok_s_decode")))
        .map(|r| fv(g(r, "tok_s_decode")))
        .collect::<Vec<_>>());
    let e2e = avg(&usage_rows
        .iter()
        .filter(|r| truthy(g(r, "tok_s_e2e")))
        .map(|r| fv(g(r, "tok_s_e2e")))
        .collect::<Vec<_>>());
    let ttft = avg(&usage_rows
        .iter()
        .filter(|r| truthy(g(r, "ttft_ms")))
        .map(|r| fv(g(r, "ttft_ms")))
        .collect::<Vec<_>>());
    let cold_turns = usage_rows
        .iter()
        .filter(|r| iv(g(r, "cache_read_tokens")) == 0)
        .count();
    let write_turns = usage_rows
        .iter()
        .filter(|r| truthy(g(r, "cache_write_tokens")))
        .count();

    // models: model -> (n, usd, inp, cr, out, e2e list)
    let mut models: Vec<(String, i64, f64, i64, i64, i64, Vec<f64>)> = Vec::new();
    for r in usage_rows {
        let key = {
            let m = sv(g(r, "model"));
            if m.is_empty() {
                "?".to_string()
            } else {
                m
            }
        };
        let idx = match models.iter().position(|(k, ..)| *k == key) {
            Some(i) => i,
            None => {
                models.push((key.clone(), 0, 0.0, 0, 0, 0, Vec::new()));
                models.len() - 1
            }
        };
        let e = &mut models[idx];
        e.1 += 1;
        e.2 += fv(g(r, "cost_total"));
        e.3 += iv(g(r, "input_tokens"));
        e.4 += iv(g(r, "cache_read_tokens"));
        e.5 += iv(g(r, "output_tokens"));
        if truthy(g(r, "tok_s_e2e")) {
            e.6.push(fv(g(r, "tok_s_e2e")));
        }
    }

    // days: "YYYY-MM-DD" -> (n, usd, out, cr) — insertion ordered
    let mut day_order: Vec<String> = Vec::new();
    let mut days: std::collections::HashMap<String, (i64, f64, i64, i64)> =
        std::collections::HashMap::new();
    for r in usage_rows {
        let ts = sv(g(r, "ts"));
        let key = ts.get(..10).unwrap_or("").to_string();
        if !days.contains_key(&key) {
            day_order.push(key.clone());
        }
        let e = days.entry(key).or_insert((0, 0.0, 0, 0));
        e.0 += 1;
        e.1 += fv(g(r, "cost_total"));
        e.2 += iv(g(r, "output_tokens"));
        e.3 += iv(g(r, "cache_read_tokens"));
    }
    day_order.sort();

    let mean = |col: &str| -> f64 {
        avg(&ctx_rows
            .iter()
            .filter(|r| truthy(g(r, col)))
            .map(|r| fv(g(r, col)))
            .collect::<Vec<_>>())
    };
    let sections: &[(&str, f64)] = &[
        ("total", mean("prompt_total_tokens")),
        ("system", mean("system_tokens")),
        ("rules", mean("rules_tokens")),
        ("project", mean("project_tokens")),
        ("tools", mean("tools_tokens")),
        ("skills", mean("skills_tokens")),
        ("history", mean("history_tokens")),
        ("prompt", mean("prompt_tokens")),
    ];
    let mut est_ratio = 0.0;
    if !ctx_rows.is_empty() {
        let pairs: Vec<f64> = ctx_rows
            .iter()
            .zip(usage_rows.iter())
            .filter(|(r, u)| {
                truthy(g(r, "prompt_total_tokens"))
                    && (iv(g(u, "input_tokens")) + iv(g(u, "cache_read_tokens"))) > 0
            })
            .map(|(r, u)| {
                fv(g(r, "prompt_total_tokens"))
                    / (iv(g(u, "input_tokens")) + iv(g(u, "cache_read_tokens"))) as f64
            })
            .collect();
        est_ratio = avg(&pairs);
    }

    let mut skill_order: Vec<String> = Vec::new();
    let mut skill_tokens: std::collections::HashMap<String, Vec<i64>> =
        std::collections::HashMap::new();
    for r in ctx_rows {
        let raw = g(r, "skill_loaded_tokens");
        if !truthy(raw) {
            continue;
        }
        let data = match raw {
            Value::String(s) => serde_json::from_str::<Value>(s).unwrap_or(Value::Null),
            other => other.clone(),
        };
        if let Value::Object(o) = data {
            for (name, toks) in o {
                if !skill_tokens.contains_key(&name) {
                    skill_order.push(name.clone());
                }
                skill_tokens.entry(name).or_default().push(iv(&toks));
            }
        }
    }
    let mem_turns = ctx_rows
        .iter()
        .filter(|r| !sv(g(r, "memory_ids")).trim().is_empty())
        .count();

    let overview = vec![
        json!({"metric": "回合", "value": n.to_string()}),
        json!({"metric": "费用 USD", "value": format!("{cost:.4}")}),
        json!({"metric": "输出 tokens", "value": format!("{out}")}),
        json!({"metric": "推理 tokens", "value": format!("{reasoning}")}),
        json!({"metric": "未缓存输入", "value": format!("{inp}")}),
        json!({"metric": "缓存读", "value": format!("{cr}")}),
        json!({"metric": "缓存命中率", "value": format!("{hit}%")}),
        json!({"metric": "解码 tok/s", "value": if decode != 0.0 { decode.to_string() } else { "-".into() }}),
        json!({"metric": "端到端 tok/s", "value": if e2e != 0.0 { e2e.to_string() } else { "-".into() }}),
        json!({"metric": "首字延迟 ms", "value": if ttft != 0.0 { ttft.to_string() } else { "-".into() }}),
        json!({"metric": "空缓存回合", "value": cold_turns.to_string()}),
        json!({"metric": "写缓存回合", "value": write_turns.to_string()}),
    ];
    let mut models_sorted = models;
    models_sorted.sort_by(|a, b| b.2.partial_cmp(&a.2).unwrap_or(std::cmp::Ordering::Equal));
    let model_rows: Vec<Value> = models_sorted
        .iter()
        .map(|(m, n, usd, inp, cr, out, e2e)| {
            json!({
                "model": m, "n": n, "usd": round4(*usd), "inp": inp, "cr": cr, "out": out,
                "hit": pct(*cr as f64, (*inp + *cr) as f64), "e2e": avg(e2e),
            })
        })
        .collect();
    let ctx_tbl: Vec<Value> = CTX_SECTIONS
        .iter()
        .map(|(key, label)| {
            let tokens = sections
                .iter()
                .find(|(k, _)| k == key)
                .map(|(_, v)| *v)
                .unwrap_or(0.0);
            json!({"section": label, "tokens": tokens})
        })
        .collect();
    let day_rows: Vec<Value> = day_order
        .iter()
        .map(|d| {
            let (n, usd, out, cr) = days[d];
            json!({"day": d, "n": n, "usd": round4(usd), "out": out, "cr": cr})
        })
        .collect();
    let mut skill_sorted: Vec<(String, Vec<i64>)> = skill_order
        .iter()
        .map(|k| (k.clone(), skill_tokens[k].clone()))
        .collect();
    skill_sorted.sort_by(|a, b| b.1.iter().sum::<i64>().cmp(&a.1.iter().sum::<i64>()));
    let skill_tbl: Vec<Value> = skill_sorted
        .iter()
        .map(|(k, v)| {
            json!({
                "skill": k, "loads": v.len(),
                "avg_tokens": avg(&v.iter().map(|x| *x as f64).collect::<Vec<_>>()),
                "total_tokens": v.iter().sum::<i64>(),
            })
        })
        .collect();
    let _ = mem_turns;

    let note = format!(
        "费用/tok 为实测；上下文 tokens 为估算（chars / 校准 cpt；本样本估算/实测 = {est_ratio}）。命中率 = cacheRead / (cacheRead + 未缓存 input)。"
    );
    Some(block(
        "成本 / 缓存 / 上下文",
        "agent",
        &note,
        vec![
            table(
                overview,
                &[("metric", "指标"), ("value", "值")],
                "总览",
                None,
            ),
            table(
                model_rows,
                &[
                    ("model", "模型"),
                    ("n", "回合"),
                    ("usd", "USD"),
                    ("inp", "未缓存in"),
                    ("cr", "缓存读"),
                    ("out", "出"),
                    ("hit", "命中%"),
                    ("e2e", "e2e tok/s"),
                ],
                "按模型",
                Some(json!({"kind": "bars", "label": "model", "value": "usd", "unit": "USD"})),
            ),
            table(
                ctx_tbl,
                &[("section", "段"), ("tokens", "平均 tokens")],
                "上下文构成（估算）",
                Some(
                    json!({"kind": "stack", "label": "section", "value": "tokens", "unit": "tok"}),
                ),
            ),
            table(
                day_rows,
                &[
                    ("day", "日期"),
                    ("n", "回合"),
                    ("usd", "USD"),
                    ("out", "出"),
                    ("cr", "缓存读"),
                ],
                "每天成本曲线",
                Some(json!({"kind": "line", "label": "day", "value": "usd", "unit": "USD"})),
            ),
            table(
                skill_tbl,
                &[
                    ("skill", "加载的 skill"),
                    ("loads", "次数"),
                    ("avg_tokens", "平均 tokens"),
                    ("total_tokens", "合计 tokens"),
                ],
                "Skill 上下文成本（SKILL.md 正文）",
                Some(
                    json!({"kind": "bars", "label": "skill", "value": "total_tokens", "unit": "tok"}),
                ),
            ),
        ],
    ))
}

// ---------------------------------------------------------- build_metrics ----

const METRICS_SPEC: &[(&str, &str, &str, &str, Option<f64>, &str)] = &[
    ("turns", "回合", "", "flat", None, "窗口内回合数"),
    ("tools", "工具调用", "", "flat", None, "PostToolUse 次数"),
    (
        "tools_per_turn",
        "工具/回合",
        "",
        "down",
        Some(25.0),
        "单回合超过 25 次即过载",
    ),
    ("work_s", "工作秒", "s", "flat", None, "非等待工具墙钟"),
    ("wait_s", "等待秒", "s", "down", None, "轮询/等待墙钟"),
    ("wall_s", "墙钟", "s", "flat", None, "工作 + 等待"),
    (
        "waste_pct",
        "浪费占比",
        "%",
        "down",
        Some(20.0),
        "(等待 + 失败) / 墙钟",
    ),
    (
        "fail_n",
        "失败调用",
        "",
        "down",
        Some(0.0),
        "exit_code != 0",
    ),
    (
        "fail_rate_pct",
        "失败率",
        "%",
        "down",
        Some(5.0),
        "失败 / 工具",
    ),
    (
        "retry_n",
        "同回合重试",
        "",
        "down",
        Some(0.0),
        "同族失败后又跑一次",
    ),
    (
        "reread_extra",
        "多余读取",
        "",
        "down",
        None,
        "同一文件第 2 次起计数",
    ),
    (
        "reread_ratio",
        "重复读/文件",
        "次",
        "down",
        Some(2.0),
        "读取次数 / 去重文件数",
    ),
    (
        "locate_s",
        "定位搜索秒",
        "s",
        "down",
        None,
        "缺路径线索回合的搜索族墙钟",
    ),
    (
        "idle_s",
        "空档秒",
        "s",
        "down",
        None,
        ">600s（>10 分钟无事件）累计",
    ),
    (
        "extra_trips",
        "额外往返",
        "",
        "down",
        Some(0.0),
        "短催 + 纠正 + 催促",
    ),
    ("cost_usd", "费用", "USD", "down", None, "实测计费"),
    (
        "cache_hit_pct",
        "缓存命中率",
        "%",
        "up",
        Some(90.0),
        "cacheRead / (cacheRead + 未缓存 input)",
    ),
    (
        "cache_write_n",
        "写缓存回合",
        "",
        "down",
        Some(0.0),
        "前缀被改写",
    ),
    (
        "skill_tokens",
        "skill 重复传输",
        "tok",
        "down",
        None,
        "估算：正文 tokens × 剩余回合",
    ),
    (
        "loss_usd",
        "可归因损耗 $",
        "USD",
        "down",
        None,
        "损耗账本合计",
    ),
    ("loss_s", "可归因损耗秒", "s", "down", None, "损耗账本合计"),
];

/// The Agent's optimization surface: stable ids, now-value, target, direction.
pub fn build_metrics(summary: &Value, losses: &[Value], plane: &Value) -> Vec<Value> {
    let health = g(summary, "health");
    let flow = g(summary, "flow");
    let val = |mid: &str| -> Value {
        match mid {
            "turns" => g(summary, "n_turns").clone(),
            "tools" => g(summary, "n_tools").clone(),
            "tools_per_turn" => g(summary, "tools_per_turn").clone(),
            "work_s" => g(summary, "work_s").clone(),
            "wait_s" => g(summary, "wait_s").clone(),
            "wall_s" => json!(round1(fv(g(summary, "work_s")) + fv(g(summary, "wait_s")))),
            "fail_n" => g(summary, "fail_n").clone(),
            "fail_rate_pct" => g(health, "fail_rate").clone(),
            "retry_n" => g(summary, "retry_n").clone(),
            "waste_pct" => g(health, "waste_pct").clone(),
            "reread_extra" => {
                let v = g(summary, "reread_extra");
                if v.is_null() {
                    g(summary, "redundant_reads").clone()
                } else {
                    v.clone()
                }
            }
            "reread_ratio" => g(summary, "reread_ratio").clone(),
            "locate_s" => g(summary, "locate_s").clone(),
            "extra_trips" => g(flow, "extra_roundtrips").clone(),
            "idle_s" => g(summary, "idle_s").clone(),
            "cost_usd" => g(summary, "cost_usd").clone(),
            "cache_hit_pct" => g(summary, "cache_hit_pct").clone(),
            "cache_write_n" => g(plane, "cache_write_n").clone(),
            "skill_tokens" => g(plane, "skill_tokens").clone(),
            "loss_usd" => json!(round4(losses.iter().map(|l| fv(g(l, "usd"))).sum::<f64>())),
            "loss_s" => json!(round1(losses.iter().map(|l| fv(g(l, "s"))).sum::<f64>())),
            _ => Value::Null,
        }
    };
    let mut out = Vec::new();
    for (id, label, unit, dir, target, note) in METRICS_SPEC {
        let value = val(id);
        if value.is_null() {
            continue;
        }
        let target_v = target.map(|t| json!(t)).unwrap_or(Value::Null);
        out.push(json!({
            "id": id, "label": label, "unit": unit, "dir": dir, "target": target_v,
            "value": value, "baseline": null, "delta": null, "note": note,
        }));
    }
    out
}

/// Δ against the previous equal-length window. No baseline -> leave None.
pub fn attach_baseline(metrics: &mut [Value], base: &[Value]) {
    if base.is_empty() {
        return;
    }
    for m in metrics.iter_mut() {
        let id = sv(g(m, "id"));
        let Some(b) = base.iter().find(|b| sv(g(b, "id")) == id) else {
            continue;
        };
        let (Some(prev), Some(now)) = (optf(g(b, "value")), optf(g(m, "value"))) else {
            continue;
        };
        if let Some(o) = m.as_object_mut() {
            o.insert("baseline".into(), g(b, "value").clone());
            o.insert("delta".into(), json!(round4(now - prev)));
        }
    }
}

// ---------------------------------------------------------- build_losses ----

fn loss_finding(
    id: &str,
) -> Option<(
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    &'static str,
)> {
    let v = match id {
        "fail_retry" => (
            "失败与重试在烧时间",
            "命令/工具以非 0 退出，或同族失败后原样重试；错误没有转成新策略。",
            "失败先读 stderr/输出；同一命令族连续失败 2 次必须换方案，禁止原样重跑。",
            "- 同一命令族失败 2 次必须停下读错误、换方案；禁止原样重试。",
            "fail_n",
        ),
        "reread" => (
            "重复读：上下文在反复重建",
            "同一文件在窗口内被多次读取，说明每次都要重新建立上下文，而不是拿到接口/行号。",
            "任务里直接点名文件与函数/行号；Agent 读一次就把关键接口写进结论，不要跨回合全量重读。",
            "- 同一文件不要跨回合反复全量读；只读相关函数，读到的接口写进结论。",
            "reread_ratio",
        ),
        "wait_poll" => (
            "空等轮询占了墙钟",
            "CheckCommandStatus 一类轮询没有产出，只是等结果。",
            "长任务先给阶段结论再继续；轮询合并成一次检查，不要一步一等。",
            "- 长任务不要一步一停：完成子目标先给结论+下一步，再等确认。",
            "wait_s",
        ),
        "cache_write" => (
            "前缀被改写导致缓存重填",
            "会话进行中 system/AGENTS/skill 前缀变了，cacheWrite>0，下一回合整段重新预填。",
            "同一会话内冻结前缀；规则/skill 的改动放到下一会话。",
            "- 会话进行中不改前缀（AGENTS / skill / system）；改动留到下一会话。",
            "cache_write_n",
        ),
        "rework" => (
            "返工往返：整个回合是流程损耗",
            "用户用短催/纠正/催促推动，说明上一回合没有自驱到阶段结论，或方向没对齐。",
            "首条 prompt 给全 cwd/仓库/目标/验收；每完成子目标先给结论+下一步再停。",
            "- 长任务自驱到阶段结论再停，不要一步一等。",
            "extra_trips",
        ),
        "locate" => (
            "缺定位线索，先花时间找",
            "prompt 没给路径/仓库/文件，Agent 只能先用搜索族命令定位。",
            "prompt 里点名文件或符号；Agent 先定位文件再读，禁止用全库 rg 代替阅读。",
            "- 首条 prompt 给 cwd + 仓库根 + 目标文件；禁止用全库 rg/grep 代替阅读。",
            "locate_s",
        ),
        "idle" => (
            "长时间空档",
            "相邻事件间隔超过 10 分钟，中间没有可见进展（模型生成中不算）。",
            "长任务每 10 分钟或每个子目标给一次进展与结论。",
            "- 长任务每 10 分钟或每个子目标给一次进展。",
            "idle_s",
        ),
        "skill_bloat" => (
            "skill 正文重复进上下文",
            "整篇 SKILL.md 进 history，之后每回合重发。",
            "skill 只取命中段；加载前先确认该 skill 与当前任务相关。",
            "- skill 只取命中段；SKILL.md 正文不整篇反复灌注。",
            "skill_tokens",
        ),
        _ => return None,
    };
    Some(v)
}

pub struct LossInput {
    pub fail_n: i64,
    pub sec_fail: f64,
    pub sec_retry: f64,
    pub retry_n: i64,
    pub wait_s: f64,
    pub sec_locate: f64,
    pub locate_n: i64,
    pub sec_reread: f64,
    pub reread_n: i64,
    pub reread_detail: Vec<Value>,
    pub cache_write_tokens: i64,
    pub cache_write_n: i64,
    pub unit_usd: f64,
    pub cost_usd: f64,
    pub idle_s: f64,
    pub skill_resend_tokens: i64,
    pub total_wall: f64,
}

/// L1: five kinds of loss, each attributable to turns/events with s or usd.
/// Seconds are exclusive (priority fail > retry > reread > locate).
pub fn build_losses(turns: &[Turn], refs: &Refs, input: &LossInput) -> Vec<Value> {
    let mut losses: Vec<Value> = Vec::new();

    let add = |out: &mut Vec<Value>,
               lid: &str,
               label: &str,
               s: f64,
               usd: f64,
               kind: &str,
               refs_in: Vec<Value>,
               how: String| {
        let s = round1(s);
        let usd = round4(usd);
        if s < 5.0 && usd < 0.01 {
            return;
        }
        out.push(json!({
            "id": lid, "label": label, "s": s, "usd": usd, "kind": kind, "how": how,
            "refs": refs_in.into_iter().take(8).collect::<Vec<_>>(),
        }));
    };

    // fail_usd: per-turn failure share of the turn cost.
    let mut fail_usd = 0.0;
    for t in turns {
        if t.fails > 0 && t.cost_usd != 0.0 {
            fail_usd += t.cost_usd * (t.fails as f64 / (t.tools.max(1) as f64));
        }
    }
    add(
        &mut losses,
        "fail_retry",
        "失败与重试",
        input.sec_fail + input.sec_retry,
        fail_usd,
        "measured",
        refs.fail.clone(),
        format!(
            "失败 {} 次（{}s）+ 同回合重试 {} 次（{}s）；$ 按回合内失败工具占比分摊",
            input.fail_n,
            round1(input.sec_fail),
            input.retry_n,
            round1(input.sec_retry)
        ),
    );

    let reread_paths: std::collections::HashSet<String> = input
        .reread_detail
        .iter()
        .take(5)
        .map(|d| sv(g(d, "path")))
        .collect();
    let reread_refs: Vec<Value> = refs
        .read
        .iter()
        .filter(|r| reread_paths.contains(&sv(g(r, "path"))))
        .cloned()
        .collect();
    add(
        &mut losses,
        "reread",
        "重复读（上下文重建）",
        input.sec_reread,
        0.0,
        "measured",
        reread_refs,
        format!(
            "同一窗口内多余读取 {} 次（第 2 次起计，已扣除计入失败/定位的调用）",
            input.reread_n
        ),
    );
    if !input.reread_detail.is_empty() {
        if let Some(last) = losses.last_mut() {
            if let Some(o) = last.as_object_mut() {
                o.insert(
                    "detail".into(),
                    Value::Array(input.reread_detail.iter().take(6).cloned().collect()),
                );
            }
        }
    }

    add(
        &mut losses,
        "wait_poll",
        "空等轮询",
        input.wait_s,
        0.0,
        "measured",
        refs.wait.clone(),
        "CheckCommandStatus 类轮询墙钟；等待不产出".into(),
    );

    let cache_usd = input.cache_write_tokens as f64 * input.unit_usd;
    add(
        &mut losses,
        "cache_write",
        "前缀重填（缓存被改写）",
        0.0,
        cache_usd,
        "estimated",
        vec![],
        format!(
            "{} 个回合 cacheWrite>0，共 {} tokens 重新预填（按本窗混合单价 ${}/tok 估算）",
            input.cache_write_n,
            input.cache_write_tokens,
            round(input.unit_usd, 8)
        ),
    );

    let rework: Vec<&Turn> = turns
        .iter()
        .filter(|t| t.nudge || t.correction || t.push)
        .collect();
    let rework_s: f64 = rework.iter().map(|t| t.wall_s).sum();
    let rework_usd: f64 = rework.iter().map(|t| t.cost_usd).sum();
    let mut kinds: Vec<&str> = Vec::new();
    if rework.iter().any(|t| t.correction) {
        kinds.push("纠正");
    }
    if rework.iter().any(|t| t.nudge) {
        kinds.push("短催");
    }
    if rework.iter().any(|t| t.push) {
        kinds.push("催促");
    }
    add(&mut losses,
        "rework",
        "返工往返",
        rework_s,
        rework_usd,
        "measured",
        rework
            .iter()
            .map(|t| json!({"turn": t.index, "ts": t.ts, "event_id": t.event_id, "label": crate::mine::first_line(&t.prompt, 90)}))
            .collect(),
        format!(
            "{} 个回合由{}触发，整个回合视为损耗",
            rework.len(),
            if kinds.is_empty() { "流程摩擦".to_string() } else { kinds.join("/") }
        ),
    );

    add(
        &mut losses,
        "locate",
        "缺定位线索导致的搜索",
        input.sec_locate,
        0.0,
        "measured",
        refs.locate.clone(),
        format!(
            "{} 次 search 族调用落在没有路径/仓库线索的回合上",
            input.locate_n
        ),
    );

    add(
        &mut losses,
        "idle",
        "长时间空档",
        input.idle_s,
        0.0,
        "measured",
        vec![],
        "相邻事件间隔 >600s（>10 分钟无任何事件）的时间累计".into(),
    );

    let skill_usd = input.skill_resend_tokens as f64 * input.unit_usd;
    add(
        &mut losses,
        "skill_bloat",
        "上下文重复传输（skill 正文）",
        0.0,
        skill_usd,
        "estimated",
        vec![],
        format!(
            "skill 正文 {} tokens 在后续回合被重复传输（按混合单价估算）",
            input.skill_resend_tokens
        ),
    );

    for l in losses.iter_mut() {
        let s = fv(g(l, "s"));
        let usd = fv(g(l, "usd"));
        if let Some(o) = l.as_object_mut() {
            o.insert(
                "s_share".into(),
                json!(if input.total_wall != 0.0 {
                    round1(100.0 * s / input.total_wall)
                } else {
                    0.0
                }),
            );
            o.insert(
                "usd_share".into(),
                json!(if input.cost_usd != 0.0 {
                    round1(100.0 * usd / input.cost_usd)
                } else {
                    0.0
                }),
            );
        }
    }
    losses.sort_by(|a, b| {
        let ua = fv(g(a, "usd"));
        let ub = fv(g(b, "usd"));
        ub.partial_cmp(&ua)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                fv(g(b, "s"))
                    .partial_cmp(&fv(g(a, "s")))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });
    losses
}

fn round(x: f64, digits: u32) -> f64 {
    let f = 10f64.powi(digits as i32);
    (x * f).round() / f
}

fn sev_for(loss: &Value) -> &'static str {
    let usd = fv(g(loss, "usd"));
    let s = fv(g(loss, "s"));
    let share = {
        let us = if usd != 0.0 {
            fv(g(loss, "usd_share"))
        } else {
            0.0
        };
        let ss = if s != 0.0 {
            fv(g(loss, "s_share"))
        } else {
            0.0
        };
        us.max(ss)
    };
    if (usd != 0.0 && usd >= 0.5) || s >= 600.0 || share >= 35.0 {
        "high"
    } else if (usd != 0.0 && usd >= 0.15) || s >= 120.0 || share >= 12.0 {
        "med"
    } else {
        "note"
    }
}

// ------------------------------------------------------------- _insights ----

pub fn insights(losses: &[Value], metrics: &[Value], summary: &Value, plane: &Value) -> Vec<Value> {
    let mut out: Vec<Value> = Vec::new();

    let add = |out: &mut Vec<Value>,
               fid: &str,
               axis: &str,
               title: &str,
               claim: String,
               cause: &str,
               action: &str,
               gate: &str,
               metric_id: &str,
               impact_s: f64,
               impact_usd: f64,
               kind: &str,
               refs: Vec<Value>,
               evidence: String,
               sev_in: &str,
               confidence: f64| {
        let metric = metrics.iter().find(|m| sv(g(m, "id")) == metric_id);
        let mut sev = sev_in.to_string();
        if sev == "high" && (action.is_empty() || metric.is_none()) {
            sev = "med".to_string();
        }
        let metric_v = match metric {
            Some(m) => json!({
                "id": sv(g(m, "id")), "now": g(m, "value"), "target": g(m, "target"),
                "unit": g(m, "unit"), "dir": g(m, "dir"),
            }),
            None => Value::Null,
        };
        out.push(json!({
            "id": fid, "axis": axis, "audience": "agent", "use": "agents.md",
            "title": title, "text": claim, "cause": cause, "action": action, "gate": gate,
            "draft": gate, "evidence": evidence, "sev": sev,
            "impact": {"s": round1(impact_s), "usd": round4(impact_usd), "kind": kind},
            "metric": metric_v,
            "refs": refs.into_iter().take(8).collect::<Vec<_>>(),
            "confidence": confidence,
        }));
    };

    for loss in losses {
        let id = sv(g(loss, "id"));
        let Some(spec) = loss_finding(&id) else {
            continue;
        };
        let sev = sev_for(loss);
        let detail = g(loss, "detail");
        let mut top = String::new();
        if let Value::Array(ds) = detail {
            if !ds.is_empty() {
                top = " · top: ".to_string()
                    + &ds
                        .iter()
                        .take(3)
                        .map(|d| format!("{}×{}", sv(g(d, "path")), iv(g(d, "reads"))))
                        .collect::<Vec<_>>()
                        .join("、");
            }
        }
        let mut shares: Vec<String> = Vec::new();
        if truthy(g(loss, "s_share")) {
            shares.push(format!("s 占比 {}%", fv(g(loss, "s_share"))));
        }
        if truthy(g(loss, "usd_share")) {
            shares.push(format!("$ 占比 {}%", fv(g(loss, "usd_share"))));
        }
        let shares_txt = if shares.is_empty() {
            String::new()
        } else {
            format!(" · {}", shares.join(" · "))
        };
        let evidence = format!(
            "{} {}s / ${}（{}{}）{}",
            sv(g(loss, "label")),
            fv(g(loss, "s")),
            fv(g(loss, "usd")),
            sv(g(loss, "kind")),
            shares_txt,
            top
        );
        let usd = fv(g(loss, "usd"));
        let claim = format!(
            "{}。影响 {}s{}。",
            sv(g(loss, "how")),
            fv(g(loss, "s")),
            if usd != 0.0 {
                format!(" / ${usd}")
            } else {
                String::new()
            }
        );
        let refs = match g(loss, "refs") {
            Value::Array(a) => a.clone(),
            _ => vec![],
        };
        add(
            &mut out,
            &id,
            "agent",
            spec.0,
            claim,
            spec.1,
            spec.2,
            spec.3,
            spec.4,
            fv(g(loss, "s")),
            usd,
            &sv(g(loss, "kind")),
            refs,
            evidence,
            sev,
            if sv(g(loss, "kind")) == "measured" {
                0.9
            } else {
                0.6
            },
        );
    }

    let hit = g(summary, "cache_hit_pct");
    let usage_turns = iv(g(summary, "usage_turns"));
    if !hit.is_null() && usage_turns >= 20 && fv(hit) < 80.0 {
        let cold = iv(g(plane, "cold_turns"));
        add(
            &mut out,
            "cache_miss",
            "agent",
            "缓存命中率偏低",
            format!(
                "缓存命中 {}%（{} 个计费回合），{} 个回合完全未命中：前缀一改，整段 cache 失效。",
                fv(hit),
                usage_turns,
                cold
            ),
            "system / AGENTS / skill 前缀在会话中变化，或前缀结构不稳定。",
            "冻结会话内前缀；把大段规则前置并且保持字节稳定。",
            "- 会话进行中不改前缀（AGENTS / skill / system）；改动留到下一会话。",
            "cache_hit_pct",
            0.0,
            0.0,
            "measured",
            vec![],
            format!("cache_hit={}% cold_turns={}/{}", fv(hit), cold, usage_turns),
            if fv(hit) < 60.0 { "high" } else { "med" },
            0.8,
        );
    }

    if out.is_empty() {
        if iv(g(summary, "n_tools")) >= 20 {
            let tools = iv(g(summary, "n_tools"));
            let fail = iv(g(summary, "fail_n"));
            let waste = fv(g(g(summary, "health"), "waste_pct"));
            add(
                &mut out,
                "stable",
                "agent",
                "执行稳定",
                format!("{tools} 次工具、失败 {fail} 次；损耗账本在阈值以下。"),
                "没有可归因的损耗事件。",
                "保持当前前缀稳定性与定位方式。",
                "",
                "fail_n",
                0.0,
                0.0,
                "measured",
                vec![],
                format!("tools={tools} fail={fail} waste={waste}%"),
                "good",
                0.8,
            );
        } else {
            let nrows = iv(g(summary, "n_rows"));
            add(
                &mut out,
                "sparse",
                "user",
                "样本不足",
                "事件太少，还不构成可归因的损耗账本。".into(),
                &format!("窗口内只有 {nrows} 行事件。"),
                "多跑几个完整回合再看分析。",
                "",
                "turns",
                0.0,
                0.0,
                "measured",
                vec![],
                format!("n_rows={nrows}"),
                "note",
                1.0,
            );
        }
    }

    let order = |sev: &str| match sev {
        "high" => 0,
        "med" => 1,
        "note" => 2,
        "good" => 3,
        _ => 2,
    };
    out.sort_by(|a, b| {
        order(&sv(g(a, "sev")))
            .cmp(&order(&sv(g(b, "sev"))))
            .then_with(|| {
                fv(g(g(b, "impact"), "usd"))
                    .partial_cmp(&fv(g(g(a, "impact"), "usd")))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| {
                fv(g(g(b, "impact"), "s"))
                    .partial_cmp(&fv(g(g(a, "impact"), "s")))
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
    });
    out
}

// -------------------------------------------------------------- brief ----

pub fn fmt_s(v: &Value) -> String {
    let n = fv(v);
    if n >= 3600.0 {
        format!("{:.1}h", n / 3600.0)
    } else {
        format!("{}s", round1(n))
    }
}

fn agent_findings(findings: &[Value]) -> Vec<Value> {
    let keep = [
        "id",
        "sev",
        "axis",
        "title",
        "text",
        "cause",
        "action",
        "gate",
        "impact",
        "metric",
        "refs",
        "confidence",
        "ack",
    ];
    findings
        .iter()
        .map(|f| {
            let mut m = Map::new();
            for k in keep {
                let v = g(f, k);
                if !v.is_null() {
                    m.insert(k.into(), v.clone());
                }
            }
            Value::Object(m)
        })
        .collect()
}

pub fn agent_brief(result: &Value) -> String {
    let win = g(result, "window");
    let mut lines = vec![
        format!(
            "# 会话分析 · {}{}",
            sv(g(result, "scope")),
            if sv(g(result, "session_id")).is_empty() {
                String::new()
            } else {
                format!(" · {}", sv(g(result, "session_id")))
            }
        ),
        String::new(),
        format!(
            "窗口 {} → {} · {} 回合 · {} 工具{}",
            or_q(g(win, "from")),
            or_q(g(win, "to")),
            iv(g(win, "turns")),
            iv(g(win, "tools")),
            if truthy(g(win, "truncated")) {
                "  ⚠ 12000 行截断"
            } else {
                ""
            }
        ),
        String::new(),
        "## 指标（Δ = 对基线）".into(),
    ];
    if let Value::Array(ms) = g(result, "metrics") {
        for m in ms {
            let d = g(m, "delta");
            let delta = if d.is_null() {
                String::new()
            } else {
                format!("  Δ{:+} vs {}", fv(d), sv(g(m, "baseline")))
            };
            let tgt = if g(m, "target").is_null() {
                String::new()
            } else {
                format!(" → 目标 {}{}", sv(g(m, "target")), sv(g(m, "unit")))
            };
            lines.push(format!(
                "- {} ({}): {}{}{}{}",
                sv(g(m, "label")),
                sv(g(m, "id")),
                sv(g(m, "value")),
                sv(g(m, "unit")),
                tgt,
                delta
            ));
        }
    }
    lines.push(String::new());
    lines.push("## 损耗（按 $ / 秒）".into());
    if let Value::Array(ls) = g(result, "losses") {
        for l in ls {
            let usd = if truthy(g(l, "usd")) {
                format!(" / ${}", fv(g(l, "usd")))
            } else {
                String::new()
            };
            lines.push(format!(
                "- {}: {}s{}（{}）{}",
                sv(g(l, "label")),
                fv(g(l, "s")),
                usd,
                sv(g(l, "kind")),
                sv(g(l, "how"))
            ));
        }
    }
    lines.push(String::new());
    lines.push("## 结论与动作".into());
    if let Value::Array(fs) = g(result, "findings") {
        for f in fs {
            let imp = g(f, "impact");
            let usd = if truthy(g(imp, "usd")) {
                format!(" / ${}", fv(g(imp, "usd")))
            } else {
                String::new()
            };
            lines.push(format!(
                "### [{}] {}  ({}s{}, {})",
                sv(g(f, "sev")),
                sv(g(f, "title")),
                fv(g(imp, "s")),
                usd,
                sv(g(imp, "kind"))
            ));
            lines.push(format!("- 依据: {}", sv(g(f, "text"))));
            if truthy(g(f, "cause")) {
                lines.push(format!("- 原因: {}", sv(g(f, "cause"))));
            }
            if truthy(g(f, "action")) {
                lines.push(format!("- 动作: {}", sv(g(f, "action"))));
            }
            if truthy(g(f, "gate")) {
                lines.push(format!("- 闸门: {}", sv(g(f, "gate"))));
            }
            let mt = g(f, "metric");
            if !mt.is_null() {
                if g(mt, "target").is_null() {
                    lines.push(format!(
                        "  复测 {}={}{}",
                        sv(g(mt, "id")),
                        sv(g(mt, "now")),
                        sv(g(mt, "unit"))
                    ));
                } else {
                    lines.push(format!(
                        "  复测 {}={}→{}{}",
                        sv(g(mt, "id")),
                        sv(g(mt, "now")),
                        sv(g(mt, "target")),
                        sv(g(mt, "unit"))
                    ));
                }
            }
        }
    }
    let verify = g(result, "verify");
    lines.push(String::new());
    lines.push("## 复测".into());
    lines.push(format!("- {}", sv(g(verify, "rerun"))));
    lines.push(format!("- 期望: {}", sv(g(verify, "expect"))));
    let acked: Vec<&Value> = match g(result, "findings") {
        Value::Array(fs) => fs.iter().filter(|f| truthy(g(f, "ack"))).collect(),
        _ => vec![],
    };
    if !acked.is_empty() {
        let loopv = g(result, "loop");
        let closed = g(loopv, "closed").as_array().map(|a| a.len()).unwrap_or(0);
        let open = g(loopv, "open").as_array().map(|a| a.len()).unwrap_or(0);
        lines.push(String::new());
        lines.push(format!(
            "## 闭环核对（已声明 {} 条 · 闭环 {} · 未改善 {}）",
            iv(g(loopv, "total")),
            closed,
            open
        ));
        for f in acked {
            let a = g(f, "ack");
            let mt = g(f, "metric");
            let state = if g(a, "closed").as_bool() == Some(true) {
                "闭环"
            } else if g(a, "closed").as_bool() == Some(false) {
                "未改善"
            } else {
                "无目标"
            };
            lines.push(format!(
                "- [{}] {}: {} {} -> {}（目标 {}）=> {}{}",
                sv(g(a, "status")),
                sv(g(f, "title")),
                if sv(g(mt, "id")).is_empty() {
                    "-".into()
                } else {
                    sv(g(mt, "id"))
                },
                sv(g(a, "at_now")),
                sv(g(a, "now")),
                sv(g(mt, "target")),
                state,
                if truthy(g(a, "note")) {
                    format!(" · 备注: {}", sv(g(a, "note")))
                } else {
                    String::new()
                }
            ));
        }
    }
    lines.join("\n")
}

fn or_q(v: &Value) -> String {
    let s = sv(v);
    if s.is_empty() {
        "?".into()
    } else {
        s
    }
}

pub fn agent_view(result: &Value, base_metrics: &[Value]) -> Value {
    let mut metrics: Vec<Value> = match g(result, "metrics") {
        Value::Array(a) => a.clone(),
        _ => vec![],
    };
    attach_baseline(&mut metrics, base_metrics);
    let findings = match g(result, "findings") {
        Value::Array(a) => a.clone(),
        _ => vec![],
    };
    let stable: Vec<Value> = findings
        .iter()
        .filter(|f| sv(g(f, "sev")) == "good")
        .map(|f| g(f, "title").clone())
        .collect();
    let metric_ids: Vec<Value> = metrics
        .iter()
        .filter(|m| !g(m, "target").is_null())
        .map(|m| g(m, "id").clone())
        .collect();
    let mut view = json!({
        "view": "agent",
        "ok": truthy(g(result, "ok")),
        "scope": g(result, "scope"),
        "session_id": sv(g(result, "session_id")),
        "window": g(result, "window"),
        "metrics": metrics,
        "losses": g(result, "losses"),
        "findings": agent_findings(&findings),
        "turns": g(result, "turns"),
        "series": g(result, "series"),
        "loop": g(result, "loop"),
        "stable": stable,
        "verify": {
            "metric_ids": metric_ids,
            "rerun": sv(g(result, "rerun")),
            "expect": "同一窗口重跑，metric.value 向 target 移动；findings 里同一 id 不再出现或 sev 降低",
        },
    });
    let brief = agent_brief(&view);
    if let Some(o) = view.as_object_mut() {
        o.insert("brief".into(), json!(brief));
    }
    view
}

pub fn ts_str(epoch: f64) -> String {
    use chrono::TimeZone;
    let secs = epoch.floor() as i64;
    let micros = ((epoch - epoch.floor()) * 1_000_000.0).round() as u32;
    match chrono::Utc.timestamp_opt(secs, micros.min(999_999) * 1000) {
        chrono::LocalResult::Single(dt) => dt.format("%Y-%m-%d %H:%M:%S.%6f").to_string(),
        _ => String::new(),
    }
}

// -------------------------------------------------------------- acks ----

pub fn fetch_acks(rows: &[Value]) -> Value {
    let mut out = Map::new();
    for r in rows {
        let fid = sv(g(r, "finding_id"));
        if fid.is_empty() || out.contains_key(&fid) {
            continue;
        }
        out.insert(
            fid,
            json!({
                "status": if sv(g(r, "status")).is_empty() { "applied".into() } else { sv(g(r, "status")) },
                "ts": sv(g(r, "ts")),
                "note": sv(g(r, "note")),
                "metric_id": sv(g(r, "metric_id")),
                "at_now": g(r, "metric_now"),
                "target": g(r, "target"),
            }),
        );
    }
    Value::Object(out)
}

fn reached(value: &Value, target: &Value, direction: &Value) -> Option<bool> {
    let (v, t) = (optf(value), optf(target));
    let (v, t) = match (v, t) {
        (Some(v), Some(t)) => (v, t),
        _ => return None,
    };
    match direction.as_str() {
        Some("up") => Some(v >= t),
        Some("down") => Some(v <= t),
        _ => None,
    }
}

pub fn attach_acks(result: &mut Value, acks: &Value) {
    let findings = match g(result, "findings") {
        Value::Array(a) => a.clone(),
        _ => return,
    };
    let mut applied = Vec::new();
    let mut dismissed = Vec::new();
    let mut closed = Vec::new();
    let mut still_open = Vec::new();
    let mut untracked = Vec::new();
    let mut updated = findings.clone();
    for f in updated.iter_mut() {
        let id = sv(g(f, "id"));
        let Some(ack) = acks.get(&id) else {
            continue;
        };
        let metric = g(f, "metric").clone();
        let now = g(&metric, "now").clone();
        let mut ack = ack.clone();
        let at_now = g(&ack, "at_now").clone();
        let moved = match (optf(&at_now), optf(&now)) {
            (Some(a), Some(n)) => json!(round4(n - a)),
            _ => Value::Null,
        };
        let closed_v = reached(&now, g(&metric, "target"), g(&metric, "dir"));
        if let Some(o) = ack.as_object_mut() {
            o.insert("now".into(), now.clone());
            o.insert("moved".into(), moved);
            o.insert(
                "closed".into(),
                match closed_v {
                    Some(b) => json!(b),
                    None => Value::Null,
                },
            );
        }
        if let Some(o) = f.as_object_mut() {
            o.insert("ack".into(), ack.clone());
        }
        if sv(g(&ack, "status")) == "dismissed" {
            dismissed.push(json!(id));
            continue;
        }
        applied.push(json!(id));
        match closed_v {
            Some(true) => closed.push(json!(id)),
            Some(false) => still_open.push(json!(id)),
            None => untracked.push(json!(id)),
        }
    }
    if applied.is_empty() && dismissed.is_empty() {
        return;
    }
    let total = applied.len() + dismissed.len();
    if let Some(o) = result.as_object_mut() {
        o.insert("findings".into(), Value::Array(updated));
        o.insert(
            "loop".into(),
            json!({
                "applied": applied, "dismissed": dismissed, "closed": closed,
                "open": still_open, "untracked": untracked, "total": total,
            }),
        );
    }
}
