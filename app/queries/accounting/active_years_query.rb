module Accounting
  class ActiveYearsQuery
    def self.call(property: nil, user: nil, additional_years: [])
      new(property: property, user: user).call(additional_years: additional_years)
    end

    def initialize(property: nil, user: nil)
      @property = property
      @user = user
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
      elsif user
        db_years = JournalEntry
          .joins(:postings)
          .where(postings: { property_id: user.properties.select(:id) })
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

      attr_reader :property, :user
  end
end
