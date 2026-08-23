module Accounting
  class AccountActivityQuery
    class AccountPostingRow < Data.define(
      :id,
      :posting,
      :occurred_on,
      :journal_entry,
      :description,
      :debit_cents,
      :credit_cents,
      :amount_cents,
      :running_raw_balance_cents,
      :running_natural_balance_cents,
      :property,
      :rentable_unit,
      :tenancy,
      :party,
      :memo
    )
    end

    class QueryResult < Data.define(
      :account,
      :date_range,
      :opening_raw_balance_cents,
      :opening_natural_balance_cents,
      :closing_raw_balance_cents,
      :closing_natural_balance_cents,
      :rows
    )
    end

    def self.call(account:, from: nil, through: nil, year: nil, date_range: nil, property: nil, rentable_unit: nil, tenancy: nil, party: nil)
      new(
        account: account,
        from: from,
        through: through,
        year: year,
        date_range: date_range,
        property: property,
        rentable_unit: rentable_unit,
        tenancy: tenancy,
        party: party
      ).call
    end

    def initialize(account:, from: nil, through: nil, year: nil, date_range: nil, property: nil, rentable_unit: nil, tenancy: nil, party: nil)
      @account = account
      @date_range = date_range || DateRange.parse(from: from, through: through, year: year)
      @property = property
      @rentable_unit = rentable_unit
      @tenancy = tenancy
      @party = party
    end

    def call
      acct = account
      unless acct && date_range.valid?
        return QueryResult.new(
          account: acct,
          date_range: date_range,
          opening_raw_balance_cents: 0,
          opening_natural_balance_cents: 0,
          closing_raw_balance_cents: 0,
          closing_natural_balance_cents: 0,
          rows: []
        )
      end

      opening_raw = compute_opening_raw_balance
      opening_natural = NaturalBalance.convert(acct, opening_raw)

      period_postings = scoped_postings_query
      rows = [] # : Array[AccountPostingRow]
      current_raw = opening_raw

      period_postings.each do |posting|
        current_raw += posting.amount_cents
        current_natural = NaturalBalance.convert(acct, current_raw)

        debit = posting.amount_cents.positive? ? posting.amount_cents : 0
        credit = posting.amount_cents.negative? ? posting.amount_cents.abs : 0

        rows << AccountPostingRow.new(
          id: posting.id,
          posting: posting,
          occurred_on: posting.journal_entry.occurred_on,
          journal_entry: posting.journal_entry,
          description: posting.journal_entry.description,
          debit_cents: debit,
          credit_cents: credit,
          amount_cents: posting.amount_cents,
          running_raw_balance_cents: current_raw,
          running_natural_balance_cents: current_natural,
          property: posting.property,
          rentable_unit: posting.rentable_unit,
          tenancy: posting.tenancy,
          party: posting.party,
          memo: posting.memo
        )
      end

      closing_raw = current_raw
      closing_natural = NaturalBalance.convert(acct, closing_raw)

      QueryResult.new(
        account: acct,
        date_range: date_range,
        opening_raw_balance_cents: opening_raw,
        opening_natural_balance_cents: opening_natural,
        closing_raw_balance_cents: closing_raw,
        closing_natural_balance_cents: closing_natural,
        rows: rows
      )
    end

    private

      attr_reader :account, :date_range, :property, :rentable_unit, :tenancy, :party

      def base_scope
        acct = account
        return Posting.none unless acct

        scope = acct.postings.joins(:journal_entry)
        scope = scope.where(property_id: property.id) if property
        scope = scope.where(rentable_unit_id: rentable_unit.id) if rentable_unit
        scope = scope.where(tenancy_id: tenancy.id) if tenancy
        scope = scope.where(party_id: party.id) if party
        scope
      end

      def compute_opening_raw_balance
        return 0 unless date_range.from

        base_scope
          .where("journal_entries.occurred_on < ?", date_range.from)
          .sum(:amount_cents)
      end

      def scoped_postings_query
        scope = base_scope
        if date_range.from
          scope = scope.where("journal_entries.occurred_on BETWEEN ? AND ?", date_range.from, date_range.through)
        else
          scope = scope.where("journal_entries.occurred_on <= ?", date_range.through)
        end

        scope.includes(:property, :rentable_unit, :tenancy, :party, :journal_entry)
             .order("journal_entries.occurred_on ASC, journal_entries.id ASC, postings.id ASC")
      end
  end
end
