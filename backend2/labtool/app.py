"""
SITAA lab bench — Streamlit console for the FP-01 … FP-08 acceptance flow.

    cd backend && streamlit run labtool/app.py

Enrol a small team dataset, then drop in a fresh photo and watch every stage run in
order, ending in the matched person's identity card.

Split of work: the five ML models run on the Flask backend over HTTP; matching, scoring
and FIR decoding run here against the repo's own matching.py and fir.py. That is what
lets the bench work on a machine with no model weights and no TensorFlow, and it is the
only way to get a ranked candidate list — /authenticate returns just the winner.
"""

import sys
from pathlib import Path

BACKEND_DIR = Path(__file__).resolve().parent.parent
if str(BACKEND_DIR) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIR))

import altair as alt  # noqa: E402
import pandas as pd  # noqa: E402
import streamlit as st  # noqa: E402

from labtool import client, gallery, rank, stages, styles  # noqa: E402

SUPPORTED_TYPES = ["png", "jpg", "jpeg", "bmp", "webp"]
DEFAULT_BATCH = "labtool"

st.set_page_config(page_title="SITAA Lab Bench", page_icon="🫆", layout="wide")


# ══════════════════════════════════════════════════════════════════════════════
# SHARED HELPERS
# ══════════════════════════════════════════════════════════════════════════════

def tone_for(passed) -> str:
    return "pass" if passed else "fail"


def fmt_ms(value) -> str:
    return f"{value:,.0f} ms" if value else "—"


def render_stage(stage: stages.Stage) -> None:
    styles.stage_header(stage.ref, stage.title, stage.status, stage.summary,
                        stage.duration_ms, stage.server_ms)


def gallery_label(entry: dict) -> str:
    finger = stages.FINGER_NAMES.get(entry.get("finger_position", 0), "Unknown")
    return f"{entry.get('name', '?')} · {entry.get('uid', '?')} · {finger}"


# ══════════════════════════════════════════════════════════════════════════════
# STAGE RENDERERS — shared by the enrol and identify tabs
# ══════════════════════════════════════════════════════════════════════════════

def render_capture_stage(run: stages.PipelineRun) -> None:
    stage = run.stage("FP-01")
    if not stage:
        return
    render_stage(stage)

    left, right = st.columns(2)
    with left:
        if "original" in run.images:
            st.image(run.images["original"], caption="Captured frame", width="stretch")
    with right:
        if "cropped" in run.images:
            st.image(run.images["cropped"], caption="YOLO finger crop", width="stretch")
        else:
            st.info("No crop returned — the pipeline stopped before this point.")

    data = stage.data
    cols = st.columns(3)
    with cols[0]:
        styles.metric_card("Detection confidence", f"{data.get('detection_conf', 0.0):.3f}",
                           "YOLO best finger box", tone_for(stage.status == "pass"))
    with cols[1]:
        in_roi = data.get("in_roi")
        styles.metric_card("Centred in ROI", "Yes" if in_roi else "No",
                           data.get("roi_guidance") or "within 12% tolerance",
                           tone_for(bool(in_roi)) if in_roi is not None else "skip")
    with cols[2]:
        ox, oy = data.get("offset_x"), data.get("offset_y")
        styles.metric_card("Offset from centre",
                           f"{ox:+.0f}, {oy:+.0f}" if ox is not None else "—",
                           "x, y in pixels", "skip")


def render_quality_stage(run: stages.PipelineRun) -> None:
    stage = run.stage("FP-03")
    if not stage:
        return
    render_stage(stage)

    blur = stage.data.get("blur") or {}
    bright = stage.data.get("brightness") or {}
    glare = stage.data.get("glare") or {}

    cols = st.columns(4)
    with cols[0]:
        styles.metric_card("Blur", f"{blur.get('blur_score', 0):.1f}",
                           "Laplacian variance, floor 20.0",
                           "fail" if blur.get("is_blurry") else "pass")
    with cols[1]:
        too_dark, too_bright = bright.get("too_dark"), bright.get("too_bright")
        styles.metric_card("Brightness", f"{bright.get('brightness', 0):.1f}",
                           "acceptable band 50 – 210",
                           "fail" if (too_dark or too_bright) else "pass")
    with cols[2]:
        styles.metric_card("Glare", f"{glare.get('glare_fraction', 0) * 100:.2f}%",
                           f"method: {glare.get('method', 'n/a')}",
                           "fail" if glare.get("has_glare") else "pass")
    with cols[3]:
        issues = stage.data.get("issues") or []
        styles.metric_card("Issues", str(len(issues)),
                           issues[0] if issues else "none raised",
                           "fail" if issues else "pass")

    if stage.status == "warn":
        styles.note(
            "Quality did not pass. /enroll and /authenticate would reject this frame with "
            "HTTP 422 — the bench continues so you can see the rest of the chain."
        )


def render_liveness_stage(run: stages.PipelineRun) -> None:
    stage = run.stage("FP-02")
    if not stage:
        return
    render_stage(stage)
    if stage.status == "skip":
        return

    liveness = stage.data.get("liveness") or {}
    bypassed = stage.data.get("bypassed")

    cols = st.columns(2)
    with cols[0]:
        verdict = ("Not checked" if bypassed
                   else "Live" if liveness.get("is_live") else "Spoof suspected")
        styles.metric_card("Verdict", verdict, "MobileNetV2 anti-spoof", stage.status)
    with cols[1]:
        styles.metric_card("Confidence",
                           "—" if bypassed else f"{float(liveness.get('confidence', 0.0)):.3f}",
                           "softmax, live class", stage.status)

    if bypassed:
        styles.note(
            f"The anti-spoof model did not run — the backend reported "
            f"<code>{liveness.get('note') or liveness.get('error')}</code>. That means "
            f"ALLOW_LIVENESS_BYPASS is set on the server or the weights are missing. "
            f"FP-02 is not being exercised, and any capture will pass this stage, "
            f"including a photo of a photo."
        )


def render_multifinger_stage(run: stages.PipelineRun) -> None:
    stage = run.stage("FP-04")
    if stage:
        render_stage(stage)


def render_preprocess_stage(run: stages.PipelineRun) -> None:
    stage = run.stage("FP-05")
    if not stage:
        return
    render_stage(stage)

    if stage.status == "fail":
        if stage.data.get("detection_disagreement"):
            styles.note(
                "Worth logging against the backend: app.py runs detection twice with "
                "different settings — imgsz=320 in /quality_check and imgsz=800 in "
                "detect_and_crop — so the two can disagree on the same frame."
            )
        else:
            st.error(stage.data.get("error", "Pipeline failed"))
        return

    cols = st.columns(3)
    with cols[0]:
        if "cropped" in run.images:
            st.image(run.images["cropped"], caption="1 · Cropped finger",
                     width="stretch")
    with cols[1]:
        if "preprocessed" in run.images:
            st.image(run.images["preprocessed"],
                     caption="2 · Contact-equivalent (segmented, enhanced, binarised)",
                     width="stretch")
    with cols[2]:
        if "visualization" in run.images:
            st.image(run.images["visualization"], caption="3 · Minutiae overlay",
                     width="stretch")

    styles.note(
        "U²-Net produces the segmentation mask, Zero-DCE fires only when mean luminance is "
        "below 150, then an adaptive threshold binarises the ridges. The mask itself is "
        "applied server-side and is not returned as a separate image."
    )


def render_template_stage(run: stages.PipelineRun) -> None:
    stage = run.stage("FP-06")
    if not stage:
        return
    render_stage(stage)

    info = run.fir
    if not info or info.get("record") is None:
        st.error(info.get("error", "No FIR record was produced."))
        return

    cols = st.columns(4)
    with cols[0]:
        styles.metric_card("Record size", f"{info.get('record_bytes', 0):,} B",
                           "uncompressed 19794-4", "pass")
    with cols[1]:
        styles.metric_card("Image", f"{info.get('width')}×{info.get('height')}",
                           f"{info.get('resolution_dpi')} dpi", "pass")
    with cols[2]:
        norm = info.get("normalisation") or {}
        styles.metric_card("500 dpi normalisation", str(norm.get("method", "—")),
                           f"scale ×{norm.get('scale_factor', 1.0):.3f}"
                           if norm.get("scale_factor") else "", "pass")
    with cols[3]:
        ok = info.get("roundtrip_ok")
        styles.metric_card("Decode round trip", "Verified" if ok else "Failed",
                           "encoded, then parsed back here" if ok
                           else info.get("roundtrip_error", ""), tone_for(ok))

    if info.get("source") == "local":
        styles.note(
            f"The backend answered <code>{info.get('server_status')}</code> for "
            f"/export_fir, so this record was encoded here in the bench with the repo's "
            f"fir.py ({info.get('encode_ms', 0):.1f} ms). That endpoint ships in the "
            f"current commit — the deployed server is running older code. The record "
            f"itself is identical to what the backend would emit, but if you need to "
            f"demonstrate the <em>deployed</em> system producing FIRs, redeploy first."
        )

    left, right = st.columns(2)
    with left:
        if "preprocessed" in run.images:
            st.image(run.images["preprocessed"], caption="Source image, before encoding",
                     width="stretch")
    with right:
        if "fir_decoded" in run.images:
            st.image(run.images["fir_decoded"],
                     caption="Decoded back out of the FIR record",
                     width="stretch")

    with st.expander("ISO/IEC 19794-4 header, field by field"):
        header_rows = info.get("header_fields") or []
        if header_rows:
            st.dataframe(pd.DataFrame(header_rows), width="stretch", hide_index=True)
        record = info.get("record") or b""
        if record:
            st.caption("First 46 bytes, raw")
            st.code(record[:46].hex(" ").upper(), language=None)

    norm = info.get("normalisation") or {}
    if norm.get("method") == "passthrough":
        styles.note(
            "Ridge frequency could not be measured, so the image was left at its original "
            "scale rather than resampled by a guessed factor. The record is still "
            "conformant, but its 500 dpi claim is nominal."
        )


def render_timing_panel(run: stages.PipelineRun) -> None:
    totals = stages.budget_totals(run)
    cols = st.columns(4)
    with cols[0]:
        styles.metric_card("Capture → FIR, wall clock",
                           fmt_ms(totals["device_wall_ms"]),
                           "FP-01/02/03/05/06", "skip")
    with cols[1]:
        styles.metric_card("Server compute", fmt_ms(totals["server_compute_ms"]),
                           "as reported by the backend", "skip")
    with cols[2]:
        styles.metric_card("Local compute", fmt_ms(totals["local_compute_ms"]),
                           "FIR encoding in the bench", "skip")
    with cols[3]:
        styles.metric_card("Network + untimed", fmt_ms(totals["network_ms"]),
                           "wall clock minus both", "skip")

    styles.note(
        "These are server round trips, not on-device times. The spec's mandatory "
        "under-5-second on-device budget covers capture, QC, liveness, preprocessing and "
        "FIR creation — none of which run on a phone in this repo yet, so that budget is "
        "still unmeasured. Treat the figures above as an upper bound on the cloud half only. "
        "The bench also calls two or three endpoints per image, so the backend repeats "
        "detection and preprocessing each time."
    )

    metrics = (run.fir or {}).get("pipeline_metrics") or {}
    steps = metrics.get("steps") or []
    if steps:
        with st.expander("Server-side step breakdown (from /export_fir)"):
            st.dataframe(pd.DataFrame(steps), width="stretch", hide_index=True)
            st.caption(
                f"model inference {metrics.get('model_inference_sum_ms', 0):,.1f} ms · "
                f"overhead {metrics.get('system_overhead_ms', 0):,.1f} ms · "
                f"total {metrics.get('total_time_ms', 0):,.1f} ms"
            )


# ══════════════════════════════════════════════════════════════════════════════
# TAB 1 — DATASET
# ══════════════════════════════════════════════════════════════════════════════

def render_dataset_tab(base_url: str) -> None:
    st.subheader("Build the gallery")
    st.caption(
        "Upload one index-finger photo per person. Each photo runs the full FP-01 → FP-06 "
        "chain; the resulting minutiae set becomes that person's gallery template."
    )

    uploads = st.file_uploader("Dataset photos", type=SUPPORTED_TYPES,
                               accept_multiple_files=True, key="dataset_uploader")

    if uploads:
        with st.form("enrol_form"):
            st.markdown("**Assign an identity to each photo**")
            rows = []
            for index, upload in enumerate(uploads):
                thumb_col, name_col, uid_col, finger_col = st.columns([1, 2, 2, 2])
                with thumb_col:
                    st.image(upload, width="stretch")
                with name_col:
                    default_name = Path(upload.name).stem.replace("_", " ").replace("-", " ").title()
                    name = st.text_input("Name", value=default_name, key=f"name_{index}_{upload.name}")
                with uid_col:
                    uid = st.text_input("Unique ID", value=f"UID{index + 1:03d}",
                                        key=f"uid_{index}_{upload.name}")
                with finger_col:
                    label = st.selectbox("Finger", [c[0] for c in stages.FINGER_CHOICES],
                                         index=0, key=f"finger_{index}_{upload.name}")
                    finger_position = dict(stages.FINGER_CHOICES)[label]
                rows.append({"upload": upload, "name": name, "uid": uid,
                             "finger_position": finger_position})

            st.divider()
            also_server = st.checkbox(
                "Also enrol on the backend (writes into the server's uidai.db)", value=False)
            batch = st.text_input("Server batch name", value=DEFAULT_BATCH,
                                  disabled=not also_server)
            submitted = st.form_submit_button("Enrol all", type="primary")

        if submitted:
            _run_enrolment(base_url, rows, also_server, batch)

    st.divider()
    _render_gallery_grid()


def _run_enrolment(base_url: str, rows: list, also_server: bool, batch: str) -> None:
    progress = st.progress(0.0, text="Starting…")
    results = []

    for position, row in enumerate(rows):
        upload = row["upload"]
        progress.progress(position / max(1, len(rows)), text=f"Processing {upload.name}…")

        if not row["name"].strip() or not row["uid"].strip():
            results.append({"photo": upload.name, "status": "skipped",
                            "detail": "name and unique ID are both required"})
            continue

        image_bytes = upload.getvalue()
        run = stages.run_capture_pipeline(base_url, image_bytes,
                                          finger_position=row["finger_position"],
                                          filename=upload.name)

        if not run.ok:
            results.append({"photo": upload.name, "status": "rejected",
                            "detail": f"{run.fail_ref or '—'}: {run.fail_reason or 'unknown'}",
                            "minutiae": len(run.minutiae)})
            continue

        subject_id = gallery.upsert_subject(row["name"], row["uid"])
        gallery.upsert_template(
            subject_id=subject_id,
            finger_position=row["finger_position"],
            minutiae=run.minutiae,
            image_path=gallery.save_dataset_image(image_bytes, row["uid"],
                                                  row["finger_position"], upload.name),
            image_sha256=gallery.sha256_bytes(image_bytes),
            thumb_png=gallery.make_thumb(image_bytes),
            liveness_conf=float(run.liveness.get("confidence", 0.0)),
            det_conf=run.det_conf,
            qc=run.quality,
            fir_meta={k: v for k, v in (run.fir or {}).items() if k not in ("record", "header_fields")},
        )

        detail = f"{len(run.minutiae)} minutiae"
        status = "enrolled"
        if run.stage("FP-02") and run.stage("FP-02").status != "pass":
            status = "enrolled (liveness flagged)"
        if run.stage("FP-03") and run.stage("FP-03").status != "pass":
            detail += " · quality warning"

        if also_server and batch.strip():
            server_call = client.enroll(base_url, image_bytes, row["name"], row["uid"],
                                        batch.strip(), row["finger_position"], upload.name)
            detail += (" · server ok" if server_call.succeeded
                       else f" · server rejected: {server_call.error}")

        results.append({"photo": upload.name, "status": status, "detail": detail,
                        "minutiae": len(run.minutiae)})

    progress.progress(1.0, text="Done")

    st.markdown("**Enrolment results**")
    for result in results:
        line = f"**{result['photo']}** — {result['detail']}"
        if result["status"].startswith("enrolled"):
            st.success(f"{line} ({result['status']})")
        elif result["status"] == "rejected":
            st.error(f"{line} (rejected)")
        else:
            st.warning(f"{line} (skipped)")


def _render_gallery_grid() -> None:
    entries = gallery.list_templates()
    st.subheader(f"Gallery — {len(entries)} template(s), "
                 f"{len({e['uid'] for e in entries})} subject(s)")

    if not entries:
        st.info("Nothing enrolled yet. Upload photos above to build the gallery.")
        return

    for entry in entries:
        cols = st.columns([1, 3, 2, 2, 2, 1])
        with cols[0]:
            if entry.get("thumb_png"):
                st.image(bytes(entry["thumb_png"]), width="stretch")
        with cols[1]:
            st.markdown(f"**{entry['name']}**")
            st.caption(f"{entry['uid']} · "
                       f"{stages.FINGER_NAMES.get(entry['finger_position'], 'Unknown')}")
        with cols[2]:
            st.metric("Minutiae", entry["minutiae_count"])
        with cols[3]:
            st.metric("Liveness", f"{entry.get('liveness_conf') or 0:.2f}")
        with cols[4]:
            st.metric("Detection", f"{entry.get('det_conf') or 0:.2f}")
        with cols[5]:
            if st.button("Delete", key=f"del_{entry['id']}"):
                gallery.delete_template(entry["id"])
                st.rerun()

    st.caption(f"Templates stored in {gallery.DB_PATH} · photos in {gallery.DATASET_DIR}")


# ══════════════════════════════════════════════════════════════════════════════
# TAB 2 — IDENTIFY (1:N)
# ══════════════════════════════════════════════════════════════════════════════

def render_identify_tab(base_url: str, threshold: float, algorithm: str) -> None:
    st.subheader("Identify a probe photo")
    st.caption(
        "Upload a fresh capture of someone already in the gallery. Every FP stage runs in "
        "order, then the probe is scored against each enrolled template."
    )

    entries = gallery.list_templates()
    if not entries:
        st.warning("The gallery is empty — enrol some photos on the Dataset tab first.")
        return

    subjects = sorted({(e["uid"], e["name"]) for e in entries})

    top = st.columns([3, 2, 2])
    with top[0]:
        probe = st.file_uploader("Probe photo", type=SUPPORTED_TYPES, key="probe_uploader")
    with top[1]:
        mode = st.radio("Search scope", ["1:N — whole gallery", "1:10 — one person's fingers"],
                        key="search_mode")
    with top[2]:
        finger_label = st.selectbox("Probe finger (for the FIR record)",
                                    [c[0] for c in stages.FINGER_CHOICES], index=0)
        finger_position = dict(stages.FINGER_CHOICES)[finger_label]

    scoped = entries
    if mode.startswith("1:10"):
        claimed = st.selectbox("Claimed identity",
                               [f"{name} ({uid})" for uid, name in subjects])
        claimed_uid = claimed.rsplit("(", 1)[-1].rstrip(")")
        scoped = [e for e in entries if e["uid"] == claimed_uid]
        st.caption(f"Scoring against {len(scoped)} template(s) enrolled for {claimed_uid}.")

    if st.button("Run the pipeline", type="primary", disabled=probe is None):
        image_bytes = probe.getvalue()
        with st.spinner("Running FP-01 → FP-07…"):
            run = stages.run_capture_pipeline(base_url, image_bytes,
                                              finger_position=finger_position,
                                              filename=probe.name)
            ranked = rank.identify(run.minutiae, scoped, algorithm=algorithm) if run.minutiae else []
            verdict = rank.decide(ranked, threshold)

        probe_sha = gallery.sha256_bytes(image_bytes)
        probe_id = None
        if ranked:
            probe_id = gallery.log_probe(
                top1_uid=verdict["top1"]["uid"], top1_name=verdict["top1"]["name"],
                top1_score=verdict["top1_score"], top2_score=verdict["top2_score"],
                threshold=threshold, decision=verdict["decision"], scores=ranked,
                image_sha256=probe_sha)

        st.session_state["identify"] = {
            "run": run, "ranked": ranked, "verdict": verdict,
            "probe_id": probe_id, "probe_sha": probe_sha,
            "threshold": threshold, "scoped": len(scoped), "scoped_entries": scoped,
            "duplicate": gallery.find_template_by_sha(probe_sha),
        }

    state = st.session_state.get("identify")
    if not state:
        return

    st.divider()
    _render_identify_result(state, subjects)


def _render_identify_result(state: dict, subjects: list) -> None:
    run = state["run"]
    ranked = state["ranked"]
    verdict = state["verdict"]
    threshold = state["threshold"]

    if state.get("duplicate"):
        dup = state["duplicate"]
        st.error(
            f"This is byte-identical to the photo already enrolled for "
            f"**{dup['name']} ({dup['uid']})**. Matching a file against itself scores near "
            f"1.0 and proves nothing — use a separate capture as the probe."
        )

    render_capture_stage(run)
    render_quality_stage(run)
    render_liveness_stage(run)
    render_multifinger_stage(run)
    render_preprocess_stage(run)
    render_template_stage(run)

    if run.fail_ref and not run.ok:
        st.error(f"Pipeline stopped at {run.fail_ref}: {run.fail_reason}")

    if not ranked:
        st.warning("No candidates were scored — there is nothing to match against.")
        return

    # ── FP-07 Matching & scoring ─────────────────────────────────────────────
    styles.stage_header(
        "FP-07", "Matching & Scoring",
        "pass" if verdict["decision"] == "match" else "warn",
        f"{len(run.minutiae)} probe minutiae scored against {state['scoped']} gallery "
        f"template(s) with matching.match_templates · rank-1 {verdict['top1_score']:.4f} "
        f"vs threshold {threshold:.2f}",
    )

    frame = pd.DataFrame([{
        "Rank": index + 1,
        "Name": row["name"],
        "Unique ID": row["uid"],
        "Finger": stages.FINGER_NAMES.get(row["finger_position"], "Unknown"),
        "Gallery minutiae": row["minutiae_count"],
        "Score": row["score"],
        "Decision": "accept" if row["score"] >= threshold else "reject",
    } for index, row in enumerate(ranked)])

    table_col, chart_col = st.columns([3, 2])
    with table_col:
        st.dataframe(
            frame, width="stretch", hide_index=True,
            column_config={"Score": st.column_config.ProgressColumn(
                "Score", format="%.4f", min_value=0.0, max_value=1.0)},
        )
    with chart_col:
        chart_frame = frame.assign(Label=frame["Name"] + " · " + frame["Unique ID"])
        bars = (alt.Chart(chart_frame)
                .mark_bar()
                .encode(x=alt.X("Score:Q", scale=alt.Scale(domain=[0, 1])),
                        y=alt.Y("Label:N", sort="-x", title=None),
                        color=alt.Color("Decision:N",
                                        scale=alt.Scale(domain=["accept", "reject"],
                                                        range=["#1e6f45", "#c9ccd1"]),
                                        legend=None),
                        tooltip=["Name", "Unique ID", "Score", "Decision"]))
        rule = (alt.Chart(pd.DataFrame({"t": [threshold]}))
                .mark_rule(color="#b33a33", strokeDash=[5, 4])
                .encode(x="t:Q"))
        st.altair_chart(bars + rule, use_container_width=True)

    cols = st.columns(3)
    with cols[0]:
        styles.metric_card("Rank-1 score", f"{verdict['top1_score']:.4f}",
                           verdict["top1"]["name"] if verdict["top1"] else "—",
                           tone_for(verdict["decision"] == "match"))
    with cols[1]:
        styles.metric_card("Rank-2 score", f"{verdict['top2_score']:.4f}",
                           "next best candidate", "skip")
    with cols[2]:
        margin = verdict["margin"]
        styles.metric_card("Separation", f"{margin:+.4f}",
                           "rank-1 minus rank-2",
                           "pass" if margin > 0.05 else "warn")

    if verdict["decision"] == "match" and verdict["margin"] < 0.05:
        styles.note(
            "Rank 1 and rank 2 are within 0.05 of each other. The decision is technically "
            "above threshold but the gallery is not separating these two people — worth "
            "recapturing before trusting it."
        )

    # ── FP-08 End-to-end ─────────────────────────────────────────────────────
    matched = verdict["decision"] == "match"
    live_stage = run.stage("FP-02")
    spoofed = bool(live_stage and live_stage.status == "fail")

    styles.stage_header(
        "FP-08", "End-to-End Demo", "pass" if (matched and not spoofed) else "fail",
        "Identity resolved" if matched else "No candidate cleared the threshold",
    )

    if spoofed and matched:
        st.error(
            "A match was found, but the liveness stage rejected this capture. In the real "
            "flow /authenticate returns 422 spoof_detected and never reaches matching."
        )

    if matched:
        _render_identity_card(verdict, run)
    else:
        st.markdown(
            f"""
            <div class="id-card id-card--reject">
              <div class="id-hi">No match</div>
              <div class="id-row"><span class="id-key">Best candidate</span>
                <span class="id-val">{verdict['top1']['name'] if verdict['top1'] else '—'}</span></div>
              <div class="id-row"><span class="id-key">Score</span>
                <span class="id-val id-val--mono">{verdict['top1_score']:.4f}</span></div>
              <div class="id-row"><span class="id-key">Threshold</span>
                <span class="id-val id-val--mono">{threshold:.2f}</span></div>
            </div>
            """,
            unsafe_allow_html=True,
        )

    st.markdown("")
    render_timing_panel(run)

    # ── Compare every registered algorithm on this exact capture ─────────────
    st.divider()
    _render_algorithm_comparison(run, state["scoped_entries"], threshold)

    # ── Ground truth capture — this is what feeds the calibration tab ────────
    st.divider()
    st.markdown("**Record the true identity**")
    st.caption(
        "Tagging this run tells the Metrics tab which score was genuine and which were "
        "impostors. Without it there is no genuine distribution and no EER."
    )
    options = ["(not recorded)"] + [f"{name} ({uid})" for uid, name in subjects] + \
              ["Not enrolled — nobody in the gallery"]
    choice = st.selectbox("Who is this really?", options, key="truth_select")
    if st.button("Save ground truth", disabled=state.get("probe_id") is None):
        if choice.startswith("(not"):
            true_uid = ""
        elif choice.startswith("Not enrolled"):
            true_uid = "__none__"
        else:
            true_uid = choice.rsplit("(", 1)[-1].rstrip(")")
        gallery.set_probe_truth(state["probe_id"], true_uid)
        st.success("Recorded. The Metrics tab now includes this run.")


def _render_algorithm_comparison(run: stages.PipelineRun, scoped_entries: list,
                                 threshold: float) -> None:
    st.markdown("**Compare every algorithm on this capture**")
    st.caption(
        "The slow part — capture, liveness, preprocessing, minutiae extraction — only "
        "ran once, above. Scoring the same probe against every registered algorithm is "
        "local matching.py work and costs milliseconds each, so it always runs, not just "
        "when you ask for it."
    )

    if not run.minutiae:
        st.info("No probe minutiae to compare — the pipeline didn't reach FP-07.")
        return

    rows = rank.identify_all_algorithms(run.minutiae, scoped_entries, threshold)
    frame = pd.DataFrame([{
        "Algorithm": r["display"],
        "Rank-1": r["top1_name"] or "—",
        "Score": r["top1_score"],
        "Margin": r["margin"],
        "Decision": "accept" if r["decision"] == "match" else "reject",
    } for r in rows])

    table_col, chart_col = st.columns([3, 2])
    with table_col:
        st.dataframe(
            frame, width="stretch", hide_index=True,
            column_config={"Score": st.column_config.ProgressColumn(
                "Score", format="%.4f", min_value=0.0, max_value=1.0)},
        )
    with chart_col:
        bars = (alt.Chart(frame)
                .mark_bar()
                .encode(x=alt.X("Score:Q", scale=alt.Scale(domain=[0, 1])),
                        y=alt.Y("Algorithm:N", sort="-x", title=None),
                        color=alt.Color("Decision:N",
                                        scale=alt.Scale(domain=["accept", "reject"],
                                                        range=["#1e6f45", "#c9ccd1"]),
                                        legend=None),
                        tooltip=["Algorithm", "Rank-1", "Score", "Margin", "Decision"]))
        rule = (alt.Chart(pd.DataFrame({"t": [threshold]}))
                .mark_rule(color="#b33a33", strokeDash=[5, 4])
                .encode(x="t:Q"))
        st.altair_chart(bars + rule, use_container_width=True)

    agree = len({r["top1_uid"] for r in rows if r["top1_uid"]})
    if agree > 1:
        styles.note(
            f"The {len(rows)} algorithms don't agree on rank-1 — {agree} different people "
            f"were picked as the best candidate. Worth a closer look at which one is right "
            f"before trusting any single algorithm's answer here."
        )
    elif agree == 1 and rows:
        winner = next((r["top1_name"] for r in rows if r["top1_name"]), "")
        if winner:
            styles.note(f"Every algorithm that found a candidate agrees on rank-1: {winner}.")


def _render_identity_card(verdict: dict, run: stages.PipelineRun) -> None:
    top = verdict["top1"]
    entry = top["entry"]
    finger = stages.FINGER_NAMES.get(top["finger_position"], "Unknown")

    photo_col, detail_col = st.columns([1, 3])
    with photo_col:
        if entry.get("thumb_png"):
            st.image(bytes(entry["thumb_png"]), caption="Enrolled photo",
                     width="stretch")
    with detail_col:
        st.markdown(
            f"""
            <div class="id-card">
              <div class="id-hi">Hi {top['name']}</div>
              <div class="id-row"><span class="id-key">Unique ID</span>
                <span class="id-val id-val--mono">{top['uid']}</span></div>
              <div class="id-row"><span class="id-key">Finger</span>
                <span class="id-val">{finger} (ISO code {top['finger_position']})</span></div>
              <div class="id-row"><span class="id-key">Match score</span>
                <span class="id-val id-val--mono">{verdict['top1_score']:.4f}</span></div>
              <div class="id-row"><span class="id-key">Margin over rank 2</span>
                <span class="id-val id-val--mono">{verdict['margin']:+.4f}</span></div>
              <div class="id-row"><span class="id-key">Probe minutiae</span>
                <span class="id-val id-val--mono">{len(run.minutiae)}</span></div>
              <div class="id-row"><span class="id-key">Gallery minutiae</span>
                <span class="id-val id-val--mono">{top['minutiae_count']}</span></div>
              <div class="id-row"><span class="id-key">Enrolled</span>
                <span class="id-val">{entry.get('created_at', '—')}</span></div>
            </div>
            """,
            unsafe_allow_html=True,
        )


def _render_leaderboard(entries: list) -> None:
    """
    Every registered algorithm scored against the same real gallery, side by side —
    the live version of MATCHING_ALGORITHMS.md's results table, computed from your
    actual enrolled photos instead of synthetic data. This is the bake-off.
    """
    st.markdown("**Leaderboard — every algorithm on this gallery**")
    rows = rank.gallery_pairs_all_algorithms(entries)
    frame = pd.DataFrame([{
        "Algorithm": r["display"],
        "Impostor pairs": r["impostor_count"],
        "Mean impostor score": r["impostor_mean"],
        "Highest impostor score": r["impostor_max"],
        "Genuine pairs": r["genuine_count"],
        "Mean genuine score": r["genuine_mean"],
        "Separation": r["separation"],
    } for r in rows])

    has_genuine = any(r["genuine_count"] for r in rows)
    sort_col = "Separation" if has_genuine else "Mean impostor score"
    ascending = not has_genuine  # lower mean-impostor is "better" absent genuine data
    display_frame = frame.sort_values(sort_col, ascending=ascending, na_position="last")

    st.dataframe(
        display_frame, width="stretch", hide_index=True,
        column_config={
            "Mean impostor score": st.column_config.NumberColumn(format="%.4f"),
            "Highest impostor score": st.column_config.NumberColumn(format="%.4f"),
            "Mean genuine score": st.column_config.NumberColumn(format="%.4f"),
            "Separation": st.column_config.NumberColumn(format="%.4f"),
        },
    )

    if has_genuine:
        chart_frame = frame.dropna(subset=["Separation"])
        bars = (alt.Chart(chart_frame)
                .mark_bar()
                .encode(x=alt.X("Separation:Q"),
                        y=alt.Y("Algorithm:N", sort="-x", title=None),
                        color=alt.value("#1e6f45"),
                        tooltip=["Algorithm", "Mean genuine score",
                                "Mean impostor score", "Separation"]))
        st.altair_chart(bars, use_container_width=True)
        st.caption("Separation = mean genuine score − mean impostor score. Higher is "
                   "better — more room between the two distributions to place a threshold.")
    else:
        chart_frame = frame.dropna(subset=["Mean impostor score"])
        bars = (alt.Chart(chart_frame)
                .mark_bar()
                .encode(x=alt.X("Mean impostor score:Q"),
                        y=alt.Y("Algorithm:N", sort="x", title=None),
                        color=alt.value("#c9ccd1"),
                        tooltip=["Algorithm", "Impostor pairs", "Mean impostor score",
                                "Highest impostor score"]))
        st.altair_chart(bars, use_container_width=True)
        styles.note(
            "No genuine comparisons yet, so this ranks by mean impostor score only "
            "(lower is better — it means less overlap with where a genuine match should "
            "land). That's a proxy, not the real answer: an algorithm can suppress "
            "impostor scores by also suppressing genuine ones. Tag some Identify-tab "
            "probes with their true identity to get a real, separation-based ranking."
        )


# ══════════════════════════════════════════════════════════════════════════════
# TAB 3 — METRICS & CALIBRATION
# ══════════════════════════════════════════════════════════════════════════════

def render_metrics_tab(threshold: float, algorithm: str) -> None:
    st.subheader("Score separation and threshold calibration")

    entries = gallery.list_templates()
    probes = gallery.list_probes()
    labelled = [p for p in probes if p.get("true_uid")]

    if len(entries) < 2:
        st.info("Enrol at least two subjects to see any score separation.")
        return

    pairs = rank.gallery_pairs(entries, algorithm=algorithm)
    genuine_probe = rank.genuine_scores_from_probes(
        [p for p in labelled if p["true_uid"] != "__none__"])
    impostor_probe = rank.impostor_scores_from_probes(labelled)

    genuine_scores = [row["score"] for row in pairs["genuine"]] + \
                     [row["score"] for row in genuine_probe]
    impostor_scores = [row["score"] for row in pairs["impostor"]] + \
                      [row["score"] for row in impostor_probe]

    cols = st.columns(4)
    with cols[0]:
        styles.metric_card("Gallery templates", str(len(entries)),
                           f"{len({e['uid'] for e in entries})} subjects", "skip")
    with cols[1]:
        styles.metric_card("Impostor comparisons", str(len(impostor_scores)),
                           f"{len(pairs['impostor'])} gallery pairs + "
                           f"{len(impostor_probe)} from probes", "skip")
    with cols[2]:
        styles.metric_card("Genuine comparisons", str(len(genuine_scores)),
                           f"{len(pairs['genuine'])} gallery pairs + "
                           f"{len(genuine_probe)} from probes",
                           "pass" if genuine_scores else "warn")
    with cols[3]:
        styles.metric_card("Labelled probes", str(len(labelled)),
                           f"{len(probes)} runs logged", "skip")

    if not genuine_scores:
        styles.note(
            "No genuine comparisons yet. With one photo per person the gallery can only "
            "produce impostor pairs — run a probe on the Identify tab and tag it with the "
            "true identity to start building the genuine side."
        )

    st.divider()
    _render_leaderboard(entries)
    st.divider()

    st.markdown(f"**Deep dive: {rank.algorithm_display_name(algorithm)}**")
    st.caption("Pick a different algorithm in the sidebar to change everything below.")

    sweep = rank.sweep(genuine_scores, impostor_scores)

    # ── Distributions ────────────────────────────────────────────────────────
    st.markdown("**Score distributions**")
    dist_rows = [{"kind": "impostor", "score": s} for s in impostor_scores] + \
                [{"kind": "genuine", "score": s} for s in genuine_scores]
    dist_frame = pd.DataFrame(dist_rows)

    hist = (alt.Chart(dist_frame)
            .mark_bar(opacity=0.75)
            .encode(x=alt.X("score:Q", bin=alt.Bin(step=0.02),
                            scale=alt.Scale(domain=[0, 1]), title="match score"),
                    y=alt.Y("count()", title="comparisons", stack=None),
                    color=alt.Color("kind:N",
                                    scale=alt.Scale(domain=["impostor", "genuine"],
                                                    range=["#c9ccd1", "#1e6f45"]))))
    rule = (alt.Chart(pd.DataFrame({"t": [threshold]}))
            .mark_rule(color="#b33a33", strokeDash=[5, 4])
            .encode(x="t:Q"))
    st.altair_chart(hist + rule, use_container_width=True)

    # ── Threshold recommendation ─────────────────────────────────────────────
    st.markdown("**Operating threshold**")
    cols = st.columns(4)
    with cols[0]:
        styles.metric_card("In use today", f"{rank.DEFAULT_THRESHOLD:.2f}",
                           "hardcoded in app.py and slap_app.py", "warn")
    with cols[1]:
        recommended = sweep["recommended"]
        styles.metric_card("Recommended", f"{recommended:.3f}" if recommended else "—",
                           {"eer": "equal-error point",
                            "impostor_floor": "clears every impostor seen",
                            "none": "not enough data"}[sweep["basis"]],
                           "pass" if sweep["basis"] == "eer" else "warn")
    with cols[2]:
        styles.metric_card("EER", f"{sweep['eer'] * 100:.2f}%" if sweep["eer"] is not None else "—",
                           f"at threshold {sweep['eer_threshold']}"
                           if sweep["eer_threshold"] is not None else "needs genuine data",
                           "pass" if sweep["eer"] is not None else "skip")
    with cols[3]:
        highest = max(impostor_scores) if impostor_scores else 0.0
        styles.metric_card("Highest impostor score", f"{highest:.4f}",
                           "any threshold below this admits a false accept",
                           "fail" if highest >= threshold else "pass")

    if sweep["basis"] == "impostor_floor":
        styles.note(
            "This recommendation only guarantees FAR = 0 on the impostor scores collected so "
            "far. It is a floor, not a calibrated operating point — the false reject rate is "
            "unknown until labelled genuine comparisons exist."
        )
    elif sweep["basis"] == "eer" and sweep["genuine_count"] < 20:
        styles.note(
            f"The equal-error point is computed from only {sweep['genuine_count']} genuine "
            f"comparison(s). It is directionally useful but far too thin to submit — the "
            f"acceptance gate wants at least 20 users."
        )

    # ── FAR / FRR curve ──────────────────────────────────────────────────────
    if genuine_scores and impostor_scores:
        st.markdown("**FAR / FRR across the threshold range**")
        curve = pd.DataFrame([r for r in sweep["rows"]])
        melted = curve.melt(id_vars="threshold", value_vars=["far", "frr"],
                            var_name="metric", value_name="rate").dropna()
        line = (alt.Chart(melted)
                .mark_line(strokeWidth=2)
                .encode(x=alt.X("threshold:Q", scale=alt.Scale(domain=[0, 1])),
                        y=alt.Y("rate:Q", title="rate", scale=alt.Scale(domain=[0, 1])),
                        color=alt.Color("metric:N",
                                        scale=alt.Scale(domain=["far", "frr"],
                                                        range=["#b33a33", "#1e6f45"]))))
        st.altair_chart(line + rule, use_container_width=True)

    # ── Rank-1 accuracy, the acceptance gate ────────────────────────────────
    st.markdown("**User-wise rank-1 accuracy**")
    accuracy = rank.rank1_accuracy(
        [p for p in labelled if p["true_uid"] != "__none__"], threshold)
    if accuracy["overall"] is None:
        st.info("No labelled probes yet — tag a few identification runs to populate this.")
    else:
        cols = st.columns(3)
        with cols[0]:
            styles.metric_card("Overall", f"{accuracy['overall'] * 100:.1f}%",
                               f"{accuracy['correct']}/{accuracy['attempts']} probes",
                               "pass" if accuracy["overall"] > 0.85 else "fail")
        with cols[1]:
            styles.metric_card("Subjects tested", str(len(accuracy["per_subject"])),
                               "gate wants at least 20",
                               "pass" if len(accuracy["per_subject"]) >= 20 else "warn")
        with cols[2]:
            styles.metric_card("At threshold", f"{threshold:.2f}",
                               "change it in the sidebar", "skip")

        st.dataframe(pd.DataFrame([{
            "Name": row["name"], "Unique ID": row["uid"],
            "Attempts": row["attempts"], "Correct": row["correct"],
            "Accuracy": row["accuracy"],
        } for row in accuracy["per_subject"]]),
            width="stretch", hide_index=True,
            column_config={"Accuracy": st.column_config.ProgressColumn(
                "Accuracy", format="%.0f%%", min_value=0.0, max_value=1.0)})

    # ── Exports ──────────────────────────────────────────────────────────────
    st.divider()
    cols = st.columns(3)
    with cols[0]:
        pair_frame = pd.DataFrame(pairs["impostor"] + pairs["genuine"])
        st.download_button("Download gallery pair scores (CSV)",
                           pair_frame.to_csv(index=False).encode(),
                           file_name="labtool_pair_scores.csv", mime="text/csv",
                           disabled=pair_frame.empty)
    with cols[1]:
        sweep_frame = pd.DataFrame(sweep["rows"])
        st.download_button("Download FAR/FRR sweep (CSV)",
                           sweep_frame.to_csv(index=False).encode(),
                           file_name="labtool_far_frr.csv", mime="text/csv")
    with cols[2]:
        if st.button("Clear probe history"):
            gallery.clear_probes()
            st.rerun()


# ══════════════════════════════════════════════════════════════════════════════
# TAB 4 — SERVER
# ══════════════════════════════════════════════════════════════════════════════

EXPECTED_MODELS = [
    ("finger_detector", "YOLO finger detection (FP-01)"),
    ("liveness", "MobileNetV2 anti-spoof (FP-02)"),
    ("brightspot", "YOLO glare detector (FP-03)"),
    ("u2net", "U²-Net segmentation (FP-05)"),
    ("zero_dce", "Zero-DCE low-light enhancement (FP-05)"),
    ("minutiae", "MinutiaeNet extraction (FP-06/07)"),
]


def render_server_tab(base_url: str) -> None:
    st.subheader("Backend")

    edited = st.text_input("Base URL", value=base_url, key="base_url_input")
    cols = st.columns([1, 1, 4])
    with cols[0]:
        if st.button("Save URL"):
            client.save_base_url(edited)
            st.session_state["base_url"] = edited.strip().rstrip("/")
            st.rerun()
    with cols[1]:
        refresh = st.button("Check health")

    if refresh or "health" not in st.session_state:
        st.session_state["health"] = client.health(base_url)

    call = st.session_state["health"]
    if not call.ok:
        st.error(f"Cannot reach {base_url} — {call.error}")
        return

    payload = call.payload
    loaded = set(payload.get("models") or [])

    cols = st.columns(3)
    with cols[0]:
        styles.metric_card("Status", str(payload.get("status", "?")),
                           base_url, tone_for(payload.get("status") == "ok"))
    with cols[1]:
        styles.metric_card("Device", str(payload.get("device", "?")),
                           "where inference runs", "skip")
    with cols[2]:
        styles.metric_card("Round trip", fmt_ms(call.wall_ms), "GET /health", "skip")

    st.markdown("**Models loaded**")
    st.dataframe(pd.DataFrame([{
        "Model": key, "Purpose": purpose,
        "Loaded": "yes" if key in loaded else "no",
    } for key, purpose in EXPECTED_MODELS]), width="stretch", hide_index=True)

    missing = [key for key, _ in EXPECTED_MODELS if key not in loaded]
    if missing:
        st.error(
            "Missing on the server: " + ", ".join(missing) +
            ". Weights are loaded with an os.path.exists guard, so a missing file is "
            "skipped silently rather than raising — the affected stage will simply "
            "produce nothing."
        )
    if not payload.get("liveness_available", True):
        st.warning("Liveness is unavailable. check_liveness fails closed unless "
                   "ALLOW_LIVENESS_BYPASS=1 is set, which must never be set in deployment.")

    st.markdown("**Endpoints the bench uses**")
    if refresh or "endpoints" not in st.session_state:
        st.session_state["endpoints"] = {
            route: client.endpoint_present(base_url, route)
            for route in ("/quality_check", "/process", "/export_fir", "/enroll")
        }
    present = st.session_state["endpoints"]
    st.dataframe(pd.DataFrame([{"Endpoint": route,
                                "Deployed": "yes" if ok_ else "no — 404"}
                               for route, ok_ in present.items()]),
                 width="stretch", hide_index=True)

    if not present.get("/export_fir", True):
        st.warning(
            "This server predates /export_fir — that route ships in the commit that added "
            "the ISO 19794-4 encoder. FP-06 still works: the bench encodes the record "
            "locally with the same fir.py. Redeploy the backend if you need to show the "
            "deployed system producing FIRs."
        )

    with st.expander("Raw /health response"):
        st.json(payload)

    styles.note(
        "/health reports whether weights loaded, not whether a stage is actually enforced. "
        "Run a capture on the Identify tab and check the FP-02 card — a server with "
        "liveness bypassed still reports liveness_available: true here."
    )


# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

def main() -> None:
    styles.inject()
    gallery.init_db()

    if "base_url" not in st.session_state:
        st.session_state["base_url"] = client.load_base_url()
    base_url = st.session_state["base_url"]

    algorithms = rank.list_algorithms()

    with st.sidebar:
        st.markdown("### Bench settings")
        threshold = st.slider("Decision threshold", 0.0, 1.0, rank.DEFAULT_THRESHOLD, 0.01,
                              help="0.25 is what app.py hardcodes today. The Metrics tab "
                                   "recommends a calibrated value.")
        algorithm = st.selectbox(
            "Matching algorithm", algorithms,
            index=algorithms.index(rank.DEFAULT_ALGORITHM)
                  if rank.DEFAULT_ALGORITHM in algorithms else 0,
            format_func=rank.algorithm_display_name,
            help="Every algorithm registered in matching.py's _ALGORITHMS dict shows up "
                 "here automatically, numbered algorithm000+ — see MATCHING_ALGORITHMS.md "
                 "for what each one is. This is the algorithm every other control on this "
                 "page uses; the Identify and Metrics tabs also let you compare all of "
                 "them at once regardless of this selection.")
        st.divider()
        st.caption(f"Backend: {base_url}")
        st.caption(f"Gallery: {gallery.DB_PATH.name}")
        if algorithm == "legacy":
            st.warning("Legacy matcher active — absolute-space edges, scores 0 on a "
                       "rotated finger.")

    styles.header(
        "SITAA Lab Bench",
        "Contactless fingerprint pipeline · FP-01 → FP-08",
        f"matcher: {algorithm} · threshold {threshold:.2f}",
    )

    dataset_tab, identify_tab, metrics_tab, server_tab = st.tabs(
        ["Dataset", "Identify (1:N)", "Metrics & calibration", "Server"])

    with dataset_tab:
        render_dataset_tab(base_url)
    with identify_tab:
        render_identify_tab(base_url, threshold, algorithm)
    with metrics_tab:
        render_metrics_tab(threshold, algorithm)
    with server_tab:
        render_server_tab(base_url)


main()
