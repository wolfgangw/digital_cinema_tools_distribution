# Installer principles

Minimize intrusion. These tools should be easy to install alongside the user's existing environment.

- Install only missing dependencies needed for the requested tools; reuse compatible installations where practical.
- Keep tool-managed runtimes, gems, and files under `~/.digital_cinema_tools`.
- Preserve the user's Ruby/version-manager configuration and shell customizations. Keep necessary PATH additions small and explicit.
- Do not require or perform full system upgrades as part of setup.
- Report package-manager failures clearly; do not automatically repair the system, force package overwrites, or weaken signature checks.
- Do not run the full installer on a working machine just to test changes. Use temporary directories, mocked package operations, and isolated build checks.
- Keep installation instructions short and task-focused. Explain extra steps only when actually needed.
- Make local commits for distinct changes. Do not push or publish wiki changes unless requested.
