This review runs locally, before the change is pushed. Nothing is published:
return the review as the structured output.

- `findings`: one entry per defect, most severe first.
  - `file` and `line`: a line the diff touches, on the new side, taken from
    `pr.diff` rather than guessed from the file. Use line 0 for a finding with
    no line to attach to.
  - `severity`: `blocking` when the failure scenario ships a bug, a security
    gap or an unsafe migration; `minor` when the defect is real but its
    consequence is small (a comment that asserts the wrong behaviour, a
    missing test for a traced edge case).
  - `summary`: the defect in one sentence.
  - `failure_scenario`: inputs or state -> wrong outcome.
  - `fix`: what to change.
- `rules_read`: the rule files you read.
- `summary`: as described above, ending with the one-line count.
