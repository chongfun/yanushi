require 'rails_helper'

RSpec.describe "PaymentIngestions", type: :system, js: true do
  include ActiveJob::TestHelper

  let!(:user) { create(:user) }
  let!(:tenant_a) { create(:tenant, user: user, name: "Tenant Alpha") }
  let!(:property_a) { create(:rental_property, user: user, address: "123 Alpha St") }
  let!(:lease_a) { create(:lease, rental_property: property_a, lease_type: "month_to_month", commencement_date: Date.today, annual_rental_amount: 12000) }

  let!(:tenant_b) { create(:tenant, user: user, name: "Tenant Beta") }
  let!(:property_b) { create(:rental_property, user: user, address: "456 Beta Ave") }
  let!(:lease_b) { create(:lease, rental_property: property_b, lease_type: "month_to_month", commencement_date: Date.today, annual_rental_amount: 18000) }

  let!(:document) do
    create(:payment_document,
      user: user,
      attachment_file: "dummy_pdf_content",
      attachment_filename: "receipt.pdf",
      attachment_content_type: "application/pdf"
    )
  end

  let!(:ingestion) do
    create(:payment_ingestion,
      user: user,
      source: "pdf_upload",
      status: "pending",
      payer_name: "Tenant Alpha",
      amount: 1000.0,
      payment_date: Date.today,
      payment_method: "zelle",
      transaction_number: "TXN123",
      payment_document: document
    )
  end

  around do |example|
    previous_queue_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline

    example.run
  ensure
    ActiveJob::Base.queue_adapter = previous_queue_adapter
  end

  before do
    lease_a.tenants << tenant_a
    lease_b.tenants << tenant_b

    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"

    # Wait for authentication to complete
    expect(page).to have_text("Total Income")
  end

  it "performs dynamic filtering of tenant and lease dropdowns on ingestion show page" do
    visit payment_ingestion_path(ingestion)

    # Verify both tenants exist in tenant dropdown
    expect(page).to have_selector("select#payment_ingestion_tenant_id option", text: "Tenant Alpha")
    expect(page).to have_selector("select#payment_ingestion_tenant_id option", text: "Tenant Beta")

    # Select Tenant Beta
    select "Tenant Beta", from: "payment_ingestion_tenant_id"

    # The lease dropdown should update to show only Tenant Beta's lease and auto-select it
    expect(find("#payment_ingestion_lease_id").value).to eq(lease_b.id.to_s)
    expect(page).to have_selector("select#payment_ingestion_lease_id option", text: /456 Beta Ave/)
    expect(page).not_to have_selector("select#payment_ingestion_lease_id option", text: /123 Alpha St/)

    # Select Tenant Alpha
    select "Tenant Alpha", from: "payment_ingestion_tenant_id"
    expect(find("#payment_ingestion_lease_id").value).to eq(lease_a.id.to_s)
    expect(page).to have_selector("select#payment_ingestion_lease_id option", text: /123 Alpha St/)
    expect(page).not_to have_selector("select#payment_ingestion_lease_id option", text: /456 Beta Ave/)

    # Select blank Tenant
    select "Select Tenant", from: "payment_ingestion_tenant_id"

    # Both leases should now be selectable again in the lease dropdown
    select "456 Beta Ave - Month To Month (Commenced #{Date.today.strftime('%b %Y')})", from: "payment_ingestion_lease_id"

    # Selecting Lease B should auto-select Tenant Beta in the tenant dropdown
    expect(find("#payment_ingestion_tenant_id").value).to eq(tenant_b.id.to_s)
  end

  it "runs the end-to-end upload and confirm flow" do
    # Create tenant matching the fixture receipt (Jane Smith)
    jane = create(:tenant, user: user, name: "Jane Smith", email_address: "jane@example.com")
    property = create(:rental_property, user: user, address: "789 Pine Rd")
    lease = create(:lease, rental_property: property, lease_type: "month_to_month", commencement_date: Date.new(2024, 1, 1), annual_rental_amount: 15000)
    lease.tenants << jane

    # 1. Visit Upload Page
    visit new_payment_ingestion_path
    expect(page).to have_text("Select Document PDF")

    # 2. Attach file and Submit
    pdf_path = Rails.root.join("spec/fixtures/files/receipts/202403 Venmo.pdf")
    attach_file "payment_ingestion_pdf_file", pdf_path, make_visible: true

    page.execute_script("document.querySelector('form').submit()")

    # 3. Verify redirected to index with success notification
    expect(page).to have_text("Document uploaded successfully and is being processed in the background.")

    # 4. Check reviewable queue row
    expect(page).to have_selector("table.table-zebra tbody tr")
    expect(page).to have_text("Jane Smith")
    expect(page).to have_text("Venmo")

    # 5. Click Review
    page.execute_script("document.querySelector('td a.btn-primary').click()")
    expect(page).to have_text("Review Payment Ingestion")
    expect(page).to have_text("Matched")

    # 6. Confirm transaction
    expect(page).to have_selector("form[action*='confirm']")
    page.execute_script("document.querySelector('form[action*=\"confirm\"]').submit()")

    # 7. Should redirect to index and show in History
    expect(page).to have_text("Payment confirmed and tenant payment created successfully.")
    expect(page).to have_selector("table.table-sm tbody tr")
    expect(page).to have_text("Jane Smith")

    expect(TenantPayment.exists?(transaction_number: "9991209384910283")).to be_truthy
  end
end
