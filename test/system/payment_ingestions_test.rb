require "application_system_test_case"

class PaymentIngestionsTest < ApplicationSystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400]

  setup do
    @user = users(:one)
    
    # Create tenants & leases
    @tenant_a = Tenant.create!(user: @user, name: "Tenant Alpha", email_address: "alpha@example.com")
    @property_a = RentalProperty.create!(user: @user, address: "123 Alpha St")
    @lease_a = Lease.create!(rental_property: @property_a, lease_type: "month_to_month", commencement_date: Date.today, annual_rental_amount: 12000)
    @lease_a.tenants << @tenant_a

    @tenant_b = Tenant.create!(user: @user, name: "Tenant Beta", email_address: "beta@example.com")
    @property_b = RentalProperty.create!(user: @user, address: "456 Beta Ave")
    @lease_b = Lease.create!(rental_property: @property_b, lease_type: "month_to_month", commencement_date: Date.today, annual_rental_amount: 18000)
    @lease_b.tenants << @tenant_b

    @document = PaymentDocument.create!(
      user: @user,
      attachment_file: "dummy_pdf_content",
      attachment_filename: "receipt.pdf",
      attachment_content_type: "application/pdf"
    )

    @ingestion = PaymentIngestion.create!(
      user: @user,
      source: "pdf_upload",
      status: "pending",
      payer_name: "Tenant Alpha",
      amount: 1000.0,
      payment_date: Date.today,
      payment_method: "zelle",
      transaction_number: "TXN123",
      payment_document: @document
    )

    # Log in
    visit new_session_path
    fill_in "email", with: @user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    
    # Wait for authentication to complete fully
    assert_text "Total Income"
  end

  test "dynamic filtering of tenant and lease dropdowns on ingestion show page" do
    visit payment_ingestion_path(@ingestion)

    # Verify both tenants exist in tenant dropdown
    assert_selector "select#payment_ingestion_tenant_id option", text: "Tenant Alpha"
    assert_selector "select#payment_ingestion_tenant_id option", text: "Tenant Beta"

    # Select Tenant Beta
    select "Tenant Beta", from: "payment_ingestion_tenant_id"

    # The lease dropdown should update to show only Tenant Beta's lease
    # (since Tenant Beta only has 1 lease, it should also auto-select it!)
    assert_equal @lease_b.id.to_s, find("#payment_ingestion_lease_id").value
    assert_selector "select#payment_ingestion_lease_id option", text: /456 Beta Ave/
    assert_no_selector "select#payment_ingestion_lease_id option", text: /123 Alpha St/

    # Select Tenant Alpha
    select "Tenant Alpha", from: "payment_ingestion_tenant_id"
    assert_equal @lease_a.id.to_s, find("#payment_ingestion_lease_id").value
    assert_selector "select#payment_ingestion_lease_id option", text: /123 Alpha St/
    assert_no_selector "select#payment_ingestion_lease_id option", text: /456 Beta Ave/

    # Select blank Tenant (Select Tenant)
    select "Select Tenant", from: "payment_ingestion_tenant_id"

    # Both leases should now be selectable again in the lease dropdown
    select "456 Beta Ave - Month To Month (Commenced #{Date.today.strftime('%b %Y')})", from: "payment_ingestion_lease_id"

    # Selecting Lease B should auto-select Tenant Beta in the tenant dropdown
    assert_equal @tenant_b.id.to_s, find("#payment_ingestion_tenant_id").value
  end
end
