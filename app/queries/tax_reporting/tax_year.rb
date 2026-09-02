module TaxReporting
  class TaxYear
    MIN_YEAR = 1901
    MAX_YEAR = 2099
    YEAR_REGEX = /\A\d{4}\z/

    attr_reader :year

    def self.parse(raw_value, default: Date.current.year)
      if raw_value.blank?
        return default ? new(default) : nil
      end

      if raw_value.is_a?(TaxYear)
        return raw_value
      end

      str = raw_value.to_s.strip
      return nil unless str.match?(YEAR_REGEX)

      int_val = str.to_i
      return nil unless int_val.between?(MIN_YEAR, MAX_YEAR)

      new(int_val)
    end

    def self.parse!(raw_value, default: Date.current.year)
      parsed = parse(raw_value, default: default)
      return parsed if parsed

      raise InvalidTaxYearError, "Invalid tax year: #{raw_value.inspect}. Expected 4-digit year between #{MIN_YEAR} and #{MAX_YEAR}."
    end

    def initialize(year)
      @year = year.to_i
    end

    def to_i
      @year
    end

    def to_s
      @year.to_s
    end

    def ==(other)
      if other.is_a?(TaxYear)
        year == other.year
      elsif other.is_a?(Integer) || other.is_a?(String)
        year == other.to_i
      else
        false
      end
    end
    alias_method :eql?, :==

    def hash
      year.hash
    end
  end

  class InvalidTaxYearError < ArgumentError; end
end
