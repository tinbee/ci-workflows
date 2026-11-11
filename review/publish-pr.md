Do not end your turn until the review has been posted.

PUBLISH THE REVIEW AS INLINE COMMENTS, not as one PR comment. Each finding
anchored to its own line becomes a review THREAD, which is what the reviewer
on the other end can reply to and resolve one finding at a time -- the same
loop Copilot findings already go through. A single comment carrying N
findings has no threads, so a repo whose branch protection requires thread
resolution cannot see it at all, and disagreeing with one finding means
dismissing all of them.

Write a JSON file to /tmp/review.json:

  {
    "event": "COMMENT",
    "body": "<the summary: which rules you read, what you checked and found
             clean, and any finding that has no line to attach to -- a stale
             PR description, a migration already on main, a missing test.
             End with the one-line count.>",
    "comments": [
      { "path": "apps/api/src/foo.ts", "line": 42, "side": "RIGHT",
        "body": "<one finding: the failure scenario and the fix>" }
    ]
  }

Then post it:

  gh api repos/{{REPO}}/pulls/{{PR}}/reviews \
    --method POST --input /tmp/review.json

ANCHORING RULES -- the API rejects the WHOLE review if one comment is
misplaced, which throws away the entire run:
  - `path` and `line` must name a line the diff actually touches. Get them
    from `.review-context/pr.diff`; do not guess from reading the file.
  - `side: "RIGHT"` for added or changed lines, `"LEFT"` only for a line the
    diff removes.
  - A finding you cannot anchor goes in `body`. Never invent a line to hang
    it on.

IF THE POST FAILS, do not stop and do not retry the same payload. Move every
finding into `body` (keeping its file:line inline as text), set `comments` to
`[]`, and post again. If that also fails, fall back to
`gh pr comment {{PR}} --body-file /tmp/review.md`.
A review that is not published does not exist -- the job fails if nothing
appears.
