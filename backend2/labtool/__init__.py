"""
labtool — desktop bench for the SITAA acceptance flow (FP-01 … FP-08).

Heavy ML stages run on the Flask backend over HTTP; matching, scoring and FIR
decoding run here, in-process, against the repo's own `matching.py` and `fir.py`.
That split is what makes the tool usable on a machine with no model weights and
no TensorFlow, while still scoring with the production matcher.
"""
