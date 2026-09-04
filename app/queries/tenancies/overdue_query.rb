module Tenancies
  # Splits an outstanding tenancy balance into the part that is genuinely late
  # and the part that is still inside its grace period.
  #
  # Rent posts from a recurring job, so on the first of every month each
  # occupied tenancy carries a positive balance that is not yet a problem.
  # Credits are applied first-in-first-out, so whatever a tenancy has received
  # settles its oldest charges first; the part of the balance that exceeds the
  # charges not yet past their due date plus grace period is what is overdue.
  #
  # One grouped query covers every tenancy passed in, so callers that already
  # hold the tenancies and their balances (the Overview) add no per-row queries.
  class OverdueQuery
    def self.call(tenancies:, balances:, as_of: nil)
      new(tenancies: tenancies, balances: balances, as_of: as_of).call
    end

    def initialize(tenancies:, balances:, as_of: nil)
      @tenancies = Array(tenancies).compact
      @balances = balances || {}
      @as_of = as_of || Date.current
    end

    # => { tenancy_id => overdue_cents }, never negative, one key per tenancy.
    def call
      return {} if tenancies.empty?

      not_yet_due = not_yet_due_cents_by_tenancy
      result = {} # : Hash[Integer, Integer]
      tenancies.each do |tenancy|
        balance_cents = balances[tenancy.id] || 0
        result[tenancy.id] = [ balance_cents - (not_yet_due[tenancy.id] || 0), 0 ].max
      end
      result
    end

    private

      attr_reader :tenancies, :balances, :as_of

      # Posted, active charges whose due date plus the tenancy's own grace
      # period has not yet passed. `date + integer` is a date in Postgres.
      def not_yet_due_cents_by_tenancy
        Charge.active
              .posted
              .joins(:tenancy)
              .where(tenancy_id: tenancies.map(&:id))
              .where("charges.due_on + tenancies.late_period_days >= ?", as_of)
              .group(:tenancy_id)
              .sum(:amount_cents)
      end
  end
end
