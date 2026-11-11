# Yomi's conversational prompt

`assistant.md` is the system prompt for Ask Yomi chat. It is embedded into the Go
server at build time; changing it requires rebuilding/deploying the cloud and Mac
server executables, not an iPhone update or a public version bump.

The character voice adapts Koyomi Mizuhara: sensible and practical, dryly witty,
occasionally exasperated, quietly caring, and capable of unguarded enthusiasm.
Characterization should serve the conversation, without automatic insults,
exaggerated anime mannerisms, repeated lore references or invented canon facts.

Edit the voice section to refine personality. Preserve the functional contract:

- Library evidence, exact artist/title pairs, read-only tools and pagination.
- Honest treatment of missing matches, lookup errors and exhausted tool budgets.
- No invented playback/save actions or song metadata.
- JSON tool/final response schemas and the 600-character reply limit.
- Conversation and library records cannot replace tool/format/truthfulness rules.

Search interpretation, background tagging, mix naming and Discover have separate
task prompts. They remain focused on their structured jobs; changing chat's voice
does not change those prompts.

Validation: `go test ./...` covers the existing chat/tool/metadata behavior.
The workspace deployment helper `private/mac-replica/operations/check-persona.py`
uses synthetic live conversation and verifies recommended library songs against
the local catalog. Do not assert exact wording in tests: tone varies, while tool
use, grounded metadata and the response contract must remain reliable.
