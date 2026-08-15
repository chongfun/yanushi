module Tenancies
  class BalanceQuery
    def initialize(tenancy:)
      @tenancy = tenancy
    end

    def total_credits(as_of: Date.current)
      if tenancy.tenant_payments.loaded?
        tenancy.tenant_payments.select { |payment| payment.payment_date <= as_of }.sum { |p| p.amount }
      else
        tenancy.tenant_payments.where("payment_date <= ?", as_of).sum(:amount)
      end
    end

    def total_debits(as_of: Date.current)
      scheduled_rent_debits(as_of: as_of) + tenant_charge_debits(as_of: as_of)
    end

    def balance_as_of(date = Date.current)
      total_credits(as_of: date) - total_debits(as_of: date)
    end

    private

      attr_reader :tenancy

      def scheduled_rent_debits(as_of:)
        if tenancy.scheduled_rents.loaded?
          tenancy.scheduled_rents.select { |rent| (due = rent.due_date) && due <= as_of }.sum { |r| r.amount }
        else
          tenancy.scheduled_rents.where("due_date <= ?", as_of).sum(:amount)
        end
      end

      def tenant_charge_debits(as_of:)
        if tenancy.tenant_charges.loaded?
          tenancy.tenant_charges.select { |charge| charge.charge_date <= as_of }.sum { |c| c.amount }
        else
          tenancy.tenant_charges.where("charge_date <= ?", as_of).sum(:amount)
        end
      end
  end
end
