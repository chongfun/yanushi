module Accounting
  class TenancyActivityQuery
    def self.call(tenancy:, from: nil, through: nil, year: nil, date_range: nil)
      new(
        tenancy: tenancy,
        from: from,
        through: through,
        year: year,
        date_range: date_range
      ).call
    end

    def initialize(tenancy:, from: nil, through: nil, year: nil, date_range: nil)
      @tenancy = tenancy
      @date_range = date_range || DateRange.parse(from: from, through: through, year: year)
    end

    def call
      return [] unless tenancy && date_range.valid?

      journal_entry_ids = Posting
        .where(tenancy_id: tenancy.id)
        .select(:journal_entry_id)
        .distinct

      scope = JournalEntry.where(id: journal_entry_ids)

      if date_range.from && date_range.through
        scope = scope.where(occurred_on: date_range.from..date_range.through)
      elsif date_range.from
        scope = scope.where("occurred_on >= ?", date_range.from)
      elsif date_range.through
        scope = scope.where("occurred_on <= ?", date_range.through)
      end

      entries = scope
        .includes(
          :source,
          :reversal,
          postings: [ :account, :property, :rentable_unit, :tenancy, :party ],
          reversal_of: [ :source, :reversal, postings: [ :account, :property, :rentable_unit, :tenancy, :party ] ]
        )
        .order(occurred_on: :desc, id: :desc)

      as_of_date = date_range.through || date_range.as_of
      entries.map { |entry| ActivityProjector.project(entry, as_of: as_of_date) }
    end

    private

      attr_reader :tenancy, :date_range
  end
end
