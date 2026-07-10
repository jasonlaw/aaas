---
name: windows-git-bash
description: Use this whenever a Bash script or shell command needs to be checked on Windows and plain `bash` is not on PATH. It records the Git-for-Windows Bash fallback, especially for `bash -n install.sh` style syntax checks in repos where Git is installed.
---

# Windows Git Bash

When working in a Windows PowerShell workspace and a Bash script needs syntax validation or light execution, first try normal `bash`. If PowerShell reports that `bash` is not recognized, check whether Git for Windows is installed.

Use:

```powershell
Get-Command git -ErrorAction SilentlyContinue
```

If Git is installed under `C:\Program Files\Git`, run Git Bash directly:

```powershell
& 'C:\Program Files\Git\bin\bash.exe' -n install.sh
```

For other scripts, replace `install.sh` with the target script path.

Notes:

- Prefer `-n` for syntax validation when the user only needs a parser check.
- If Git is installed somewhere else, derive the path from `git.exe` and look for sibling Git Bash locations such as `..\bin\bash.exe`.
- WSL may exist without a distro installed, so Git Bash is often the better fallback in this workspace.
