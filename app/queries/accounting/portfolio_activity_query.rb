module Accounting
  class PortfolioActivityQuery
    PortfolioActivityResult = Data.define(
      :rows,
      :page,
      :per_page,
      :total_pages,
      :total_count,
      :date_range,
      :property_id
    )

    def self.call(user:, date_range: nil, from: nil, through: nil, year: nil, property_id: nil, page: 1, per_page: 25)
      new(
        user: user,
        date_range: date_range,
        from: from,
        through: through,
        year: year,
        property_id: property_id,
        page: page,
        per_page: per_page
      ).call
    end

    def initialize(user:, date_range: nil, from: nil, through: nil, year: nil, property_id: nil, page: 1, per_page: 25)
      @user = user
      @date_range = date_range || DateRange.parse(from: from, through: through, year: year)
      @property_id = property_id.presence
      @page = [ page.to_i, 1 ].max
      @per_page = [ per_page.to_i, 1 ].max
    end

    def call
      return empty_result unless user && date_range.valid?

      property_scope = user.properties
      if property_id
        property_scope = property_scope.where(id: property_id)
      end

      journal_entry_ids = Posting
        .where(property_id: property_scope.select(:id))
        .select(:journal_entry_id)
        .distinct

      scope = JournalEntry.where(id: journal_entry_ids)

      if date_range.from
        scope = scope.where(occurred_on: date_range.from..date_range.through)
      elsif date_range.through
        scope = scope.where("occurred_on <= ?", date_range.through)
      end

      total_count = scope.count
      total_pages = total_count.zero? ? 0 : (total_count.to_f / per_page).ceil
      current_page = total_pages > 0 ? [ page, total_pages ].min : page

      entries = scope
        .order(occurred_on: :desc, id: :desc)
        .limit(per_page)
        .offset((current_page - 1) * per_page)
        .includes(
          :source,
          :reversal,
          postings: [ :account, :property, :rentable_unit, :tenancy, :party ],
          reversal_of: [ :source, :reversal, postings: [ :account, :property, :rentable_unit, :tenancy, :party ] ]
        )

      as_of_date = date_range.through || date_range.as_of
      rows = entries.map { |entry| ActivityProjector.project(entry, as_of: as_of_date) }

      PortfolioActivityResult.new(
        rows: rows,
        page: current_page,
        per_page: per_page,
        total_pages: total_pages,
        total_count: total_count,
        date_range: date_range,
        property_id: property_id
      )
    end

    private

      attr_reader :user, :date_range, :property_id, :page, :per_page

      def empty_result
        PortfolioActivityResult.new(
          rows: [],
          page: 1,
          per_page: per_page,
          total_pages: 0,
          total_count: 0,
          date_range: date_range,
          property_id: property_id
        )
      end
  end
end
