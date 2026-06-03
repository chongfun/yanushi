module Leases
  class BalanceQuery
    def initialize(lease:)
      @lease = lease
    end

    def total_credits(as_of: Date.current)
      if lease.tenant_payments.loaded?
        lease.tenant_payments.select { |payment| payment.payment_date <= as_of }.sum(&:amount)
      else
        lease.tenant_payments.where("payment_date <= ?", as_of).sum(:amount)
      end
    end

    def total_debits(as_of: Date.current)
      scheduled_rent_debits(as_of:) + tenant_charge_debits(as_of:)
    end

    def balance_as_of(date = Date.current)
      total_credits(as_of: date) - total_debits(as_of: date)
    end

    private

    attr_reader :lease

    def scheduled_rent_debits(as_of:)
      if lease.scheduled_rents.loaded?
        lease.scheduled_rents.select { |rent| (due = rent.due_date) && due <= as_of }.sum(&:amount)
      else
        lease.scheduled_rents.where("due_date <= ?", as_of).sum(:amount)
      end
    end

    def tenant_charge_debits(as_of:)
      if lease.tenant_charges.loaded?
        lease.tenant_charges.select { |charge| charge.charge_date <= as_of }.sum(&:amount)
      else
        lease.tenant_charges.where("charge_date <= ?", as_of).sum(:amount)
      end
    end
  end
end
