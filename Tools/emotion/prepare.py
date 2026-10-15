#!/usr/bin/env python3
"""Lays out the acted-emotion corpora as one folder per label, the shape CreateML trains from.

    prepare.py <RAVDESS zips or folders...> <CREMA-D AudioWAV folder (optional)> --out data/

RAVDESS (Livingstone & Russo, Zenodo 1188976, CC BY-NC-SA 4.0): file names such as
03-01-05-01-02-01-12.wav, whose third field is the emotion. The song set (Audio_Song_*) is
sung rather than spoken and matters for a rapper's takes, so both sets are taken.
CREMA-D (Cao et al., GitHub CheyneyComputerScience/CREMA-D, ODbL): names such as
1001_DFA_ANG_XX.wav, whose third field is the emotion.
"""
import shutil
import sys
import zipfile
from pathlib import Path

RAVDESS = {"01": "neutral", "02": "calm", "03": "happy", "04": "sad", "05": "angry", "06": "fearful", "07": "disgust", "08": "surprised"}
CREMA = {"NEU": "neutral", "HAP": "happy", "SAD": "sad", "ANG": "angry", "FEA": "fearful", "DIS": "disgust"}


def main():
    args = sys.argv[1:]
    out = Path(args[args.index("--out") + 1]) if "--out" in args else Path("data")
    sources = [Path(a) for a in args if not a.startswith("--") and Path(a) != out]
    out.mkdir(parents=True, exist_ok=True)
    counts = {}
    for source in sources:
        if source.suffix == ".zip":
            with zipfile.ZipFile(source) as archive:
                for name in archive.namelist():
                    if name.endswith(".wav"):
                        fields = Path(name).stem.split("-")
                        label = RAVDESS.get(fields[2]) if len(fields) == 7 else None
                        if label:
                            target = out / label / Path(name).name
                            target.parent.mkdir(exist_ok=True)
                            target.write_bytes(archive.read(name))
                            counts[label] = counts.get(label, 0) + 1
        else:
            for wav in source.rglob("*.wav"):
                fields = wav.stem.split("_") if "_" in wav.stem else wav.stem.split("-")
                label = CREMA.get(fields[2]) if len(fields) == 4 else RAVDESS.get(fields[2]) if len(fields) == 7 else None
                if label:
                    target = out / label / wav.name
                    target.parent.mkdir(exist_ok=True)
                    shutil.copy(wav, target)
                    counts[label] = counts.get(label, 0) + 1
    print({label: counts[label] for label in sorted(counts)})


if __name__ == "__main__":
    main()
