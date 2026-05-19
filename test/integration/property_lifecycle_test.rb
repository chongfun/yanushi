require "test_helper"

class PropertyLifecycleTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    post session_url, params: { email: @user.email, password: "password" }
  end

  test "complete property lifecycle: creation to rent payment" do
    # 1. Create a Rental Property
    assert_difference "RentalProperty.count", 1 do
      post rental_properties_url, params: {
        rental_property: {
          address: "123 Integration St",
          property_type: "single_family_residence",
          square_footage: 1500
        }
      }
    end
    property = RentalProperty.last
    assert_redirected_to rental_property_url(property)

    # 2. Create a Lease for the Property
    # Note: after_create callback on Lease generates ScheduledRents
    assert_difference "Lease.count", 1 do
      assert_difference "ScheduledRent.count", 12 do
        post leases_url, params: {
          lease: {
            rental_property_id: property.id,
            commencement_date: Date.new(2025, 1, 1),
            termination_date: Date.new(2025, 12, 31),
            annual_rental_amount: 24000,
            lease_type: "term"
          }
        }
      end
    end
    lease = Lease.last
    assert_redirected_to lease_url(lease)

    # 3. Record a Tenant Payment for the lease
    scheduled_rent = lease.scheduled_rents.order(:due_date).first
    assert_difference "TenantPayment.count", 1 do
      post tenant_payments_url, params: {
        tenant_payment: {
          lease_id: lease.id,
          amount: 2000,
          payment_date: Date.new(2025, 1, 1),
          payment_method: "Check"
        }
      }
    end

    # 4. Verify the scheduled rent is marked as covered
    scheduled_rent.reload
    assert scheduled_rent.covered?
  end
end
