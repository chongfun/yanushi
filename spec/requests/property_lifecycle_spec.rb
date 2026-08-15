require "rails_helper"

RSpec.describe "PropertyLifecycle", type: :request do
  let(:user) { create(:user) }
  let(:party) { create(:party, user: user) }

  before do
    post session_url, params: { email: user.email, password: "password" }
  end

  it "runs the complete property lifecycle: creation to rent payment" do
    # 1. Create a Property (with implicit main unit)
    expect {
      post properties_url, params: {
        property: {
          address: "123 Integration St",
          asset_type: "single_family",
          square_footage: 1500
        }
      }
    }.to change(Property, :count).by(1).and change(RentableUnit, :count).by(1)

    property = Property.last
    unit = property.rentable_units.first
    expect(response).to redirect_to(property_url(property))

    # 2. Create a Tenancy for the Property Unit
    expect {
      post tenancies_url, params: {
        tenancy: {
          rentable_unit_id: unit.id,
          commencement_date: Date.new(2025, 1, 1),
          termination_date: Date.new(2025, 12, 31),
          agreement_type: "fixed_term",
          party_ids: [ party.id ],
          rent_amount: "2000.00"
        }
      }
    }.to change(Tenancy, :count).by(1)
     .and change(TenancyParty, :count).by(1)
     .and change(RentTerm, :count).by(1)

    tenancy = Tenancy.last
    expect(response).to redirect_to(tenancy_url(tenancy))

    # 3. Record a Tenant Payment for the tenancy
    expect {
      post tenant_payments_url, params: {
        tenant_payment: {
          tenancy_id: tenancy.id,
          amount: 2000,
          payment_date: Date.new(2025, 1, 1),
          payment_method: "check"
        }
      }
    }.to change(TenantPayment, :count).by(1)

    payment = TenantPayment.last
    expect(response).to redirect_to(tenant_payment_url(payment))
    expect(payment.tenancy).to eq(tenancy)
  end
end
