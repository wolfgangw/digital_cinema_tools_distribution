# Digital Cinema Tools Distribution

Install or update the tools using [Setup](https://github.com/wolfgangw/digital_cinema_tools_distribution/wiki/Setup). The setup script installs into `~/.digital_cinema_tools`, prepares Ruby 3.4.6, asdcplib, FFmpeg, and required Ruby gems, and links the commands into its `.bin` directory.

## dcp_inspect layout

`dcp_inspect` is a launcher for the complete release in `vendor/dcp_inspect/`. That bundle contains the executable, `lib/`, `VERSION`, and its own `xsd/` store. Keep the bundle and launcher together. The distribution's root `xsd/` serves the other tools independently. `toollist` lists command entry points.

dcp_inspect uses `nokogiri`, `ttfunk`, `base64`, Ruby OpenSSL, and `asdcp-info`. Audio analysis also uses `asdcp-unwrap`, FFmpeg (`ebur128` and `astats` filters), and `mkfifo`. Optional `fd`/`fdfind` accelerates discovery. `--nh --na` skips hashing and audio analysis; `--tfs` enables the fullscreen interface.

## Releasing dcp_inspect

Develop, test, version, and commit the inspector in [backports](https://github.com/wolfgangw/backports). From this distribution checkout, run:

```sh
ruby scripts/update-dcp-inspect.rb ../backports
ruby test/dcp_inspect_distribution_test.rb
git diff --stat
git add dcp_inspect vendor/dcp_inspect
git commit -m 'Update dcp_inspect release'
```

## Checks

```sh
bash -n digital-cinema-tools-setup scripts/install-dcp-inspect-dependencies.sh
ruby scripts/verify-dcp-inspect.rb            # release integrity and CLI startup
ruby scripts/verify-dcp-inspect.rb --runtime  # also gems, commands, FFmpeg filters
ruby test/dcp_inspect_distribution_test.rb    # requires minitest and inspector gems
ruby test/setup_platform_test.rb             # platform, package-manager, launcher tests
ruby test/setup_uninstall_test.rb            # confirmed removal and shell cleanup
ruby test/setup_update_test.rb               # update checks and installer handoff
```


Tests use temporary directories and mock dependency installation; they do not install system packages or alter the user's shell configuration. Full setup still needs platform testing on Linux and macOS.
