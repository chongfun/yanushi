module Tenancies
  class AgreementsController < ApplicationController
    before_action :set_tenancy

    def show
      @current_rent_term = @tenancy.primary_rent_term
      @security_deposit_held_cents = Accounting::SecurityDepositBalanceQuery.call(tenancy: @tenancy, as_of: Date.current)
      @balance_cents = Accounting::TenancyBalanceQuery.balance_cents_as_of(tenancy: @tenancy, as_of: Date.current)
    end

    private

      def set_tenancy
        @tenancy = authenticated_user.tenancies.includes(
          { rentable_unit: :property },
          { tenancy_parties: :party },
          :rent_terms,
          :security_deposit
        ).find(params.expect(:tenancy_id))
      end
  end
end
