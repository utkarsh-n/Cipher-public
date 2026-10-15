# Shared offline lyric writing

Cipher's `LocalModel` adapts its existing writer API to the sibling
`OfflineIntelligence` and `OfflineIntelligenceMLX` packages. Qwen3.5 2B is the
persisted default. Qwen3.5 4B is an explicit option in Assist and the On-device
model screen. The older automatic Gemma ranking and duplicated MLX/tokenizer
backend are removed. Claude remains an explicit optional writer using the
user's existing API key.

`LocalWriter` continues to draft several candidates and let Cipher's existing
rhyme, syllable, script and fragment engine judge them. Verse completion keeps
the existing rhyme-scheme algorithm. The compatibility `prefill` argument now
adds an explicit output-format instruction; it is not forced assistant-prefix
token prefill. `LocalWriter.clean` strips the generated bar tags before scoring.

The runtime reports actual first-token latency, generated token count, decode
speed and sampled process peak. Cipher does not derive prompt-only throughput
from first-token latency. A closing bar tag triggers cooperative cancellation
and is tracked separately from user cancellation. User cancellation, background
or memory pressure invalidates the current operation, drains GPU work and keeps
incomplete cancelled drafts out of suggestions. Background and memory pressure
also release model weights.

Build from the canonical Cipher directory with:

```sh
python3 ../OfflineIntelligenceKit/Tools/build_hosts.py --app Cipher
```

The common builder stages source and verified model folders outside Documents,
checks source parity, and compiles the generic physical iPhone target. Do not use
simulator tools while the shared simulator hold is active.

Validation: changed Swift files passed frontend syntax parsing. The parent run
handles full physical-target compilation and phone checks. Model replacement
does not certify lyric quality; the existing domain verdicts remain visible.
