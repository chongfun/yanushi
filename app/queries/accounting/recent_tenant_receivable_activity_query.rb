module Accounting
  class RecentTenantReceivableActivityQuery
    DEFAULT_LIMIT = 5

    def self.call(tenancy:, limit: DEFAULT_LIMIT, as_of: Date.current)
      new(tenancy: tenancy, limit: limit, as_of: as_of).call
    end

    def initialize(tenancy:, limit: DEFAULT_LIMIT, as_of: Date.current)
      @tenancy = tenancy
      @limit = limit
      @as_of = as_of
    end

    def call
      t = tenancy
      return [] unless t

      user = t.accounting_user
      return [] unless user

      account = user.accounts.find_by(key: "tenant_receivable")
      return [] unless account

      base_scope = account.postings
                          .joins(:journal_entry)
                          .where(tenancy_id: t.id)
      base_scope = base_scope.where("journal_entries.occurred_on <= ?", as_of) if as_of.present?

      recent_postings = base_scope
        .includes(
          journal_entry: [
            :source,
            :reversal,
            reversal_of: [ :source, :reversal, postings: [ :account, :property, :rentable_unit, :tenancy, :party ] ],
            postings: [ :account, :property, :rentable_unit, :tenancy, :party ]
          ]
        )
        .order("journal_entries.occurred_on DESC, journal_entries.id DESC, postings.id DESC")
        .limit(limit)
        .to_a

      return [] if recent_postings.empty?

      oldest_recent = recent_postings.last

      prior_balance_cents = base_scope
        .where(
          "journal_entries.occurred_on < :date OR (journal_entries.occurred_on = :date AND (journal_entries.id < :entry_id OR (journal_entries.id = :entry_id AND postings.id < :posting_id)))",
          date: oldest_recent.journal_entry.occurred_on,
          entry_id: oldest_recent.journal_entry_id,
          posting_id: oldest_recent.id
        )
        .sum(:amount_cents)

      running = prior_balance_cents
      ascending_rows = recent_postings.reverse.map do |posting|
        entry = posting.journal_entry
        running += posting.amount_cents
        projected = ActivityProjector.project(entry, as_of: as_of)

        TenantReceivableActivityQuery::StatementRow.new(
          id: entry.id,
          occurred_on: entry.occurred_on,
          journal_entry: entry,
          kind: projected.kind,
          label: projected.label,
          description: projected.description,
          amount_cents: posting.amount_cents,
          running_balance_cents: running,
          party: projected.party,
          source: projected.source,
          reversal: projected.reversal,
          corrected: projected.corrected,
          lifecycle_status: projected.lifecycle_status
        )
      end

      ascending_rows.reverse
    end

    private

      attr_reader :tenancy, :limit, :as_of
  end
end
