# VS Code settings layout

- Shared settings: `.vscode/settings.json` (applies when opening the folder) and `.vscode/LQR.code-workspace` (applies when opening the workspace file).
- Local overrides: copy `.vscode/LQR.local.code-workspace.example` to `.vscode/LQR.local.code-workspace`, adjust paths/personal toggles, and open that workspace in VS Code. The local workspace layers on top of the shared settings but stays untracked.

Optional: if you prefer not to use a workspace file, keep machine-specific values in your VS Code **User** settings instead of adding them to the repo.
