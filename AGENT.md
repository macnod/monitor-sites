# Monitor Sites – Agent Overview

Monitor Sites is a Common Lisp program that periodically checks
configured web sites via HTTP GET and sends Mattermost notifications
when sites are unreachable or when the monitoring host loses internet
connectivity.

## Live Introspection: `eval-in-monitor-sites`

An Elisp helper, `eval-in-monitor-sites`, evaluates a Common Lisp form
against a **running** Monitor Sites instance (over Slime, in the
`:monitor-sites` package) and returns the result.

- Argument: a single `form`, given as a string (or a Lisp form).
- Evaluation context: the `:monitor-sites` package, so package-local
  nicknames like `u:` (dc-eclectic), `dr:` (drakma), `dt:` (dc-time),
  `pl:` (p-log), and `re:` (ppcre) are available.
- Invoke it via the `Eval` tool.

Example:

    (eval-in-monitor-sites "(+ 1 1)")
    ;; => ("" "2" nil)

The function routes through `monitor-sites::eval-safely`, which
catches errors server-side so the Swank connection never breaks.
