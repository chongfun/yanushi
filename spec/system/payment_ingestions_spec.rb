require "rails_helper"

RSpec.describe "PaymentIngestions", type: :system, js: true do
  include ActiveJob::TestHelper

  let!(:user) { create(:user) }
  let!(:tenant_a) { create(:party, user: user, display_name: "Tenant Alpha") }
  let!(:property_a) { create(:property, user: user, address: "123 Alpha St") }
  let!(:unit_a) { create(:rentable_unit, property: property_a) }
  let!(:lease_a) { create(:tenancy, rentable_unit: unit_a, agreement_type: "month_to_month", commencement_date: Date.today) }

  let!(:tenant_b) { create(:party, user: user, display_name: "Tenant Beta") }
  let!(:property_b) { create(:property, user: user, address: "456 Beta Ave") }
  let!(:unit_b) { create(:rentable_unit, property: property_b) }
  let!(:lease_b) { create(:tenancy, rentable_unit: unit_b, agreement_type: "month_to_month", commencement_date: Date.today) }

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
    create(:tenancy_party, tenancy: lease_a, party: tenant_a, role: "tenant", effective_from: Date.today)
    create(:tenancy_party, tenancy: lease_b, party: tenant_b, role: "tenant", effective_from: Date.today)

    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"

    # Wait for authentication to complete
    expect(page).to have_text("Total Income")
  end

  it "performs dynamic filtering of party and tenancy dropdowns on ingestion show page" do
    visit payment_ingestion_path(ingestion)

    expect(page).to have_selector("select#payment_ingestion_party_id option", text: "Tenant Alpha")
    expect(page).to have_selector("select#payment_ingestion_party_id option", text: "Tenant Beta")

    select "Tenant Beta", from: "payment_ingestion_party_id"
  end
end
