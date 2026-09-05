"""Analysis of Interaction Fingerprint exports.

Everything here reads the files the app writes (`session_*.json[l]`, `calibration_*.json`)
and reproduces the app's own gaze arithmetic in Python so a model can be judged offline,
against the grid and against taps, before it is shipped.
"""
