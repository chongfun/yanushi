module Accounting
  class TenancyBalancesQuery
    def self.call(tenancies:, as_of: nil)
      new(tenancies: tenancies, as_of: as_of).call
    end

    def initialize(tenancies:, as_of: nil)
      @tenancies = Array(tenancies).compact
      @as_of = parse_as_of(as_of) || Date.current
    end

    def call
      return {} if tenancies.empty?

      tenancy_ids = tenancies.map(&:id)
      result = tenancy_ids.index_with { 0 }

      scope = Posting.joins(:account, :journal_entry)
                     .where(accounts: { key: "tenant_receivable" })
                     .where(tenancy_id: tenancy_ids)
                     .where("journal_entries.occurred_on <= ?", as_of)

      sums = scope.group(:tenancy_id).sum(:amount_cents)

      sums.each do |tenancy_id, amount_cents|
        result[tenancy_id] = amount_cents
      end

      result
    end

    private

      attr_reader :tenancies, :as_of

      def parse_as_of(val)
        return nil if val.blank?
        return val if val.is_a?(Date)
        return val.to_date if val.respond_to?(:to_date)

        Date.parse(val.to_s.strip)
      rescue ArgumentError, Date::Error
        nil
      end
  end
end
