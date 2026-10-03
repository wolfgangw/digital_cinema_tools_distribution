# frozen_string_literal: true
require_relative 'timing'
require 'ttfunk'
require 'uri'

module DcpInspect
  module Inspection
    # Shared Interop/SMPTE semantics, based on the browser inspector's
    # timed-text-semantics/resources modules; see BROWSER_BACKPORT_LICENSE.
    class TimedText
      UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      attr_reader :findings, :summary

      def self.time(value, rate: nil, smpte: false, duration: false)
        if !smpte && duration && value.to_s.match?(/\A\d{1,3}\z/)
          return value.to_i <= 249 ? Rational(value.to_i, 250) : nil
        end
        match = /\A(\d{2}):(\d{2}):(\d{2})([:.])(\d{1,3})\z/.match(value.to_s)
        return nil unless match && match[2].to_i < 60 && match[3].to_i < 60
        base = match[1].to_i * 3600 + match[2].to_i * 60 + match[3].to_i
        if smpte
          return nil unless rate && rate > 0 && match[1].to_i < 24 && match[4] == ':' && match[5].size == (rate - 1).to_s.size && match[5].to_i < rate
          base + Rational(match[5].to_i, rate)
        elsif match[4] == ':'
          return nil unless match[5].size == 3 && match[5].to_i < 250
          base + Rational(match[5].to_i, 250)
        else
          base + Rational(match[5].ljust(3, '0').to_i, 1000)
        end
      end

      def initialize(document, context = {}, &resolver)
        @namespace = document.root.namespace&.href
        @xml = document.dup
        @xml.remove_namespaces!
        @smpte = @xml.root.name == 'SubtitleReel'
        @context, @resolver, @findings = context, resolver, []
        @fonts, @runs, @resources = {}, [], []
        @rate = Timing.units(value('TimeCodeRate'))
        @start = @smpte ? parse_time(value('StartTime') || "00:00:00:#{'0' * ((@rate || 24) - 1).to_s.size}") : Rational(0)
        @subtitles = @xml.xpath('//Subtitle')
        inspect_metadata
        inspect_fonts
        inspect_subtitles
        inspect_stereo if @smpte
        inspect_resources
        @summary = { format: @smpte ? 'SMPTE' : 'Interop', count: @subtitles.size,
          first_time_in: @first&.to_s, last_time_out: @last&.to_s,
          language: value('Language'), resources: @resources }
      end

      def value(name)
        @xml.root.at_xpath(name)&.text&.strip
      end

      def add(code, message, node = @xml.root, severity = :error)
        @findings << { code: "timed-text.#{code}", severity: severity, message: message, line: node.line }
      end

      def parse_time(value, duration: false)
        self.class.time(value, smpte: @smpte, rate: @rate, duration: duration)
      end

      def inspect_metadata
        id = value(@smpte ? 'Id' : 'SubtitleID').to_s.sub(/\Aurn:uuid:/i, '')
        add('id.invalid', 'Subtitle document ID must be a UUID') unless UUID.match?(id)
        expected = @context[:document_id]
        add('id.mismatch', "Subtitle document ID #{id} does not match expected #{expected}") if expected && id.downcase != expected.sub(/\Aurn:uuid:/i, '').downcase
        reel = value('ReelNumber')
        if reel.to_s.empty? || !reel.match?(/\A\d+\z/)
          add('reel-number.invalid', 'Subtitle ReelNumber is empty or non-numerical', @xml.root, :hint) unless @smpte && reel.nil?
        elsif @context[:reel] && reel.to_i != @context[:reel]
          add('reel-number.mismatch', "Subtitle ReelNumber #{reel} differs from CPL reel #{@context[:reel]}", @xml.root, :hint)
        end
        add('language.suspicious', 'Subtitle Language contains no alphabetic character', @xml.root, :hint) if !@smpte && !value('Language').to_s.match?(/\p{L}/)
        return unless @smpte
        if @context[:descriptor_namespace] && @namespace != @context[:descriptor_namespace]
          add('namespace.mismatch', "Subtitle namespace #{@namespace} differs from MXF descriptor #{@context[:descriptor_namespace]}")
        end
        edit_rate = Timing.rate(value('EditRate'))
        add('edit-rate.invalid', 'Subtitle EditRate is invalid') unless edit_rate
        add('time-code-rate.mismatch', 'TimeCodeRate must equal EditRate rounded to the nearest integer') if edit_rate && @rate != edit_rate.round
        [@context[:edit_rate], @context[:descriptor_rate]].compact.each do |actual|
          add('edit-rate.mismatch', "Subtitle EditRate #{edit_rate} differs from CPL/MXF EditRate #{actual}") if edit_rate && edit_rate != actual
        end
        add('start-time.invalid', 'Subtitle StartTime is invalid') unless @start
        expected_type = { 'MainSubtitle' => 'MainSubtitle', 'MainCaption' => 'Caption' }[@context[:kind]]
        if expected_type && value('DisplayType') && value('DisplayType') != expected_type
          add('display-type.mismatch', "Subtitle DisplayType #{value('DisplayType')} does not match #{expected_type}")
        end
      end

      def inspect_fonts
        loads = @xml.root.xpath('LoadFont')
        loads.each do |font|
          id = font[@smpte ? 'ID' : 'Id'].to_s
          add('font.id.duplicate', "LoadFont ID declared more than once: #{id}", font) if @fonts.key?(id)
          add('font.id.empty', 'LoadFont ID is empty', font) if id.empty?
          @fonts[id] = { resource: @smpte ? font.text.strip : font['URI'].to_s, node: font }
        end
        add('font.multiple-load-fonts', 'Interop permits only one LoadFont', loads[1]) if !@smpte && loads.size > 1
        if @xml.at_xpath('//Text') && loads.empty?
          add('font.load-font.missing', @smpte ? 'Text requires a LoadFont resource' : 'No LoadFont; playback uses a default font', @xml.root, @smpte ? :error : :hint)
        end
      end

      def inspect_subtitles
        previous, previous_spot, closed_end = nil, nil, nil
        @xml.xpath('//Font/text()[normalize-space()] | //SubtitleList/text()[normalize-space()]').each do |text|
          next if text.ancestors.any? { |node| node.name == 'Text' || node.name == 'Subtitle' }
          add('text.outside-text', "Text outside Text/Image element: #{text.text.strip.inspect}", text)
        end
        add('subtitles.empty', 'Subtitle document contains no Subtitle instances', @xml.root, :hint) if @subtitles.empty?
        @subtitles.each_with_index do |subtitle, index|
          label = "Subtitle #{subtitle['SpotNumber'] || index + 1}"
          time_in, time_out = parse_time(subtitle['TimeIn']), parse_time(subtitle['TimeOut'])
          add('time-in.invalid', "#{label}: invalid TimeIn #{subtitle['TimeIn'].inspect}", subtitle) unless time_in
          add('time-out.invalid', "#{label}: invalid TimeOut #{subtitle['TimeOut'].inspect}", subtitle) unless time_out
          add('interval.not-positive', "#{label}: TimeOut must be later than TimeIn", subtitle) if time_in && time_out && time_out <= time_in
          add('order.not-ascending', "#{label}: TimeIn is earlier than the preceding subtitle", subtitle) if time_in && previous && time_in < previous
          add('time-in.before-start', "#{label}: TimeIn precedes StartTime", subtitle) if time_in && @start && time_in < @start
          previous = time_in if time_in
          spot = Timing.units(subtitle['SpotNumber'])
          if spot && previous_spot && spot != previous_spot + 1
            add('spot.discontinuity', "#{label}: SpotNumber does not follow #{previous_spot}; check subtitle continuity", subtitle, :hint)
          end
          previous_spot = spot if spot
          fades = %w[FadeUpTime FadeDownTime].map do |field|
            raw = subtitle[field]
            fade = raw.nil? ? (@smpte && @rate && @rate > 0 ? Rational(2, @rate) : Rational(0)) : parse_time(raw, duration: true)
            add('fade.invalid', "#{label}: invalid #{field}", subtitle) unless fade
            fade
          end
          if time_in && time_out && fades.all? && fades.sum > time_out - time_in
            add('fade-window.invalid', "#{label}: fades exceed subtitle duration", subtitle)
          end
          @first = [@first, time_in].compact.min
          @last = [@last, time_out].compact.max
          contents = subtitle.xpath('.//Text | .//Image')
          add('subtitle.empty', "#{label}: contains no Text or Image", subtitle) if contents.empty?
          subtitle.xpath('.//text()[normalize-space()]').each do |text|
            unless text.ancestors.any? { |n| %w[Text Image LoadVariableZ].include?(n.name) }
              add('text.outside-text', "#{label}: text outside Text/Image element: #{text.text.strip.inspect}", text)
            end
          end
          contents.each do |content|
            add('content.empty', "#{label}: empty #{content.name}", content, :hint) if content.text.strip.empty?
            if content.name == 'Text'
              content.xpath('.//text()').each do |text|
                next if text.text.empty?
                font = text.ancestors.find { |node| node.name == 'Font' && node[@smpte ? 'ID' : 'Id'] }
                id = font&.[](@smpte ? 'ID' : 'Id') || @fonts.keys.first
                add('font.reference-missing', "#{label}: undeclared Font ID #{id}", content) if id && !@fonts.key?(id)
                @runs << { id: id, text: text.text, node: content }
              end
            end
            align = content['HAlign'] || content['Halign']
            if align && align != 'center' && !%w[ClosedCaption ClosedSubtitle].include?(@context[:kind])
              add('placement.off-center', "#{label}: #{content.name} horizontal alignment is #{align}; review placement", content, :hint)
            end
          end
          if %w[ClosedCaption ClosedSubtitle].include?(@context[:kind])
            add('closed.overlap', "#{label}: closed-display subtitles overlap", subtitle) if time_in && closed_end && time_in < closed_end
            closed_end = [closed_end, time_out].compact.max
            add('closed.image', "#{label}: closed display prohibits Image", subtitle) if contents.any? { |n| n.name == 'Image' }
            add('closed.lines', "#{label}: closed display permits at most three Text elements", subtitle) if contents.count { |n| n.name == 'Text' } > 3
            texts = contents.select { |n| n.name == 'Text' }
            aligns = texts.map { |n| n['Valign'] || n['VAlign'] }.compact.uniq
            positions = texts.map { |n| n['Vposition'] || n['VPosition'] }.compact
            add('closed.valign', "#{label}: closed-display Text elements must share vertical alignment", subtitle) if aligns.size > 1
            add('closed.vposition', "#{label}: closed-display Text elements must have distinct vertical positions", subtitle) if positions.uniq.size != positions.size
          end
        end
        if !@smpte && @runs.map { |run| run[:id] }.compact.uniq.size > 1
          add('font.multiple-ids', 'Interop references multiple Font IDs')
        end
        # Check against the native asset timeline. CPL EntryPoint/Duration trims
        # are allowed; subtitles outside that playback window are not damage.
        intrinsic, rate = @context.values_at(:intrinsic, :edit_rate)
        if @last && @start && intrinsic && rate && rate > 0 && @last - @start > intrinsic / rate
          add('duration.exceeded', "Last subtitle TimeOut #{@last} s exceeds native asset duration #{intrinsic / rate} s after StartTime")
        end
      end

      def inspect_resources
        references = @fonts.map { |id, font| [font[:resource], :font, font[:node], id] }
        references.concat(@xml.xpath('//Image').map { |node| [node.text.strip, :image, node, nil] })
        references.uniq { |resource, kind, _node, id| [resource, kind, id] }.each do |resource, kind, node, id|
          normalized = @smpte ? resource.sub(/\Aurn:uuid:/i, '').downcase : resource
          if resource.empty? || @smpte && (!resource.start_with?('urn:uuid:') || !UUID.match?(normalized))
            add('resource.reference-invalid', "Invalid #{kind} resource reference #{resource.inspect}", node)
            next
          end
          declared = @context[:declared_resources]
          if @smpte && declared && !declared.keys.any? { |key| key.downcase == normalized }
            add('resource.not-in-descriptor', "Resource #{resource} is absent from the MXF descriptor", node)
            next
          end
          if @smpte && declared
            mime = declared.find { |key, _mime| key.downcase == normalized }&.last
            expected = kind == :image ? ['image/png'] : %w[application/font-sfnt application/vnd.ms-opentype application/x-font-opentype application/x-opentype font/otf font/opentype font/sfnt font/ttf]
            add('resource.mime-mismatch', "MXF descriptor declares #{mime} for #{kind} resource #{resource}", node) if mime && !expected.include?(mime.downcase)
          end
          begin
            path = @resolver&.call(normalized)
            unless path && File.file?(path)
              add('resource.missing', "#{kind} resource unavailable or not declared: #{resource}", node)
              next
            end
            if kind == :image
              png = File.binread(path, 24)
              valid = png.size == 24 && png.start_with?("\x89PNG\r\n\x1a\n".b) && png[12, 4] == 'IHDR'
              width, height = valid ? png[16, 8].unpack('NN') : [0, 0]
              add('image.invalid', "Resource #{resource} has no valid PNG signature/IHDR dimensions", node) unless valid && width > 0 && height > 0
              picture_width, picture_height = @context.values_at(:picture_width, :picture_height)
              if picture_width && picture_height && (width > picture_width || height > picture_height)
                add('image.dimensions', "PNG #{resource} is #{width}x#{height}, larger than the picture #{picture_width}x#{picture_height}", node)
              end
              @resources << { kind: kind, reference: resource, width: width, height: height }
            else
              inspect_font(path, resource, id, node)
              @resources << { kind: kind, reference: resource, bytes: File.size(path) }
            end
          rescue StandardError => error
            add('resource.read-failed', "Cannot inspect #{kind} resource #{resource}: #{error.message}", node)
          end
        end
        if @smpte && @context[:declared_resources]
          used = references.map { |resource, _kind, _node, _id| resource.sub(/\Aurn:uuid:/i, '').downcase }
          @context[:declared_resources].each_key do |resource|
            add('resource.descriptor-orphan', "MXF declares unused ancillary resource #{resource}", @xml.root, :hint) unless used.include?(resource.downcase)
          end
        end
      end

      def inspect_stereo
        ids = {}
        @subtitles.each do |subtitle|
          variables = subtitle.xpath('LoadVariableZ')
          variables.each do |variable|
            id = variable['ID'].to_s
            add('variable-z.id', "LoadVariableZ ID is empty or duplicated: #{id}", variable) if id.empty? || ids[id]
            ids[id] = true
            tokens = variable.text.split
            valid = tokens.any? && tokens.all? do |token|
              match = /\A([+-]?(?:\d+(?:\.\d*)?|\.\d+))(?::(\+?\d+))?\z/.match(token)
              match && match[1].to_f.between?(-100, 100) && (!match[2] || match[2].to_i > 0)
            end
            add('variable-z.vector', 'LoadVariableZ requires Z values between -100 and 100 and positive integer durations', variable) unless valid
          end
          subtitle.xpath('.//Text | .//Image').each do |content|
            z, variable = content['Zposition'], content['VariableZ']
            if z && (!z.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)\z/) || !z.to_f.between?(-100, 100))
              add('z-position.invalid', "Invalid Zposition #{z}", content)
            end
            next unless variable
            add('variable-z.fallback', 'VariableZ requires a Zposition fallback', content) unless z
            unless variables.any? { |node| node['ID'] == variable }
              add('variable-z.reference', "VariableZ #{variable} has no LoadVariableZ in this Subtitle", content)
            end
          end
        end
      end

      def inspect_font(path, resource, id, node)
        magic = File.binread(path, 4)
        unless ["\x00\x01\x00\x00".b, 'OTTO', 'true', 'typ1'].include?(magic)
          add('font.invalid', "Resource #{resource} is not an SFNT font", node)
          return
        end
        add('font.size', "Interop font #{resource} exceeds 640 KB", node) if !@smpte && File.size(path) > 655_360
        font = TTFunk::File.open(path)
        maps = font.cmap.unicode
        if maps.empty?
          add('font.glyphs.unchecked', "Font #{resource} has no supported Unicode cmap", node, :hint)
          return
        end
        @runs.select { |run| run[:id] == id }.each do |run|
          missing = run[:text].codepoints.uniq.reject { |cp| [9, 10, 13].include?(cp) || maps.any? { |map| map[cp].to_i > 0 } }
          add('font.glyphs.missing', "Font #{resource} lacks glyphs #{missing.map { |cp| 'U+%04X' % cp }.join(', ')}", run[:node], :hint) if missing.any?
        end
      end
    end
  end
end
