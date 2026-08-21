module Accounting
  class ActiveYearsQuery
    def self.call(property:, additional_years: [])
      new(property: property).call(additional_years: additional_years)
    end

    def initialize(property:)
      @property = property
    end

    def call(additional_years: [])
      years = Set.new
      years << Date.current.year

      if property
        db_years = JournalEntry
          .joins(:postings)
          .where(postings: { property_id: property.id })
          .pluck(Arel.sql("DISTINCT EXTRACT(YEAR FROM journal_entries.occurred_on)::integer"))
          .compact

        years.merge(db_years)
      end

      additional_years.each do |year|
        next unless year.respond_to?(:to_i)

        parsed_year = year.to_i
        years << parsed_year unless parsed_year.zero?
      end

      years.to_a.sort
    end

    private

      attr_reader :property
  end
end
