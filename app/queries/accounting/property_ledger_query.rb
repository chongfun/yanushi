module Accounting
  class PropertyLedgerQuery
    def self.call(property:, from: nil, through: nil, year: nil, date_range: nil, limit: nil)
      new(
        property: property,
        from: from,
        through: through,
        year: year,
        date_range: date_range,
        limit: limit
      ).call
    end

    def initialize(property:, from: nil, through: nil, year: nil, date_range: nil, limit: nil)
      @property = property
      @date_range = date_range || DateRange.parse(from: from, through: through, year: year)
      @limit = limit
    end

    def call
      prop = property
      return [] unless prop && date_range.valid?

      journal_entry_ids = Posting
        .where(property_id: prop.id)
        .select(:journal_entry_id)
        .distinct

      scope = JournalEntry.where(id: journal_entry_ids)

      if date_range.from
        scope = scope.where(occurred_on: date_range.from..date_range.through)
      else
        scope = scope.where("occurred_on <= ?", date_range.through)
      end

      scope = scope.order(occurred_on: :desc, id: :desc)
      scope = scope.limit(limit) if limit.present?

      entries = scope
        .includes(
          :source,
          :reversal,
          postings: [ :account, :property, :rentable_unit, :tenancy, :party ],
          reversal_of: [ :source, :reversal, postings: [ :account, :property, :rentable_unit, :tenancy, :party ] ]
        )

      as_of_date = date_range.through || date_range.as_of
      entries.map { |entry| ActivityProjector.project(entry, as_of: as_of_date) }
    end

    private

      attr_reader :property, :date_range, :limit
  end
end
