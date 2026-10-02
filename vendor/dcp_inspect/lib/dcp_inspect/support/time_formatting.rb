# frozen_string_literal: true

require "date"

module DcpInspect
  module Support
    module TimeFormatting
      def time_to_datetime(time)
        DateTime.parse(time.to_s)
      end

      def datetime_friendly_mmmddyyyy(datetime)
        "#{DateTime::ABBR_MONTHNAMES[datetime.month]} #{datetime.day} #{datetime.year}"
      end

      def distance_of_time_in_words(from_time, to_time = 0, include_seconds = false, _options = {})
        from_time = from_time.to_time if from_time.respond_to?(:to_time)
        to_time = to_time.to_time if to_time.respond_to?(:to_time)
        minutes = (((to_time - from_time).abs) / 60).round
        seconds = (to_time - from_time).abs.round

        case minutes
        when 0..1
          return minutes.zero? ? "less than 1 minute" : amount('minute', minutes) unless include_seconds
          seconds <= 59 ? "less than 1 minute" : "1 minute"
        when 2..44 then amount('minute', minutes)
        when 45..89 then "about 1 hour"
        when 90..1439 then "about #{amount('hour', (minutes.to_f / 60).round)}"
        when 1440..2519 then "1 day"
        when 2520..43199 then amount('day', (minutes.to_f / 1440).round)
        when 43200..86399 then "about 1 month"
        when 86400..525599 then amount('month', (minutes.to_f / 43_200).round)
        else year_distance(from_time, to_time, minutes)
        end
      end

      private

      def amount(item, count)
        "#{count} #{item}#{count == 1 ? '' : 's'}"
      end

      def year_distance(from_time, to_time, minutes)
        first_year = from_time.year + (from_time.month >= 3 ? 1 : 0)
        last_year = to_time.year - (to_time.month < 3 ? 1 : 0)
        leap_years = first_year > last_year ? 0 : (first_year..last_year).count { |year| Date.leap?(year) }
        adjusted = minutes - (leap_years * 1440)
        years, remainder = adjusted.divmod(525_600)
        return "about #{amount('year', years)}" if remainder < 131_400
        return "over #{amount('year', years)}" if remainder < 394_200

        "almost #{amount('year', years + 1)}"
      end
    end
  end
end
