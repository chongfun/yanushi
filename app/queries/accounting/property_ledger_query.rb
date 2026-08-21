module Accounting
  class PropertyLedgerQuery
    def self.call(property:, from: nil, through: nil, year: nil, date_range: nil)
      new(
        property: property,
        from: from,
        through: through,
        year: year,
        date_range: date_range
      ).call
    end

    def initialize(property:, from: nil, through: nil, year: nil, date_range: nil)
      @property = property
      @date_range = date_range || DateRange.parse(from: from, through: through, year: year)
    end

    def call
      return [] unless property && date_range.valid?

      journal_entry_ids = Posting
        .where(property_id: property.id)
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

      attr_reader :property, :date_range
  end
end
