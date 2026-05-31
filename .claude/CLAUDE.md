# Alberta Weather — Claude Instructions

## Pre-commit security sweep (required before every commit + push)

Run this before staging any commit. No exceptions.

### 1. Gitleaks (if installed)
```bash
gitleaks detect --source . --report-format json --report-path /tmp/gitleaks-report.json -v
```

### 2. Manual grep sweep on changed files
```bash
git diff --name-only HEAD   # or against staged: git diff --cached --name-only
# then for each changed file:
grep -n -E "[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}|/home/[a-z_]+/|[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|AKIA[A-Z0-9]+|sk-[a-zA-Z0-9]{20,}|password\s*=|secret\s*=" <file>
```

### What's acceptable (pre-cleared)
- `localhost` / `127.0.0.1` — localhost guard in main.dart, not a secret
- Apple Team ID `DVWLB3H5M3` and bundle ID `ca.hakooja.albertaweather` — public app identifiers, fine in tracked source
- `https://alberta-weather-api.fly.dev` — public API URL in codemagic.yaml

### What blocks a commit
- Any email address (including leohakooja@gmail.com / bhakooja@gmail.com)
- Any API key, token, or password
- Any internal hostname or private IP

## Deployment

Push to `main` → Codemagic auto-builds → TestFlight (Family/Friends group).
Build takes ~10–15 min. Test on the actual iPhone — browser rendering does not
match the phone.

## Known git history issue
`leohakooja@gmail.com` is baked into commit `246e924` (was in codemagic.yaml).
Must be scrubbed with `git filter-repo` before the repo ever goes public.
