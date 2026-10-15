Verified shared offline Qwen3.5 models are staged outside the source tree by
`OfflineIntelligenceKit/Tools/build_hosts.py --app Cipher`.

Folders: `Models/qwen-2b` (default) and `Models/qwen-4b` (optional), each containing
the shared catalog's immutable revision metadata. Selected 4B never silently falls
back to another model. Existing Application Support/Models storage remains a local
import location for these verified catalog folders.
