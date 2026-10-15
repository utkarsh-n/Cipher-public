# Public source snapshot

This repository contains a reviewed source snapshot. Original Git history, credentials, personal records, local signing identities, device diagnostics, build outputs, downloaded model weights, firmware, and unreviewed media are excluded. Existing upstream license and attribution files apply to their respective components. Publication does not grant a new license to third-party content.

Configure your own Apple signing team to run native apps on a physical device. Downloaded datasets, binary runtimes, fonts, demo media, and models may need to be obtained separately using the documented upstream sources or fetch/build tools. This publication review does not certify that this snapshot builds or runs.

## Project setup and omitted assets

The current manifest and `Cipher.xcodeproj` are retained; the alternate `Cipher 2.xcodeproj` and original Git history are omitted. Clone [OfflineIntelligenceKit](https://github.com/utkarsh-n/OfflineIntelligenceKit) beside this repository to satisfy the manifest's core and `MLX` paths.

The source snapshot omits `Tools/data/`, downloaded corpora, emotion training audio, all `Cipher/Resources/*.tsv`, `lexicon.bin`, Sutton SignWriting font binaries, `VocalEmotion.mlmodel` and shared local-model weights. The app therefore needs resource preparation before it can provide its full word/culture/sign/emotion features. The retained `Tools/build_lexicon.sh`, `Tools/lexgen/`, `Tools/culture/`, `Tools/roots/` and `Tools/emotion/` contain the relevant pipelines. A complete resource rebuild may require upstream source preparation not packaged here.

Keep the source attribution in `Cipher/Views/SettingsView.swift`. Corpus sources have different CC BY-SA, CC BY, CC0, BSD and public-domain terms; fonts require their OFL notice. The emotion preparation script identifies RAVDESS CC BY-NC-SA 4.0 and CREMA-D ODbL training data. Obtain the applicable notices and confirm distribution terms before supplying or redistributing derived data/models. Set `CIPHER_CONTACT` to your own public crawler contact address before using Wikimedia/MusicBrainz tools; no personal contact address is included.
