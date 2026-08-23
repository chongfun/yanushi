module Accounting
  class DateRange
    attr_reader :from, :through, :year, :errors

    def self.parse(params = nil)
      parsed_params = if params.respond_to?(:permit)
        params.permit(:year, :from, :through, :range_mode).to_h.symbolize_keys
      elsif params.respond_to?(:to_h)
        params.to_h.symbolize_keys
      else
        Hash.new
      end
      parsed_params = Hash.new unless parsed_params.is_a?(Hash)

      raw_year = parsed_params[:year]
      raw_from = parsed_params[:from]
      raw_through = parsed_params[:through]
      range_mode = parsed_params[:range_mode].to_s.presence

      if range_mode == "year" && raw_year.present?
        new(year: raw_year)
      elsif range_mode == "custom" && (raw_from.present? || raw_through.present?)
        new(from: raw_from, through: raw_through)
      elsif raw_from.present? || raw_through.present?
        new(from: raw_from, through: raw_through)
      elsif raw_year.present?
        new(year: raw_year)
      else
        new(year: Date.current.year)
      end
    end

    def initialize(from: nil, through: nil, year: nil)
      @errors = []
      @year = parse_year(year)

      if (y = @year)
        @from = Date.new(y, 1, 1)
        @through = Date.new(y, 12, 31)
      else
        parsed_from = parse_date(from, :from)
        parsed_through = parse_date(through, :through)
        @from = parsed_from
        @through = parsed_through

        if parsed_through.blank?
          @through = Date.current
        end

        if parsed_from && parsed_through && parsed_from.year == parsed_through.year && parsed_from == parsed_from.beginning_of_year && parsed_through == parsed_through.end_of_year
          @year = parsed_from.year
        end
      end

      validate!
    end

    def valid?
      @errors.empty?
    end

    def range
      return nil unless valid?

      f = from
      t = through
      return nil unless f && t

      f..t
    end

    def as_of
      through || Date.current
    end

    def to_h
      { from: from, through: through, year: year }
    end

    private

      def parse_year(val)
        return nil if val.blank?
        return val.to_i if val.is_a?(Integer)
        return val.to_s.strip.to_i if val.to_s.strip =~ /\A\d{4}\z/

        @errors << "Invalid year format"
        nil
      end

      def parse_date(val, field)
        return nil if val.blank?
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s.strip)
      rescue ArgumentError, Date::Error
        @errors << "Invalid #{field} date"
        nil
      end

      def validate!
        f = from
        t = through
        if f && t && f > t
          @errors << "From date cannot be after through date"
        end
      end
  end
end
