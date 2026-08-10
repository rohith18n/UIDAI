#!/opt/anaconda3/bin/python3
# -*- coding: utf-8 -*-
"""Generate a detailed PDF review of the UIDAI SITAA PDD problems."""

from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.enums import TA_LEFT, TA_JUSTIFY, TA_CENTER
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    HRFlowable, KeepTogether, PageBreak
)

OUT = "/Users/rajkumar/Desktop/uidi/UIDAI/UIDAI_SITAA_PDD_Review.pdf"

# ---------------------------------------------------------------- styles
styles = getSampleStyleSheet()

NAVY = colors.HexColor("#0B2545")
BLUE = colors.HexColor("#13315C")
ACCENT = colors.HexColor("#134074")
LIGHT = colors.HexColor("#EEF2F7")
RED = colors.HexColor("#B00020")
AMBER = colors.HexColor("#9A6700")
GREEN = colors.HexColor("#1B5E20")
GREY = colors.HexColor("#444444")

def S(name, **kw):
    base = kw.pop("parent", styles["Normal"])
    return ParagraphStyle(name, parent=base, **kw)

title_style = S("TitleX", fontName="Helvetica-Bold", fontSize=20,
                textColor=NAVY, leading=24, spaceAfter=4)
subtitle_style = S("SubX", fontName="Helvetica", fontSize=11,
                   textColor=GREY, leading=15, spaceAfter=2)
h1 = S("H1", fontName="Helvetica-Bold", fontSize=14, textColor=colors.white,
       leading=18, spaceBefore=14, spaceAfter=8, leftIndent=6)
h2 = S("H2", fontName="Helvetica-Bold", fontSize=11.5, textColor=ACCENT,
       leading=15, spaceBefore=10, spaceAfter=3)
body = S("Body", fontName="Helvetica", fontSize=9.7, textColor=colors.HexColor("#1A1A1A"),
         leading=14, alignment=TA_JUSTIFY, spaceAfter=5)
small = S("Small", fontName="Helvetica", fontSize=8.6, textColor=GREY, leading=12)
label = S("Label", fontName="Helvetica-Bold", fontSize=9.2, textColor=BLUE, leading=12)
cell = S("Cell", fontName="Helvetica", fontSize=8.7, textColor=colors.HexColor("#1A1A1A"), leading=12)
cellb = S("CellB", fontName="Helvetica-Bold", fontSize=8.7, textColor=colors.white, leading=12)
bullet = S("Bullet", parent=body, leftIndent=12, bulletIndent=2, spaceAfter=3)

def sev_color(s):
    return {"HIGH": RED, "MED": AMBER, "LOW": GREEN}[s]

story = []

def section_header(text):
    t = Table([[Paragraph(text, h1)]], colWidths=[170*mm])
    t.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, -1), NAVY),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
    ]))
    story.append(Spacer(1, 6))
    story.append(t)
    story.append(Spacer(1, 4))

def problem(num, sev, where, title_txt, what, why, fix):
    """One problem block as a bordered table."""
    sc = sev_color(sev)
    head_tbl = Table(
        [[Paragraph(f"#{num}", S("num", fontName="Helvetica-Bold", fontSize=11, textColor=colors.white)),
          Paragraph(title_txt, S("ptitle", fontName="Helvetica-Bold", fontSize=10.3, textColor=colors.white, leading=13)),
          Paragraph(sev, S("sev", fontName="Helvetica-Bold", fontSize=8.5, textColor=colors.white, alignment=TA_CENTER))]],
        colWidths=[12*mm, 138*mm, 20*mm])
    head_tbl.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (1, 0), BLUE),
        ("BACKGROUND", (2, 0), (2, 0), sc),
        ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
    ]))

    rows = [
        [Paragraph("Where", label), Paragraph(where, cell)],
        [Paragraph("Problem", label), Paragraph(what, cell)],
        [Paragraph("Why it matters", label), Paragraph(why, cell)],
        [Paragraph("Recommended fix", label), Paragraph(fix, cell)],
    ]
    body_tbl = Table(rows, colWidths=[28*mm, 142*mm])
    body_tbl.setStyle(TableStyle([
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("BACKGROUND", (0, 0), (0, -1), LIGHT),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("LINEBELOW", (0, 0), (-1, -2), 0.4, colors.HexColor("#CBD5E1")),
        ("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor("#94A3B8")),
    ]))
    story.append(KeepTogether([head_tbl, body_tbl, Spacer(1, 9)]))

# ================================================================ COVER
story.append(Spacer(1, 6))
story.append(Paragraph("UIDAI SITAA &mdash; Project Design Document", title_style))
story.append(Paragraph("Critical Review: Problems, Gaps &amp; Inconsistencies", subtitle_style))
story.append(HRFlowable(width="100%", thickness=1.4, color=NAVY, spaceBefore=6, spaceAfter=8))

meta = Table([
    [Paragraph("Challenge", label), Paragraph("Contactless Fingerprint Authentication", cell)],
    [Paragraph("Document", label), Paragraph("Project Design Document v1.0", cell)],
    [Paragraph("Review date", label), Paragraph("30 May 2026", cell)],
    [Paragraph("Scope", label), Paragraph("Technical, security, compliance and completeness review of the PDD prior to MSH submission", cell)],
], colWidths=[28*mm, 142*mm])
meta.setStyle(TableStyle([
    ("VALIGN", (0, 0), (-1, -1), "TOP"),
    ("BACKGROUND", (0, 0), (0, -1), LIGHT),
    ("TOPPADDING", (0, 0), (-1, -1), 4),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ("LEFTPADDING", (0, 0), (-1, -1), 6),
    ("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor("#94A3B8")),
    ("LINEBELOW", (0, 0), (-1, -2), 0.4, colors.HexColor("#CBD5E1")),
]))
story.append(meta)
story.append(Spacer(1, 10))

# How to read
story.append(Paragraph("How to read this report", h2))
story.append(Paragraph(
    "Each problem is rated by severity and split into <b>Group A</b> (objective inconsistencies that are "
    "hard to dispute &mdash; fix these first), <b>Groups B&ndash;E</b> (technical, security and compliance "
    "concerns an expert reviewer is likely to raise), and <b>Group F</b> (items missing relative to the "
    "project's own stated goals). Severity reflects the risk to a successful pilot evaluation, not the "
    "effort to fix.", body))

leg = Table([[
    Paragraph("HIGH", cellb), Paragraph("Likely to be challenged hard / blocks credibility", small),
    Paragraph("MED", cellb), Paragraph("Should be addressed before submission", small),
    Paragraph("LOW", cellb), Paragraph("Polish / completeness", small),
]], colWidths=[16*mm, 53*mm, 14*mm, 47*mm, 14*mm, 26*mm])
leg.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (0, 0), RED),
    ("BACKGROUND", (2, 0), (2, 0), AMBER),
    ("BACKGROUND", (4, 0), (4, 0), GREEN),
    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ("TOPPADDING", (0, 0), (-1, -1), 3),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
    ("LEFTPADDING", (0, 0), (-1, -1), 4),
]))
story.append(leg)
story.append(Spacer(1, 6))

# Summary count table
story.append(Paragraph("Summary", h2))
summ = Table([
    [Paragraph("Group", cellb), Paragraph("Theme", cellb), Paragraph("Items", cellb), Paragraph("Highest severity", cellb)],
    [Paragraph("A", cell), Paragraph("Internal inconsistencies (factual)", cell), Paragraph("4", cell), Paragraph("MED", cell)],
    [Paragraph("B", cell), Paragraph("Domain-mismatch / validation gaps", cell), Paragraph("4", cell), Paragraph("HIGH", cell)],
    [Paragraph("C", cell), Paragraph("Architecture feasibility", cell), Paragraph("4", cell), Paragraph("HIGH", cell)],
    [Paragraph("D", cell), Paragraph("Security / cryptography", cell), Paragraph("3", cell), Paragraph("MED", cell)],
    [Paragraph("E", cell), Paragraph("Compliance / spec questions", cell), Paragraph("3", cell), Paragraph("MED", cell)],
    [Paragraph("F", cell), Paragraph("Missing items vs stated goals", cell), Paragraph("2", cell), Paragraph("MED", cell)],
], colWidths=[16*mm, 96*mm, 22*mm, 36*mm])
summ.setStyle(TableStyle([
    ("BACKGROUND", (0, 0), (-1, 0), ACCENT),
    ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.white, LIGHT]),
    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
    ("TOPPADDING", (0, 0), (-1, -1), 4),
    ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
    ("LEFTPADDING", (0, 0), (-1, -1), 6),
    ("BOX", (0, 0), (-1, -1), 0.6, colors.HexColor("#94A3B8")),
    ("INNERGRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#CBD5E1")),
]))
story.append(summ)
story.append(Spacer(1, 4))
story.append(Paragraph(
    "<b>Priority guidance:</b> lead with Group A (quick objective fixes), then proactively address "
    "B5, B6, C9 and C11 in the narrative &mdash; these four (PAD domain mismatch, contactless TAR realism, "
    "the TEE-inference claim, and entry-level camera macro-focus feasibility) are the points an expert "
    "evaluator will hit hardest. Getting ahead of them reads as competence rather than a gap.", small))

story.append(PageBreak())

# ================================================================ GROUP A
section_header("Group A &mdash; Internal Inconsistencies (Factual)")

problem(
    1, "MED",
    "&sect;2.1 Layer 3 vs &sect;2.3 model table",
    "U2-Net size contradicts itself",
    "Layer 3 describes U2-Net as a &ldquo;lightweight U2-Net model (1.8&nbsp;MB INT8-quantised)&rdquo;, but the "
    "technology-stack table lists U2-Net at <b>~4.7M parameters</b>.",
    "A 4.7M-parameter model quantised to INT8 is approximately 4.7&nbsp;MB, not 1.8&nbsp;MB, and 4.7M "
    "parameters is not credibly &ldquo;lightweight&rdquo;. A reviewer comparing the two pages will see a "
    "numbers mismatch and question the rest of the model-size figures.",
    "Decide on one authoritative figure. If you are using the small variant (U2-Netp, ~1.1M params) say so; "
    "otherwise correct either the 1.8&nbsp;MB or the 4.7M figure so they are internally consistent.")

problem(
    2, "MED",
    "&sect;2.3 SDK Distribution vs ML Runtime",
    "Minimum API 21 conflicts with NNAPI / Hexagon reliance",
    "The SDK claims a <b>minimum API level of 21 (Android 5.0)</b>, while the ML runtime is &ldquo;TensorFlow "
    "Lite with NNAPI delegate (Hexagon DSP, Adreno GPU)&rdquo;.",
    "The NNAPI delegate requires API 27+, and robust DSP/Hexagon acceleration requires newer versions still. "
    "On API 21&ndash;26 the pipeline silently falls back to CPU and the 2.0-second latency budget is no longer "
    "achievable. Advertising an API-21 floor for a hardware-accelerated biometric pipeline is misleading even "
    "with the &ldquo;certified for API 28+&rdquo; caveat.",
    "State a realistic functional floor for the accelerated path (e.g. API 27/28) and describe exactly what "
    "the SDK does on lower API levels (reject, or CPU fallback with a stated latency penalty).")

problem(
    3, "MED",
    "&sect;1.4, &sect;2.4, &sect;3.1, &sect;3.2, &sect;3.4, Appendices A&ndash;D",
    "Timeline, team and governance sections are blank",
    "Milestones M1&ndash;M5 all read &ldquo;Week ___&rdquo;; Stakeholder Mapping (&sect;1.4), Team Structure "
    "(&sect;3.1), Resource Adequacy (&sect;3.2) and Governance (&sect;3.4) are empty; Appendices A&ndash;D are "
    "all unchecked / not attached.",
    "As submitted, the document has no committed schedule, no named team, and no governance cadence. "
    "Evaluators read empty planning sections as low execution readiness, regardless of how strong the "
    "technical sections are.",
    "Fill in concrete target weeks, named roles, hardware/infrastructure/partner lines, a reporting cadence "
    "and escalation path, and attach (or mark a dated plan for) Appendices A&ndash;D before submission.")

problem(
    4, "MED",
    "&sect;2.1 Layer 5 &amp; &sect;4.1",
    "DSA signing is under-specified and an unusual choice",
    "The design specifies a &ldquo;DSA signature of the biometric hash&rdquo; with a device-specific key, but "
    "gives no key size and chooses DSA over RSA/ECDSA.",
    "For UIDAI device attestation, DSA is an unusual selection; it also fails catastrophically (private-key "
    "recovery) if the per-signature nonce is ever reused or weakly generated. An unspecified key size invites "
    "a follow-up question.",
    "Either justify DSA against the UIDAI device-key specification and state the key size and nonce-generation "
    "guarantee, or switch to ECDSA/RSA in line with the rest of the crypto stack.")

# ================================================================ GROUP B
section_header("Group B &mdash; Domain-Mismatch &amp; Validation Gaps")

problem(
    5, "HIGH",
    "&sect;2.1 Layer 2; &sect;1.3 KR&nbsp;5",
    "Passive PAD is trained/evaluated on the wrong domain",
    "The passive PAD is a MobileNetV3-Small &ldquo;trained and evaluated on LivDet-Fingerprint 2023&rdquo;, "
    "and the spoof-resistance KR (APCER&nbsp;&lt;&nbsp;5% / BPCER&nbsp;&lt;&nbsp;3%) is implicitly drawn from it.",
    "LivDet-Fingerprint is a <b>contact-sensor</b> spoof corpus. Your attack surface is a <b>contactless "
    "camera</b> (printed photo or screen replay held in front of the lens, 3D molds at a distance). The "
    "spoof textures, optics and artefacts are entirely different, so LivDet-derived APCER/BPCER numbers do "
    "not transfer. This is the single easiest point for an evaluator to attack.",
    "Collect or cite a contactless PAD dataset, or explicitly label the current numbers as a contact-domain "
    "baseline with a plan to revalidate on contactless attacks during M4. Do not present LivDet numbers as "
    "the pilot KR without that caveat.")

problem(
    6, "HIGH",
    "&sect;1.3 KR&nbsp;1; &sect;2.1 Layer 4",
    "90% TAR is a contact-based extrapolation against a contact gallery",
    "The headline accuracy KR is TAR&nbsp;&ge;&nbsp;90% at FAR&nbsp;0.01%, flagged as &ldquo;extrapolated "
    "from contact-based benchmarks&rdquo; to be revalidated at M4.",
    "The real task is matching a <b>contactless probe against UIDAI&rsquo;s contact-based gallery</b>. "
    "Cross-domain (contactless-to-contact) matching in the published literature typically sits well below "
    "90% at FAR&nbsp;0.01%. Even with the asterisk, stating 90% invites the &ldquo;unrealistic target&rdquo; "
    "critique and sets up the pilot to look like a miss.",
    "Frame the 90% explicitly as a contact-to-contact reference, set a separate, evidence-based contactless-to-"
    "contact target band, and describe the C2CL domain-adaptation step as the mechanism to close the gap.")

problem(
    7, "MED",
    "&sect;1.3 KR&nbsp;2; &sect;2.1 Layer 3 step&nbsp;7",
    "NFIQ2 &ge; 60 applied to contactless captures",
    "Capture-quality KR requires an NFIQ2 surrogate score &ge;&nbsp;60 on &gt;&nbsp;85% of accepted captures, "
    "using an on-device MobileNetV3 surrogate correlated against NFIQ2 offline.",
    "NFIQ2 is defined and validated for 500&nbsp;DPI grayscale <b>contact</b> fingerprints. Applying it (even "
    "via a surrogate) to rectified contactless imagery is methodologically questionable, and &ge;&nbsp;60 on "
    "&gt;&nbsp;85% of captures is aggressive for camera-based acquisition.",
    "Acknowledge the NFIQ2 contactless limitation, report the surrogate-to-NFIQ2 correlation you actually "
    "achieve, and consider a contactless-appropriate quality target rather than a borrowed contact threshold.")

problem(
    8, "MED",
    "&sect;2.3 Interoperability Targets; &sect;4.1",
    "Interoperability validated with proxy matchers, not the real AFIS",
    "Cross-sensor interoperability is validated using SourceAFIS and BOZORTH3 against the Mantra MFS100 and "
    "Startek FM220U, supplemented by NIST BIOMDI conformance.",
    "The production matcher is UIDAI&rsquo;s proprietary AFIS. Good scores on open-source matchers do not "
    "guarantee equivalent behaviour on AFIS, so the validation methodology is a proxy that may not predict "
    "the outcome that actually matters.",
    "Keep the open-matcher validation as an early signal, but state clearly that it is a proxy, and make "
    "AFIS sandbox validation an explicit M4 dependency with a fallback plan if sandbox access is delayed.")

# ================================================================ GROUP C
section_header("Group C &mdash; Architecture Feasibility")

problem(
    9, "HIGH",
    "&sect;2.1 Layers 4&ndash;5; &sect;2.2 Privacy-by-Design",
    "&ldquo;Layers 4 &amp; 5 run inside the hardware TEE&rdquo; is not realistic",
    "The target production architecture claims that template generation (Layer 4 &mdash; LEADER, U2-Net, "
    "TFLite inference) and the security layer execute &ldquo;within the device&rsquo;s hardware TEE&rdquo;.",
    "Commodity Android TEEs (TrustZone) have very limited memory and compute and provide no TFLite/NNAPI "
    "runtime. You cannot run a U2-Net / LEADER inference graph inside the TEE &mdash; TEEs are for key storage "
    "and crypto operations only. As written, this claim suggests a misunderstanding of the platform and will "
    "draw a pointed question.",
    "Scope the TEE to Layer 5 cryptographic / signing operations only. Describe Layer 4 inference as running "
    "in the app&rsquo;s native sandbox with in-memory-only buffers, and keep the &ldquo;never persisted&rdquo; "
    "privacy guarantee at that level.")

problem(
    10, "HIGH",
    "&sect;2.1 Layer 1 vs Layer 3",
    "MediaPipe hand-landmark liveness conflicts with close-up ridge capture",
    "Layer 1 uses MediaPipe Hand Landmarks for finger-in-frame detection, palm/dorsal checks and gesture "
    "liveness, while Layer 3 needs ~500&nbsp;DPI-equivalent ridge detail.",
    "To resolve ridges you must fill the frame with the fingertip; but MediaPipe Hand Landmarks needs the "
    "<b>whole hand</b> visible to produce reliable landmarks and palm/dorsal classification. A close fingertip "
    "crop defeats the hand tracker, and a hand-distance framing defeats ridge resolution. The two "
    "requirements are in direct tension and the document never reconciles them.",
    "Define the capture choreography explicitly: e.g. a hand-distance liveness/landmark phase followed by a "
    "guided zoom-in capture phase, or a fingertip-only liveness method, and show the two phases fit the "
    "latency and UX budget.")

problem(
    11, "HIGH",
    "&sect;3.3 Risk table (omission); &sect;4.2 Device Coverage",
    "Entry-level camera macro-focus feasibility is not treated as a risk",
    "Tier-3 targets are Snapdragon 439 / Helio G35-class phones, yet the risk table contains no entry on "
    "whether such cameras can focus closely enough to resolve fingerprint ridges.",
    "This is arguably the core technical risk of the entire concept. Budget-phone rear cameras often have a "
    "minimum focus distance that prevents sharp macro capture of a fingertip, producing blur that no "
    "downstream enhancement can recover. Its absence from the risk register is conspicuous.",
    "Add an explicit risk row for capture resolution / macro-focus on entry-level cameras, with a mitigation "
    "(minimum-camera-spec gating, guided distance, multi-frame fusion) and a measurement plan during M3/M4.")

problem(
    12, "MED",
    "&sect;2.1 Layer 3 step&nbsp;3; &sect;3.3 latency risk",
    "The ~737&nbsp;ms critical path is projected and optimistic",
    "The 737&nbsp;ms fast-path figure is explicitly &ldquo;derived from component-level benchmarks&rdquo; and "
    "LEADER is assumed to run in ~100&nbsp;ms on a Hexagon DSP.",
    "Component-level sums routinely understate end-to-end latency (camera, MediaPipe, copies, JNI boundaries). "
    "Custom INT8 operators frequently fall back from the DSP to CPU/GPU on mid-range SoCs, inflating the "
    "100&nbsp;ms figure. The stated &ldquo;&gt;50% margin&rdquo; is therefore theoretical until M3.",
    "Label the 737&nbsp;ms clearly as a projection, list the DSP-op-support assumption, and commit to an "
    "end-to-end measured figure on a real Snapdragon 680 device as an M3 exit criterion.")

# ================================================================ GROUP D
section_header("Group D &mdash; Security &amp; Cryptography")

problem(
    13, "MED",
    "&sect;2.2 Encryption",
    "AES-GCM IV derived deterministically from the timestamp",
    "The IV is &ldquo;derived from the last 12 bytes of the PID transaction timestamp&rdquo; for "
    "AES-256-GCM, with AAD from the last 16 bytes of the timestamp.",
    "GCM security collapses if a (key,&nbsp;IV) pair is ever reused. It is probably safe here because a fresh "
    "session key is generated per transaction, but a deterministic, low-entropy, attacker-predictable IV is a "
    "smell that a security reviewer will challenge.",
    "Either state explicitly that the per-transaction fresh key guarantees (key,&nbsp;IV) uniqueness, or use a "
    "cryptographically random 96-bit IV. If the timestamp derivation is mandated verbatim by the UIDAI RD "
    "specification, cite that clause.")

problem(
    14, "MED",
    "&sect;2.2 Encryption",
    "RSA-2048 uses PKCS#1 v1.5 padding",
    "Session-key wrapping uses RSA-2048 with &ldquo;ECB/PKCS1Padding&rdquo;.",
    "PKCS#1 v1.5 is the legacy padding associated with Bleichenbacher-style padding-oracle attacks; OAEP is "
    "the modern best practice. If this is not a hard UIDAI mandate it will be flagged.",
    "If UIDAI mandates PKCS#1 v1.5, cite the specification clause explicitly so it reads as compliance, not a "
    "design choice; otherwise move to RSA-OAEP.")

problem(
    15, "MED",
    "&sect;2.2 Anti-Tamper; &sect;4.1 RD Service Compatibility",
    "Software Keystore pilot undercuts the L1 attestation story",
    "The design claims a three-tier PKI chain (UIDAI Root &rarr; Device Provider &rarr; Device Key) plus "
    "anti-tamper (root/Frida detection, OLLVM, Play Integrity), while the pilot keys live in <b>software</b> "
    "Android Keystore.",
    "On a rooted device, software-held keys and detection heuristics are bypassable, so the pilot &ldquo;device "
    "key&rdquo; is not a genuine hardware-rooted registered-device identity. The disclosure is honest, but the "
    "surrounding language risks over-claiming L1-grade security for the pilot.",
    "Clearly separate &ldquo;pilot security posture (software, best-effort)&rdquo; from &ldquo;production L1 "
    "posture (hardware TEE / StrongBox)&rdquo;, and avoid implying the pilot already provides device-bound "
    "hardware attestation.")

# ================================================================ GROUP E
section_header("Group E &mdash; Compliance &amp; Specification Questions")

problem(
    16, "MED",
    "&sect;1.2; &sect;2.3 Interoperability",
    "Sending Bio type FIR (image) for authentication is unusual",
    "The PID block carries both FIR (ISO 19794-4 image record) and FMR (ISO 19794-2 minutiae record).",
    "UIDAI authentication has historically processed <b>FMR minutiae</b> from registered devices; pushing a "
    "full image record (FIR) for a 1:1 auth transaction is unusual, larger on the wire, and may not be "
    "accepted by the Auth API for the authentication (as opposed to enrolment) use case.",
    "Confirm against UIDAI Authentication API v2.5 that FIR is accepted for the auth use case; if not, default "
    "to FMR for auth and reserve FIR for enrolment / interoperability testing.")

problem(
    17, "MED",
    "&sect;2.2 Compliance (DPDP Act 2023)",
    "DPDP consent is delegated to the host app the SDK cannot control",
    "Consent is &ldquo;collected via &hellip; the host application&rsquo;s UX flow&rdquo;, and consent "
    "withdrawal is exposed as an SDK API.",
    "Because the SDK ships to third-party host applications, it cannot itself guarantee that valid, "
    "purpose-specific consent was obtained &mdash; that responsibility is delegated. On paper this leaves a "
    "DPDP compliance gap unless the integrator&rsquo;s obligations are contractually defined.",
    "Spell out the consent and retention obligations you contractually place on integrators, and describe any "
    "SDK-side enforcement (e.g. a required consent token before capture initiation).")

problem(
    18, "LOW",
    "&sect;3.3 Risk mitigation vs &sect;2.1 Architecture",
    "&ldquo;Post-template plausibility check&rdquo; is undefined",
    "A &ldquo;post-template plausibility check as an additional gate&rdquo; appears only in the spoof-attack "
    "risk mitigation, but no such component exists in the Layer 1&ndash;6 architecture.",
    "Introducing a security control in the risk table that is absent from the architecture looks like a "
    "retrofit and invites a &ldquo;where is this implemented?&rdquo; question.",
    "Either define the plausibility check as a named sub-stage (likely within Layer 4 or 5) or remove the "
    "reference from the risk mitigation.")

# ================================================================ GROUP F
section_header("Group F &mdash; Missing Items vs Stated Goals")

problem(
    19, "MED",
    "&sect;1.3 OKR table vs &sect;1.2 / &sect;4.4",
    "No fairness or Failure-to-Enrol/Acquire metric despite headline inclusion claims",
    "&ldquo;Demographic Fairness&rdquo; and inclusion (worn prints, elderly, Fitzpatrick V&ndash;VI) are "
    "headline priorities, yet the five OKRs contain no demographic-breakdown metric and no FTE/FTA rate.",
    "The document claims inclusion benefits but never commits to measuring them. An evaluator focused on "
    "public value will note that the central social claim has no corresponding key result.",
    "Add a per-subgroup TAR / FTA key result (e.g. worn-fingerprint and elderly cohorts) and a "
    "failure-to-acquire target, so the fairness claim is measurable.")

problem(
    20, "LOW",
    "&sect;1.3 KR&nbsp;4; &sect;2.1 Layer 1",
    "Active-liveness gesture is in tension with inclusion and the latency framing",
    "Active liveness uses a gesture challenge-response, while KR&nbsp;4 specifies &le;&nbsp;2.0&nbsp;s "
    "&ldquo;end-to-end&rdquo; latency and &sect;4.4 promises easy capture for elderly / limited-mobility users.",
    "Gesture challenge-response adds user interaction time and friction that work against the limited-mobility "
    "and elderly inclusion claims, and that wall-clock time is not part of the 2.0-second budget (which covers "
    "processing only). The &ldquo;end-to-end&rdquo; wording is therefore ambiguous.",
    "Clarify precisely what the 2.0-second figure covers (processing vs total user-perceived time) and offer "
    "a reduced-friction liveness path for accessibility cohorts.")

# ================================================================ CLOSING
section_header("Suggested Submission Strategy")
story.append(Paragraph(
    "<b>1. Fix Group A immediately.</b> These are objective inconsistencies (model size, API floor, blank "
    "planning sections, DSA spec). They cost little to correct and their presence undermines confidence in "
    "the more sophisticated sections.", body))
story.append(Paragraph(
    "<b>2. Get ahead of the four hardest objections.</b> In the narrative, proactively address the PAD "
    "domain mismatch (B5), contactless-to-contact TAR realism (B6), the TEE-inference claim (C9), and "
    "entry-level camera macro-focus feasibility (C11). Raising these yourself, with a measurement plan, "
    "signals engineering maturity.", body))
story.append(Paragraph(
    "<b>3. Reframe, don&rsquo;t hide, the pilot&rsquo;s software-security posture.</b> Cleanly separate the "
    "software-Keystore pilot from the hardware-TEE production target (D15, C9) so you never appear to "
    "over-claim L1-grade guarantees.", body))
story.append(Paragraph(
    "<b>4. Make the social claims measurable.</b> Add a fairness / FTE key result (F19) so the inclusion "
    "story has evidence behind it.", body))
story.append(Spacer(1, 8))
story.append(HRFlowable(width="100%", thickness=0.8, color=colors.HexColor("#94A3B8")))
story.append(Paragraph(
    "This review is a constructive critique intended to strengthen the PDD before MSH submission. It does not "
    "assess the underlying technology&rsquo;s merit, only the document&rsquo;s internal consistency, technical "
    "defensibility, and completeness.", small))

# ---------------------------------------------------------------- footer / build
def on_page(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(GREY)
    canvas.drawString(20*mm, 12*mm, "UIDAI SITAA PDD — Critical Review")
    canvas.drawRightString(190*mm, 12*mm, f"Page {doc.page}")
    canvas.setStrokeColor(colors.HexColor("#CBD5E1"))
    canvas.setLineWidth(0.4)
    canvas.line(20*mm, 14*mm, 190*mm, 14*mm)
    canvas.restoreState()

doc = SimpleDocTemplate(
    OUT, pagesize=A4,
    leftMargin=20*mm, rightMargin=20*mm,
    topMargin=16*mm, bottomMargin=18*mm,
    title="UIDAI SITAA PDD - Critical Review",
    author="Technical Review",
)
doc.build(story, onFirstPage=on_page, onLaterPages=on_page)
print("WROTE", OUT)
