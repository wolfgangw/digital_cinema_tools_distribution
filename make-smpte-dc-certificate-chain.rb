#!/usr/bin/env ruby
#
# make-smpte-dc-certificate-chain.rb
#
# Creates 4 related digital cinema compliant certificates as specified
# by SMPTE 430-2-2017 D-Cinema Operations -- Digital Certificate.
# The two leaf certificates are usable as
#   - XML Signer certificate with the CS role
#   - DKDM target certificate with the SM role
#
# Wolfgang Woehl 2010-2026
# v4.2026.08.28.st430-2-compliance (PRINTABLESTRING, dnQualifier fix)
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
require 'base64'
require 'fileutils'
require 'open3'
require 'openssl'
require 'tempfile'
require 'time'
require 'tmpdir'

DN_ATTRIBUTES = %w[O OU CN dnQualifier].freeze
PRINTABLE_STRING_PATTERN = /\A[A-Za-z0-9 '()+,\-.\/:=?]*\z/
RSA_KEY_BITS = 2048
RSA_PUBLIC_EXPONENT = 65_537
PROGRESS_LABEL_WIDTH = 62
SECONDS_PER_DAY = 86_400
ROOT_VALIDITY_NOT_AFTER = Time.utc(2049, 11, 30, 23, 59, 59)
# Both `openssl req` and `openssl x509` gained explicit notBefore/notAfter
# setters in OpenSSL 3.4. The script relies on them to nest validity periods.
MINIMUM_OPENSSL_VERSION = [ 3, 4, 0 ].freeze
MINIMUM_OPENSSL_VERSION_STRING = MINIMUM_OPENSSL_VERSION.join('.')

def valid_domain?(domain)
  return false unless domain.ascii_only? && domain.bytesize.between?(3, 253)
  return false unless domain.match?(/\A[A-Za-z0-9.-]+\z/)

  labels = domain.split('.', -1)
  labels.size >= 2 && labels.all? do |label|
    label.bytesize.between?(1, 63) &&
      label.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\z/)
  end
end

def run_command!(description, *command)
  printf "  %-#{ PROGRESS_LABEL_WIDTH }s", description
  stdout, stderr, status = Open3.capture3(*command)
  if status.success?
    puts '[ok]'
    stdout
  else
    puts '[FAILED]'
    warn "\nCommand failed: #{ command.join(' ') }"
    warn stderr unless stderr.empty?
    warn stdout unless stdout.empty?
    exit 1
  end
end

def check_command(description, *command)
  printf "  %-#{ PROGRESS_LABEL_WIDTH }s", description
  stdout, stderr, status = Open3.capture3(*command)
  if status.success?
    puts '[ok]'
    nil
  else
    puts '[FAILED]'
    detail = [ stdout, stderr ].reject(&:empty?).join("\n").strip
    detail.empty? ? "#{ description } failed" : "#{ description }: #{ detail }"
  end
end

def preflight_check!(description)
  printf "  %-#{ PROGRESS_LABEL_WIDTH }s", description
  $stdout.flush
  result = yield
  puts '[ok]'
  result
rescue StandardError => e
  puts '[FAILED]'
  $stdout.flush
  warn "\nOpenSSL preflight failed: #{ e.message }"
  warn 'No certificate or private-key output was created by this run.'
  exit 1
end

def capture_preflight_command!(*command)
  stdout, stderr, status = Open3.capture3(*command)
  return [ stdout, stderr ] if status.success?

  detail = [ stdout, stderr ].reject(&:empty?).join("\n").strip
  message = "#{ command.take(2).join(' ') } exited with status #{ status.exitstatus }"
  message += ": #{ detail }" unless detail.empty?
  raise message
rescue Errno::ENOENT => e
  raise "cannot execute #{ command.first.inspect }: #{ e.message }"
end

def openssl_preflight!
  puts 'OpenSSL compatibility preflight'

  version_text = preflight_check!('Locate OpenSSL CLI and read its version') do
    stdout, = capture_preflight_command!('openssl', 'version')
    version = stdout.strip
    raise 'openssl version returned no version information' if version.empty?

    version
  end
  puts "    Detected: #{ version_text }"

  version_match = version_text.match(/\AOpenSSL\s+(\d+)\.(\d+)\.(\d+)(?:[^\d]|\z)/)
  preflight_check!("Require OpenSSL >= #{ MINIMUM_OPENSSL_VERSION_STRING }") do
    unless version_match
      raise "unsupported implementation or unrecognized version string: #{ version_text.inspect }; OpenSSL #{ MINIMUM_OPENSSL_VERSION_STRING } or newer is required"
    end

    parsed = version_match.captures.map(&:to_i)
    if (parsed <=> MINIMUM_OPENSSL_VERSION).negative?
      raise "found OpenSSL #{ parsed.join('.') }; OpenSSL #{ MINIMUM_OPENSSL_VERSION_STRING } or newer is required for explicit certificate validity boundaries"
    end
    parsed
  end

  preflight_check!('Check required req/x509 command options') do
    {
      'req' => %w[-not_before -not_after -set_serial],
      'x509' => %w[-not_before -not_after -set_serial]
    }.each do |subcommand, required_options|
      stdout, stderr = capture_preflight_command!('openssl', subcommand, '-help')
      help_text = "#{ stdout }\n#{ stderr }"
      missing_options = required_options.reject { |option| help_text.include?(option) }
      next if missing_options.empty?

      raise "openssl #{ subcommand } does not support #{ missing_options.join(', ') }"
    end
  end

  preflight_check!('Run disposable RSA/SHA-256 certificate-signing probe') do
    Dir.mktmpdir('smpte-cert-openssl-preflight-') do |directory|
      key_path = File.join(directory, 'probe.key')
      root_path = File.join(directory, 'probe-root.pem')
      csr_path = File.join(directory, 'probe.csr')
      leaf_path = File.join(directory, 'probe-leaf.pem')
      extensions_path = File.join(directory, 'probe.cnf')
      probe_not_before = Time.at(Time.now.to_i).utc - 60
      probe_not_after = probe_not_before + 3_600
      not_before_argument = probe_not_before.strftime('%Y%m%d%H%M%SZ')
      not_after_argument = probe_not_after.strftime('%Y%m%d%H%M%SZ')

      File.write(
        extensions_path,
        <<~CONFIG
          [ leaf ]
          basicConstraints = critical,CA:false
          keyUsage = digitalSignature,keyEncipherment
        CONFIG
      )
      capture_preflight_command!('openssl', 'genrsa', '-out', key_path, RSA_KEY_BITS.to_s)
      capture_preflight_command!(
        'openssl', 'req', '-new', '-x509', '-sha256', '-batch',
        '-subj', '/CN=OpenSSL capability probe root',
        '-addext', 'basicConstraints=critical,CA:true',
        '-addext', 'keyUsage=keyCertSign,cRLSign',
        '-not_before', not_before_argument, '-not_after', not_after_argument,
        '-set_serial', '1', '-key', key_path, '-out', root_path
      )
      capture_preflight_command!(
        'openssl', 'req', '-new', '-sha256', '-batch',
        '-subj', '/CN=OpenSSL capability probe leaf',
        '-key', key_path, '-out', csr_path
      )
      capture_preflight_command!(
        'openssl', 'x509', '-req', '-sha256',
        '-not_before', not_before_argument, '-not_after', not_after_argument,
        '-CA', root_path, '-CAkey', key_path, '-set_serial', '2',
        '-in', csr_path, '-extfile', extensions_path, '-extensions', 'leaf',
        '-out', leaf_path
      )
      capture_preflight_command!('openssl', 'verify', '-CAfile', root_path, leaf_path)

      root_certificate = OpenSSL::X509::Certificate.new(File.binread(root_path))
      leaf_certificate = OpenSSL::X509::Certificate.new(File.binread(leaf_path))
      [ root_certificate, leaf_certificate ].each do |certificate|
        unless certificate.not_before == probe_not_before && certificate.not_after == probe_not_after
          raise 'explicit certificate validity boundaries were not preserved'
        end
      end
      raise 'probe certificate signature verification failed' unless leaf_certificate.verify(root_certificate.public_key)
    end
  end

  version_text
end

def public_key_thumbprint(public_key)
  unless public_key.is_a?(OpenSSL::PKey::RSA)
    raise "Expected an RSA public key, got #{ public_key.class }"
  end

  # For rsaEncryption SubjectPublicKeyInfo, the BIT STRING contents are the
  # DER-encoded RSAPublicKey sequence. ST 430-2 section 5.4 hashes these bytes.
  rsa_public_key_der = OpenSSL::ASN1::Sequence(
    [
      OpenSSL::ASN1::Integer(public_key.n),
      OpenSSL::ASN1::Integer(public_key.e)
    ]
  ).to_der
  Base64.strict_encode64(OpenSSL::Digest::SHA1.digest(rsa_public_key_der))
end

def certificate_config(subject, ca:, pathlen: nil)
  subject.each do |attribute, value|
    unless value.match?(PRINTABLE_STRING_PATTERN)
      raise "#{ attribute } contains characters unavailable in ASN.1 PrintableString"
    end
  end

  basic_constraints = ca ? "critical,CA:true,pathlen:#{ pathlen }" : 'critical,CA:false'
  key_usage = ca ? 'keyCertSign,cRLSign' : 'digitalSignature,keyEncipherment'

  <<~CONFIG
    [ req ]
    prompt = no
    distinguished_name = req_distinguished_name
    x509_extensions = v3_certificate
    string_mask = nombstr

    [ req_distinguished_name ]
    O = #{ subject.fetch('O') }
    OU = #{ subject.fetch('OU') }
    CN = #{ subject.fetch('CN') }
    dnQualifier = #{ subject.fetch('dnQualifier') }

    [ v3_certificate ]
    basicConstraints = #{ basic_constraints }
    keyUsage = #{ key_usage }
    subjectKeyIdentifier = hash
    authorityKeyIdentifier = keyid:always,issuer:always
  CONFIG
end

def extension(cert, oid)
  cert.extensions.find { |candidate| candidate.oid == oid }
end

def validity_asn1_values(cert)
  certificate = OpenSSL::ASN1.decode(cert.to_der)
  to_be_signed = certificate.value.fetch(0)
  validity = to_be_signed.value.fetch(4)
  validity.value
end

def name_field(name, oid)
  matches = name.to_a.select { |entry| entry[0] == oid }
  matches.one? ? matches.first[1] : nil
end

def check_name(name, description, expected_values, errors)
  entries = name.to_a
  unexpected = entries.map(&:first) - DN_ATTRIBUTES
  errors << "#{ description } contains unexpected attributes: #{ unexpected.join(', ') }" unless unexpected.empty?

  DN_ATTRIBUTES.each do |attribute|
    matches = entries.select { |entry| entry[0] == attribute }
    if matches.size != 1
      errors << "#{ description } must contain exactly one #{ attribute } (found #{ matches.size })"
      next
    end

    value, type = matches.first.values_at(1, 2)
    errors << "#{ description } #{ attribute } is not PrintableString (ASN.1 type #{ type })" unless type == OpenSSL::ASN1::PRINTABLESTRING
    errors << "#{ description } #{ attribute } has value #{ value.inspect}, expected #{ expected_values.fetch(attribute).inspect }" unless value == expected_values.fetch(attribute)
  end
end

def verify_smpte_certificate(spec, cert, parent_cert)
  errors = []
  expected_thumbprint = public_key_thumbprint(cert.public_key)
  expected_subject = {
    'O' => spec.fetch(:domain),
    'OU' => spec.fetch(:domain),
    'CN' => spec.fetch(:cn),
    'dnQualifier' => expected_thumbprint
  }
  expected_issuer = parent_cert ? parent_cert.subject.to_a.to_h { |oid, value, _type| [ oid, value ] } : expected_subject

  errors << 'certificate version is not X.509v3' unless cert.version == 2
  serial = cert.serial.to_i
  unless serial.positive? && serial.bit_length <= 64
    errors << "serial number #{ serial } is not a positive integer of 64 bits or fewer"
  end
  errors << "signature algorithm is #{ cert.signature_algorithm }, expected sha256WithRSAEncryption" unless cert.signature_algorithm.casecmp?('sha256WithRSAEncryption')
  errors << "notBefore is #{ cert.not_before.utc.iso8601 }, expected #{ spec.fetch(:not_before).iso8601 }" unless cert.not_before == spec.fetch(:not_before)
  errors << "notAfter is #{ cert.not_after.utc.iso8601 }, expected #{ spec.fetch(:not_after).iso8601 }" unless cert.not_after == spec.fetch(:not_after)
  validity_asn1_values(cert).each do |value|
    unless value.is_a?(OpenSSL::ASN1::UTCTime)
      errors << "validity timestamp #{ value.value.utc.iso8601 } is encoded as #{ value.class.name.split('::').last }, expected UTCTime"
    end
  end

  key = cert.public_key
  if key.is_a?(OpenSSL::PKey::RSA)
    errors << "RSA modulus is #{ key.n.num_bits } bits, expected #{ RSA_KEY_BITS }" unless key.n.num_bits == RSA_KEY_BITS
    errors << "RSA public exponent is #{ key.e }, expected #{ RSA_PUBLIC_EXPONENT }" unless key.e == RSA_PUBLIC_EXPONENT
  else
    errors << "public key is #{ key.class }, expected RSA"
  end

  check_name(cert.subject, "#{ spec.fetch(:label) } subject", expected_subject, errors)
  check_name(cert.issuer, "#{ spec.fetch(:label) } issuer", expected_issuer, errors)
  errors << 'subject and issuer OrganizationName differ' unless name_field(cert.subject, 'O') == name_field(cert.issuer, 'O')

  expected_issuer_name = parent_cert ? parent_cert.subject : cert.subject
  errors << 'issuer name does not exactly match the parent subject name' unless cert.issuer.to_der == expected_issuer_name.to_der
  signing_key = parent_cert ? parent_cert.public_key : cert.public_key
  errors << 'certificate signature does not verify with the issuer public key' unless cert.verify(signing_key)

  if parent_cert
    errors << 'notBefore precedes the parent certificate validity' if cert.not_before < parent_cert.not_before
    errors << 'notAfter exceeds the parent certificate validity' if cert.not_after > parent_cert.not_after
  end

  constraints = extension(cert, 'basicConstraints')
  if constraints.nil?
    errors << 'basicConstraints extension is missing'
  else
    errors << 'basicConstraints is not marked critical' unless constraints.critical?
    if spec.fetch(:ca)
      errors << 'basicConstraints does not set CA:TRUE' unless constraints.value.include?('CA:TRUE')
      errors << "basicConstraints does not contain pathlen:#{ spec.fetch(:pathlen) }" unless constraints.value.include?("pathlen:#{ spec.fetch(:pathlen) }")
    else
      errors << 'basicConstraints does not set CA:FALSE' unless constraints.value == 'CA:FALSE'
    end
  end

  key_usage = extension(cert, 'keyUsage')
  if key_usage.nil?
    errors << 'keyUsage extension is missing'
  else
    actual_usage = key_usage.value.split(', ').sort
    expected_usage = spec.fetch(:ca) ? [ 'CRL Sign', 'Certificate Sign' ] : [ 'Digital Signature', 'Key Encipherment' ]
    errors << "keyUsage is #{ key_usage.value }, expected #{ expected_usage.join(', ') }" unless actual_usage == expected_usage.sort
  end

  authority_key_identifier = extension(cert, 'authorityKeyIdentifier')
  if authority_key_identifier.nil?
    errors << 'authorityKeyIdentifier extension is missing'
  else
    %w[keyid: DirName: serial:].each do |component|
      errors << "authorityKeyIdentifier is missing #{ component.delete_suffix(':') }" unless authority_key_identifier.value.include?(component)
    end
  end

  [ errors, expected_thumbprint ]
rescue StandardError => e
  [ [ "could not inspect certificate: #{ e.message }" ], nil ]
end

if ARGV.size != 1 || !valid_domain?(ARGV.first)
  warn "Usage: #{ File.basename($PROGRAM_NAME) } <domain>"
  warn "Domain must contain at least two DNS labels and only ASCII letters, digits, hyphens, and periods."
  warn "Example: #{ File.basename($PROGRAM_NAME) } example.org"
  exit 1
end

domain = ARGV.first
openssl_version = openssl_preflight!

# Capture one common start time and use fixed end dates in November 2049. The
# one-day reduction at each issuing level keeps every child validity period
# contained within its parent's validity period. ST 430-2 requires dates through
# 2049 to be encoded as UTCTime.
validity_start = Time.now.utc
validity_start = Time.utc(
  validity_start.year,
  validity_start.month,
  validity_start.day,
  validity_start.hour,
  validity_start.min,
  validity_start.sec
)
if validity_start >= ROOT_VALIDITY_NOT_AFTER - 2 * SECONDS_PER_DAY
  warn "Cannot create a positive leaf-certificate validity period ending in November 2049."
  exit 1
end
# ST 430-2 permits serials up to 2**64, but XDC servers fail above 2**63-1
# and Dolby DSS200 servers fail above 2**32-1, so stay within the latter limit.
serials = []
serial_upper_bound = (2 ** 32 - 2) / 2
serials << rand(1..serial_upper_bound) until serials.uniq.size == 4
serials = serials.uniq.sort

FileUtils.mkdir_p('confs')
FileUtils.mkdir_p('csrs')

# The CA certificates are needed while signing and verifying, but the complete
# copies delivered to the user live in each leaf-first chain. Keep the working
# CA certificate files outside the output directory and remove them on exit.
temporary_ca_certificates = %i[ca0 ca1].to_h do |id|
  file = Tempfile.new([ "smpte-#{ id }-certificate-", '.pem' ])
  file.close
  [ id, file ]
end
at_exit { temporary_ca_certificates.each_value(&:unlink) }

specs = [
  { id: :ca0, label: 'Root CA', cn: ".ca0.#{ domain }", ca: true, pathlen: 3, validity_end_offset_days: 0, parent: nil },
  { id: :ca1, label: 'Intermediate CA', cn: ".ca1.#{ domain }", ca: true, pathlen: 2, validity_end_offset_days: 1, parent: :ca0 },
  { id: :cs, label: 'Content Signer (CS)', cn: "CS.#{ domain }", ca: false, validity_end_offset_days: 2, parent: :ca1 },
  { id: :sm, label: 'Security Manager target (SM)', cn: "SM.#{ domain }", ca: false, validity_end_offset_days: 2, parent: :ca1 }
]

specs.each_with_index do |spec, index|
  stem = spec.fetch(:id)
  spec[:domain] = domain
  spec[:serial] = serials.fetch(index)
  spec[:not_before] = validity_start
  spec[:not_after] = ROOT_VALIDITY_NOT_AFTER - spec.fetch(:validity_end_offset_days) * SECONDS_PER_DAY
  spec[:key_path] = "#{ domain }.#{ stem }.key"
  spec[:cert_path] = if spec.fetch(:ca)
                       temporary_ca_certificates.fetch(stem).path
                     else
                       "#{ domain }.#{ stem }.pem"
                     end
  spec[:config_path] = File.join('confs', "#{ stem }.cnf")
  spec[:csr_path] = File.join('csrs', "#{ domain }.#{ stem }.csr") unless spec[:parent].nil?
end
spec_by_id = specs.to_h { |spec| [ spec.fetch(:id), spec ] }

puts
puts 'SMPTE ST 430-2:2017 certificate-chain generator'
puts "  Domain:             #{ domain }"
puts "  OpenSSL:            #{ openssl_version }"
puts "  Chain:              Root CA -> Intermediate CA -> CS / SM"
puts "  DN string encoding: PrintableString"
puts "  Root validity end:  #{ ROOT_VALIDITY_NOT_AFTER.iso8601 }"
puts "  Output directory:   #{ Dir.pwd }"
puts

specs.each_with_index do |spec, index|
  puts "[#{ index + 1 }/#{ specs.size }] #{ spec.fetch(:label) }"
  run_command!(
    "Generate #{ RSA_KEY_BITS }-bit RSA private key",
    'openssl', 'genrsa', '-out', spec.fetch(:key_path), RSA_KEY_BITS.to_s
  )

  private_key = OpenSSL::PKey.read(File.binread(spec.fetch(:key_path)))
  dn_qualifier = public_key_thumbprint(private_key)
  spec[:dn_qualifier] = dn_qualifier
  subject = {
    'O' => domain,
    'OU' => domain,
    'CN' => spec.fetch(:cn),
    'dnQualifier' => dn_qualifier
  }
  File.write(
    spec.fetch(:config_path),
    certificate_config(subject, ca: spec.fetch(:ca), pathlen: spec[:pathlen])
  )
  printf "  %-#{ PROGRESS_LABEL_WIDTH }s%s\n", 'Public-key thumbprint (dnQualifier)', dn_qualifier
  printf "  %-#{ PROGRESS_LABEL_WIDTH }s%s\n", 'Write OpenSSL configuration', spec.fetch(:config_path)

  if spec[:parent].nil?
    run_command!(
      'Create self-signed certificate',
      'openssl', 'req', '-new', '-x509', '-sha256', '-batch',
      '-config', spec.fetch(:config_path),
      '-not_before', spec.fetch(:not_before).strftime('%Y%m%d%H%M%SZ'),
      '-not_after', spec.fetch(:not_after).strftime('%Y%m%d%H%M%SZ'),
      '-set_serial', spec.fetch(:serial).to_s,
      '-key', spec.fetch(:key_path),
      '-outform', 'PEM', '-out', spec.fetch(:cert_path)
    )
  else
    parent = spec_by_id.fetch(spec.fetch(:parent))
    run_command!(
      'Create certificate signing request',
      'openssl', 'req', '-new', '-sha256', '-batch',
      '-config', spec.fetch(:config_path),
      '-key', spec.fetch(:key_path),
      '-outform', 'PEM', '-out', spec.fetch(:csr_path)
    )
    run_command!(
      "Sign certificate with #{ parent.fetch(:label) }",
      'openssl', 'x509', '-req', '-sha256',
      '-not_before', spec.fetch(:not_before).strftime('%Y%m%d%H%M%SZ'),
      '-not_after', spec.fetch(:not_after).strftime('%Y%m%d%H%M%SZ'),
      '-CA', parent.fetch(:cert_path), '-CAkey', parent.fetch(:key_path),
      '-set_serial', spec.fetch(:serial).to_s,
      '-in', spec.fetch(:csr_path),
      '-extfile', spec.fetch(:config_path), '-extensions', 'v3_certificate',
      '-outform', 'PEM', '-out', spec.fetch(:cert_path)
    )
  end
  puts
end

certificates = specs.to_h do |spec|
  [ spec.fetch(:id), OpenSSL::X509::Certificate.new(File.binread(spec.fetch(:cert_path))) ]
end

puts 'Certificate details'
specs.each do |spec|
  cert = certificates.fetch(spec.fetch(:id))
  certificate_location = spec.fetch(:ca) ? 'embedded in chain outputs (no standalone PEM)' : spec.fetch(:cert_path)
  puts "  #{ spec.fetch(:label) }: #{ certificate_location }"
  puts "    Subject CN:       #{ name_field(cert.subject, 'CN') }"
  puts "    Issuer CN:        #{ name_field(cert.issuer, 'CN') }"
  puts "    Serial:           #{ cert.serial } (0x#{ cert.serial.to_s(16).upcase })"
  puts "    Validity:         #{ cert.not_before.utc.iso8601 } .. #{ cert.not_after.utc.iso8601 }"
  puts "    dnQualifier:      #{ name_field(cert.subject, 'dnQualifier') }"
end
puts

puts 'Verification'
verification_errors = []
root = spec_by_id.fetch(:ca0)
intermediate = spec_by_id.fetch(:ca1)

verification_errors << check_command(
  'OpenSSL root self-verification',
  'openssl', 'verify', '-CAfile', root.fetch(:cert_path), root.fetch(:cert_path)
)
verification_errors << check_command(
  'OpenSSL intermediate-chain verification',
  'openssl', 'verify', '-CAfile', root.fetch(:cert_path), intermediate.fetch(:cert_path)
)
%i[cs sm].each do |id|
  leaf = spec_by_id.fetch(id)
  verification_errors << check_command(
    "OpenSSL #{ leaf.fetch(:label) } chain verification",
    'openssl', 'verify', '-CAfile', root.fetch(:cert_path),
    '-untrusted', intermediate.fetch(:cert_path), leaf.fetch(:cert_path)
  )
end

specs.each do |spec|
  parent_cert = spec[:parent] ? certificates.fetch(spec.fetch(:parent)) : nil
  errors, thumbprint = verify_smpte_certificate(spec, certificates.fetch(spec.fetch(:id)), parent_cert)
  unless thumbprint == spec.fetch(:dn_qualifier)
    errors << 'certificate public key differs from the generated private key'
  end
  printf "  %-#{ PROGRESS_LABEL_WIDTH }s", "ST 430-2 checks: #{ spec.fetch(:label) }"
  if errors.empty?
    puts '[ok]'
  else
    puts '[FAILED]'
    errors.each { |error| verification_errors << "#{ spec.fetch(:label) }: #{ error }" }
  end
end

if certificates.fetch(:cs).public_key.to_der == certificates.fetch(:sm).public_key.to_der
  verification_errors << 'CS and SM certificates unexpectedly contain the same public key'
end
if serials.uniq.size != specs.size
  verification_errors << 'certificate serial numbers are not unique'
end
verification_errors.compact!

unless verification_errors.empty?
  warn "\nVERIFICATION FAILED (#{ verification_errors.size } problem#{ verification_errors.one? ? '' : 's' })"
  verification_errors.each { |error| warn "  - #{ error }" }
  exit 1
end

cs_chain_path = "#{ domain }.cs.chain.cert"
sm_chain_path = "#{ domain }.sm.chain.cert"
File.binwrite(
  cs_chain_path,
  [ :cs, :ca1, :ca0 ].map { |id| File.binread(spec_by_id.fetch(id).fetch(:cert_path)) }.join
)
File.binwrite(
  sm_chain_path,
  [ :sm, :ca1, :ca0 ].map { |id| File.binread(spec_by_id.fetch(id).fetch(:cert_path)) }.join
)

puts
puts 'All certificate and chain checks passed.'
puts 'Output'
puts "  Chain order:        leaf -> intermediate -> root"
puts "  CS chain:           #{ cs_chain_path }"
puts "  SM chain:           #{ sm_chain_path }"
puts "  Private keys:       #{ domain }.{ca0,ca1,cs,sm}.key"
puts "  Leaf certificates:  #{ domain }.{cs,sm}.pem"
puts "  CA certificates:    embedded in both chains (no standalone PEMs)"
puts "  Configurations:     confs/"
puts "  CSRs:               csrs/"
