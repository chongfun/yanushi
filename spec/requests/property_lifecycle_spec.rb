require 'rails_helper'

RSpec.describe "PropertyLifecycle", type: :request do
  let(:user) { create(:user) }

  before do
    post session_url, params: { email: user.email, password: "password" }
  end

  it "runs the complete property lifecycle: creation to rent payment" do
    # 1. Create a Rental Property
    expect {
      post rental_properties_url, params: {
        rental_property: {
          address: "123 Integration St",
          property_type: "single_family_residence",
          square_footage: 1500
        }
      }
    }.to change(RentalProperty, :count).by(1)

    property = RentalProperty.last
    expect(response).to redirect_to(rental_property_url(property))

    # 2. Create a Lease for the Property
    expect {
      expect {
        post leases_url, params: {
          lease: {
            rental_property_id: property.id,
            commencement_date: Date.new(2025, 1, 1),
            termination_date: Date.new(2025, 12, 31),
            annual_rental_amount: 24000,
            lease_type: "term"
          }
        }
      }.to change(ScheduledRent, :count).by(12)
    }.to change(Lease, :count).by(1)

    lease = Lease.last
    expect(response).to redirect_to(lease_url(lease))

    # 3. Record a Tenant Payment for the lease
    scheduled_rent = lease.scheduled_rents.order(:due_date).first
    expect {
      post tenant_payments_url, params: {
        tenant_payment: {
          lease_id: lease.id,
          amount: 2000,
          payment_date: Date.new(2025, 1, 1),
          payment_method: "Check"
        }
      }
    }.to change(TenantPayment, :count).by(1)

    # 4. Verify the scheduled rent is marked as covered
    scheduled_rent.reload
    expect(scheduled_rent.covered?).to be_truthy
  end
end
