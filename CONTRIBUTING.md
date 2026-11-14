# Contributing

Thanks for looking. This is one person's project, so reviews can be slow.

## Before you start

- Open an issue first for anything bigger than a small fix, so we can agree it fits.
- Read the README of the folder you are changing. Each one says what it does and how to test it.

## Sending a change

1. Fork, make a branch, keep the change to one thing.
2. Run the tests for the folders you touched (see each folder's README). Say in the pull request which ones you ran and what they printed.
3. Never commit secrets, IP addresses, home-folder paths or personal names. Machine-specific values go in `~/.ragnarok/local.conf`, which is not in git; the code must work with generic defaults.
4. Keep the house rules from the main README: AI output is a proposal until a person approves it, and every write leaves a receipt.

## License of contributions

By sending a pull request you agree your change is licensed under the license of the folder it lands in:
AGPL-3.0-only for most of the repo, PolyForm Noncommercial 1.0.0 for `runner/conveyor/` (see the README's License section).

## Conduct

Everyone taking part follows the [Code of Conduct](CODE_OF_CONDUCT.md).
