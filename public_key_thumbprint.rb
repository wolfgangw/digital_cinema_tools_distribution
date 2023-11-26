#!/usr/bin/env ruby
#
# public_key_thumbprint.rb calculates the public key thumbprint of X509 certificates
#
# Wolfgang Woehl 2012-2023
#
# See https://bugs.ruby-lang.org/issues/4421 for a related ticket and discussion
#
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
AppName = File.basename __FILE__

require 'openssl'
require 'base64'

if ARGV.size < 1
  puts "Usage: #{ AppName } <cert> [<more certs>]"
  exit 1
end

ARGV.each do |arg|
  begin
    cert = OpenSSL::X509::Certificate.new( open arg )
  rescue Exception => e
    puts "#{ arg }: #{ e.message }"
    exit 1
    next
  end
  pkey_der = OpenSSL::ASN1::Sequence(
    [
      OpenSSL::ASN1::Integer( cert.public_key.n ),
      OpenSSL::ASN1::Integer( cert.public_key.e )
    ]
  ).to_der
  public_key_thumbprint = OpenSSL::Digest.new( 'sha1', pkey_der ).digest
  public_key_thumbprint_b64 = Base64.encode64( public_key_thumbprint ).chomp
  public_key_thumbprint_b16 = public_key_thumbprint.unpack( 'H2' * 20 ).join

  puts "Note: If present, dnQualifier in #{ arg }'s Subject shall match calculated public key thumbprint b64"
  puts "Subject: #{ cert.subject.to_s }"
  puts "Public key thumbprint b64: #{ public_key_thumbprint_b64 }"
  puts "Public key thumbprint b16: #{ public_key_thumbprint_b16 }"
end

exit 0

