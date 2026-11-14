# Releasing

The public repository is generated from the private one; it is never edited by hand.

## How a release is made

From the private repository:

```sh
python3 ops/tools/public-export/export.py --check-only   # build in a temp folder and run the checks
python3 ops/tools/public-export/export.py ../ragnarok-public
cd ../ragnarok-public && git add -A && git commit -m "Release YYYY-MM-DD" && git push
```

`export.py` takes only files git tracks at HEAD, leaves out private records (`drop.txt`), puts in sample
data (`overlay/`, made by `make-sample.py`), replaces leftover machine-specific values, and stops with
nothing written if any personal value or any gitleaks finding (beyond known false positives) is left.

## Before pushing a release

1. `--check-only` passes.
2. Build and test the parts you changed inside the generated copy (each folder's README says how).
3. App bundles are built from source: nothing compiled is shipped except the small script launcher
   `agents/iphone-agent/iPhone Commands.app`, which must pass `codesign --verify --strict` (ad-hoc signed).
4. Tag the release (`git tag vYYYY.MM.DD`) and write what changed in the GitHub release notes.

## Values that look personal but are not

Scanners will flag these. They are placeholders or test inputs, kept on purpose:

- Paths: `/Users/x`, `/Users/sam`, `/Users/me`, `/home/sam`, `/home/tester` (fake users in tests and examples).
- Private IPs in tests (`10.x`, `192.168.1.10/.21/.50`, `100.64.0.7`): several tests check that private addresses
  are blocked or recognized, so they need private-looking inputs. `100.64.0.0` is the Tailscale (CGNAT) range.
- Emails ending in `example.com`, `.local`, `.test`, `.invalid`: test data.
- `origin@rgnrk.co`: the maintainer's public contact (license, security, conduct).

Anything else that looks like a real address, path or email is a bug: add it to the scrub or check list in
`ops/tools/public-export/export.py` and fix it at the source.
