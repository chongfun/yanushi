module Properties
  class TenanciesController < ApplicationController
    before_action :set_property

    def index
      all_tenancies = @property.tenancies
                               .includes(:parties, :tenancy_parties, :rentable_unit, :rent_terms)
                               .order(commencement_date: :desc)
                               .to_a
      @active_tenancies = all_tenancies.select(&:active?)
      @upcoming_tenancies = all_tenancies.select(&:upcoming?)
      @past_tenancies = all_tenancies.select(&:past?)
      @balances = Accounting::TenancyBalancesQuery.call(tenancies: all_tenancies)
    end

    private

      def set_property
        @property = authenticated_user.properties.includes(rentable_units: :tenancies).find(params.expect(:property_id))
      end
  end
end
