# Review prompt

What the cold-context reviewer is told, in **one copy** for both places it runs:

| Runs in | Assembled as | Returns |
| --- | --- | --- |
| `claude-review.yml` (the `claude-review` label, on GitHub) | `core.md` + `publish-pr.md` | inline review threads on the PR |
| a repo's local pre-flight (`make local-ci`, before the push) | `core.md` + `local/return-structured.md` | structured JSON on stdout |

`assemble.sh <ending.md>` joins the two and fills `{{PROJECT_CONTEXT}}`, `{{PROJECT_RULES}}`,
`{{REPO}}` and `{{PR}}` from the environment, and refuses to print a prompt with a
placeholder left in it. Both callers go through it, so a change to what the reviewer is
told reaches both on the next run at `v1`. The rules themselves stay in `../review-rules/`.

## `local/`: the local review container

Built by a consumer's `scripts/local-ci/run.sh` from `git archive v1 review review-rules`
of this repository (build context `review/`, `docker build -f local/review.Dockerfile`):

- **`review.Dockerfile`, `review.sh`**: the Claude CLI on the commit under review, Read /
  Glob / Grep only. It loads none of the commit's own Claude config (`--setting-sources
  user`, an empty `--strict-mcp-config`, `disableAllHooks`): a commit's `.mcp.json` ran
  code in the container holding the token before those flags (tinbee/woahbar#10).
- **`proxy.Dockerfile`, `proxy.conf`, `proxy-allow.txt`**: the container's only egress.
  The review runs on an `--internal` network; this tinyproxy allows CONNECT to
  `api.anthropic.com` and refuses everything else (tinbee/woahbar#12).
- **`schema.json`**: the shape of the result: `findings[{file, line, severity: blocking |
  minor, summary, failure_scenario, fix}]`, `rules_read`, `summary`.

The checks half of local-ci (CI's build and test commands, services such as Postgres)
is stack-specific and stays in each repo until a second one shows what is common.
