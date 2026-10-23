# Contribute with any AI assistant

Use this workflow for a code or documentation change. The shared instructions
are [AGENTS.md](../../AGENTS.md), and detailed editing conventions and test
selection are in [the contributor reference](../reference/contributing.md).

## Start a change

1. Read the shared instructions. If your assistant does not discover them
   automatically, explicitly ask it to read the root instruction file before
   starting. Claude's entry point imports that file; other tools may need an
   explicit file reference or their own minimal adapter.
2. Check the working tree and create a topic branch. Preserve existing user
   changes. A checkout is not a cluster deployment.
3. Read the documentation for the component you are changing. Implement the
   change and update its behavior documentation together.
4. Run the relevant checks from the contributor reference. For documentation,
   run `./tests/doc-links-test.sh` and `git diff --check`.
5. Review the diff and prepare a merge request explaining the resulting
   behavior, validation and any deployment requirements. Keep cluster
   deployment separate from the repository change.

## Move knowledge out of private memory

1. Review project memories and local instruction files you can access. Ask
   their owners to review any memories outside that access; do not claim that
   searching a checkout audits another contributor's private environment.
2. Check each statement against current code, tests and documentation. Resolve
   contradictions before promoting it. Do not copy credentials, private site
   values, stale task state or unsupported assumptions into the repository.
3. Put durable contributor rules in the shared instructions, technical facts
   and historical explanations in the appropriate `docs/` page, and
   reproducible requirements in tests where useful. Update an existing source
   rather than creating another copy.
4. Replace any migrated memory with a pointer to its canonical source, or remove
   the redundant entry. Temporary task notes and personal preferences may stay
   local; project correctness must not depend on them.
5. Have a contributor unfamiliar with the change follow the repository alone.
   Add missing context to the canonical source, not back into private memory.

For this migration, the tracked checkout contained no project memory file; the
local `.agents/` and `.codex/` directories were empty. External accounts and
contributors' private memories were not available to audit. Their owners must
complete the review above before declaring those memories fully migrated.

## Check a new assistant or adapter

1. Start a fresh session without previous project conversation or private
   project memory. Open the repository and assign a small, reversible task,
   such as identifying the checks needed for a proposed health-runner change.
2. Verify that the assistant reads the shared instructions and relevant linked
   docs. It should distinguish checkout changes from deployment, preserve site
   data, explain inconclusive probes, and choose the applicable offline tests.
3. If discovery fails, explicitly reference the root instructions. If a tool
   requires its own entry-point file, add only a reference using that tool's
   supported mechanism. Do not duplicate policies in the adapter.
4. Repeat for each assistant the team supports and record the tool/version and
   observed result in the merge request. Static link checks do not establish
   that a particular client loads instructions automatically.

CI checks links and keeps the Claude adapter limited to its shared import.
Fresh-session behavior must still be verified in the actual clients; it cannot
be established by an offline shell suite.
