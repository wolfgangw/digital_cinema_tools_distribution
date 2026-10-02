# encoding: utf-8
require_relative "orchestrator"
require_relative "audio_analysis"
#
# dcp_inspect checks and validates DCPs (Digital Cinema Packages)
#
# 2011-2026 Wolfgang Woehl
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
module DcpInspect
  module Inspection
    class Runtime
AppName = File.basename( $0 )
AppVersion = "v#{ DcpInspect::VERSION }"
AppStartSeconds = Time.now
XSDDir = File.expand_path('../../../xsd', __dir__)
#
# dcp_inspect is a tool for deep inspection and validation of digital
# cinema packages (DCP). This includes integrity checks, asset inspection,
# schema validation, signature and certificate verification and
# composition summaries
#
# Usage:
#
#   dcp_inspect --help
#   dcp_inspect /path/to/dir
#
# Installation:
#
#   See https://github.com/wolfgangw/digital_cinema_tools_distribution/wiki
#   for an easy-to-use setup script. This will install everything required.
#
# Features:
#
# - Will find and check all DCPs in a filesystem tree
#
# - Runs schema validation on all infrastructure files and DCSubtitle.
#   Validation errors will be reported but dcp_inspect will still try to
#   inspect the contents of non-valid files.
#
# - Checks and verifies signatures
#
# - Reports detailed composition information
#
# - Deep-inspects compositions. This includes composition type consistency
#   and completeness checks. dcp_inspect goes through some lengths to determine
#   a composition's type (SMPTE/Interop).
#
# - Checks presence and sanity of DCSubtitle resources
#
# - Reports in detail all errors encountered
#
# See [Examples](https://github.com/wolfgangw/backports/wiki/Example-output-from-dcp_inspect).
#
# Manual installation / Requirements:
#
#   If you prefer manual installation you will need the following:
#
#  - $ git clone git://github.com/wolfgangw/backports.git
#  - asdcplib and its cli tools (http://www.cinecert.com/asdcplib/)
#  - Nokogiri, a ruby wrapper for libxml2 (gem install nokogiri)
#  - dcp_inspect requires xsd/ next to it.
#
#   Run
#     $ git pull
#   in backports to keep up-to-date.
#
#
# Thanks to the Nokogiri team. You're a wicked crew.
# Thanks to Julik for his Timecode library.
#   https://github.com/guerilla-di/timecode
# Thanks to Mattias Mattsson for DCSubtitle.v1.mattsson.xsd and
#   great feedback from Göteborg International Film Festival.
# Thanks to Mike Radford and Tammo Buhren for test materials.
# Thanks to Alexis Michaltsis for interesting test cases and feedback.
# Thanks to Lilian Lefranc for constant feedback and a donation
#   which clearly exceeded what can safely be called a gesture.
#   Appreciated and you rock.
# Thanks to Adrianne Jorge for a great user report from Sundance and Sarasota.
# Thanks to Terrence Meiczinger.
#

# ruby version and platform
RubyVersionPlatform = [ RUBY_ENGINE, RUBY_VERSION, RUBY_PLATFORM ].join( ' ' )

# Exit codes
DCP_OK = 0
DCP_ERROR = 1
NO_ARG = 2
TOO_MANY_ARGS = 3
ARG_NOT_A_DIR = 4
XML_CATALOG_NOT_FOUND = 5
XSD_STORE_NOT_FOUND = 6
BAD_HASH_LIMIT_ARG = 7
LOGFILE_WRITE_ERROR = 8
FILE_ACCESS_ERROR = 9
LOGFILE_EXISTS_ERROR = 10
GEM_LOAD_ERROR = 11
REQUIRED_COMMAND_NOT_FOUND = 12
ENV_DCP_INSPECT_DIR_NOT_SET = 13
DCP_INSPECT_DIR_NOT_WRITABLE = 14
AUTOLOGFILE_WRITE_ERROR = 15
MKFIFO_FAIL = 16
RMFIFO_FAIL = 17
USER_INTERRUPT = 18
RUBY_VERSION_NOT_SUPPORTED = 19
RUBY_TYPE_ERROR = 20
RUBY_EXCEPTION = 21
GRACEFUL_SHUTDOWN = 22
LIB_LOAD_ERROR = 23
RUBY_NAME_ERROR = 24
RUBY_ARGUMENT_ERROR = 25
# Exit code 26 used to report an obsolete fd/fdfind version. Discovery is now
# implemented with Ruby's standard library, so the value remains reserved for
# compatibility with callers that may have recorded it.
REQUIRED_COMMAND_FDFIND_VERSION_TOO_OLD = 26
NO_VALID_AUTOLOG_FILENAME = 27

# Constants
PictureBitrateMaxDCI = 250.0 # Mb/s
PictureBitrateMaxDCISafetyMargin = 2.0 # percent
PictureBitrateMaxDCISafe = ( PictureBitrateMaxDCI / 100 * ( 100 - PictureBitrateMaxDCISafetyMargin ) ).round( 2 )
PictureBitrateMaxHFR = 400.0 # Mb/s

# Required libs
required_libs = [
  'optparse',
  'ostruct',
  'pathname',
  'shellwords',
  'openssl',
  'stringio',
  'json',
  'io/console',
  'fileutils',
  'open3',
  'date',
]
if RUBY_VERSION < '3.4'
  required_libs << 'base64'
end
missing_libs = []
required_libs.each do |lib|
  begin
    require lib
  rescue LoadError => e
    puts e.inspect
    missing_libs << lib
  end
end
if missing_libs.any?
  raise DcpInspect::Inspection::Error.new(
    "Ruby installation (#{RubyVersionPlatform}) is missing required libraries (#{missing_libs.join(', ')})",
    LIB_LOAD_ERROR
  )
end
# Required gems
required_gems = [
  'nokogiri',
  'ttfunk',
]
if RUBY_VERSION >= '3.4'
  required_gems << 'base64'
end
missing_gems = []
required_gems.each do |gem|
  begin
    require gem
  rescue LoadError => e
    puts e.inspect
    missing_gems << gem
  end
end
if missing_gems.any?
  raise DcpInspect::Inspection::Error.new(
    "Please run 'gem install #{missing_gems.join(' ')}' and try again",
    GEM_LOAD_ERROR
  )
end

# * lib/logger.rb
DLogger = DcpInspect::UI::DLogger
TFSColor = DcpInspect::UI::TFSColor
TFSRenderer = DcpInspect::UI::TFSRenderer
TFSLogger = DcpInspect::UI::TFSLogger

InspectionEvent = DcpInspect::Model::InspectionEvent
CheckResult = DcpInspect::Model::CheckResult
InspectionRun = DcpInspect::Model::InspectionRun
DcpPackage = DcpInspect::Model::DcpPackage
ModelNode = DcpInspect::Model::ModelNode
AssetMap = DcpInspect::Model::AssetMap
PackingList = DcpInspect::Model::PackingList
CompositionPlaylist = DcpInspect::Model::CompositionPlaylist
Reel = DcpInspect::Model::Reel
ReelAsset = DcpInspect::Model::ReelAsset
DcpAsset = DcpInspect::Model::DcpAsset

attr_reader :logger, :options, :dashboard

def initialize(options:, logger: nil, stdout: $stdout, dashboard: nil, started_at: Time.now)
  @options = options
  @dashboard = dashboard
  @tfs_dashboard = dashboard
  @logger = logger || DLogger.new('', options, stdout)
  @started_at = started_at
  @run_datetime = time_to_datetime(started_at)
  @asdcplib_version = MxfTools.asdcplib_version.join('.')
  @filesystem_walker = DcpInspect::FilesystemWalker.new
  @schema_store = DcpInspect::XML::SchemaStore.new(XSDDir)
  @document_reader = DcpInspect::XML::DocumentReader.new(
    logger: @logger,
    mxf_inspector: ->(file) { MxfTools.mxf_inspect(file) }
  )
  @c14n_available = Nokogiri::XML::Document.new.respond_to?('canonicalize')
  @check_hashes_hits = 0
  @check_hashes_limit_hits = 0
  @check_hashes_limit_nice = hash_limit_label(options.check_hashes_limit)
  @signed_cpls_count = 0
  @signed_cpls_verified_count = 0
  @signed_pkls_count = 0
  @signed_pkls_verified_count = 0
  @encrypted_compositions = 0
  @dcp_inspect_temp = nil

  validate_schema_store!
end

def call(path)
  @dcp_inspect_temp = Pipe.new if options.audio_analysis || options.image_analysis
  inspection = dcp_inspect(options, path)
  print_inspection_messages(inspection) unless logger.is_quiet
  inspection
ensure
  @dcp_inspect_temp&.remove
  @dcp_inspect_temp = nil
end

def backend_description
  detail = filesystem_walker.fd_command ? " (#{filesystem_walker.fd_command})" : ''
  "#{filesystem_walker.backend}#{detail}"
end

private

def validate_schema_store!
  unless File.directory?(XSDDir)
    raise DcpInspect::Inspection::Error.new("Local XSD store #{XSDDir} not found", XSD_STORE_NOT_FOUND)
  end

  catalog = File.join(XSDDir, 'catalog.xml')
  return if File.file?(catalog)

  raise DcpInspect::Inspection::Error.new("Local XML Catalog #{catalog} not found", XML_CATALOG_NOT_FOUND)
end

def hash_limit_label(limit)
  return nil if limit == :no_limit
  return bytes_from_nice_bytes(limit).to_k if limit =~ /\d+(\.?\d+)?(kb|mb|gb)/

  raise DcpInspect::Inspection::Error.new(
    "Option --hash-limit argument #{limit.inspect} does not compute. Use an integer or decimal with KB, MB, or GB",
    BAD_HASH_LIMIT_ARG
  )
end

public

class ::Nokogiri::XML::Document
  def collect_all_namespaces_href_keys
    xpath( "//namespace::*" ).inject( {} ) do |hash, ns|
      ( hash[ ns.href ] ||= [] ) << ns.prefix unless ( hash[ ns.href ] and hash[ ns.href ].include? ns.prefix )
      hash
    end
  end
  def collect_all_namespaces_prefix_keys
    xpath( "//namespace::*" ).inject( {} ) do |hash, ns|
      ( hash[ ns.prefix ] ||= [] ) << ns.href unless ( hash[ ns.prefix ] and hash[ ns.prefix ].include? ns.href )
      hash
    end
  end
end


# lib/mxf.rb
module MxfTools
  extend self
  def asdcplib_version
    out, err, status = Open3.capture3( 'asdcp-info', '-V' )
    match = "#{ out }\n#{ err }".match( /(\d+)\.(\d+)\.(\d+)/ )
    return [ 0, 0, 0 ] unless status.success? && match

    match.captures.map { |e| e.to_i }
  end

  def asdcplib_version_supported?
    major = asdcplib_version.first
    case major
    when 1
      true
    else
      false
    end
  end

  def mxf_inspect( filename )
    out, err, = Shell.asdcp_mxf_info( filename )
    if err =~ /EditRate and SampleRate do not match/ and err =~ /File may contain JPEG Interop stereoscopic images/
      # With 1.12.58 this is not required anymore. Keep it for backwards compat
      out, err, = Shell.asdcp_mxf_interop_stereoscopic_info( filename )
    end

    if out.empty?
      return nil
    elsif err =~ /Program stopped on error/
      if err =~ /SeekToRIP failed/
        return nil
      elsif err =~ /File open failure/
        return nil
      end
    end

    out = out.split( /\n\s*/ ).collect { |line| line.split( ': ' ) }
    et = [ 'EssenceType',
           case out.first.to_s
           when /#{ MStr::Stereoscopic_pictures }/
             MStr::Stereoscopic_pictures
           when /#{ MStr::Pictures }/
             MStr::Pictures
           when /#{ MStr::Mpeg2 }/
             MStr::Mpeg2
           when /#{ MStr::Audio }/
             MStr::Audio
           when /#{ MStr::Atmos }/
             MStr::Atmos
           when /#{ MStr::Timed_text }/i
             MStr::Timed_text
           else
             nil
           end
    ]
    return Hash[ out << et ]
  end
end # MxfTools
include MxfTools


class Pipe
  def initialize
    @pipename = "#{ AppName }_#{ rand( 2 ** 32 ).to_s( 16 ) }"
    @pipe = nil
    make_pipe
  end
  def remove
    File.delete(path) if File.exist?(path)
  end
  def path
    "/tmp/#{ @pipename }"
  end
  private
  def make_pipe
    system('mkfifo', path) || raise("Could not create FIFO #{path}")
    @pipe = self.path
  end
end # Pipe


def bars( list )
  level = '█▇▆▅▄▃▂▁'
  '|' + list.inject( [] ) do |ary, value|
    case value
    when '-inf'
      ary << '.'
    else
      case value.to_f.abs
      when 0.0
        level_index = level[ 0 ]
      else
        level_index = [ 0, ( Math.log2 value.to_f.abs ).to_i.abs, level.size - 1 ].sort[ 1 ] # clamp between 0 and level.size - 1
      end
      ary << level[ level_index ]
    end
    ary
  end.join('|') + '|'
end


AudioLoudnessTargetLufs = -27.0

def audio_loudness_state( integrated_lufs )
  return { :status => 'UNKNOWN', :role => :warn, :delta => nil } unless integrated_lufs

  delta = integrated_lufs - AudioLoudnessTargetLufs
  distance = delta.abs
  status = if distance <= 1.0
             'OK'
           elsif distance <= 3.0
             delta.positive? ? 'WARN LOUD' : 'WARN LOW'
           else
             delta.positive? ? 'LOUD' : 'LOW'
           end
  role = distance <= 1.0 ? :ok : ( distance <= 3.0 ? :warn : :error )
  { :status => status, :role => role, :delta => delta }
end

def audio_silent?( stats )
  peak = stats.dig( :pk_lev_db, :overall )
  rms = stats.dig( :rms_lev_db, :overall )
  peak == '-inf' && ( rms.nil? || rms == '-inf' )
end

def parse_ffmpeg_audio_analysis( stderr )
  stats = {
    :integrated_lufs => nil,
    :lra_lu => nil,
    :true_peak_dbfs => nil,
    :pk_lev_db => { :overall => nil, :channels => [] },
    :rms_lev_db => { :overall => nil, :channels => [] }
  }
  in_ebur_summary = false
  astats_channel = nil

  stderr.to_s.each_line do |line|
    in_ebur_summary = true if line.include?( 'Summary:' ) && line.include?( 'Parsed_ebur128' )
    if in_ebur_summary && line =~ /^\s*I:\s+(-?\d+(?:\.\d+)?)\s+LUFS/
      stats[ :integrated_lufs ] = Regexp.last_match( 1 ).to_f
      next
    end
    if in_ebur_summary && line =~ /^\s*LRA:\s+(-?\d+(?:\.\d+)?)\s+LU/
      stats[ :lra_lu ] = Regexp.last_match( 1 ).to_f
      next
    end
    if in_ebur_summary && line =~ /^\s*Peak:\s+(-?\d+(?:\.\d+)?|-inf)\s+dBFS/
      stats[ :true_peak_dbfs ] = Regexp.last_match( 1 )
      next
    end

    if line =~ /Parsed_astats_.*Channel:\s+(\d+)/
      astats_channel = Regexp.last_match( 1 ).to_i
      next
    elsif line =~ /Parsed_astats_.*Overall/
      astats_channel = :overall
      next
    elsif line =~ /Parsed_astats_.*Peak level dB:\s+(-?\d+(?:\.\d+)?|-inf)/
      value = Regexp.last_match( 1 )
      if astats_channel == :overall
        stats[ :pk_lev_db ][ :overall ] = value
      elsif astats_channel
        stats[ :pk_lev_db ][ :channels ][ astats_channel - 1 ] = value
      end
    elsif line =~ /Parsed_astats_.*RMS level dB:\s+(-?\d+(?:\.\d+)?|-inf)/
      value = Regexp.last_match( 1 )
      if astats_channel == :overall
        stats[ :rms_lev_db ][ :overall ] = value
      elsif astats_channel
        stats[ :rms_lev_db ][ :channels ][ astats_channel - 1 ] = value
      end
    end
  end

  if audio_silent?( stats )
    stats.merge!( :silent => true, :status => 'SILENT', :role => :muted, :delta => nil )
  else
    stats.merge!( audio_loudness_state( stats[ :integrated_lufs ] ) )
  end
  stats
end

def audio_analysis_report( stats )
  return '' unless stats
  return "Audio analysis failed: #{ stats[ :error ] }" if stats[ :error ]
  return 'No audio signal: RMS -inf dBFS, Peak -inf dBFS' if stats[ :silent ]

  parts = []
  if stats[ :integrated_lufs ]
    delta = stats[ :delta ] ? format( '%+.1f LU', stats[ :delta ] ) : nil
    parts << "Loudness #{ format( '%.1f', stats[ :integrated_lufs ] ) } LUFS I #{ delta } [#{ stats[ :status ] }]"
  end
  parts << "LRA #{ format( '%.1f', stats[ :lra_lu ] ) } LU" if stats[ :lra_lu ]
  if stats[ :pk_lev_db ] && stats[ :pk_lev_db ][ :overall ]
    peak_channels = stats[ :pk_lev_db ][ :channels ].compact
    parts << "Peak #{ stats[ :pk_lev_db ][ :overall ] } dBFS #{ bars( peak_channels ) }"
  elsif stats[ :true_peak_dbfs ]
    parts << "True peak #{ stats[ :true_peak_dbfs ] } dBFS"
  end
  parts.join( ' ' )
end

def audio_progress_duration_label( seconds )
  total = [ seconds.to_f.round, 0 ].max
  hours = total / 3600
  minutes = ( total % 3600 ) / 60
  secs = total % 60
  hours > 0 ? format( '%d:%02d:%02d', hours, minutes, secs ) : format( '%02d:%02d', minutes, secs )
end

def audio_progress_line( label, percent, current_seconds, total_seconds )
  current = audio_progress_duration_label( current_seconds )
  total = audio_progress_duration_label( total_seconds )
  "#{ label }: Audio analysis: #{ percent }% #{ current }/#{ total }"
end

def audio_characteristics( pipe, asset_file, channel_count, entry_point, duration, edit_rate, key = nil, logger = nil, label = 'Audio' )
  total_seconds = edit_rate.to_f.positive? ? duration.to_f / edit_rate.to_f : 0.0
  unwrap_args = [ 'asdcp-unwrap', '-f', entry_point.to_s, '-d', duration.to_s ]
  unwrap_args += [ '-k', key ] if key
  unwrap_args += [ asset_file, pipe.path ]

  ffmpeg_args = [
    'ffmpeg', '-hide_banner', '-nostats', '-nostdin', '-v', 'info',
    '-progress', 'pipe:1',
    '-f', 'wav', '-i', pipe.path,
    '-filter_complex', 'ebur128=peak=true,astats=metadata=0:reset=0',
    '-f', 'null', '-'
  ]

  logger.cr( audio_progress_line( label, 0, 0, total_seconds ) ) if logger
  stderr_text = DcpInspect::Inspection::AudioAnalysis.run(unwrap_args, ffmpeg_args) do |line|
    next unless line =~ /^out_time_(?:us|ms)=(\d+)/

    current_seconds = Regexp.last_match( 1 ).to_i / 1_000_000.0
    percent = total_seconds.positive? ? [ ( current_seconds * 100 / total_seconds ).to_i, 100 ].min : 0
    logger.cr( audio_progress_line( label, percent, current_seconds, total_seconds ) ) if logger
  end
  stats = parse_ffmpeg_audio_analysis( stderr_text )
  unless stats[ :integrated_lufs ] && stats.dig( :pk_lev_db, :overall )
    raise DcpInspect::Inspection::AudioAnalysis::Error, 'ffmpeg returned no complete loudness/peak measurements'
  end
  logger.cr( audio_progress_line( label, 100, total_seconds, total_seconds ) ) if logger
  stats
end


# lib/magic_strings.rb
MStr = DcpInspect::Inspection::Vocabulary


# lib/shell_tools.rb
module Shell
  class << self
    def asdcp_mxf_info( filename )
      out, err, status = Open3.capture3( "asdcp-info -v -i -d -r #{ Shellwords.shellescape filename }" )
      out = out.chomp
      return out, err, status
    end
    def asdcp_mxf_interop_stereoscopic_info( filename )
      out, err, status = Open3.capture3( "asdcp-info -3 -v -i -d -r #{ Shellwords.shellescape filename }" )
      out = out.chomp
      return out, err, status
    end
  end
end


class ::Numeric
  TERA = 1099511627776.0
  GIGA = 1073741824.0
  MEGA = 1048576.0
  KILO = 1024.0
  def to_k
    case
    when self == 1 then '1 Byte'
    when self < KILO then "%d Bytes" % self
    when self < MEGA then "%.1f KB" % ( self / KILO )
    when self < GIGA then "%.1f MB" % ( self / MEGA )
    when self < TERA then "%.1f GB" % ( self / GIGA )
    else "%.1f TB" % ( self / TERA )
    end
  end
end


# Glyph availability
module ::TTFunk
  class File
    def provides_glyphs_for?( unicode_string )
      unicode_string.unpack("U*").all? { |c| cmap.unicode.first[c] > 0 }
    end
  end
end


# Signature counters
@signed_cpls_count = 0
@signed_cpls_verified_count = 0
@signed_pkls_count = 0
@signed_pkls_verified_count = 0

# Plaintext/Encrypted compositions counter
@encrypted_compositions = 0


# lib/tools.rb
# date and time helpers
def time_to_datetime( time ) # OpenSSL's ruby bindings return Time objects for certificate validity info
  DateTime.parse( time.to_s )
end

def datetime_friendly( dt ) # return something in the form of "Tuesday Nov 30 2010 18:56"
  "#{ DateTime::DAYNAMES[ dt.wday ] } #{ DateTime::ABBR_MONTHNAMES[ dt.month ] } #{ dt.day.to_s } #{ dt.year.to_s } #{ '%02d' % dt.hour.to_s }:#{ '%02d' % dt.min.to_s }"
end
def datetime_friendly_mmmddyyyy( dt ) # return something in the form of "Nov 30 2010"
  "#{ DateTime::ABBR_MONTHNAMES[ dt.month ] } #{ dt.day.to_s } #{ dt.year.to_s }"
end
def yyyymmdd( datetime ) # used in KDM filenames. See http://www.kdmnamingconvention.com/
  datetime.to_s.split( 'T' ).first.gsub( /-/,'' )
end

def hours_minutes_seconds_verbose( seconds )
  t = seconds
  hrs = ( ( t / 3600 ) ).to_i
  min = ( ( t / 60 ) % 60 ).to_i
  sec = t % 60
  return [
    hrs > 0 ? hrs.to_s + " hour#{ 's' * ( hrs > 1 ? 1 : 0 ) }" : nil ,
    min > 0 ? min.to_s + " minute#{ 's' * ( min > 1 ? 1 : 0 ) }" : nil ,
    sec == 1 ? sec.to_i.to_s + ' second' : sec != 0 ? sec.to_s + ' seconds' : nil ,
    t > 60 ? "(#{ t } seconds)" : nil
  ].compact.join( ' ' )
end

def hms_from_seconds( seconds )
  hours = ( seconds / 3600.0 ).to_i
  minutes = ( ( seconds / 60.0 ) % 60 ).to_i
  secs = seconds % 60
  return [ hours, minutes, secs ].join( ':' )
end

def seconds_from_hms( timestring ) # hh:mm:ss.fraction
  a = timestring.split( ':' )
  hours = a[ 0 ].to_i
  minutes = a[ 1 ].to_i
  secs = a[ 2 ].to_f
  return ( hours * 3600 + minutes * 60 + secs )
end

def time_string( t )
  return "--:--:--" if t.nil?
  t = t.to_i; s = t % 60; m  = ( t / 60 ) % 60; h = t / 3600
  "%02d:%02d:%02d" % [ h, m, s ]
end

# Adapted from actionpack-3.2.11/lib/action_view/helpers/date_helper.rb
def distance_of_time_in_words(from_time, to_time = 0, include_seconds = false, options = {})
  from_time = from_time.to_time if from_time.respond_to?(:to_time)
  to_time = to_time.to_time if to_time.respond_to?(:to_time)
  distance_in_minutes = (((to_time - from_time).abs)/60).round
  distance_in_seconds = ((to_time - from_time).abs).round

  case distance_in_minutes
  when 0..1
    return distance_in_minutes == 0 ?
      "less than 1 minute" :
      "#{ amount 'minute', distance_in_minutes }" unless include_seconds

    case distance_in_seconds
    when 0..59   then "less than 1 minute"
    else             "1 minute"
    end

  when 2..44           then "#{ amount 'minute', distance_in_minutes }"
  when 45..89          then "about 1 hour"
  when 90..1439        then "about #{ amount 'hour', (distance_in_minutes.to_f / 60.0).round }"
  when 1440..2519      then "1 day"
  when 2520..43199     then "#{ amount 'day', (distance_in_minutes.to_f / 1440.0).round }"
  when 43200..86399    then "about 1 month"
  when 86400..525599   then "#{ amount 'month', (distance_in_minutes.to_f / 43200.0).round }"
  else
    fyear = from_time.year
    fyear += 1 if from_time.month >= 3
    tyear = to_time.year
    tyear -= 1 if to_time.month < 3
    leap_years = (fyear > tyear) ? 0 : (fyear..tyear).count{|x| Date.leap?(x)}
    minute_offset_for_leap_year = leap_years * 1440
    minutes_with_offset         = distance_in_minutes - minute_offset_for_leap_year
    remainder                   = (minutes_with_offset % 525600)
    distance_in_years           = (minutes_with_offset / 525600)
    if remainder < 131400
      "about #{ amount 'year', distance_in_years }"
    elsif remainder < 394200
      "over #{ amount 'year', distance_in_years }"
    else
      "almost #{ amount 'year', distance_in_years + 1 }"
    end
  end
end

# misc helpers
#
class ::String
  def black;          "\e[30m#{self}\e[0m" end
  def red;            "\e[31m#{self}\e[0m" end
  def green;          "\e[32m#{self}\e[0m" end
  def brown;          "\e[33m#{self}\e[0m" end
  def blue;           "\e[34m#{self}\e[0m" end
  def magenta;        "\e[35m#{self}\e[0m" end
  def cyan;           "\e[36m#{self}\e[0m" end
  def gray;           "\e[37m#{self}\e[0m" end

  def bg_black;       "\e[40m#{self}\e[0m" end
  def bg_red;         "\e[41m#{self}\e[0m" end
  def bg_green;       "\e[42m#{self}\e[0m" end
  def bg_brown;       "\e[43m#{self}\e[0m" end
  def bg_blue;        "\e[44m#{self}\e[0m" end
  def bg_magenta;     "\e[45m#{self}\e[0m" end
  def bg_cyan;        "\e[46m#{self}\e[0m" end
  def bg_gray;        "\e[47m#{self}\e[0m" end

  def bold;           "\e[1m#{self}\e[22m" end
  def italic;         "\e[3m#{self}\e[23m" end
  def underline;      "\e[4m#{self}\e[24m" end
  def blink;          "\e[5m#{self}\e[25m" end # temptingudontknowhow
  def invert;  "\e[7m#{self}\e[27m" end
end

# turn items like '100KB' or '1.5 GB' to bytes
def bytes_from_nice_bytes( nice_bytes )
  parts = nice_bytes.downcase.split( /(kb|mb|gb)/ )
  n = Float( parts.first )
  if parts[ 1 ]
    case parts[ 1 ]
    when 'kb'
      n * Numeric::KILO.to_i
    when 'mb'
      n * Numeric::MEGA.to_i
    when 'gb'
      n * Numeric::GIGA.to_i
    end
  else
    n
  end
end


# plural helper english
def amount( item, count )
  if count.is_a? Array or count.is_a? Hash
    "#{ count.size } #{ item }#{ pl count }"
  elsif count.integer?
    "#{ count } #{ item }#{ pl count }"
  end
end
def plural( item, count )
  "#{ item }#{ pl count }"
end
def pl( count )
  if count.is_a? Array or count.is_a? Hash
    count.size != 1 ? 's' : ''
  elsif count.integer?
    count != 1 ? 's' : ''
  end
end

# Thanks to Rein Henrichs
def truncate( text, num_words = 6, truncate_string = " [...]" )
  if text.nil? then return end
  arr = text.split( ' ' )
  arr.length > num_words ? arr[ 0...num_words ].join( ' ' ) + truncate_string : text
end

# package path helper
def package( relative_path )
  File.join( @package_dir, relative_path )
end

def print_inspection_messages( inspection )
  inspection[ :errors ].map { |e| @logger.errors [ 'Error', e ].join( ': ' ) }
  inspection[ :hints ].map { |e| @logger.hints [ 'Hint', e ].join( ': ' ) }
  inspection[ :siginfo ].map { |e| @logger.siginfo [ 'Siginfo', e ].join( ': ' ) }
  inspection[ :info ].map { |e| @logger.info [ 'Info', e ].join( ': ' ) }
end


#
# lib/timecode-ticks_tc.rb (Julik's timecode -- https://github.com/guerilla-di/timecode + parse_with_ticks)
# Timecode is a convenience object for calculating SMPTE timecode natively.
# The promise is that you only have to store two values to know the timecode - the amount
# of frames and the framerate. An additional perk might be to save the dropframeness,
# but we avoid that at this point.
#
# You can calculate in timecode objects as well as with conventional integers and floats.
# Timecode is immutable and can be used as a value object. Timecode objects are sortable.
#
Timecode = DcpInspect::Timecode

def parse_dcsubtitle_tc_string( tc_string, fps )
  case tc_string
  when /\d\d:\d\d:\d\d:\d\d\d/ # hh:mm:ss:ttt
    Timecode.parse_with_ticks( tc_string, fps )
  when /\d\d:\d\d:\d\d\.\d\d\d/ # hh:mm:ss.sss
    Timecode.parse( tc_string, fps )
  else
    nil
  end
end


DC_Signer_Crypto_Compliance = DcpInspect::Crypto::SignerCompliance
DC_Signature_Verification = DcpInspect::Crypto::SignatureVerification

Eta = DcpInspect::Progress::Eta

def command_exists?( command )
  ENV[ 'PATH' ].split( File::PATH_SEPARATOR ).any? { |d| File.exist? File.join( d, command ) }
end

def detect_terminal_size
  if command_exists?( 'tput' )
    { :columns => `tput cols`.to_i, :lines => `tput lines`.to_i }
  else
    nil
  end
end

def with_etabar( args, options, etabar_title, etabar_pbar_width, etabar_looks_like, logger, &block )
  eta = Eta.new( etabar_title, etabar_pbar_width, etabar_looks_like, detect_terminal_size, options, logger )
  chunks_per_percent = args.size / 100 + 1
  index = 0
  result = Array.new
  ( 0 .. 100 ).each do |percentage|
    chunks_per_percent.times do
      break if index == args.size
      result << yield( args[ index ] )
      index += 1
    end
    eta.update_terminal percentage
  end
  eta.preserve_terminal_title_with_message "Done"
  return result.reject { |e| e.nil? }
end

def digest_with_etabar( digest_algorithm, title, file, pbar_width, looks_like, options, logger )
  size = File.size file
  chunksize = 1_048_576

  dgst = OpenSSL::Digest.new( digest_algorithm )
  eta = Eta.new( title, pbar_width, looks_like, detect_terminal_size, options, logger )
  eta.update_terminal( 0 )

  bytes_read = 0
  last_percentage = 0
  File.open( file, 'rb' ) do |io|
    while ( chunk = io.read( chunksize ) )
      dgst.update chunk
      bytes_read += chunk.bytesize
      percentage = size.zero? ? 100 : [ ( bytes_read * 100 / size ), 100 ].min
      next unless percentage > last_percentage

      ( last_percentage + 1 .. percentage ).each { |p| eta.update_terminal( p ) }
      last_percentage = percentage
    end
  end
  eta.update_terminal( 100 ) if last_percentage < 100

  return dgst.digest, eta
end

# lib/xml.rb
#
# FIXME
# Looking only at the first prefix returned from collect_all_namespaces_href_keys
# for a given namespace will fall on its nose when there would be multiple prefixes
# for the same namespace. E.g. I think in a Signature it would be entirely valid to
# use different prefixes for different portions, all evaluating to the same namespace.
#
# Good enough for now but ktfim
#
def namespace_prefix( doc, ns )
  @document_reader.namespace_prefix(doc, ns)
end

def schema_validate_xml( xml, file )
  errors = Array.new
  asdcp_type = xml.root.node_name
  # find schema match
  case asdcp_type
    # special handling as DCSubtitle files are not namespaced
  when 'DCSubtitle'
    xsd_file = 'DCSubtitle.v1.mattsson.xsd'
  else
    case asdcp_type
    when 'AssetMap'
      # see fhg
      xsd_file = ( MStr::Schemas[ xml.namespaces[ 'xmlns' ] ] or MStr::Schemas[ xml.namespaces[ 'xmlns:am' ] ] )
    else
      xsd_file = ( MStr::Schemas[ xml.namespaces[ 'xmlns' ] ] )
    end
  end
  if xsd_file
    validation_errors = @schema_store.validate(xml, xsd_file)
  else
    if xml.namespaces.empty?
      errors << "Could not determine Schema (no namespace provided) ❌"
      return false, errors
    else
      errors << "Could not determine Schema for #{ xml.namespaces.inspect } ❌"
      return false, errors
    end
  end
  if validation_errors.empty?
    return true, errors
  else
    validation_errors.each do |e|
      errors << "Schema check ❌: #{ File.basename xsd_file } #{ file } line #{ e.line }: #{ e }"
    end
    return false, errors
  end
end

def schema_validation( errors, error_status, xml, source_file, id, type_indicator )
  valid, validation_errors = schema_validate_xml( xml, source_file )
  if valid == false
    validation_errors.each do |e|
      errors << "#{ type_indicator } #{ id }: #{ e }"
      error_status = true
    end
  end
  return valid, errors, error_status
end

def check_signature( xml )
  DC_Signature_Verification.new( xml )
end

def signature_verification_errors( errors, error_status, signature_result, id, file, type_indicator )
  if signature_result.crypto.errors[ :context ].values.flatten.any?
    signature_result.crypto.errors[ :context ].each do |sigerr|
      next if sigerr[1].empty?
      sigerr[1].each do |err|
        errors << "#{ type_indicator } #{ id }: Signature ❌: #{ err }"
      end
    end
    error_status = true
  end
  if ! signature_result.verified?
    errors << "#{ type_indicator } #{ id }: Signature verification failure ❌:\n\t#{ signature_result.messages.join( "\n\t" ) }"
    error_status = true
  end
  return errors, error_status
end

def signature_verification_hints( hints, signature_result, id, file, type_indicator )
  if signature_result.crypto.hints[ :context ].values.flatten.any?
    signature_result.crypto.hints[ :context ].each do |sighint|
      next if sighint[1].empty?
      sighint[1].each do |hint|
        hints << "#{ type_indicator } #{ id }: Signature: #{ hint }"
      end
    end
  end
  return hints
end

def signature_verification_siginfo( siginfo, signature_result, id, file, type )
  if signature_result.crypto.siginfo[ :context ].values.flatten.any?
    signature_result.crypto.siginfo[ :context ].each do |info|
      next if info[1].empty?
      info[1].each do |infoblob|
        siginfo << "#{ type } #{ id }: Signature: #{ infoblob }"
      end
    end
  end
  if signature_result.crypto.siginfo[ :expired_certs ].any?
    amount_expired = signature_result.crypto.siginfo[ :expired_certs ].size
    siginfo << "#{ type } #{ id }: Signature: #{ type } has #{ amount_expired } expired #{ plural( 'certificate', amount_expired ) }. This is not an error".bold
  end
  return siginfo
end

# FIXME
# returns xml or false.
# in addition to xml all kinds of stuff will be examined here
# hence the hoopla to skip expected errors from non-xml.
# still: what an appalling method
def get_xml_of_type( asdcp_type, file, errors, errors_status )
  @document_reader.read_type(asdcp_type, file, errors, errors_status)
end

def xml?( file )
  @document_reader.xml(file)
end

# FIXME Rather brittle mechanism here. I'd like to have infrastructure types show up (CompositionPlaylist, PackingList, DCSubtitle, DCMetadata)
def get_asset_uuid( file )
  @document_reader.asset_uuid(file)
end

def element_text( xml, xpath_query, ns )
  text = xml.xpath( xpath_query, ns )
  if text.empty?
    nil
  else
    text
  end
end

def uuid_from_urn_scheme( string )
  string.split( 'urn:uuid:' ).last
end

# Returns subject, issuer and serial (from signing certificate) and x509serialnumber (from Signer..X509SerialNumber)
def signer_info( xml, sig )
  sig_info = Hash.new
  if ! sig.signature_node.empty?
    sig_info[ :signer_name ] = sig.signer_name
    sig_info[ :signer_issuer_name ] = sig.signer_issuer
    if ! sig.signer_node.empty?
      signer_ns_prefix = namespace_prefix( xml, MStr::Ns_Xmldsig )
      sig_info[ :x509serialnumber ] = sig.signer_node.first.xpath( "//#{ signer_ns_prefix }:X509SerialNumber", signer_ns_prefix => MStr::Ns_Xmldsig ).first.text.to_i
      sig_info[ :cert_serial ] = sig.crypto.context.first.serial.to_i unless sig.crypto.context.empty?
    end
  end
  return sig_info
end


def font?( file )
  fh = File.open( file, 'r' )
  magic = fh.read( 4 ).unpack( 'H*' ).first
  fh.close
  case magic
  when "00010000"
    MStr::TTF
  when "4f54544f"
    MStr::OTF
  else
    nil
  end
end


def confirm_or_create( location )
  testfile = File.join( location, rand.to_s )
  if File.exist?( location )
    begin
      FileUtils.touch( testfile )
      File.delete( testfile )
      return true
    rescue Exception
      return false
    end
  else
    begin
      FileUtils.mkdir_p( location )
      return true
    rescue Exception
      return false
    end
  end
end


# And the error goes to ...
def error_output
  where = Array.new
  where << 'below' if @logger.prints_errors
  where << 'with increased verbosity' if ! @logger.prints_errors
  where << "in autolog at #{ ENV[ 'DCP_INSPECT_DIR' ] }" if @logger.writes_autolog
  where << 'in autolog with option --autolog' if ! @logger.writes_autolog
  where << "in #{ @logger.logfile }" if @logger.writes_logfile
  where << 'in a logfile with option --logfile' if ! @logger.writes_logfile
  return where.join ' or '
end


def composition_summary_oneliner( composition_summary )
  context = composition_summary[ :context ].nil? ? '' : " (#{ composition_summary[ :context ] })"
  "CPL #{ composition_summary[ :cpl_id ] }#{ context }: Composition summary: " + [ [ :content_title_text, :type, :crypto, :spatiality, :aspect, :resolution, :picture_bitrate_avg, :duration, :edit_rate ].reject { |k| composition_summary[k].nil? }.map { |k| composition_summary[k] } ].join( ', ' )
end

def cpl_reel_asset_references( xml )
  return [] unless xml && xml.root && xml.root.namespace

  cpl_ns = xml.root.namespace.href
  cpl_ns_prefix = namespace_prefix( xml, cpl_ns )
  refs = []
  reels = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:ReelList/#{ cpl_ns_prefix }:Reel" )
  reels.each_with_index do |reel, index|
    reel_no = index + 1
    reel.xpath( "#{ cpl_ns_prefix }:AssetList/*" ).each do |asset|
      next if asset.node_name == 'CompositionMetadataAsset'
      next if asset.node_name == 'MainMarkers'

      asset_ns = asset.namespaces
      asset_id = asset.xpath( "#{ cpl_ns_prefix }:Id", asset_ns ).text.to_s.split( ':' ).last.to_s
      next if asset_id.empty?

      key_id = asset.xpath( "#{ cpl_ns_prefix }:KeyId", asset_ns ).text.to_s.split( ':' ).last.to_s
      key_id = nil if key_id.empty?
      edit_rate_text = asset.xpath( "#{ cpl_ns_prefix }:EditRate", asset_ns ).text
      n, d = edit_rate_text.split( ' ' ).map { |num| num.to_i }

      refs << {
        :reel_no => reel_no,
        :kind => asset.node_name,
        :id => asset_id,
        :intrinsic_duration => asset.xpath( "#{ cpl_ns_prefix }:IntrinsicDuration", asset_ns ).text.to_i,
        :entry_point => asset.xpath( "#{ cpl_ns_prefix }:EntryPoint", asset_ns ).text.to_i,
        :duration => asset.xpath( "#{ cpl_ns_prefix }:Duration", asset_ns ).text.to_i,
        :edit_rate => n && d && d != 0 ? Rational( n, d ).to_f : nil,
        :key_id => key_id
      }
    end
  end
  refs
end

def register_cpl_hash_priorities( priorities, xml, cpl_order )
  cpl_reel_asset_references( xml ).each_with_index do |ref, asset_order|
    priority = [ 0, cpl_order, ref[ :reel_no ].to_i, asset_order ]
    current = priorities[ ref[ :id ] ]
    priorities[ ref[ :id ] ] = current ? [ current, priority ].min : priority
  end
end

def hash_priority_for_pkl_asset( asset_id, type, pkl_order, priorities )
  priorities[ asset_id ] || [ type =~ /text\/xml/ ? 1 : 2, pkl_order, asset_id.to_s ]
end

def preview_cpl_model( inspection_run, xml, dict, pkl_id = nil )
  return unless inspection_run && xml && xml.root && xml.root.namespace

  cpl_ns = xml.root.namespace.href
  cpl_ns_prefix = namespace_prefix( xml, cpl_ns )
  cpl_id = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:Id" ).text.split( ':' ).last
  return if cpl_id.empty?

  cpl_path = dict ? dict[ cpl_id ] : nil
  cpl_file = cpl_path ? package( cpl_path ) : nil
  cpl_type = case cpl_ns
  when MStr::Smpte_cpl
    MStr::AssetTypeSmpte
  when MStr::Interop_cpl
    MStr::AssetTypeInterop
  else
    MStr::AssetTypeUnknown
  end

  cpl_model = inspection_run.composition(
    cpl_id,
    :packing_list_id => pkl_id,
    :path => cpl_path,
    :absolute_path => cpl_file,
    :namespace => cpl_ns,
    :type => cpl_type,
    :present => cpl_file ? File.exist?( cpl_file ) : nil
  )

  content_title_text = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:ContentTitleText" ).text
  cpl_model.title = content_title_text.empty? ? '[Empty]' : content_title_text
  begin
    if ( lang_aud_subs = content_title_text.split( '_' )[ 3 ].match( /^[A-Z]{2,3}-[A-Za-z]{2,3}$/ ) )
      cpl_model.language = lang_aud_subs.to_s
    end
  rescue
  end

  annotation_text = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:AnnotationText" ).text
  cpl_model.annotation = annotation_text.empty? ? '[Empty]' : annotation_text

  content_kind = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:ContentKind" ).text
  cpl_model.content_kind = content_kind.empty? ? '[Empty]' : content_kind

  issue_date = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:IssueDate" ).text
  cpl_model.issue_date = issue_date unless issue_date.empty?

  issuer = xml.at_xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:Issuer" )
  cpl_model.issuer = issuer ? ( issuer.text.empty? ? '[Empty]' : issuer.text ) : '[Not present]'

  creator = xml.at_xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:Creator" )
  cpl_model.creator = creator ? ( creator.text.empty? ? '[Empty]' : creator.text ) : '[Not present]'

  cpl_reel_asset_references( xml ).each do |ref|
    reel_no = ref[ :reel_no ]
    cpl_model.reel( reel_no )
    asset_path = dict ? dict[ ref[ :id ] ] : nil

    inspection_run.reel_asset(
      cpl_id,
      reel_no,
      ref[ :id ],
      :kind => ref[ :kind ],
      :intrinsic_duration => ref[ :intrinsic_duration ],
      :entry_point => ref[ :entry_point ],
      :duration => ref[ :duration ],
      :edit_rate => ref[ :edit_rate ],
      :key_id => ref[ :key_id ],
      :details => 'CPL reference parsed; detailed checks pending',
      :resolved => asset_path ? File.exist?( package( asset_path ) ) : false
    )
  end
end


# FIXME ad-hoc 02.01.2024
def build_signer_issuer_short_report( xml, signature_result, sig_info, type_moniker )
  report = Array.new
  if signature_result.crypto.context.size >= 2
    signer_not_before_dt = time_to_datetime( signature_result.crypto.context[0].not_before )
    signer_not_after_dt = time_to_datetime( signature_result.crypto.context[0].not_after )
    issuer_not_before_dt = time_to_datetime( signature_result.crypto.context[1].not_before )
    issuer_not_after_dt = time_to_datetime( signature_result.crypto.context[1].not_after )
    report << "#{ type_moniker } Signer:        (#{ datetime_friendly_mmmddyyyy signer_not_before_dt }-#{ datetime_friendly_mmmddyyyy signer_not_after_dt }) #{ sig_info[ :signer_name ] }" if sig_info[ :signer_name ]
    report << "#{ type_moniker } Signer Issuer: (#{ datetime_friendly_mmmddyyyy issuer_not_before_dt }-#{ datetime_friendly_mmmddyyyy issuer_not_after_dt }) #{ sig_info[ :signer_issuer_name ] }" if sig_info[ :signer_issuer_name ]
  else # should not happen
    report = []
  end
  return report
end


# lib/cpl.rb
def cpl_inspect_xml( xml, dict, audio_stats, package_dir, composition_summaries, errors, hints, siginfo, info, options, inspection_run = nil, context = {} )
  cpl_errors = false
  initial_error_count = errors.size
  report = Array.new
  reels_report = Array.new
  cpl_referenced_assets = Array.new
  cpl_referenced_assets_encrypted = Array.new
  cpl_referenced_assets_encrypted_inferred_from_key_id = Array.new
  cpl_referenced_assets_types = Array.new
  cpl_reels_references_complete = Array.new

  ns = xml.collect_all_namespaces_href_keys
  cpl_ns = xml.root.namespace.href
  cpl_ns_prefix = namespace_prefix( xml, cpl_ns )
  cpl_id = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:Id" ).text.split( ':' ).last
  cpl_file = package dict[ cpl_id ]
  context ||= {}
  dict_label = context[ :dict_label ] || 'Assetmap dictionary'
  accounting = context[ :accounting ] || {}
  report << context[ :report_context ] if context[ :report_context ]

  case cpl_ns
  when MStr::Smpte_cpl
    cpl_type = MStr::AssetTypeSmpte
  when MStr::Interop_cpl
    cpl_type = MStr::AssetTypeInterop
  else
    cpl_type = MStr::AssetTypeUnknown
    errors << "CPL #{ cpl_id }: Default namespace unknown ❌: #{ cpl_ns }: #{ cpl_file }"
    errors << "CPL #{ cpl_id }: Default namespace unknown ❌: This might be a dcp_inspect bug. If you think it is ..."
    errors << "CPL #{ cpl_id }: Default namespace unknown ❌: ... please file an issue at https://github.com/wolfgangw/backports/issues/new"
    cpl_errors = true
  end
  cpl_referenced_assets_types << cpl_type
  cpl_model = inspection_run ? inspection_run.composition(
    cpl_id,
    :path => dict[ cpl_id ],
    :absolute_path => cpl_file,
    :namespace => cpl_ns,
    :type => cpl_type,
    :present => File.exist?( cpl_file )
  ) : nil

  # Check schema
  if options.schema_validate
    begin
      valid, errors, cpl_errors = schema_validation( errors, cpl_errors, xml, cpl_file, cpl_id, 'CPL' )
      if cpl_model
        cpl_model.schema_status = valid ? 'OK' : 'Errors'
        inspection_run.add_check( cpl_model, :schema, valid ? :ok : :error, "CPL #{ cpl_id }" )
      end
      report << "CPL #{ cpl_id }: Schema check: #{ valid ? 'OK ✅' : "Errors ❌ (See #{ error_output })" }"
    rescue Exception => e
      errors << "CPL #{ cpl_id }: Exception in Schema check ❌: #{ e.message }"
      cpl_errors = true
      if cpl_model
        cpl_model.schema_status = 'Errors'
        inspection_run.add_check( cpl_model, :schema, :error, errors.last )
      end
      report << errors.last
    end
  end

  # Check signature
  if @c14n_available
    signature_result = check_signature( xml )
    if signature_result.verified? and signature_result.crypto.errors[ :context ].values.flatten.empty?
      if accounting[ :verified_cpl_ids ]
        unless accounting[ :verified_cpl_ids ][ cpl_id ]
          @signed_cpls_verified_count += 1
          accounting[ :verified_cpl_ids ][ cpl_id ] = true
        end
      else
        @signed_cpls_verified_count += 1
      end
    end
    unless signature_result.signature_node.empty?
      errors, cpl_errors = signature_verification_errors( errors, cpl_errors, signature_result, cpl_id, cpl_file, 'CPL' )
      hints = signature_verification_hints( hints, signature_result, cpl_id, cpl_file, 'CPL' )
      siginfo = signature_verification_siginfo( siginfo, signature_result, cpl_id, cpl_file, 'CPL' )
    end
    if cpl_model
      cpl_model.signature_status = signature_result.messages.last
      inspection_run.add_check( cpl_model, :signature, signature_result.check_status, signature_result.messages.last )
    end
    report << "CPL #{ cpl_id }: #{ signature_result.messages.last }"
  else
    signature_result = nil
  end

  if signature_result and ! signature_result.signature_node.empty?
    if accounting[ :signed_cpl_ids ]
      unless accounting[ :signed_cpl_ids ][ cpl_id ]
        @signed_cpls_count += 1
        accounting[ :signed_cpl_ids ][ cpl_id ] = true
      end
    else
      @signed_cpls_count += 1
    end
    # FIXME why are we doing sig_info instead of just using signature_result.*?
    sig_info = signer_info( xml, signature_result )
    short_report = build_signer_issuer_short_report( xml, signature_result, sig_info, 'CPL' )
    unless short_report.empty?
      report << short_report[ 0 ]
      report << short_report[ 1 ]
    end

    # Todo: Compare names in Signer and certificate
    #

    # Check Signer.X509Data.X509IssuerSerial info vs signer certificate
    # See e.g. dcp_2/V174* for a serial mismatch
    if ! signature_result.signer_node.empty? and sig_info[ :x509serialnumber ] and sig_info[ :cert_serial ]
      if sig_info[ :x509serialnumber ] != sig_info[ :cert_serial ]
        report << "CPL Signer serial mismatch ❌: X509SerialNumber: #{ sig_info[ :x509serialnumber ] } Certificate: #{ sig_info[ :cert_serial ] }"
        errors << "CPL #{ cpl_id }: Signer serial mismatch ❌: X509SerialNumber: #{ sig_info[ :x509serialnumber ] } Certificate: #{ sig_info[ :cert_serial ] }"
        cpl_errors = true
      end
    else
      report << 'CPL Signer info :x509serialnumber or :cert_serial could not be retrieved ❌'
      errors << "CPL #{ cpl_id }: Signer info :x509serialnumber or :cert_serial could not be retrieved ❌"
      cpl_errors = true
    end
  end

  # CPL:Id RFC-4122 compliant?
  if cpl_id !~ MStr::Uuid_rfc4122_re
    report << "CPL Id:           #{ cpl_id } [Not RFC-4122 compliant] ❌"
    errors << "CPL #{ cpl_id }: Value of CompositionPlaylist:Id is not RFC-4122 compliant ❌"
    cpl_errors = true
  else
    report << "CPL Id:           #{ cpl_id }"
  end

  report << "CPL file:         #{ cpl_file }"
  report << "CPL type:         #{ cpl_type } (#{ cpl_ns })"
  cpl_model.type = cpl_type if cpl_model

  # Scrounge ContentTitleText
  content_title_text = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:ContentTitleText" ).text
  if content_title_text.empty?
    report << "ContentTitleText: [Empty] ❌"
    errors << "CPL #{ cpl_id }: ContentTitleText is empty ❌"
    cpl_model.title = '[Empty]' if cpl_model
  else
    report << "ContentTitleText: #{ content_title_text }"
    cpl_model.title = content_title_text if cpl_model
  end

  begin
    if ( lang_aud_subs = content_title_text.split( '_' )[ 3 ].match( /^[A-Z]{2,3}-[A-Za-z]{2,3}$/ ) )
      report << "\tLanguage audio and subtitles: #{ lang_aud_subs }"
      cpl_model.language = lang_aud_subs.to_s if cpl_model
    end
  rescue
  end

  annotation_text = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:AnnotationText" ).text
  if annotation_text.empty?
    report << "AnnotationText:   [Empty]"
    cpl_model.annotation = '[Empty]' if cpl_model
  else
    report << "AnnotationText:   #{ annotation_text }"
    cpl_model.annotation = annotation_text if cpl_model
  end

  # Check ContentKind
  content_kind_nodeset = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:ContentKind" )
  content_kind = content_kind_nodeset.text
  content_kind_scope_is_default = false
  if content_kind_nodeset.first
    content_kind_scope = content_kind_nodeset.first.attributes[ 'scope' ]
  end
  if content_kind.empty?
    hints << "CPL #{ cpl_id }: ContentKind is empty. May lead to display issues in player UIs"
    report << "ContentKind:      [Empty]"
    cpl_model.content_kind = '[Empty]' if cpl_model
  else
    if content_kind_scope
      if content_kind_scope.value == MStr::Cpl_content_kind_default_scope
        content_kind_scope_is_default = true
      else
        hints << "CPL #{ cpl_id }: ContentKind has non-standard scoped value #{ content_kind.inspect }. May lead to display issues in player UIs"
        report << "ContentKind:      #{ content_kind } [Non-standard scope #{ content_kind_scope.value.inspect }]"
        cpl_model.content_kind = "#{ content_kind } [Non-standard scope #{ content_kind_scope.value.inspect }]" if cpl_model
      end
    else
      content_kind_scope_is_default = true
    end
    if content_kind_scope_is_default
      if MStr::Cpl_standard_content.include? content_kind
        report << "ContentKind:      #{ content_kind }"
        cpl_model.content_kind = content_kind if cpl_model
      else
        hints << "CPL #{ cpl_id }: ContentKind has non-standard value #{ content_kind.inspect }. May lead to display issues in player UIs"
        report << "ContentKind:      #{ content_kind } [Non-standard value]"
        cpl_model.content_kind = "#{ content_kind } [Non-standard value]" if cpl_model
      end
    end
  end

  # IssueDate
  issue_date = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:IssueDate" )
  if issue_date
    if issue_date.text.empty?
      errors << "CPL #{ cpl_id }: IssueDate is empty ❌"
      cpl_errors = true
      report << "IssueDate:        [Empty -- See schema errors #{ error_output }] ❌"
      cpl_model.issue_date = '[Empty]' if cpl_model
    else
      begin
        issue_date_dt = DateTime.parse issue_date.text
        now_dt = DateTime.now
      rescue Exception => e
        errors << "CPL #{ cpl_id }: Can not parse IssueDate #{ issue_date.text.inspect } ❌"
        cpl_errors = true
      end
      if issue_date_dt
        unless accounting[ :info_cpl_ids ] && accounting[ :info_cpl_ids ][ cpl_id ]
          if issue_date_dt >= now_dt
            info << "CPL #{ cpl_id }: Composition #{ content_title_text.empty? ? '[ContentTitleText empty]' : content_title_text.inspect } was issued in the future: IssueDate #{ issue_date.text.inspect } ahead of now (#{ now_dt.to_s }) by #{ distance_of_time_in_words( issue_date_dt, now_dt ) }"
          elsif issue_date_dt < now_dt
            info << "CPL #{ cpl_id }: Composition #{ content_title_text.empty? ? '[ContentTitleText empty] ❌' : content_title_text.inspect } was issued #{ distance_of_time_in_words( issue_date_dt, now_dt ) } ago"
          end
          accounting[ :info_cpl_ids ][ cpl_id ] = true if accounting[ :info_cpl_ids ]
        end
        issue_date_friendly = datetime_friendly( issue_date_dt )
        report << "IssueDate:        #{ issue_date.text } (#{ issue_date_friendly })"
        cpl_model.issue_date = "#{ issue_date.text } (#{ issue_date_friendly })" if cpl_model
      end
    end
  else
    report << "IssueDate:        [Not present -- See schema errors #{ error_output }]"
    cpl_model.issue_date = '[Not present]' if cpl_model
  end

  # TKR? (FIXME: Check URL scheme)
  issuer = xml.at_xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:Issuer" )
  if issuer
    #
    # Interop and SMPTE UserText types -- used for Issuer -- are referred to by different names
    # Interop: 'lang' (see xsd/PROTO-ASDCP-CPL-20040511.xsd)
    # SMPTE: 'language' (see xsd/SMPTE-429-7-2006-CPL.xsd)
    #
    if ( issuer.attributes[ 'language' ] and issuer.attributes[ 'language' ].value == MStr::Tkr_attr ) or ( issuer.attributes[ 'lang' ] and issuer.attributes[ 'lang' ].value == MStr::Tkr_attr )
      report << "TKR Base URL:     #{ issuer.text }"
      cpl_model.issuer = issuer.text if cpl_model
    else
      if issuer.text.empty?
        hints << "CPL #{ cpl_id }: Issuer is empty"
        report << 'Issuer:           [Empty]'
        cpl_model.issuer = '[Empty]' if cpl_model
      else
        report << "Issuer:           #{ issuer.text }"
        cpl_model.issuer = issuer.text if cpl_model
      end
    end
  else
    report << 'Issuer:           [Not present]'
    cpl_model.issuer = '[Not present]' if cpl_model
  end

  # Creator
  creator = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:Creator" )
  if creator
    if creator.text.empty?
      hints << "CPL #{ cpl_id }: Creator is empty"
      report << 'Creator:          [Empty]'
      cpl_model.creator = '[Empty]' if cpl_model
    else
      report << "Creator:          #{ creator.text }"
      cpl_model.creator = creator.text if cpl_model
    end
  else
    report << 'Creator:          [Not present]'
    cpl_model.creator = '[Not present]' if cpl_model
  end

  #
  # Metadata // CMA
  # FIXME: For now this is merely a printout. We don't check against actual asset metadata
  #
  if ( ns.keys & MStr::Composition_metadata_href ).any?
    cma_href_match = ( ns.keys & MStr::Composition_metadata_href ).first
    cma = xml.xpath( '//meta:CompositionMetadataAsset/meta:*', 'meta' => cma_href_match )
    if cma
      report << 'CompositionMetadataAsset:'
      cma.each do |e|
        report << "                  #{ e.node_name }: #{ e.text.strip.gsub( /\n\s*/, ' ' ) }"
      end
    end
  end

  # Reels
  reels = xml.xpath( "/#{ cpl_ns_prefix }:CompositionPlaylist/#{ cpl_ns_prefix }:ReelList/#{ cpl_ns_prefix }:Reel" )
  report << "Number of Reels:  #{ reels.size }"
  total_duration = 0
  composition_edit_rates = Array.new
  #
  # A composition can be "incomplete" in different ways:
  #   - referenced assets can exist outside of a given package (ok case)
  #   - referenced assets can be invalid/damaged/empty/missing (fail case)
  # Collecting fail case id's in broken_assets to later on figure out
  # which case we're looking at.
  #
  broken_assets = Array.new
  reels_references = Array.new
  is_stereoscopic = Array.new # build a flag for naming convention checks
  composition_picture_aspect_ratios = Array.new
  composition_picture_resolutions = Array.new
  composition_picture_decomposition_levels = Array.new
  composition_picture_bitrates_max = Array.new
  composition_picture_bitrates_avg = Array.new
  composition_sound_channel_formats = Array.new
  composition_sound_channel_counts = Array.new
  supplemental_refs = { :main_picture => 0, :main_sound => 0, :main_subtitle => 0, :main_caption => 0, :aux_data => 0 }

  reels.each_with_index do |reel, index|
    reel_no = index + 1
    cpl_model.reel( reel_no ) if cpl_model
    cpl_reel = "CPL #{ cpl_id }: Reel #{ reel_no }"
    reels_report << "Reel #{ reel_no }:"
    reels_references[ index ] = Hash.new
    durations = Array.new
    edit_rates = Array.new
    assets = reel.xpath( "#{ cpl_ns_prefix }:AssetList/*" )

    # Check uniqueness of asset kinds which need to be unique in a reel.
    # Multiple instances of ClosedCaption, MainCaption and ClosedSubtitle allowed.
    asset_node_names = assets.collect { |a| a.node_name }
    assets_required_unique = asset_node_names - [ 'ClosedCaption', 'MainCaption', 'ClosedSubtitle' ]
    if assets_required_unique.uniq.size != assets_required_unique.size
      errors << "#{ cpl_reel }: Found duplicate asset kinds"
      cpl_errors = true
    end

    # Check a whole bunch of other things
    assets.each do |asset|

      #
      # CompositionMetadataAsset is already handled
      # Defer handling of MainMarkers to later on when we know reel duration
      #
      next if asset.node_name == 'CompositionMetadataAsset'

      # Collect reel referenced EssenceTypes (mainly to check for SMPTE reel completeness)
      case asset.node_name
      when 'MainPicture', 'MainStereoscopicPicture'
        reels_references[ index ][ :picture ] = true
      when 'MainSound'
        reels_references[ index ][ :sound ] = true
      when 'MainSubtitle'
        reels_references[ index ][ :subtitle ] = true
      when 'ClosedCaption'
        reels_references[ index ][ :caption ] = true
      end

      # Build a flag collection for naming convention checks: is_stereoscopic?
      case asset.node_name
      when 'MainPicture'
        is_stereoscopic[ index ] = false
      when 'MainStereoscopicPicture'
        is_stereoscopic[ index ] = true
      end

      asset_ns = asset.namespaces
      asset_id = asset.xpath( "#{ cpl_ns_prefix }:Id", asset_ns ).text.split( ':' ).last
      intrinsic_duration = asset.xpath( "#{ cpl_ns_prefix }:IntrinsicDuration", asset_ns ).text.to_i
      entry_point = asset.xpath( "#{ cpl_ns_prefix }:EntryPoint", asset_ns ).text.to_i
      duration = asset.xpath( "#{ cpl_ns_prefix }:Duration", asset_ns ).text.to_i
      if asset.xpath( "#{ cpl_ns_prefix }:KeyId", asset_ns )
        cpl_key_id = asset.xpath( "#{ cpl_ns_prefix }:KeyId", asset_ns ).text.split( ':' ).last
      else
        cpl_key_id = nil
      end

      # FIXME Timecode will die on edit_rate == 0
      cpl_asset_edit_rate_text = asset.xpath( "#{ cpl_ns_prefix }:EditRate", asset_ns ).text
      n, d = cpl_asset_edit_rate_text.split( ' ' ).map { |num| num.to_i }
      if n and d
        edit_rate = Rational( n, d ).to_f
      else
        edit_rate = nil
      end

      case asset.node_name
      when 'MainMarkers'
        # MainMarkers does not have Duration
      else
        durations << duration
      end
      edit_rates << edit_rate

      if dict
        if dict[ asset_id ]
          asset_file = package dict[ asset_id ]

          if File.exist?( asset_file )

            meta = MxfTools.mxf_inspect( asset_file )

            # MXF?
            if meta

              # Check asset Id for RFC-4122 compliance. All assets except DCSubtitle require this
              if asset_id !~ MStr::Uuid_rfc4122_re
                errors << "#{ cpl_reel }: Listed asset Id #{ asset_id } is not RFC-4122 compliant ❌"
                cpl_errors = true
              end

              # Get asset edit rate early
              begin
                n, d = ( meta[ 'EditRate' ] || meta[ 'SampleRate' ] ).split( '/' ).map { |num| num.to_i }
                asset_edit_rate = Rational( n, d ).to_f
              rescue Exception => e
                errors << "#{ cpl_reel }: Could not scrounge edit rate from #{ asset.node_name } asset #{ asset_id } ❌"
                cpl_errors = true
              end

              # Label types Interop/SMPTE
              case meta[ 'Label Set Type' ]
              when 'MXF Interop'
                cpl_referenced_assets << { asset_id => true }
                cpl_referenced_assets_types << MStr::AssetTypeInterop
              when 'SMPTE'
                cpl_referenced_assets << { asset_id => true }
                cpl_referenced_assets_types << MStr::AssetTypeSmpte
              else
                broken_assets << asset_id
                cpl_referenced_assets << { asset_id => false }
                cpl_referenced_assets_types << MStr::AssetTypeUnknown
              end

              # Encrypted essence?
              if meta[ 'EncryptedEssence' ]
                if meta[ 'EncryptedEssence' ] == 'Yes'
                  if meta[ 'CryptographicKeyID' ]
                    asset_key_id = meta[ 'CryptographicKeyID' ]
                    if asset_key_id == cpl_key_id
                      cpl_referenced_assets_encrypted << asset_id
                    else
                      case cpl_key_id
                      when nil
                        errors << "#{ cpl_reel }: #{ asset.node_name }: References encrypted asset but KeyId is [nil] ❌: #{ asset_id }"
                        cpl_errors = true
                      else
                        errors << "#{ cpl_reel }: #{ asset.node_name }: KeyId and CryptographicKeyID mismatch ❌: #{ asset_id }: #{ asset_file }"
                        cpl_errors = true
                      end
                    end
                  else
                    errors << "#{ cpl_reel }: #{ asset.node_name }: Could not read CryptographicKeyID in #{ asset_file } ❌"
                    cpl_errors = true
                  end
                end
              else
                errors << "#{ cpl_reel }: #{ asset.node_name }: Could not read EncryptedEssence Yes/No in #{ asset_file } ❌"
                cpl_errors = true
              end

              # IntrinsicDuration / EntryPoint / Duration sane?
              sane_IntrinsicDuration_EntryPoint_Duration = true
              if intrinsic_duration - entry_point < duration
                errors << "#{ cpl_reel }: Duration #{ duration } in #{ asset.node_name } does not compute ❌: IntrinsicDuration #{ intrinsic_duration } - EntryPoint #{ entry_point } < Duration #{ duration }"
                sane_IntrinsicDuration_EntryPoint_Duration = false
                cpl_errors = true
              end
              if entry_point >= intrinsic_duration
                exceed_frames = entry_point + 1 - intrinsic_duration
                errors << "#{ cpl_reel }: EntryPoint #{ entry_point } in #{ asset.node_name } exceeds IntrinsicDuration #{ intrinsic_duration } by #{ amount( 'frame', exceed_frames ) } ❌"
                sane_IntrinsicDuration_EntryPoint_Duration = false
                cpl_errors = true
              end
              if intrinsic_duration != meta[ 'ContainerDuration' ].to_i
                errors << "#{ cpl_reel }: IntrinsicDuration #{ intrinsic_duration } in #{ asset.node_name } does not match ContainerDuration #{ meta[ 'ContainerDuration' ].nil? ? '[NaN]' : meta[ 'ContainerDuration' ] } of asset #{ asset_id } ❌"
                cpl_errors = true
                if meta[ 'ContainerDuration' ].to_i - entry_point < duration
                  errors << "#{ cpl_reel }: Duration #{ duration } in #{ asset.node_name } does not compute ❌: ContainerDuration #{ meta[ 'ContainerDuration' ] } of asset #{ asset_id } - EntryPoint #{ entry_point } < Duration #{ duration }"
                  sane_IntrinsicDuration_EntryPoint_Duration = false
                  cpl_errors = true
                end
              end
              if sane_IntrinsicDuration_EntryPoint_Duration
                asset_snippet = [ 'ask', entry_point.to_s, duration.to_s ].join( '_' ).to_sym
              end

              # Check picture
              case asset.node_name
              when 'MainPicture', 'MainStereoscopicPicture'

                # decomposition levels
                if meta[ 'DecompositionLevels' ]
                  picture_decomposition_levels = meta[ 'DecompositionLevels' ].to_i
                  composition_picture_decomposition_levels << picture_decomposition_levels
                else
                  picture_decomposition_levels = nil
                  composition_picture_decomposition_levels << nil
                  errors << "#{ cpl_reel }: Expected to read image DecompositionLevels value but got nil ❌"
                  cpl_errors = true
                end

                # width and height
                picture_stored_width, picture_stored_height = meta[ 'StoredWidth' ], meta[ 'StoredHeight' ]
                picture_dimensions = "#{ picture_stored_width }x#{ picture_stored_height }"
                picture_aspect_ratio = ( picture_stored_width.to_f / picture_stored_height.to_f ).round( 3 )

                # avg and max bitrate
                if meta[ 'Max BitRate' ]
                  picture_bitrate_max_mbs = meta[ 'Max BitRate' ].split( ' ' )[0].to_f
                else
                  picture_bitrate_max_mbs = nil
                end
                if meta[ 'Average BitRate' ]
                  picture_bitrate_avg_mbs = meta[ 'Average BitRate' ].split( ' ' )[0].to_f
                else
                  picture_bitrate_avg_mbs = nil
                end

                # aspect ratio
                case picture_aspect_ratio
                when 1.896 # Full container
                  picture_aspect_ratio_moniker = 'C'
                when 1.85 # Flat
                  picture_aspect_ratio_moniker = 'F'
                when 2.387 # Scope
                  picture_aspect_ratio_moniker = 'S'
                when 1.778 # HD
                  picture_aspect_ratio_moniker = '16:9'
                  hints << "#{ cpl_reel }: #{ asset.node_name } has non-DCI aspect ratio #{ picture_aspect_ratio } (#{ picture_dimensions }, #{ picture_aspect_ratio_moniker }): Playback with proper non-standard masking recommended"
                else
                  picture_aspect_ratio_moniker = picture_aspect_ratio.to_s
                  hints << "#{ cpl_reel }: #{ asset.node_name } has non-DCI aspect ratio #{ picture_aspect_ratio } (#{ picture_dimensions }, #{ picture_aspect_ratio_moniker }): Playback with proper non-standard masking recommended"
                end
                composition_picture_aspect_ratios << picture_aspect_ratio

                # dimensions
                case picture_dimensions
                when '1998x1080', '2048x858', '2048x1080'
                  picture_dimensions_moniker = '2K'
                when '3996x2160', '4096x1716', '4096x2160'
                  picture_dimensions_moniker = '4K'
                when '1920x1080', '3840x2160'
                  picture_dimensions_moniker = 'HD' if picture_dimensions == '1920x1080'
                  picture_dimensions_moniker = 'UHD' if picture_dimensions == '3840x2160'
                  hints << "#{ cpl_reel }: #{ asset.node_name } has non-DCI pixel dimensions (#{ picture_dimensions }, #{ picture_dimensions_moniker })"
                else
                  picture_dimensions_moniker = picture_dimensions
                  errors << "#{ cpl_reel }: #{ asset.node_name } has non-DCI pixel dimensions (#{ picture_dimensions })"
                  cpl_errors = true
                end
                composition_picture_resolutions << picture_dimensions_moniker

                # FIXME wording: HFR is part of DCI/SMPTE
                # bitrate
                if picture_bitrate_max_mbs
                  if picture_bitrate_max_mbs > PictureBitrateMaxDCI
                    if picture_bitrate_max_mbs > PictureBitrateMaxHFR
                      errors << "#{ cpl_reel }: #{ asset.node_name } bitrate maximum #{ meta[ 'Max BitRate' ] } exceeds DCI and HFR maxima (#{ PictureBitrateMaxDCI } and #{ PictureBitrateMaxHFR } Mb/s) ❌"
                      cpl_errors = true
                    # FIXME
                    elsif picture_bitrate_max_mbs <= PictureBitrateMaxHFR
                      errors << "#{ cpl_reel }: #{ asset.node_name } bitrate maximum #{ meta[ 'Max BitRate' ] } exceeds DCI maximum (#{ PictureBitrateMaxDCI } Mb/s) ❌"
                      cpl_errors = true
                      hints << "#{ cpl_reel }: #{ asset.node_name } bitrate maximum #{ meta[ 'Max BitRate' ] } exceeds DCI maximum (#{ PictureBitrateMaxDCI } Mb/s). Playback might fail on DCI systems. Playback might work on HFR systems"
                    end
                  end
                  if picture_bitrate_max_mbs > PictureBitrateMaxDCISafe and picture_bitrate_max_mbs <= PictureBitrateMaxDCI
                    hints << "#{ cpl_reel }: #{ asset.node_name } bitrate maximum #{ meta[ 'Max BitRate' ] } exceeds suggested safe maximum #{ PictureBitrateMaxDCISafe } Mb/s. Playback might fail on DCI systems"
                  end
                end
                if picture_bitrate_avg_mbs
                  if picture_bitrate_avg_mbs > PictureBitrateMaxDCISafe and picture_bitrate_avg_mbs <= PictureBitrateMaxDCI
                    hints << "#{ cpl_reel }: #{ asset.node_name } bitrate average #{ meta[ 'Average BitRate' ] } exceeds suggested safe average #{ PictureBitrateMaxDCISafe } Mb/s. Playback might fail on DCI systems"
                  end
                end
                if sane_IntrinsicDuration_EntryPoint_Duration == true
                  composition_picture_bitrates_max << picture_bitrate_max_mbs
                  composition_picture_bitrates_avg << { :duration => duration, :picture_bitrate_avg_mbs => picture_bitrate_avg_mbs }
                end


              end # Check picture (MainPicture)


              # Check audio
              case asset.node_name
              when 'MainSound'

                # channel format
                if meta[ 'ChannelFormat' ]
                  audio_channel_format = meta[ 'ChannelFormat' ].to_i
                  composition_sound_channel_formats << audio_channel_format
                else
                  audio_channel_format = nil
                  composition_sound_channel_formats << nil
                  errors << "#{ cpl_reel }: Expected to read sound ChannelFormat but got nil ❌"
                  cpl_errors = true
                end

                # Sampling rate
                audio_sampling_rate = meta[ 'AudioSamplingRate' ]
                if audio_sampling_rate != '48000/1' and audio_sampling_rate != '96000/1'
                  errors << "#{ cpl_reel }: MainSound sampling rate #{ audio_sampling_rate } Hz. Expected 48 kHz or 96 kHz ❌"
                  cpl_errors = true
                end

                # Bits per sample
                audio_quantization_bits = meta[ 'QuantizationBits' ].to_i
                if audio_quantization_bits != 24
                  errors << "#{ cpl_reel }: MainSound quantization #{ audio_quantization_bits } bps. Expected 24 bps ❌"
                  cpl_errors = true
                end

                # Channel configuration
                audio_channel_count = meta[ 'ChannelCount' ].to_i
                case audio_channel_count
                when 1, 3, 4, 5, 7
                  errors << "#{ cpl_reel }: MainSound has #{ amount( 'channel', audio_channel_count ) } ❌: Use 5.1, 7.1, 7.1DS or wild track (2.0 is expected to mostly work)"
                  cpl_errors = true
                  audio_channel_count_moniker = audio_channel_count.to_s
                when 2
                  hints << "#{ cpl_reel }: MainSound has 2 channels: Expected to mostly work. Use 5.1, 7.1, 7.1DS or wild track to make sure"
                  audio_channel_count_moniker = '20'
                when 6
                  audio_channel_count_moniker = '51'
                when 8
                  audio_channel_count_moniker = '71'
                when 12
                  audio_channel_count_moniker = '11.1'
                else
                  audio_channel_count_moniker = audio_channel_count.to_s
                end
                composition_sound_channel_counts << audio_channel_count_moniker

                # Block align
                audio_block_align = meta[ 'BlockAlign' ].to_i
                if audio_block_align != audio_channel_count * 3 # don't use audio_quantization_bits here -- anything other than 24 bps is an error
                  errors << "#{ cpl_reel }: MainSound has unexpected BlockAlign value #{ audio_block_align } ❌: Expected #{ audio_channel_count * 3 }: Check audio source"
                  cpl_errors = true
                end

                # Edit rate
                if asset_edit_rate != edit_rate
                  errors << "#{ cpl_reel }: MainSound EditRate #{ edit_rate } does not match asset EditRate #{ asset_edit_rate } ❌"
                  cpl_errors = true
                end

                # Audio characteristics (EBU R-128 loudness, peak levels, silent channels)
                audio_stats[ asset_id ] ||= Hash.new
                dkdms = Hash.new
                if options.audio_analysis
                  if sane_IntrinsicDuration_EntryPoint_Duration
                    audio_stats[ asset_id ][ asset_snippet ] ||= nil

                    if meta[ 'EncryptedEssence' ] == 'Yes'
                      if dkdms[ cpl_id ]
                        if dkdms[ cpl_id ][ asset_key_id ]
                          key = dkdms[ cpl_id ][ asset_key_id ]
                        else
                          hints << "#{ cpl_reel }: MainSound: Audio analysis requested but got no key for asset #{ asset_id }: Not yet implemented"
                          key = nil
                        end
                      else
                        hints << "#{ cpl_reel }: MainSound: Audio analysis requested but got no DKDM for CPL #{ cpl_id }: Not yet implemented"
                        key = nil
                      end
                    else
                      key = nil
                    end

                    if @dcp_inspect_temp
                      if audio_stats[ asset_id ][ asset_snippet ]
                        @logger.info "#{ cpl_reel }: Audio analysis: Seen #{ asset_id }:#{ entry_point }:#{ duration } before. Using previous result"
                      else
                        audio_progress_label = "CPL #{ cpl_id.split( '-' ).first } R#{ reel_no } MainSound"
                        if key || meta[ 'EncryptedEssence' ] == 'No'
                          begin
                            audio_stats[ asset_id ][ asset_snippet ] = audio_characteristics( @dcp_inspect_temp, asset_file, audio_channel_count, entry_point, duration, edit_rate, key, @logger, audio_progress_label )
                            @logger.info "#{ cpl_reel }: Audio analysis: Done"
                          rescue DcpInspect::Inspection::AudioAnalysis::Error => error
                            audio_stats[ asset_id ][ asset_snippet ] = { :error => error.message }
                            errors << "#{ cpl_reel }: Audio analysis failed ❌: #{ error.message }"
                            cpl_errors = true
                            @logger.errors errors.last
                          end
                        end
                      end
                    else
                      hints << "#{ cpl_reel }: MainSound: Audio analysis requested but got no temp location to write to"
                    end

                  end
                end


              end # Check audio (MainSound)


              # This meta_report (and edit_rate) abomination below needs to go. Ugh
              meta_report = [
                meta[ 'Label Set Type' ] || 'Label Set Type:' + MStr::AssetTypeUnknown,
                meta[ 'ContainerDuration' ] ? meta[ 'EditRate' ] || meta[ 'SampleRate' ] ? Timecode.new( meta[ 'ContainerDuration' ].to_i, asset_edit_rate ).to_s : '[NaN]' : 'ContainerDuration:' + MStr::AssetTypeUnknown,
                meta[ 'EncryptedEssence' ] ? meta[ 'EncryptedEssence' ] == 'Yes' ? 'encrypted' : 'plaintext' : 'Encrypted:' + MStr::AssetTypeUnknown,
                asset.node_name =~ /Picture/ ? ( meta[ 'StoredWidth' ] || 'StoredWidth:' + MStr::AssetTypeUnknown ) + 'x' + ( meta[ 'StoredHeight' ] || 'StoredHeight:' + MStr::AssetTypeUnknown ) : '',
                asset.node_name =~ /Picture/ ? meta[ 'Average BitRate' ] ? 'avg ' + meta[ 'Average BitRate' ] : 'avg [NaN Mb/s]' : '',
                asset.node_name =~ /Picture/ ? meta[ 'Max BitRate' ] ? 'max ' + meta[ 'Max BitRate' ] : 'max [NaN Mb/s]' : '',
                asset.node_name =~ /Sound/ ?
                  ( meta[ 'ChannelCount' ].to_s + 'ch' || 'ChannelCount:' + MStr::AssetTypeUnknown ) + ' ' +
                  ( audio_sampling_rate == '48000/1' ? '48kHz' : audio_sampling_rate == '96000/1' ? '96kHz' : audio_sampling_rate ) + ' ' +
                  ( ( meta[ 'QuantizationBits' ] || 'QuantizationBits:' + MStr::AssetTypeUnknown ) + 'bps' )
                  : '',
                asset.node_name =~ /Sound/ ? audio_stats[ asset_id ] ? audio_stats[ asset_id ][ asset_snippet ] ? audio_analysis_report( audio_stats[ asset_id ][ asset_snippet ] ) : '' : '' : '',
                meta[ 'EssenceType' ] || 'EssenceType:' + MStr::AssetTypeUnknown
              ].reject { |e| e.nil? or e.empty? }.join( ', ' )

            else

              # DCSubtitle?
              xml, errors, cpl_errors = get_xml_of_type( 'DCSubtitle', asset_file, errors, cpl_errors )
              if xml

                cpl_referenced_assets << { asset_id => true }
                cpl_referenced_assets_types << MStr::AssetTypeInterop

                #
                # DCSubtitle Schema validation
                #
                if options.schema_validate
                  begin
                    valid, errors, cpl_errors = schema_validation( errors, cpl_errors, xml, asset_file, asset_id, 'DCSubtitle' )
                    report << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Schema check: #{ valid ? 'OK ✅' : "Errors ❌ (See #{ error_output })" }"
                  rescue Exception => e
                    errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Exception in Schema check ❌: #{ e.message }"
                    cpl_errors = true
                    report << errors.last
                  end
                end

                #
                # Check for content of ReelNumber element
                #
                if ( reelnumber_el = xml.xpath( '/DCSubtitle/ReelNumber' ) and reelnumber_el.size == 1 )
                  if reelnumber_el.children.size == 1
                    if reelnumber_el.children.first.class == Nokogiri::XML::Text
                      reelnumber_el_content = reelnumber_el.children.first.content
                      if reelnumber_el_content.strip =~ /\d+/
                        if reelnumber_el_content.to_i != reel_no
                          hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: ReelNumber '#{ reelnumber_el_content.to_i }' does not match its CPL reel number '#{ reel_no }'"
                          report << hints.last
                        end
                      else
                        hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: ReelNumber content is not numerical: #{ reelnumber_el_content.inspect }"
                        report << hints.last
                      end
                    else
                      errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: ReelNumber has unexpected content ❌: #{ reelnumber_el.children.first.class }"
                      cpl_errors = true
                      report << errors.last
                    end
                  else
                    if reelnumber_el.children.size == 0
                      hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: ReelNumber has no content"
                      report << hints.last
                    elsif reelnumber_el.children.size > 1 # Note that TI's DTD says CDATA (non-parsed character data)
                      hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: ReelNumber has more than 1 subelement"
                      report << hints.last
                    end
                  end
                else
                  if reelnumber_el.size == 0
                    errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: ReelNumber element not found ❌"
                    cpl_errors = true
                    report << errors.last
                  else
                    errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: More than 1 ReelNumber element found ❌"
                    cpl_errors = true
                    report << errors.last
                  end
                end

                #
                # Check for content of Language element
                #
                if ( language_el = xml.xpath( '/DCSubtitle/Language' ) and language_el.size == 1 )
                  if language_el.children.size == 1
                    if language_el.children.first.class == Nokogiri::XML::Text
                      language_el_content = language_el.children.first.content
                      if ! ( language_el_content.strip =~ /[[:alpha:]]/ )
                        hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Language content contains unexpected characters: #{ language_el_content.inspect }"
                        report << hints.last
                      end
                    else
                      errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Language has unexpected content ❌: #{ language_el.children.first.class }"
                      cpl_errors = true
                      report << errors.last
                    end
                  else
                    if language_el.children.size == 0
                      hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Language has no content"
                      report << hints.last
                    elsif language_el.children.size > 1 # Note that TI's DTD says CDATA (non-parsed character data)
                      hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Language has more than 1 subelement"
                      report << hints.last
                    end
                  end
                else
                  if language_el.size == 0
                    errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Language element not found ❌"
                    cpl_errors = true
                    report << errors.last
                  else
                    errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: More than 1 Language element found ❌"
                    cpl_errors = true
                    report << errors.last
                  end
                end

                xml.remove_namespaces!
                if ( subtitles = xml.xpath( '//Subtitle' ) and subtitles.size > 0 )

                  #
                  # Check for TC range violations
                  #
                  subtitles.each do |sub|
                    [ 'TimeIn', 'TimeOut' ].each do |tc_attr_name|
                      tc_string = sub.attributes[ tc_attr_name ].value
                      begin
                        parse_dcsubtitle_tc_string( tc_string, edit_rate )
                      rescue Exception => e
                        spot_number = ( sub.attributes[ 'SpotNumber' ] ? sub.attributes[ 'SpotNumber' ].value : nil )
                        errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Spot #{ spot_number }: #{ e.inspect }"
                      end
                    end
                  end

                  #
                  # Scan all subtitles to find actual first_time_in and last_time_out
                  # Last subtitle is not necessarily the last displayed
                  # Scrounge content snippets along the way
                  #
                  # See CRAWL which sports empty Subtitle elements
                  #
                  # TI spec 2.9 Subtitle says
                  #
                  #   "The Subtitle element is a parent element. It includes [...] one or more child elements [...]"
                  #
                  # The XSD we're using right now (DCSubtitle.v1.mattsson.xsd), though, has
                  #
                  #     <xs:choice minOccurs="0" maxOccurs="unbounded">
                  #       <xs:element minOccurs="0" maxOccurs="unbounded" ref="Font"/>
                  #       <xs:element minOccurs="0" maxOccurs="unbounded" ref="Text"/>
                  #       <xs:element ref="Image"/>
                  #     </xs:choice>
                  #
                  # Correctness tbd
                  #
                  # First
                  #
                  first_time_in = subtitles.first.attributes[ 'TimeIn' ].value
                  nodeset = subtitles.first.xpath( '*/Text|Text|*/Image|Image' )
                  if nodeset.empty?
                    first_time_in_text = '[No child element]'
                    hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: First Subtitle element has neither Text nor Image"
                  else
                    first_time_in_text = truncate( nodeset.first.text.strip, 3 ) # first line
                  end
                  subtitles[ 1 .. -1 ].each do |sub|
                    if first_time_in < sub.attributes[ 'TimeIn' ].value
                      break
                    end
                    first_time_in = sub.attributes[ 'TimeIn' ].value
                  end
                  #
                  # Last
                  #
                  last_time_out = subtitles.last.attributes[ 'TimeOut' ].value
                  nodeset = subtitles.last.xpath( '*/Text|Text|*/Image|Image' )
                  if nodeset.empty?
                    last_time_out_text = '[No child element]'
                    hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Last Subtitle element has neither Text nor Image"
                  else
                    last_time_out_text = truncate( nodeset.last.text.strip, 3 )
                  end
                  subtitles.reverse[ 1 .. -1 ].each do |sub|
                    if last_time_out > sub.attributes[ 'TimeOut' ].value
                      break
                    end
                    last_time_out = sub.attributes[ 'TimeOut' ].value
                    nodeset = sub.xpath( '*/Text|Text|*/Image|Image' )
                    if nodeset.empty?
                      last_time_out_text = '[No child element]'
                      hints << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Last to-be-displayed Subtitle element has neither Text nor Image"
                    else
                      last_time_out_text = truncate( nodeset.last.text.strip, 3 ) # last line
                    end
                  end

                  begin
                    first_time_in = parse_dcsubtitle_tc_string( first_time_in, edit_rate )
                    last_time_out = parse_dcsubtitle_tc_string( last_time_out, edit_rate )
                  rescue Exception => e
                    errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Timecode: #{ e.message } ❌"
                    cpl_errors = true
                  end

                  #
                  # Cross-check duration/reel duration and last TimeOut
                  # We don't have reel_duration yet so here's an indirect way to tell if something's wrong
                  # FIXME
                  # Boy-oh-boy, this an ugly hack which exposes nicely the essential design flaw
                  #
                  # duration (self) and last TimeOut
                  #
                  if last_time_out.to_i > duration
                    errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Last TimeOut #{ last_time_out.to_s } exceeds MainSubtitle duration #{ Timecode.new( duration, edit_rate ).to_s } ❌"
                    cpl_errors = true
                  end
                  #
                  # reel duration (preliminary) and last TimeOut
                  #
                  if durations.size > 1 # Assume we have one previous asset duration
                    begin
                      reel_duration_prelim = Timecode.new( durations[ 0 .. -2 ].min, edit_rates[ 0 .. -2 ].min )
                      if last_time_out > reel_duration_prelim
                        errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Last TimeOut #{ last_time_out.to_s } exceeds reel duration #{ reel_duration_prelim } ❌"
                        cpl_errors = true
                      end
                    rescue Exception => e
                      errors << "#{ cpl_reel }: DCSubtitle #{ asset_id }: Timecode: #{ e.message }"
                      cpl_errors = true
                    end
                  end


                  #
                  # Check for empty elements. Thanks to Mattias Mattsson, Lilian Lefranc and Johann Hohenwarter for the field feedback
                  #
                  empty_subtitles = 0
                  subtitles.each do |sub|
                    spot_number = ( sub.attributes[ 'SpotNumber' ] ? sub.attributes[ 'SpotNumber' ].value : nil )
                    if sub.children.empty? or ( sub.children.size == 1 and sub.children.first.is_a? Nokogiri::XML::Text )
                      empty_subtitles += 1
                      errors << "#{ cpl_reel }: DCSubtitle: Empty Subtitle element#{ spot_number ? ': SpotNumber ' + spot_number : '' } ❌"
                      cpl_errors = true
                    elsif ( nodeset = sub.xpath( '*/Text|Text|*/Image|Image' ) )
                      nodeset.each do |node|
                        if node.text == ''
                          empty_subtitles += 1
                          hints << "#{ cpl_reel }: DCSubtitle: Empty #{ node.name } element#{ spot_number ? ': SpotNumber ' + spot_number : '' }. While not a specification error this can lead to playback problems in the field. Consider fixing"
                        end
                      end
                    end
                  end

                  #
                  # Check whether all referenced resources (font, subtitle images)
                  # are in the dictionary and exist on the medium
                  #
                  text_elements = false
                  text_elements_values = Array.new
                  load_font_el = xml.xpath( '//LoadFont' )
                  font_el = xml.xpath( '//Font' )

                  subtitles.each do |sub|
                    spot_number = ( sub.attributes[ 'SpotNumber' ] ? sub.attributes[ 'SpotNumber' ].value : nil )
                    nodeset = sub.xpath( '*/Text|Text|*/Image|Image' )
                    nodeset.each do |node|
                      case node.name
                      when 'Text'
                        text_elements = true
                        text_elements_values << { :number => spot_number, :text => node.text.strip }
                      when 'Image'
                        unless node.text.empty? # Checked above
                          asset_name = File.join( asset_id, node.text )
                          asset_pick = dict.select { |k, v| v =~ Regexp.new( asset_name ) }

                          if asset_pick.empty?
                            errors << "#{ cpl_reel }: DCSubtitle: #{ spot_number ? 'SpotNumber ' + spot_number + ': ' : '' }Referenced subtitle image #{ asset_name.inspect } not in AssetMap"
                            cpl_errors = true
                          else
                            unless File.exist?( package asset_pick.values.first ) # FIXME
                              errors << "#{ cpl_reel }: DCSubtitle: #{ spot_number ? 'SpotNumber ' + spot_number + ': ' : '' }Referenced subtitle image #{ asset_name.inspect } not found on the medium"
                              cpl_errors = true
                            end
                          end

                        end
                      end
                    end
                  end

                  # Check referenced font file
                  if text_elements
                    if load_font_el.empty?
                      hints << "#{ cpl_reel }: DCSubtitle: No LoadFont element found. Playback will use a default font"
                    else
                      # FIXME 1 LoadFont element
                      load_font_uri = load_font_el.first.attributes[ 'URI' ].value
                      font_asset = File.join( asset_id, File.basename( load_font_uri ) )
                      font_path = nil
                      if dict.values.any? { |val| val =~ /#{ font_asset }$/ && font_path = val }
                        font_asset = package font_path
                        if File.exist?( font_asset )
                          if font?( font_asset )
                            # Check for font max size recommendation
                            font_asset_size = File.size font_asset
                            if font_asset_size > 655360 # 640 KB
                              errors << "#{ cpl_reel }: DCSubtitle: Font #{ font_asset } size #{ font_asset_size.to_k } exceeds 640 KB ❌"
                              cpl_errors = true
                            end
                            # Get font name
                            begin
                              # Scrounge font subfamily name
                              font_fu = TTFunk::File.open font_asset
                              begin
                                font_unique_subfamily = font_fu.name.unique_subfamily[ 1 ].to_s # FIXME not always 2nd element. Why/how?
                                info << "#{ cpl_reel }: DCSubtitle: Referenced font subfamily: #{ font_unique_subfamily }"
                              rescue TypeError => e
                                hints << "#{ cpl_reel }: DCSubtitle: Referenced font #{ font_asset }: Failed to extract internal name structure"
                              end

                              # Check if all glyphs can be rendered with provided font
                              glyphs_missing = false
                              text_elements_values.each do |spot|
                                unless font_fu.provides_glyphs_for?( spot[ :text ] )
                                  glyphs_missing = true
                                  # pick the exact ones
                                  glyphs_missing_list = Array.new
                                  spot[ :text ].split( '' ).each do |char|
                                    glyphs_missing_list << char unless font_fu.provides_glyphs_for?( char )
                                  end
                                  hints << "#{ cpl_reel }: DCSubtitle: SpotNumber #{ spot[ :number ] }: Font is missing #{ amount( 'glyph', glyphs_missing_list ) } to render #{ spot[ :text ].inspect } (#{ spot[ :text ].encoding }) ❌: #{ glyphs_missing_list.inspect }"
                                end
                              end
                              if glyphs_missing
                                hints << "#{ cpl_reel }: DCSubtitle: Font #{ font_asset } is missing some required glyphs ❌"
                              end
                            rescue NoMethodError => e
                              errors << "#{ cpl_reel }: DCSubtitle: Referenced font #{ font_asset } not valid ❌: #{ e.message }"
                              cpl_errors = true
                            end
                          else
                            errors << "#{ cpl_reel }: DCSubtitle: Font #{ font_asset } referenced in LoadFont is neither #{ MStr::TTF } nor #{ MStr::OTF } ❌"
                            cpl_errors = true
                          end
                        end
                      else
                        errors << "#{ cpl_reel }: DCSubtitle: Referenced font #{ font_asset } not in AssetMap ❌"
                        cpl_errors = true
                      end
                      if load_font_el.size > 1
                        hints << "#{ cpl_reel }: DCSubtitle: Found multiple LoadFont elements. Playback will use 1st: #{ load_font_uri }"
                      end
                    end
                  end # text_elements

                  # Check LoadFont / Font Id dependency
                  # See https://github.com/wolfgangw/digital_cinema_tools_distribution/issues/15 for discussion
                  # TI's Subtitle_Specification_TI_1.1.pdf: Font's attributes are all #IMPLIED (not required)
                  font_ids = Array.new
                  font_el.each do |el|
                    font_ids << el.attributes[ 'Id' ].value if el.attributes[ 'Id' ]
                  end
                  font_ids.uniq!
                  if font_ids.size > 1
                    errors << "#{ cpl_reel }: DCSubtitle: Multiple Font Ids referenced ❌: #{ font_ids.inspect }"
                    cpl_errors = true
                  end
                  if load_font_el.empty?
                    if font_ids.size > 0
                      errors << "#{ cpl_reel }: DCSubtitle: No Font Id declared via LoadFont but referenced Font Ids found ❌: #{ font_ids.inspect }"
                      cpl_errors = true
                    end
                  else
                    if load_font_el.first.attributes[ 'Id' ]
                      load_font_id = load_font_el.first.attributes[ 'Id' ].value
                      font_ids.each do |font_id|
                        if font_id != load_font_id
                          errors << "#{ cpl_reel }: DCSubtitle: Referenced font Id '#{ font_id }' does not match the Id '#{ load_font_id }' declared in LoadFont. Font cannot be loaded ❌"
                          cpl_errors = true
                        end
                      end
                    end
                  end

                  #
                  # Check DCSubtitle's edit rate and nag about non-24-fps rates
                  #
                  if edit_rate != 24.0
                    hints << "#{ cpl_reel }: DCSubtitle: EditRate != 24 fps: #{ edit_rate } fps. Playback may fail"
                  end

                  # DCSubtitle meta report
                  meta_report = "DCSubtitle, #{ amount( 'subtitle', subtitles.to_a ) }, #{ first_time_in } '#{ first_time_in_text.nil? ? '[nil]' : first_time_in_text }' - #{ last_time_out } '#{ last_time_out_text.nil? ? '[nil]' : last_time_out_text }'#{ empty_subtitles > 0 ? ' Error: ' + empty_subtitles.to_s + ' empty Subtitle element' + ( empty_subtitles > 1 ? 's' : '' ) : '' }"

                else
                  meta_report = 'DCSubtitle, no Subtitle found'
                end
                meta = { 'EssenceType' => MStr::Timed_text }

              else # No meta and not DCSubtitle either

                broken_assets << asset_id
                cpl_referenced_assets << { asset_id => false }
                cpl_referenced_assets_types << MStr::AssetTypeUnknown
                meta_report = 'File found but not AS-DCP MXF ❌'

                # We don't have meta. Infer encryption from presence of KeyId
                if cpl_key_id
                  cpl_referenced_assets_encrypted_inferred_from_key_id << asset_id
                end

              end
            end

          else # Asset file does not exist

            broken_assets << asset_id
            cpl_referenced_assets << { asset_id => false }
            cpl_referenced_assets_types << MStr::AssetTypeUnknown
            meta_report = "Referenced asset file missing ❌: #{ dict[ asset_id ] }"

            # Infer encryption from presence of KeyId
            if cpl_key_id
              cpl_referenced_assets_encrypted_inferred_from_key_id << asset_id
            end

          end # File.exist?

        else # ok case: Supplemental/VF/External

          case asset.node_name
          when 'MainMarkers'
            meta_report = "We have MainMarkers"
          else

            cpl_referenced_assets << { asset_id => false }
            cpl_referenced_assets_types << MStr::AssetTypeUnknown
            meta_report = "Referenced asset file not listed in #{ dict_label }: Supplemental/VF/External"
            hints << "#{ cpl_reel }: #{ asset.node_name }: #{ meta_report }"
            case asset.node_name
            when 'MainPicture', 'MainStereoscopicPicture'
              supplemental_refs[ :main_picture ] += 1
            when 'MainSound'
              supplemental_refs[ :main_sound ] += 1
            when 'MainSubtitle'
              supplemental_refs[ :main_subtitle ] += 1
            when 'MainCaption'
              supplemental_refs[ :main_caption ] += 1
            when 'AuxData'
              supplemental_refs[ :aux_data ] += 1
            end

            # Infer encryption from presence of KeyId
            if cpl_key_id
              cpl_referenced_assets_encrypted_inferred_from_key_id << asset_id
            end

          end

        end # if dict[ asset_id ]
      end # if dict

      if inspection_run
        asset_file_for_model = dict && dict[ asset_id ] ? package( dict[ asset_id ] ) : nil
        inspection_run.reel_asset(
          cpl_id,
          reel_no,
          asset_id,
          :kind => asset.node_name,
          :intrinsic_duration => intrinsic_duration,
          :entry_point => entry_point,
          :duration => duration,
          :edit_rate => edit_rate,
          :key_id => cpl_key_id,
          :details => meta_report,
          :resolved => asset_file_for_model ? File.exist?( asset_file_for_model ) : false
        )
      end

      begin
        reels_report << "#{ "%6s" % duration }  #{ edit_rate.nil? ? 'EditRate funk' : Timecode.new( duration, edit_rate ) } @ #{ edit_rate }  Entry #{ Timecode.new( entry_point, edit_rate ) }  #{ asset_id.split( '-' ).first }  #{ asset.node_name }\t(#{ meta_report })"
      rescue Exception => e
        errors << "#{ cpl_reel }: Duration #{ duration }: EditRate #{ edit_rate }: #{ e.message }"
        cpl_errors = true
      end

      if meta
        case asset.node_name
        when 'MainStereoscopicPicture'
          unless meta[ 'EssenceType' ] == MStr::Stereoscopic_pictures
            reels_report << "Essence type mismatch ❌: Expected MainStereoscopicPicture, got #{ meta[ 'EssenceType' ] || '[nil]' }"
            errors << "#{ cpl_reel }: " + reels_report.last
            cpl_errors = true
          end
        when 'MainPicture'
          unless ( meta[ 'EssenceType' ] == MStr::Pictures or meta[ 'EssenceType' ] == MStr::Mpeg2 )
            reels_report << "Essence type mismatch ❌: Expected MainPicture, got #{ meta[ 'EssenceType' ] || '[nil]' }"
            errors << "#{ cpl_reel }: " + reels_report.last
            cpl_errors = true
          end
        when 'MainSound'
          unless meta[ 'EssenceType' ] == MStr::Audio
            reels_report << "Essence type mismatch ❌: Expected MainSound, got #{ meta[ 'EssenceType' ] || '[nil]' }"
            errors << "#{ cpl_reel }: " + reels_report.last
            cpl_errors = true
          end
        when 'MainSubtitle'
          unless meta[ 'EssenceType' ] == MStr::Timed_text
            reels_report << "Essence type mismatch ❌: Expected MainSubtitle, got #{ meta[ 'EssenceType' ] || '[nil]' }"
            errors << "#{ cpl_reel }: " + reels_report.last
            cpl_errors = true
          end
        when 'ClosedCaption'
          unless meta[ 'EssenceType' ] == MStr::Timed_text
            reels_report << "Essence type mismatch ❌: Expected ClosedCaption, got #{ meta[ 'EssenceType' ] || '[nil]' }"
            errors << "#{ cpl_reel }: " + reels_report.last
            cpl_errors = true
          end
        end
      end

    end # assets.each

    # Check reel's editrate sanity
    if edit_rates.uniq.size != 1
      reels_report << "\tEditRate mismatch ❌"
      composition_edit_rates << edit_rates.max
      errors << "#{ cpl_reel }: EditRate mismatch ❌"
      cpl_errors = true
    else
      composition_edit_rates << edit_rates.min
    end

    # Check reel's duration sanity
    if durations.uniq.size != 1
      reels_report << "\tDuration mismatch ❌"
      errors << "#{ cpl_reel }: Duration mismatch ❌: #{ durations.inspect }"
      cpl_errors = true
    else
      reel_duration = durations.first / edit_rates.min # seconds. gets it done but ugh
      total_duration += durations.first # frames
      if edit_rates.min > 0 and reel_duration < 1
        reels_report << "\tReel duration less than 1 second ❌"
        errors << "#{ cpl_reel }: Reel duration less than 1 second (#{ "%0.3f" % reel_duration } seconds, #{ amount( 'frame', durations.first.to_i ) }@#{ edit_rates.min } fps) ❌"
        cpl_errors = true
      elsif edit_rates.min > 0 and reel_duration < 5 # Doremi TB 65 (2010-03-09)
        hints << "#{ cpl_reel }: Reel duration less than 5 seconds. Doremi TB 65 suggests a 5 second minimum for safe playback on Doremi systems"
      end
    end

  end # reels loop

  # Setup composition summary one-liner
  composition_summary = Hash.new
  composition_summary[ :cpl_id ] = cpl_id
  composition_summary[ :context ] = context[ :summary_context ] if context[ :summary_context ]
  composition_summary[ :content_title_text ] = content_title_text.inspect


  # Composition duration
  if composition_edit_rates.uniq.size == 1
    composition_edit_rate = composition_edit_rates.first
  else
    composition_edit_rate = 0
  end
  reels_report << 'Total duration:'
  begin
    total_duration_tc = Timecode.new( total_duration, composition_edit_rate )
  rescue Exception => e
    errors << "CPL #{ cpl_id }: Exception in reel report ❌: #{ e.message }"
  end
  if composition_edit_rate == 0
    cpl_errors = true
  end
  reels_report << "#{ "%6s" % total_duration }  #{ composition_edit_rate == 0 ? 'EditRate funk' : total_duration_tc } @ #{ composition_edit_rate }" # FIXME edit_rate
  if total_duration_tc
    composition_summary[ :duration ] = total_duration_tc.to_s
    composition_summary[ :edit_rate ] = "#{ composition_edit_rate } fps"
  else
    composition_summary[ :duration ] = '[Duration does not compute] ❌'
  end

  # Cosmetics: Interleave reels_report
  reels_report.each do |rp|
    report << rp
  end

  # Composition type SMPTE/Interop/Undetermined?
  assets_status_list = cpl_referenced_assets.map { |e| e.values }.flatten
  if cpl_referenced_assets_types.uniq.size == 1 and assets_status_list.uniq.size == 1 and assets_status_list.first == true
    composition_type = cpl_referenced_assets_types.uniq.first
    composition_summary[ :type ] = composition_type
  else
    # FIXME Composition type Mixed error or hint?
    if cpl_referenced_assets_types.include?( MStr::AssetTypeUnknown )
      composition_type = MStr::AssetTypeUndetermined
    else
      if assets_status_list.include?( false )
        composition_type = MStr::AssetTypeUndetermined
      else
        composition_type = MStr::AssetTypeMixed
      end
    end

    composition_summary[ :type ] = composition_type
    if broken_assets.size > 0
      errors << "CPL #{ cpl_id }: Composition type ❌: #{ composition_type }"
      cpl_errors = true
    else
      case cpl_type
      when MStr::AssetTypeSmpte
        errors << "CPL #{ cpl_id }: Composition type ❌: #{ composition_type }"
        cpl_errors = true
      when MStr::AssetTypeInterop
        hints << "CPL #{ cpl_id }: Composition type: #{ composition_type }"
      end
    end
  end

  # Composition requires KDM?
  if cpl_referenced_assets_encrypted.size > 0
    composition_summary[ :crypto ] = 'KDM required'
    if accounting[ :encrypted_cpl_ids ]
      unless accounting[ :encrypted_cpl_ids ][ cpl_id ]
        @encrypted_compositions += 1
        accounting[ :encrypted_cpl_ids ][ cpl_id ] = true
      end
    else
      @encrypted_compositions += 1
    end
  elsif cpl_referenced_assets_encrypted_inferred_from_key_id.size > 0
    composition_summary[ :crypto ] = 'KDM required'
    if accounting[ :encrypted_cpl_ids ]
      unless accounting[ :encrypted_cpl_ids ][ cpl_id ]
        @encrypted_compositions += 1
        accounting[ :encrypted_cpl_ids ][ cpl_id ] = true
      end
    else
      @encrypted_compositions += 1
    end
  else
    composition_summary[ :crypto ] = 'Plaintext'
  end

  # Monoscopic/Stereoscopic composition?
  if is_stereoscopic.uniq.size == 1 and is_stereoscopic.uniq.first == true
    composition_summary[ :spatiality ] = '3D'
    is_stereoscopic = true
  elsif is_stereoscopic.uniq.size == 1 and is_stereoscopic.uniq.first == false
    composition_summary[ :spatiality ] = '2D'
    is_stereoscopic = false
  elsif is_stereoscopic.uniq.size == 2
    composition_summary[ :spatiality ] = '2D/3D'
    is_stereoscopic = true
    errors << "CPL #{ cpl_id }: " + report.last # ? FIXME
    cpl_errors = true
  end

  # Check consistency of decomposition levels in picture essence
  if composition_picture_decomposition_levels.uniq.size == 1 and composition_picture_decomposition_levels.first != nil
    # we're good
  elsif composition_picture_decomposition_levels.uniq.size == 1 and composition_picture_decomposition_levels.first == nil
    errors << "CPL #{ cpl_id }: Failed to read DecompositionLevels from picture essence. Should not happen ❌"
    cpl_errors = true
  else
    unless composition_picture_decomposition_levels.size == 0 # Supplemental/VF/External
      errors << "CPL #{ cpl_id }: Found inconsistent image DecompositionLevels values across the composition (#{ composition_picture_decomposition_levels.each_with_index.map { |v, index| 'Reel ' + ( index + 1 ).to_s + ': ' + v.to_s }.join( ', ' ) }). This will produce visual artefacts in reel transitions ❌"
      cpl_errors = true
    end
  end

  # Set up composition_picture_aspect_ratio
  composition_picture_aspect_ratio = nil
  if composition_picture_aspect_ratios.size == reels.size
    if composition_picture_aspect_ratios.uniq.size == 1
      case composition_picture_aspect_ratios.first
      when 1.896
        composition_picture_aspect_ratio = { :abbrev => 'C', :name => 'Full Container' }
      when 1.85
        composition_picture_aspect_ratio = { :abbrev => 'F', :name => 'Flat' }
      when 2.387
        composition_picture_aspect_ratio = { :abbrev => 'S', :name => 'Scope' }
      when 1.778
        composition_picture_aspect_ratio = { :abbrev => 'HD', :name => 'HD' }
      else
        composition_picture_aspect_ratio = { :abbrev => composition_picture_aspect_ratios.first.to_s, :name => composition_picture_aspect_ratios.first.to_s }
      end
      composition_summary[ :aspect ] = composition_picture_aspect_ratio[ :name ]
    else
      errors << "CPL #{ cpl_id }: Found different asset aspect ratios: #{ composition_picture_aspect_ratios.inspect } ❌"
      cpl_errors = true
    end
  else
    expected_aspect_ratios = reels.size - supplemental_refs[ :main_picture ]
    if expected_aspect_ratios != composition_picture_aspect_ratios.size
      errors << "CPL #{ cpl_id }: Expected to scrounge #{ amount( 'aspect ratio', expected_aspect_ratios ) } (#{ amount( 'reel', reels.size ) }) but got #{ composition_picture_aspect_ratios.size } ❌"
      cpl_errors = true
    end
  end

  # Set up composition_picture_resolution
  composition_picture_resolution = nil
  if composition_picture_resolutions.size == reels.size
    if composition_picture_resolutions.uniq.size == 1
      case composition_picture_resolutions.first
      when '2K'
        case composition_edit_rate
        when 48.0
          composition_picture_resolution = { :abbrev => '48' } # yeah, well. Look it up in 3.9, it's true :) (Changed in 8.2)
        else
          composition_picture_resolution = { :abbrev => '2K' }
        end
      when '4K'
        composition_picture_resolution = { :abbrev => '4K' }
      when 'HD'
        composition_picture_resolution = { :abbrev => 'HD' }
      else
        composition_picture_resolution = { :abbrev => composition_picture_resolutions.first }
      end
      composition_summary[ :resolution ] = composition_picture_resolution[ :abbrev ]
    else
      errors << "CPL #{ cpl_id }: Found different picture resolutions: #{ composition_picture_resolutions.inspect } ❌"
      cpl_errors = true
    end
  else
    expected_picture_resolutions = reels.size - supplemental_refs[ :main_picture ]
    if expected_picture_resolutions != composition_picture_resolutions.size
      errors << "CPL #{ cpl_id }: Expected to scrounge #{ amount( 'picture resolution', expected_picture_resolutions ) } (#{ amount( 'reel', reels.size ) }) but got #{ composition_picture_resolutions.size } ❌"
      cpl_errors = true
    end
  end

  # Composition picture bitrate (weighted mean)
  if composition_picture_bitrates_avg.size > 0
    if ! ( composition_picture_bitrates_avg.map { |e| e.values }.flatten.include? nil )
      composition_picture_bitrate_avg = ( composition_picture_bitrates_avg.map { |w| w[ :duration ] * w[ :picture_bitrate_avg_mbs ] }.inject( 0, :+ ) / composition_picture_bitrates_avg.map { |w| w[ :duration ] }.inject( 0, :+ ) ).round( 2 )
      composition_summary[ :picture_bitrate_avg ] = "Avg #{ composition_picture_bitrate_avg } Mb/s"
    else
      composition_summary[ :picture_bitrate_avg ] = "Avg [NaN Mb/s]"
    end
  else
    composition_summary[ :picture_bitrate_avg ] = "Avg [NaN Mb/s]"
  end

  # Check consistency of channel formats in sound essence
  if composition_sound_channel_formats.uniq.size == 1 and composition_sound_channel_formats.first != nil
    # we're good
  elsif composition_sound_channel_formats.uniq.size == 1 and composition_sound_channel_formats.first == nil
    errors << "CPL #{ cpl_id }: Failed to read sound ChannelFormat values from sound essence. Should not happen"
    cpl_errors = true
  else
    unless composition_sound_channel_formats.size == 0 # Supplemental/VF/External
      errors << "CPL #{ cpl_id }: Found inconsistent sound ChannelFormat values across the composition (#{ composition_sound_channel_formats.each_with_index.map { |v, index| 'Reel ' + ( index + 1 ).to_s + ': ' + v.to_s }.join( ', ' ) }). Playback may fail"
      cpl_errors = true
    end
  end

  if composition_sound_channel_counts.size == reels.size
    if composition_sound_channel_counts.uniq.size == 1
    else
      errors << "CPL #{ cpl_id }: Found different sound channel configurations: #{ composition_sound_channel_counts.inspect }"
    end
  else
    expected_audio_types = reels.size - supplemental_refs[ :main_sound ]
    if expected_audio_types != composition_sound_channel_counts.size
      errors << "CPL #{ cpl_id }: Expected to scrounge #{ amount( 'audio type', expected_audio_types ) } (#{ amount( 'reel', reels.size ) }) but got #{ composition_sound_channel_counts.size } ❌"
      cpl_errors = true
    end
  end

  # Check if reels reference both picture and sound. If not report an error for SMPTE CPL and a hint for Interop CPL
  # See SMPTE ST 429-2:2009 section 9.1 for the requirement
  reels_references.each_with_index do |reel_refs, index|
    if reel_refs[ :picture ] and reel_refs[ :sound ] # :picture covers both MainPicture and MainStereoscopicPicture
      cpl_reels_references_complete << true
    else
      reel_no = index + 1
      assets_missing_refs = Array.new
      assets_missing_refs << 'MainPicture or MainStereoscopicPicture' if ! reel_refs[ :picture ]
      assets_missing_refs << 'MainSound' if ! reel_refs[ :sound ]
      reels_report << "#{ composition_type }: Reel #{ reel_no }: Missing #{ amount( 'reference', assets_missing_refs ) } ❌: #{ assets_missing_refs.join( ', ' ) }"
      case composition_type
      when MStr::AssetTypeSmpte
        errors << "CPL #{ cpl_id }: #{ reels_report.last }"
        cpl_errors = true
      else
        hints << "CPL #{ cpl_id }: #{ reels_report.last }"
      end
      cpl_reels_references_complete << false
    end
  end

  # Fire off a hint wrt Interop composition and non-24 fps composition edit rate
  if composition_type == 'Interop' && composition_edit_rate != 24.0
    report << "Interop composition with non-24 fps edit rate (#{ composition_edit_rate })"
    hints << "CPL #{ cpl_id }: Interop composition with non-24 fps edit rate (#{ composition_edit_rate }). Playback may fail on very old legacy systems"
  end

  # composition summary one-liner
  composition_summaries << composition_summary
  composition_summary_line = composition_summary_oneliner( composition_summary )
  report << composition_summary_line
  cpl_model.summary = composition_summary_line.sub( /^CPL #{ cpl_id }(?: \([^)]+\))?: Composition summary: /, '' ) if cpl_model

  # Composition completeness
  if assets_status_list.include?( false )
    if broken_assets.size != 0
      report << "Composition incomplete ❌: Broken assets: #{ broken_assets.inspect }"
      cpl_model.complete = report.last if cpl_model
      errors << "CPL #{ cpl_id }: Composition incomplete ❌"
      cpl_errors = true
    else
      report << "Composition incomplete: Supplemental/VF/External"
      cpl_model.complete = report.last if cpl_model
      hints << "CPL #{ cpl_id }: #{ cpl_file }: Composition incomplete: Supplemental/VF/External"
    end
  elsif cpl_reels_references_complete.include?( false )
    incomplete_reels = Array.new
    cpl_reels_references_complete.each_with_index do |e, i| incomplete_reels << ( i + 1 ).to_s if e == false end
    case composition_type
    when MStr::AssetTypeSmpte
      report << "Composition incomplete ❌: SMPTE reels require both MainPicture or MainStereoscopicPicture and MainSound: #{ plural( 'Reel', incomplete_reels ) } #{ incomplete_reels.join( ', ' ) } incomplete"
      cpl_model.complete = report.last if cpl_model
      errors << "CPL #{ cpl_id }: #{ report.last }"
      cpl_errors = true
    else
      report << "Composition warning: Reference both MainPicture or MainStereoscopicPicture and MainSound in reels in order to avoid playback issues in the field: See #{ plural( 'reel', incomplete_reels ) } #{ incomplete_reels.join( ', ' ) }"
      cpl_model.complete = report.last if cpl_model
      hints << "CPL #{ cpl_id }: #{ report.last }"
    end
  else
    report << 'Composition complete ✅'
    cpl_model.complete = report.last if cpl_model
  end
  if cpl_errors == true
    report << "There were errors ❌. See CPL #{ cpl_id } errors #{ error_output }"
  end

  if cpl_model
    # Completeness describes available assets, not whether validation passed.
    # A complete composition can still have invalid metadata or signatures.
    message = if cpl_errors
      reasons = errors.drop( initial_error_count )
      reasons.empty? ? 'Composition validation failed; see diagnostics' : "Composition validation failed: #{ reasons.join( '; ' ) }"
    else
      cpl_model.complete
    end
    inspection_run.add_check( cpl_model, :composition, cpl_errors ? :error : :ok, message )
  end
  return composition_summary, report, errors, hints, siginfo, info
end # cpl_inspect_xml


include DcpInspect::Inspection::Runtime::Orchestrator

def print_internal_error_backtrace( result )
  @logger.info "#{ result.class }: #{ result.message }"
  result.backtrace[ 0 .. 4 ].each do |tracer|
    @logger.info tracer
  end
end


def dcp_inspect_crashed_get_in_touch
  @logger.info ''
  @logger.info "Sorry, #{ AppName } #{ AppVersion } crashed"
  @logger.info "Please get in touch to help fix it"
  @logger.info "See https://github.com/wolfgangw/backports/issues"
  @logger.info "Your feedback is much appreciated. Thanks in advance"
  @logger.info ''
end


def graceful_shutdown( options, args, crash = false )
  if @dcp_inspect_temp
    @dcp_inspect_temp.remove
  end
  write_logfiles( options, args )
  if crash
    dcp_inspect_crashed_get_in_touch
  end
end

def write_model_dump( options, inspection )
  return unless options.dump_model
  return unless inspection && inspection[ :inspection_run ]

  begin
    model_json = JSON.pretty_generate( inspection[ :inspection_run ].to_h ) + "\n"
    if options.dump_model == '-'
      puts model_json
    else
      File.write( options.dump_model, model_json )
      @logger.info "Wrote inspection model to #{ options.dump_model }"
    end
  rescue Exception => e
    @logger.info "Could not write inspection model #{ options.dump_model.inspect }: #{ e.message }"
    raise DcpInspect::Inspection::Error.new("Could not write inspection model #{options.dump_model.inspect}: #{e.message}", LOGFILE_WRITE_ERROR)
  end
end

def write_result_dump( options, inspection )
  return unless options.dump_result
  return unless inspection

  payload = inspection.merge(
    :inspection_run => inspection[ :inspection_run ]&.to_h
  )
  File.write(options.dump_result, JSON.pretty_generate(payload) + "\n")
rescue Exception => e
  @logger.info "Could not write inspection result #{ options.dump_result.inspect }: #{ e.message }"
  raise DcpInspect::Inspection::Error.new("Could not write inspection result #{options.dump_result.inspect}: #{e.message}", LOGFILE_WRITE_ERROR)
end


def tfs_dashboard
  defined?( @tfs_dashboard ) && @tfs_dashboard ? @tfs_dashboard : nil
end


def finish_tfs_dashboard( exit_code, wait = false )
  dashboard = tfs_dashboard
  return unless dashboard && dashboard.active

  dashboard.finish( exit_code )
  dashboard.wait_for_quit if wait
  dashboard.stop
  @tfs_dashboard = nil
end


def write_logfiles( options, args )
  # Write autolog
  if options.logfile_autolog
    if ENV[ 'DCP_INSPECT_AUTOLOG_NAME_IS_BASENAME' ]
      autologfile = File.join(
        ENV[ 'DCP_INSPECT_DIR' ],
        Pathname( args[ 0 ] ).basename.to_s
      )
    else
      autologfile = File.join(
        ENV[ 'DCP_INSPECT_DIR' ],
        [
          Pathname( args[ 0 ] ).realpath.to_s.gsub( '/', '___' ).gsub( /\s/, '_' ),
          @run_datetime.to_s.gsub( /\D/, '-' ),
          AppVersion.split( '.' ).join,
          rand( 65536 ).to_s( 16 )
        ].join( '_' ) + ".#{ AppName }"
      )
    end

    begin
      File.write( autologfile, @logger.full_log_blob )
      @logger.info "See autolog at #{ autologfile }"
    rescue Exception => e
      @logger.info e.message
      raise DcpInspect::Inspection::Error.new(e.message, AUTOLOGFILE_WRITE_ERROR)
    end
  end

  # Write logfile
  if options.logfile
    begin
      File.write( options.logfile, @logger.full_log_blob )
      @logger.info "See logfile at #{ options.logfile }"
    rescue Exception => e
      @logger.info e.message
      raise DcpInspect::Inspection::Error.new(e.message, LOGFILE_WRITE_ERROR)
    end
  end
  if options.logfile_append
    begin
      File.open( options.logfile_append, 'a' ) { |logfile| logfile.write @logger.full_log_blob }
      @logger.info "See additions to logfile at #{ options.logfile_append }"
    rescue Exception => e
      @logger.info e.message
      raise DcpInspect::Inspection::Error.new(e.message, LOGFILE_WRITE_ERROR)
    end
  end
end

#

    end
  end
end
