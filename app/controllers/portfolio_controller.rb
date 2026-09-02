class PortfolioController < ApplicationController
  def show
    @properties = authenticated_user.properties.order(:address).includes(rentable_units: { tenancies: :parties })
    all_tenancies = @properties.flat_map { |p| p.rentable_units.flat_map(&:tenancies) }
    @balances = Accounting::TenancyBalancesQuery.call(tenancies: all_tenancies)
  end
end
