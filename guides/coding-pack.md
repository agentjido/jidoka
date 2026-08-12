# Coding Pack Architecture

`Jidoka.CodingPack` is a removable first-party extension. Jidoka does not
activate it in the kernel. A trusted host creates a workspace, creates a
registry entry, and adds the inert `jido.coding_pack` request to an agent.

## Stable IDs

The pack reserves these tool IDs:

- `coding.read`
- `coding.search`
- `coding.write`
- `coding.edit`
- `coding.shell`
- `coding.git_status`
- `coding.git_diff`
- `coding.verify`

The host can disable the full pack by omitting its registry entry or request.
It can disable or replace one tool through `Jidoka.CodingPack.entry/2`. Agent
documents cannot set a workspace root, executable, replacement, or disable
rule.

## Trusted workspace

`Jidoka.CodingPack.Workspace` accepts trusted host configuration. It stores a
canonical root, access classes, ignore sources, instruction names, byte limits,
and an execution-profile reference. Its portable projection contains a root
digest, but it does not contain the host path.

All later coding tools must resolve paths through the workspace. Resolution
rejects absolute paths, parent traversal, symbolic-link escape, special files,
and missing paths unless the caller explicitly allows a missing write target.

## Ignore order

Trusted exclusions always win. The default trusted exclusions include `.git`,
environment files, key files, dependency trees, and generated build trees.
Project ignore files then apply from the workspace root to the selected path.
Within that ordered list, the last matching rule wins. A negation can change an
earlier project rule, but it cannot change a trusted exclusion.

Ignore decisions include the path, source, pattern, and decision kind. Later
tools must reject ignored paths before they read or change content.

## Project instructions

Instruction discovery starts at the workspace root and moves towards the
selected directory. At each level it uses the configured filename order. Each
result includes a relative path, scope, byte count, SHA-256 digest, and UTF-8
content. File, count, and total-result limits apply before the data enters a
turn context.

This foundation does not expose a model-callable file, edit, shell, Git, or
verification operation.
