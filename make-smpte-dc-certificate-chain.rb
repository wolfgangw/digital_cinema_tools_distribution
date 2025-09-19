#!/usr/bin/env ruby
#
# make-smpte-dc-certificate-chain.rb
#
# Creates digital cinema compliant certificates as specified
# by SMPTE 430-2-2006 D-Cinema Operations -- Digital Certificate.
# Leaf certificates will be useable for
#   - XML signature as signer certificate
#   - SM target for DKDM generation
#
# Wolfgang Woehl 2010-2025
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
serials = Array.new
#
specified_serials_upper_bound = 2 ** 64
xdc_serials_upper_bound = 2 ** 63 - 1 # Max value signed 64 bit integer
dolby_dss220_serials_upper_bound = 2 ** 32 - 1
my_serials_upper_bound = ( dolby_dss220_serials_upper_bound - 1 ) / 2 # Give them 1 more bit
4.times do |n| serials << rand( my_serials_upper_bound ) end
serials = serials.sort

# do not reach into 10.2038 which is beyond unix timestamp issues occurring on 19.01.2038
days = 4700

if ARGV.size != 1
  puts "Domain name required (e.g. 'example.org')"
  exit 1
else
  if ARGV.first =~ /.+\..+/
    domain = ARGV.first
  else
    puts "Please specify domain name with 2 name components, separated with a period (e.g. 'example.org')"
    exit 1
  end
end

### Root CA
#
puts "Generating ca0 key..."
`openssl genrsa -out #{ domain }.ca0.key 2048`

ca0_cnf = <<EOF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions	= v3_ca
string_mask = "default"
[ v3_ca ]
basicConstraints = critical,CA:true,pathlen:3
keyUsage = keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer:always
[ req_distinguished_name ]
O = Unique organization name
OU = Organization unit
CN = Entity and dnQualifier
EOF
File.open( 'ca0.cnf', 'w' ) { |f| f.write( ca0_cnf ) }

ca0_dnq = `openssl rsa -outform PEM -pubout -in #{ domain }.ca0.key | openssl base64 -d | dd bs=1 skip=24 2>/dev/null | openssl sha1 -binary | openssl base64`.chomp
ca0_dnq = ca0_dnq.gsub( '/', '\/' )
puts ca0_dnq.inspect
#
# this is broken - the quoting protection does not make it through
# thus, whenever there is a '+' in a generated thumbprint, the
# cert will fail for dnQualifier mismatch
# workaround for now: generate new keys/certs until chance gives
# you a set of thumbprints without '+'
#
ca0_dnq = ca0_dnq.gsub( '+', '\+' )
puts ca0_dnq.inspect
ca0_subject = "/O=#{ domain }/OU=#{ domain }/CN=.ca0.#{ domain }/dnQualifier=" + ca0_dnq

puts "Generating ca0 PEM..."
`openssl req -new -x509 -sha256 -config ca0.cnf -days #{ days } -set_serial #{ serials[0] } -subj "#{ ca0_subject }" -key #{ domain }.ca0.key -outform PEM -out #{ domain }.ca0.pem`
###


### Intermediate CA
puts "Generating ca1 key..."
`openssl genrsa -out #{ domain }.ca1.key 2048`

ca1_cnf = <<EOF
[ default ]
distinguished_name	= req_distinguished_name
x509_extensions	= v3_ca
string_mask = "default"
[ v3_ca ]
basicConstraints = critical,CA:true,pathlen:2
keyUsage = keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer:always
[ req_distinguished_name ]
O = Unique organization name
OU = Organization unit
CN = Entity and dnQualifier
EOF
File.open( 'ca1.cnf', 'w' ) { |f| f.write( ca1_cnf ) }

ca1_dnq = `openssl rsa -outform PEM -pubout -in #{ domain }.ca1.key | openssl base64 -d | dd bs=1 skip=24 2>/dev/null | openssl sha1 -binary | openssl base64`.chomp
ca1_dnq = ca1_dnq.gsub( '/', '\/' )
puts ca1_dnq.inspect
#
# this is broken - the quoting protection does not make it through
# thus, whenever there is a '+' in a generated thumbprint, the
# cert will fail for dnQualifier mismatch
# workaround for now: generate new keys/certs until chance gives
# you a set of thumbprints without '+'
#
ca1_dnq = ca1_dnq.gsub( '+', '\+' )
puts ca1_dnq.inspect
ca1_subject = "/O=#{ domain }/OU=#{ domain }/CN=.ca1.#{ domain }/dnQualifier=" + ca1_dnq

puts "Generating ca1 CSR..."
`openssl req -new -config ca1.cnf -subj "#{ ca1_subject }" -key #{ domain }.ca1.key -out #{ domain }.ca1.csr`
puts "Generating ca1 PEM..."
`openssl x509 -req -sha256 -days #{ days - 1 } -CA #{ domain }.ca0.pem -CAkey #{ domain }.ca0.key -set_serial #{ serials[1] } -in #{ domain }.ca1.csr -extfile ca1.cnf -extensions v3_ca -out #{ domain }.ca1.pem`
###


### Signer (CS) leaf certificate
puts "Generating cs key..."
`openssl genrsa -out #{ domain }.cs.key 2048`

cs_cnf = <<EOF
[ default ]
distinguished_name	= req_distinguished_name
x509_extensions	= v3_ca
string_mask = "default"
[ v3_ca ]
# See SMPTE 430-2-2006 section 6.2 Validation Rules - Check 5
basicConstraints = critical,CA:false
keyUsage = digitalSignature,keyEncipherment
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
[ req_distinguished_name ]
O = Unique organization name
OU = Organization unit
CN = Entity and dnQualifier
EOF
File.open( 'cs.cnf', 'w' ) { |f| f.write( cs_cnf ) }

cs_dnq = `openssl rsa -outform PEM -pubout -in #{ domain }.cs.key | openssl base64 -d | dd bs=1 skip=24 2>/dev/null | openssl sha1 -binary | openssl base64`.chomp
cs_dnq = cs_dnq.gsub( '/', '\/' )
puts cs_dnq.inspect
#
# this is broken - the quoting protection does not make it through
# thus, whenever there is a '+' in a generated thumbprint, the
# cert will fail for dnQualifier mismatch
# workaround for now: generate new keys/certs until chance gives
# you a set of thumbprints without '+'
#
cs_dnq = cs_dnq.gsub( '+', '\+' )
puts cs_dnq.inspect
cs_subject = "/O=#{ domain }/OU=#{ domain }/CN=CS.#{ domain }/dnQualifier=" + cs_dnq

puts "Generating cs CSR..."
`openssl req -new -config cs.cnf -subj "#{ cs_subject }" -key #{ domain }.cs.key -outform PEM -out #{ domain }.cs.csr`
puts "Generating cs PEM..."
`openssl x509 -req -sha256 -days #{ days - 2 } -CA #{ domain }.ca1.pem -CAkey #{ domain }.ca1.key -set_serial #{ serials[2] } -in #{ domain }.cs.csr -extfile cs.cnf -extensions v3_ca -out #{ domain }.cs.pem`
###


### Target (SM) leaf certificate
puts "Generating sm key..."
`openssl genrsa -out #{ domain }.sm.key 2048`

sm_cnf = <<EOF
[ default ]
distinguished_name	= req_distinguished_name
x509_extensions	= v3_ca
string_mask = "default"
[ v3_ca ]
# See SMPTE 430-2-2006 section 6.2 Validation Rules - Check 5
basicConstraints = critical,CA:false
keyUsage = digitalSignature,keyEncipherment
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer:always
[ req_distinguished_name ]
O = Unique organization name
OU = Organization unit
CN = Entity and dnQualifier
EOF
File.open( 'sm.cnf', 'w' ) { |f| f.write( sm_cnf ) }

sm_dnq = `openssl rsa -outform PEM -pubout -in #{ domain }.sm.key | openssl base64 -d | dd bs=1 skip=24 2>/dev/null | openssl sha1 -binary | openssl base64`.chomp
sm_dnq = sm_dnq.gsub( '/', '\/' )
puts sm_dnq.inspect
#
# this is broken - the quoting protection does not make it through
# thus, whenever there is a '+' in a generated thumbprint, the
# cert will fail for dnQualifier mismatch
# workaround for now: generate new keys/certs until chance gives
# you a set of thumbprints without '+'
#
sm_dnq = sm_dnq.gsub( '+', '\+' )
puts sm_dnq.inspect
sm_subject = "/O=#{ domain }/OU=#{ domain }/CN=SM.#{ domain }/dnQualifier=" + sm_dnq

puts "Generating sm CSR..."
`openssl req -new -config sm.cnf -subj "#{ sm_subject }" -key #{ domain }.sm.key -outform PEM -out #{ domain }.sm.csr`
puts "Generating sm PEM..."
`openssl x509 -req -sha256 -days #{ days - 2 } -CA #{ domain }.ca1.pem -CAkey #{ domain }.ca1.key -set_serial #{ serials[3] } -in #{ domain }.sm.csr -extfile sm.cnf -extensions v3_ca -out #{ domain }.sm.pem`
###


### Keep configuration and CSRs
`mkdir confs csrs ; mv ./*.cnf confs/ ; mv ./*.csr csrs/`

### Print out issuer and subject information for each of the generated certificates
puts "\n+++ Certificate info +++\n"
[ [ 'CA 0', "#{ domain }.ca0.pem" ], [ 'CA 1', "#{ domain }.ca1.pem" ], [ 'Signer', "#{ domain }.cs.pem" ], [ 'Target/Lab', "#{ domain }.sm.pem" ] ].each do |t|
  puts "\n#{ t.first } (#{ t.last }):\n#{ `openssl x509 -noout -subject -in #{ t.last }` }   signed by\n #{ `openssl x509 -noout -issuer -in #{ t.last }` }"
end


# For illustration: Verify certificates and write certificate chain
puts "\n+++ Verify certificates and write dc-certificate-chain +++\n\n"
puts `openssl verify -CAfile #{ domain }.ca0.pem #{ domain }.ca0.pem`
`cp #{ domain }.ca0.pem #{ domain }.cs.chain.cert`
puts `openssl verify -CAfile #{ domain }.cs.chain.cert #{ domain }.ca1.pem`
`cat #{ domain }.ca1.pem >> #{ domain }.cs.chain.cert`
puts `openssl verify -CAfile #{ domain }.cs.chain.cert #{ domain }.cs.pem`
`cat #{ domain }.cs.pem >> #{ domain }.cs.chain.cert`

`cp #{ domain }.ca0.pem #{ domain }.sm.chain.cert`
`cat #{ domain }.ca1.pem >> #{ domain }.sm.chain.cert`
`cat #{ domain }.sm.pem >> #{ domain }.sm.chain.cert`
puts `openssl verify -CAfile #{ domain }.sm.chain.cert #{ domain }.sm.pem`

puts "\nDONE"

