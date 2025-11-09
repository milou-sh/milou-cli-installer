# Contributing to Milou CLI

Thanks for taking the time to improve the CLI! The Milou application itself remains proprietary, but we welcome fixes and improvements to the installer, bash modules, and documentation contained in this repository.

## Workflow

1. **Fork** the repository (or open a branch if you are part of the Milou org).
2. **Create focused changes.** Keep each PR limited to a logical change set (docs, installer tweak, CLI fix, etc.).
3. **Run the basics.** At minimum run `bash -n lib/*.sh milou` to ensure the scripts still parse. If you change Docker logic, a quick `milou start`/`milou stop` cycle is appreciated.
4. **Open a pull request.** Describe the problem, your solution, and any manual testing performed. Mention if your change impacts the proprietary Milou services so the internal team can validate before release.
5. **Stay available.** Respond to review comments so we can merge quickly.

## Style & Guidelines

- Favor clarity over cleverness. These scripts are used during on-call rotations.
- Keep `.env` / secret handling atomic and enforce permissions (use the helpers in `lib/core.sh`).
- Add short comments when code is non-obvious; avoid restating what the code already says.
- New user-facing behavior should be reflected in `README.md`.

## Security & Private Assets

- Never commit actual GHCR tokens, SSL keys, or customer data.
- Compose files reference private GHCR images. Do not embed internal Dockerfiles in this repo.
- If you need to reference closed-source behavior, open a private Milou engineering ticket instead of describing it publicly.

By contributing, you agree that your work will be released under the [MIT License](LICENSE).
