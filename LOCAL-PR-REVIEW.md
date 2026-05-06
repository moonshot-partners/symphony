# Local PR Review Guide

How to review a Symphony agent PR locally before handing to María.

## 1. Find the workspace

Every issue gets a workspace under `~/code/schoolsout-workspaces/<ISSUE-ID>/`.

```
ls ~/code/schoolsout-workspaces/
```

The workspace already has both repos cloned:
- `~/code/schoolsout-workspaces/SODEV-NNN/` → `schoolsoutapp/schools-out` (Rails)
- `~/code/schoolsout-workspaces/SODEV-NNN/fe-next-app/` → `schoolsoutapp/fe-next-app` (Next.js)

## 2. Checkout the PR branch

Get the branch name from the PR:

```bash
# Schools-out (Rails) PR
gh pr view <PR-NUMBER> --repo schoolsoutapp/schools-out --json headRefName -q .headRefName

# FE PR
gh pr view <PR-NUMBER> --repo schoolsoutapp/fe-next-app --json headRefName -q .headRefName
```

Then checkout inside the workspace:

```bash
cd ~/code/schoolsout-workspaces/SODEV-NNN

# For a schools-out PR
git fetch origin
git checkout <branch-name>

# For a fe-next-app PR
cd fe-next-app
git fetch origin
git checkout <branch-name>
```

## 3. Review the diff

```bash
# Schools-out
cd ~/code/schoolsout-workspaces/SODEV-NNN
git diff origin/dev...HEAD

# FE
cd ~/code/schoolsout-workspaces/SODEV-NNN/fe-next-app
git diff origin/dev...HEAD
```

## 4. Run quality checks

### Rails (schools-out)

```bash
cd ~/code/schoolsout-workspaces/SODEV-NNN
bundle exec rubocop                          # lint
bundle exec rspec spec/path/to/changed_spec.rb  # tests for changed files
```

> Note: RuboCop 1.52.1 + Ruby 3.4 has a pre-existing crash on some cops — not agent fault if rubocop itself errors.

### Next.js (fe-next-app)

```bash
cd ~/code/schoolsout-workspaces/SODEV-NNN/fe-next-app
pnpm install                  # if node_modules missing
pnpm format:check             # prettier check (should be clean)
pnpm lint                     # eslint
pnpm test -- --testPathPattern="path/to/changed.test.ts"  # targeted test
```

## 5. Quick sanity checklist

- [ ] Branch off `dev` (not `main`): `git log --oneline origin/dev..HEAD`
- [ ] Diff is scoped — only files the ticket required, no unrelated changes
- [ ] Every changed file maps to an AC item listed in the PR body
- [ ] No workflow infra files (`.github/workflows/`) in the diff
- [ ] Rubocop / prettier / lint exit 0

## 6. Re-trigger CI gate if needed

If scope-discipline was skipped (missing `symphony` label):

```bash
gh pr edit <PR-NUMBER> --repo schoolsoutapp/<repo> --remove-label symphony
sleep 3
gh pr edit <PR-NUMBER> --repo schoolsoutapp/<repo> --add-label symphony
```

## Common workspace paths

| PR repo | Workspace path | PR base |
|---|---|---|
| schools-out | `~/code/schoolsout-workspaces/SODEV-NNN/` | `dev` |
| fe-next-app | `~/code/schoolsout-workspaces/SODEV-NNN/fe-next-app/` | `dev` |
