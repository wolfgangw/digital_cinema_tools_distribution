# Digital Cinema Tools Distribution

Install or update the tools using the [Setup instructions](https://github.com/wolfgangw/digital_cinema_tools_distribution/wiki/Setup). The setup script installs into `~/.digital_cinema_tools`, prepares Ruby 3.4.6, asdcplib, FFmpeg, and required Ruby gems, and links the commands into its `.bin` directory.

```sh
curl -fLO https://raw.githubusercontent.com/wolfgangw/digital_cinema_tools_distribution/master/digital-cinema-tools-setup
bash digital-cinema-tools-setup
```

Run `digital-cinema-tools-setup` again for updates. When upgrading an installation whose setup script predates this release, run it twice: the first run fetches the new setup script; the second installs its additional dependencies. Setup reports a failure if the inspector bundle, Ruby gems, required commands, or audio filters are missing.

## dcp_inspect layout

`dcp_inspect` is a launcher for the complete release in `vendor/dcp_inspect/`. That bundle contains the executable, `lib/`, `VERSION`, and its own `xsd/` store. Keep the bundle and launcher together. The distribution's root `xsd/` serves the other tools independently. `toollist` lists command entry points, not their support files; it needs no changes for inspector releases.

The inspector uses `nokogiri`, `ttfunk`, `base64`, Ruby OpenSSL, and `asdcp-info`. Audio analysis also uses `asdcp-unwrap`, FFmpeg (`ebur128` and `astats` filters), and `mkfifo`. Optional `fd`/`fdfind` accelerates discovery. `--nh --na` skips hashing and audio analysis; `--tfs` enables the fullscreen interface.

## Releasing dcp_inspect

Develop, test, version, and commit the inspector in [backports](https://github.com/wolfgangw/backports). From this distribution checkout, run:

```sh
ruby scripts/update-dcp-inspect.rb ../backports
ruby test/dcp_inspect_distribution_test.rb
git diff --stat
git add dcp_inspect vendor/dcp_inspect
git commit -m 'Update dcp_inspect release'
```

The exporter selects `HEAD`, or an explicit commit/tag supplied as its second argument. It copies only committed inspector runtime files, records the source commit and per-file SHA-256 checksums in `RELEASE.json`, verifies the schema manifest and CLI startup, and replaces the bundle only after validation. Uncommitted changes to runtime files are rejected. Exporting the same commit is reproducible; stale files from previous bundles are removed. Do not edit generated bundle files directly.

Push the source commit to `backports` and the reviewed distribution commit when ready to publish. Users then receive the complete, pinned snapshot on their next setup run, without fetching a second source repository. No hand-copying files or editing `toollist` is required.

## Checks

GitHub Actions runs bundle verification and packaging tests on pushes and pull requests.

```sh
bash -n digital-cinema-tools-setup scripts/install-dcp-inspect-dependencies.sh
ruby scripts/verify-dcp-inspect.rb            # release integrity and CLI startup
ruby scripts/verify-dcp-inspect.rb --runtime  # also gems, commands, FFmpeg filters
ruby test/dcp_inspect_distribution_test.rb    # requires minitest and inspector gems
```

Tests use temporary directories and mock dependency installation; they do not install system packages or alter the user's shell configuration. Full setup still needs platform testing on Linux and macOS.
