# cd/release/validate-inputs

Checks the `cd-release` inputs before anything else runs and fails early on an
invalid combination. It runs `vrg-release-validate-inputs` from
vergil-tooling.

This action is **wired automatically** as the first check in the `cd-release`
release job. Consuming repositories do not add it themselves.

## Usage

```yaml
- name: Validate inputs
  uses: vergil-project/vergil-actions/actions/cd/release/validate-inputs@v2.1
  with:
    language: python
    container-tag: ""
    registry-publish: "true"
```

The action needs `vergil-tooling` on `PATH`.

## Inputs

| Input | Required | Default | Description |
| ----- | -------- | ------- | ----------- |
| `language` | No | `""` | The repository's language. Empty for repositories with no language ecosystem. |
| `container-tag` | No | `""` | Container image tag. |
| `registry-publish` | No | `"false"` | Whether publishing to a package registry is enabled (`"true"` to enable). |

The action has no outputs.

## Checks

The step fails when either of these holds for a language vergil-tooling
supports:

- `registry-publish` is `"true"` but the language has no publish command
  (e.g. `go`, `cpp`, `typescript`).
- `container-tag` is set but the language is not one of `python`, `java`,
  `rust` or `go`.

It passes without checking when `language` is empty. A language that
vergil-tooling does not support also passes: the action hands the language to
`vrg-release-validate-inputs` as a positional argument, and the tool rejects an
unsupported language only when it is given with `--language`.
