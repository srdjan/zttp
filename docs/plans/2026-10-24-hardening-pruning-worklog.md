# Hardening and pruning worklog, round 4

## Objective and constraints

The owner requested a ranked list before more features. The list must reduce complexity without losing functionality.
This task authorizes an audit and documentation. It does not authorize code changes or a Git history rewrite.
The source baseline is `d7aaf1f4`. Work stays on local `main`, with no push.
Standing decisions in `docs/decisions.md` still apply. Earlier closed findings stay closed unless current evidence contradicts them.

## Completed work

The main agent read the repository map, build graph, dependencies, standing decisions, and earlier pruning records.
Three read-only Sol agents reviewed the expert loop, runtime, and analyzer areas.
The expert-loop agent reported one preliminary concern, then stopped because the model reached capacity.
The main agent tested that concern independently. A `.zttp` symlink caused `NotDir`, and no outside lock appeared.
That concern is excluded from the list.

`zig build check-spine` exited 0 before documentation changes.
A documentation-link probe used an isolated temporary Git repository.
The gate exited 1 for a broken link, but exited 0 for an empty inventory and a failed Perl scanner.
These are confirmed false passes.

The branch metric probe wrote a prefix, then ran the current metric against `build.zig` with redirected stdout.
The metric exited 0 and erased the prefix. The list records this output defect separately from the scanner false pass.

The main agent reviewed the retained agent findings against source and callers.
The completed list contains 16 ranked findings and separates source evidence from observed probes.
The main agent measured 204 removable lines in the unused proof-review printer scaffolding.
The plans index now links the list and this worklog.

## Final checks

| Command | Result and scope |
|---|---|
| `zig build test -j1 --summary all` | Exit 0; 212 of 212 steps succeeded; summary reports 9,006 tests passed and six skipped |
| `zig build test-agent-protocol --summary all` | Exit 0; 535 tests passed; the build reported one minute for execution |
| `zig build check-spine test-doc-links` | Exit 0 after the new report files were staged |
| `git diff --cached --check` | Exit 0 |

The aggregate was unfiltered and used existing caches. Its summary is not an independent inventory of unique tests.
The audit did not run `bash scripts/verify.sh`, remote providers, allocation-failure probes, or cross-platform runtime tests.
The aggregate log is `/tmp/zttp-pruning-round-4-test.log`.
The named-suite log is `/tmp/zttp-pruning-round-4-agent-protocol.log`.
The final documentation log is `/tmp/zttp-pruning-round-4-docs.log`.

## Next action

The main agent will commit the report locally. The owner will select any later implementation scope.
