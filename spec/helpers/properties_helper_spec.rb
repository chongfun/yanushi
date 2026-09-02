require "rails_helper"

RSpec.describe PropertiesHelper, type: :helper do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }

  describe "#active_tenancy_for and #active_tenancies_for" do
    it "returns active tenancies for the property" do
      active_tenancy = create(:tenancy,
        rentable_unit: unit,
        agreement_type: "fixed_term",
        commencement_date: Date.current - 1.month,
        termination_date: Date.current + 11.months
      )

      expect(helper.active_tenancies_for(property)).to include(active_tenancy)
      expect(helper.active_tenancy_for(property)).to eq(active_tenancy)
      expect(helper.active_leases_for(property)).to include(active_tenancy)
      expect(helper.active_lease_for(property)).to eq(active_tenancy)
    end

    it "falls back to most recent tenancy if no tenancy is currently active" do
      past_tenancy = create(:tenancy,
        rentable_unit: unit,
        agreement_type: "fixed_term",
        commencement_date: Date.new(2023, 1, 1),
        termination_date: Date.new(2023, 12, 31)
      )

      expect(helper.active_tenancies_for(property)).to be_empty
      expect(helper.active_tenancy_for(property)).to eq(past_tenancy)
    end

    it "returns nil when property has no tenancies" do
      expect(helper.active_tenancies_for(property)).to be_empty
      expect(helper.active_tenancy_for(property)).to be_nil
    end
  end
end
