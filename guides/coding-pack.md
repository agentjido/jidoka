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

This foundation does not expose a model-callable operation by itself. Each
operation is present only when the trusted host includes its required port and
access class.

## Read-only operations

When enabled, the pack registers `coding.read` and `coding.search`. Both run
through the normal Jidoka operation policy gate before their local workspace
handler. Their policy resource states read access and includes only bounded,
declared argument fields.

`coding.read` accepts a relative `path`. It can also accept an inclusive
`start_line` and `end_line`, or a byte `offset` and `length`. The two range
forms cannot be mixed. The result contains UTF-8 content, the full-file digest,
file size, actual range, truncation state, and ignore provenance. Binary,
ignored, oversized, changed, missing, or outside-root files return typed
errors.

`coding.search` accepts `mode: "path" | "text"`, a relative base `path`, a
literal `pattern`, and an optional file `glob`. Results have deterministic path,
line, and column order. Trusted limits bound visited entries, returned results,
file size, previews, and encoded output bytes. Ignored trees are not traversed.
Binary files are counted and skipped. The operation does not call a host shell.

The host can replace or disable either operation by its stable ID when it
creates the pack registry entry.

## Reviewed mutations

The pack registers `coding.write` and `coding.edit` only when the trusted host
supplies a `Jidoka.CodingPack.MutationPort`. The port delegates to a constrained
execution environment. Jidoka requires confirmed evidence for path confinement,
file reads, file writes, checkpoints, and atomic replacement. It fails closed
when any fact is absent. The pack does not use direct host file writes.

`coding.write` creates a missing bounded UTF-8 file. Existing files require the
explicit `overwrite` flag. A caller can also give an `expected_before_sha256`
digest. A mismatch writes nothing.

`coding.edit` replaces one exact UTF-8 value. It requires an exact expected
occurrence count and can require the before digest. A count or digest mismatch
writes nothing.

Both operations resolve and check the path again immediately before mutation.
They create a portable environment checkpoint first. A successful result gives
the path, operation ID, before and after digests and sizes, atomic-write method,
checkpoint reference, confirmed enforcement evidence, and bounded structural
diff facts. It does not include changed file content. A partial backend error
reports the observed final state and the checkpoint that is available for
recovery.

## Constrained shell

The pack registers `coding.shell` only when a trusted host supplies a
`Jidoka.CodingPack.ShellPort`. The port holds an execution-environment manager,
portable binding, trusted security profile, and a command registry. An agent
can select a registered command and give arguments. It cannot select an
adapter, executable class, image, mount, or backend option.

The request accepts an executable name, argument list, bounded standard input,
relative working directory, timeout, output limit, and network-need flag. The
workspace and trusted profile set the maximum values. Each registered command
states its policy class, mutation class, and whether it can use network access.
The normal operation policy gate receives that summary without standard-input
content. The environment manager applies a second policy gate before adapter
execution.

Jidoka acquires the environment before execution and closes it after success,
failure, timeout, or cancellation. Cancellation does not stop the close call.
The result keeps standard output and standard error separate and bounded. It
also gives status, exit status, duration, truncation facts, confirmed backend
and enforcement evidence, and cleanup evidence. Missing shell, path, timeout,
output, cancellation, command-class, or limit evidence fails closed.

The coding pack does not call a host shell, `System.cmd`, or `Port.open`. It has
no interactive terminal, background-job, SSH, or raw container mode.
