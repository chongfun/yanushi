module Accounting
  class TenantReceivableActivityQuery
    class StatementRow < Data.define(
      :id,
      :occurred_on,
      :journal_entry,
      :kind,
      :label,
      :description,
      :amount_cents,
      :running_balance_cents,
      :party,
      :source,
      :reversal,
      :corrected,
      :lifecycle_status
    )
      def amount
        BigDecimal(amount_cents.to_s) / 100
      end

      def running_balance
        BigDecimal(running_balance_cents.to_s) / 100
      end

      def corrected?
        lifecycle_status == :corrected || corrected == true
      end

      def voided?
        lifecycle_status == :voided
      end

      def active?
        lifecycle_status == :active || (!corrected? && !voided?)
      end
    end

    class StatementResult < Data.define(
      :tenancy,
      :date_range,
      :opening_balance_cents,
      :closing_balance_cents,
      :rows
    )
      def opening_balance
        BigDecimal(opening_balance_cents.to_s) / 100
      end

      def closing_balance
        BigDecimal(closing_balance_cents.to_s) / 100
      end
    end

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
      t = tenancy
      return empty_result unless t && date_range.valid?

      user = t.accounting_user
      return empty_result unless user

      account = user.accounts.find_by(key: "tenant_receivable")
      return empty_result unless account

      opening_cents = compute_opening_balance(account)
      postings = scoped_postings(account)
      rows = build_rows(postings, opening_cents)
      closing_cents = rows.last&.running_balance_cents || opening_cents

      StatementResult.new(
        tenancy: t,
        date_range: date_range,
        opening_balance_cents: opening_cents,
        closing_balance_cents: closing_cents,
        rows: rows
      )
    end

    private

      attr_reader :tenancy, :date_range

      def empty_result
        StatementResult.new(
          tenancy: tenancy,
          date_range: date_range,
          opening_balance_cents: 0,
          closing_balance_cents: 0,
          rows: []
        )
      end

      def build_rows(postings, opening_cents)
        current_running = opening_cents
        as_of_date = date_range.through || date_range.as_of

        postings.map do |posting|
          entry = posting.journal_entry
          row_delta = posting.amount_cents
          current_running += row_delta

          projected = ActivityProjector.project(entry, as_of: as_of_date)

          StatementRow.new(
            id: entry.id,
            occurred_on: entry.occurred_on,
            journal_entry: entry,
            kind: projected.kind,
            label: projected.label,
            description: projected.description,
            amount_cents: row_delta,
            running_balance_cents: current_running,
            party: projected.party,
            source: projected.source,
            reversal: projected.reversal,
            corrected: projected.corrected,
            lifecycle_status: projected.lifecycle_status
          )
        end
      end

      def base_scope(account)
        account.postings
               .joins(:journal_entry)
               .where(tenancy_id: tenancy&.id)
      end

      def compute_opening_balance(account)
        return 0 unless date_range.from

        base_scope(account)
          .where("journal_entries.occurred_on < ?", date_range.from)
          .sum(:amount_cents)
      end

      def scoped_postings(account)
        scope = base_scope(account)
        if date_range.from
          scope = scope.where("journal_entries.occurred_on BETWEEN ? AND ?", date_range.from, date_range.through)
        else
          scope = scope.where("journal_entries.occurred_on <= ?", date_range.through)
        end

        scope
          .includes(
            journal_entry: [
              :source,
              :reversal,
              reversal_of: [ :source, :reversal, postings: [ :account, :property, :rentable_unit, :tenancy, :party ] ],
              postings: [ :account, :property, :rentable_unit, :tenancy, :party ]
            ]
          )
          .order("journal_entries.occurred_on ASC, journal_entries.id ASC, postings.id ASC")
      end
  end
end
