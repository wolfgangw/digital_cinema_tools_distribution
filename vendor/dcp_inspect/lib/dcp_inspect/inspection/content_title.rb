# frozen_string_literal: true
require 'json'

module DcpInspect
  module Inspection
    # Adapted from dcp_inspect/src/dcp/content-title-text.js (BSD-3-Clause).
    # Registry snapshot: ISDCF 2026-10-01, from sibling browser application.
    # Naming is a claim, never a substitute for XML/MXF technical evidence.
    module ContentTitle
      REGISTRY = JSON.parse(File.read(File.join(__dir__, 'dcnc_registry.json'))).freeze
      KINDS = %w[FTR TLR TSR TST RTG ADV SHR XSN PSA POL CLP PRO STR EPS HLT EVT].freeze
      FIELDS = %i[content aspect language territory audio resolution studio date facility].freeze
      AUDIO = %w[51 71 10 20 21 MOS IAB HI VI SL ATMOS AURO DTSX DBOX 61].freeze
      SUFFIX = /\A(?:(?:IOP|SMPTE)(?:-3D)?|i3D(?:-(?:gb|ngb))?|(?:OV|VF)(?:-\d+)?)\z/
      module_function

      def language(raw, subtitle = false)
        return { raw: raw, tag: nil, mode: 'none' } if raw == 'XX'
        lower = raw.to_s.match?(/\A[a-z0-9]+\z/)
        code = subtitle && lower ? raw.upcase : raw
        tag = REGISTRY['languages'][code] if raw.to_s.match?(/\A[A-Z0-9]+\z/) || subtitle && lower
        { raw: raw, tag: tag, mode: !tag ? 'unknown' : subtitle ? (lower ? 'burnt-in' : 'rendered') : 'audio' }
      end

      def score(field, token)
        content = KINDS.include?(token[/\A([A-Z]{3})\d*(?:-|$)/, 1])
        aspect = token.match?(/\A[FSC](?:-\d{3})?\z/)
        resolution = %w[2K 4K 48].include?(token)
        date = token.match?(/\A\d{8}\z/)
        anchor = { content: content, aspect: aspect, resolution: resolution, date: date }
        return anchor[field] ? (field == :date ? 14 : 12) : -Float::INFINITY if anchor.key?(field)
        return -Float::INFINITY if anchor.values.any? || %w[SMPTE IOP VF].include?(token)
        pieces = token.split('-')
        lang = pieces.size >= 2 && pieces.drop(1).any? { |p| %w[XX CCAP OCAP].include?(p) || language(p, true)[:mode] != 'unknown' }
        territory = REGISTRY['territories'].key?(pieces.first) || token == 'OV' || token.match?(/\A[A-Z]{2,3}-(?:TD|TL|NR)\z/)
        audio = pieces.any? { |p| AUDIO.include?(p) } || token.match?(/\A(?:IMAX\d+|\d+[Cc][Hh])\z/)
        case field
        when :language then lang ? (pieces.include?('XX') ? 12 : 10) : -Float::INFINITY
        when :territory then territory ? 10 : -Float::INFINITY
        when :audio then audio ? 10 : -Float::INFINITY
        else
          return 8 if REGISTRY[field == :studio ? 'studios' : 'facilities'].key?(token)
          lang || audio || token == 'OV' ? -Float::INFINITY : 1
        end
      end

      def parse(value)
        result = { raw: value.to_s, recognized: false, fields: {}, unknown: [], diagnostics: [] }
        return result if value.to_s.empty? || value.to_s.size > 16_384
        parts = value.split('_', -1)
        return result if parts.size > 64
        parts = parts.flat_map do |token|
          split = token.gsub(/-(?=(?:[24]K|\d{8})(?:-|$))/, '_').gsub(/(^|_)(2K|4K|\d{8})-/, '\1\2_').split('_', -1)
          result[:diagnostics] << { field: :separator, code: 'recovered', token: token } if split.size > 1
          split
        end
        return result if parts.size > 64
        start = parts.index { |t| KINDS.include?(t[/\A([A-Z]{3})\d*(?:-|$)/, 1]) }
        start = parts.index { |t| t.match?(/\A[FSC](?:-\d{3})?\z/) } unless start && start > 0
        return result unless start && start > 0
        fields = { title: parts.take(start).join('_') }
        suffix = []
        suffix.unshift(parts.pop) while parts.last&.match?(SUFFIX)
        tokens = parts.drop(start).reject(&:empty?)
        n, m = FIELDS.size, tokens.size
        scores = Array.new(n + 1) { Array.new(m + 1, -Float::INFINITY) }
        scores[n][m] = 0
        n.downto(0) do |i|
          m.downto(0) do |j|
            choices = [scores[i][j]]
            choices << -3 + scores[i + 1][j] if i < n
            choices << -4 + scores[i][j + 1] if j < m
            choices << score(FIELDS[i], tokens[j]) + scores[i + 1][j + 1] if i < n && j < m
            scores[i][j] = choices.max
          end
        end
        possibilities, visited, used = Array.new(n) { [] }, {}, {}
        visit = lambda do |i, j|
          return if visited[[i, j]]
          visited[[i, j]] = true
          if i < n && scores[i][j] == -3 + scores[i + 1][j]
            possibilities[i] |= [nil]; visit.call(i + 1, j)
          end
          visit.call(i, j + 1) if j < m && scores[i][j] == -4 + scores[i][j + 1]
          if i < n && j < m && scores[i][j] == score(FIELDS[i], tokens[j]) + scores[i + 1][j + 1]
            possibilities[i] |= [j]; used[j] = true; visit.call(i + 1, j + 1)
          end
        end
        visit.call(0, 0)
        FIELDS.each_with_index do |field, i|
          choices = possibilities[i]
          if choices.size == 1 && !choices.first.nil?
            fields[field] = tokens[choices.first]
          else
            result[:diagnostics] << { field: field, code: choices.size > 1 ? 'ambiguous' : 'missing-or-unrecognized', candidates: choices.compact.map { |j| tokens[j] } }
          end
        end
        tokens.each_with_index { |token, j| result[:diagnostics] << { field: :unassigned, code: 'unrecognized', token: token } unless used[j] }
        return result if %i[content aspect resolution date].count { |f| fields[f] } < 2
        result.merge!(recognized: true, fields: fields)
        content = fields[:content].to_s.match(/\A([A-Z]{3})(\d+)?(?:-(.*))?\z/)
        modifiers = content&.[](3).to_s.split('-')
        result[:version] = content&.[](2) || (modifiers.first&.match?(/\A\d+\z/) ? modifiers.shift : nil)
        result[:modifiers] = modifiers
        result[:content_kind] = content&.[](1)
        result[:status] = modifiers.find { |t| %w[Temp Pre Final].include?(t) }
        result[:luminance_code] = modifiers.find { |t| t.match?(/\A\d+fl\z/) }
        result[:picture_qualifiers] = modifiers & %w[DVis HDR1 EC EPIQ]
        result[:chain] = modifiers.find { |t| %w[ALT InfV].include?(t) }
        result[:dimension] = modifiers.find { |t| %w[2D 3D].include?(t) }
        result[:frame_rate] = modifiers.find { |t| %w[25 30 48 50 60 96 100 120].include?(t) }&.to_i
        result[:resolution] = fields[:resolution] == '48' ? '2K' : fields[:resolution]
        result[:frame_rate] ||= 48 if fields[:resolution] == '48'
        languages = fields[:language].to_s.split('-')
        result[:audio_language] = language(languages.first)
        result[:subtitles] = languages.drop(1).reject { |t| %w[CCAP OCAP].include?(t) }.map { |t| language(t, true) }
        result[:caption_flags] = languages & %w[CCAP OCAP]
        result[:audio] = fields[:audio].to_s.split('-')
        modifiers.each do |token|
          known = %w[Temp Pre Final 2D 3D 25 30 48 50 60 96 100 120 DVis HDR1 EC EPIQ ALT InfV RedBand].include?(token) || token.match?(/\A\d+fl\z/)
          result[:unknown] << { field: :content, token: token } unless known
        end
        result[:audio].each do |token|
          result[:unknown] << { field: :audio, token: token } unless AUDIO.include?(token) || REGISTRY['languages'].key?(token)
        end
        suffix.each do |token|
          if token.match?(/\A(?:OV|VF)(?:-\d+)?\z/)
            result[:package_type] ||= token
          else
            result[:standard] ||= token.start_with?('SMPTE') ? 'SMPTE' : 'Interop'
            result[:dimension] ||= '3D' if token.include?('3D')
          end
        end
        result
      end

      def compare(title, evidence)
        return [] unless title[:recognized]
        messages = []
        %i[standard dimension frame_rate resolution].each do |field|
          claimed, actual = title[field], evidence[field]
          messages << "ContentTitleText #{field} claims #{claimed}; inspected content is #{actual}" if claimed && actual && claimed != actual
        end
        claim = title[:package_type]&.split('-')&.first
        external = evidence[:external_ids]
        if claim == 'OV' && external&.any?
          messages << "ContentTitleText claims OV but #{external.size} referenced assets are outside the declaring PKL"
        elsif claim == 'VF' && external == []
          messages << 'ContentTitleText claims VF but all referenced assets are listed in the declaring PKL'
        end
        messages
      end
    end
  end
end
