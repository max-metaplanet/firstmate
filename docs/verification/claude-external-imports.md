# Claude Code external-CLAUDE.md-import approval

Audience: maintainer-verification.
This record holds the empirical facts [`bin/fm-claude-trust.sh`](../../bin/fm-claude-trust.sh) relies on when it writes `hasClaudeMdExternalIncludesApproved` and `hasClaudeMdExternalIncludesWarningShown`.
Refresh it whenever Claude Code's handling of those flags is re-measured; the script's own header owns the contract this evidence supports.

## Versions measured

| Host | Platform | `claude --version` | Measured |
| --- | --- | --- | --- |
| Lima fleet VM | Linux aarch64 | `2.1.325 (Claude Code)` | 2026-11-16 |
| telos64 | macOS arm64 | `2.1.325 (Claude Code)` | 2026-11-16 |

Both hosts run the same build, so the reads below cover both.

## Reads from the shipped binary

The binary is a single unstripped executable, so the facts are read out of the embedded bundle text:

```
B=$HOME/.local/share/claude/versions/2.1.325
grep -abo 'hasClaudeMdExternalIncludes[A-Za-z]*' "$B"
dd if="$B" bs=1 skip=<offset> count=<n> | tr -c '[:print:]\n' '.'
```

### The dialog's show condition reads the project-config entry only

```
async function l5i(e,n){let r=Ul();if(r.hasClaudeMdExternalIncludesApproved||r.hasClaudeMdExternalIncludesWarningShown)return!1;return nRs(await FE(e,!0,n))}
```

`Ul()` is the project-config reader:

```
function Ul(){if(xn())return xe().testProjectConfig;if(gs())return ETe;let e=fMe(),n=pe();if(!n.projects)return ETe;let r=n.projects[e]??ETe;...return r}
```

So the dialog renders only when NEITHER flag is true on `projects[<canonical project root>]` in `~/.claude.json`.
There is no settings-file, managed-settings, or environment-variable equivalent; the only related environment variables are `CLAUDE_CODE_DISABLE_CLAUDE_MDS`, which disables all `CLAUDE.md` loading, and `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`.

### The canonical project root is the git root, collapsed through `commondir`

```
function fMe(){let e=xe();if(e.projectPathForConfig!==null&&!gs())return e.projectPathForConfig;let n=Te(),r=XA(n),s=r?rJ(r):rJ(cn(yt(n)));return e.setProjectPathForConfig(s),s}
function Dt(e){try{return qt(e,K(S(e,".git"),"utf-8"))}catch{return e}}
```

`Dt` reads a linked worktree's `.git` file, follows its `gitdir:` pointer to that worktree's git dir, reads `commondir`, and returns the common dir's parent.
A linked worktree therefore keys its project config to the PRIMARY CHECKOUT.
Registration covers the launch directory and its canonical checkout, writing one entry when those paths coincide.
Secondmate-home mode also covers eligible project clones and their canonical checkouts.

### An answer writes both flags

```
function nlr(g,h,o){Ry((a)=>({...a,hasClaudeMdExternalIncludesApproved:g,hasClaudeMdExternalIncludesWarningShown:!0}),o),...}
```

`Approved` takes the answer and `WarningShown` is always set, so `Approved===false` with `WarningShown===true` is an explicit decline.
The default project entry carries both as false:

```
var ETe={allowedTools:[],...,hasTrustDialogAccepted:!1,hasClaudeMdExternalIncludesApproved:!1,hasClaudeMdExternalIncludesWarningShown:!1};
```

False with false is therefore "never asked", not a decline.

### Only `Approved===true` includes the imported content

```
ot=Ul().hasClaudeMdExternalIncludesApproved??!1
let r=Ul().hasClaudeMdExternalIncludesApproved||!1;
```

Both call sites pass that value as the `includeExternal` argument of the loader.
`WarningShown===true` on its own suppresses the dialog while leaving the imports excluded, so it is never written without `Approved`.

### A User-type `CLAUDE.md` never triggers the dialog

```
function kBn(e){let n=[];for(let r of e){if(r.type!=="User"&&r.parent&&!Gz(r.path))n.push({path:r.path,parent:r.parent});if(r.type!=="User"&&r.linkedFrom!==void 0&&!Gz(r.path))n.push({path:r.path,parent:r.linkedFrom})}return n}
function Gz(e){return Ac(e,Te())}
```

The trigger is a Project- or Local-type `CLAUDE.md` or `.claude/rules` entry importing a path outside the working directory.

## End-to-end reproduction

Run on 2026-11-16 on the Lima fleet VM, tmux 3.6, claude 2.1.325, against a disposable git checkout whose `CLAUDE.md` holds `@../outside/EXTERNAL.md`, launched as `claude --setting-sources project,local --permission-mode auto`:

- With no project entry, the pane rendered the workspace-trust dialog with the cursor on `No, exit`.
- With `hasTrustDialogAccepted` alone, the pane rendered `Allow external CLAUDE.md file imports?`, listing the outside path, with the cursor on `No, disable external imports`.
- After `bin/fm-claude-trust.sh --project <checkout>` wrote all three flags, the same launch reached the composer with no dialog of either kind.

The disposable checkout and its two store entries were removed afterwards.
[`tests/fm-claude-trust.test.sh`](../../tests/fm-claude-trust.test.sh) is the portable regression that pins the written shape without a harness.

### A recorded decline suppresses the dialog

Verified live on 2026-11-16 on the Lima fleet VM with claude 2.1.325 and tmux 3.6.
A disposable git checkout had a Project-type `CLAUDE.md` containing `@../outside/EXTERNAL.md` and this exact project entry in `~/.claude.json`:

```json
{"hasTrustDialogAccepted":true,"hasClaudeMdExternalIncludesApproved":false,"hasClaudeMdExternalIncludesWarningShown":true}
```

Launched as `claude --setting-sources project,local --permission-mode auto`, it reached the composer with no dialog of either kind.
This matches the show condition above: the imports dialog renders only when neither import flag is true.
The disposable checkout and its store entry were removed afterwards.
