# Source provenance

DataStrings 1.0 extracts and renames ArrowStrings from apache/arrow-julia local
core-rewrite commit `5552219709263c31aee94b347bce3b82f8b61d12`.
The ArrowStrings implementation and tests retain their Apache 2.0 notices.

String construction, regex forwarding, and mutable column behavior incorporate
CSV CompactString work from local CSV-kernel-proveout commit
`20e84cb2fff1f686d93138bf4ec29dc9103edf15`. The CSV MIT notice is LICENSE-CSV.md.
The new column arena supports Arrow's multiple input buffers and is tested for
retained-value lifetime across edits. Namespace, validation, documentation,
release tooling, and tests were updated for this standalone package.

DataStrings is maintained and released by JuliaData independently of the ASF.
Jacob Quinn used Claude Code and OpenAI Codex for implementation and review.
