#!/usr/bin/env bash
set -e

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for required_gem in nokogiri ttfunk base64
 do
  if gem list -i "$required_gem" > /dev/null 2>&1
  then
    echo "dcp_inspect: gem $required_gem OK"
  else
    gem install "$required_gem" --no-document
    echo "dcp_inspect: Installed gem $required_gem"
  fi
done
rbenv rehash
ruby "$script_dir/verify-dcp-inspect.rb" --runtime
