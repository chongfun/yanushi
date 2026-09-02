require "rails_helper"

RSpec.describe "Reports", type: :system do
  let!(:user) { create(:user) }
  let!(:prop1) { create(:property, user: user, address: "123 Main St") }
  let!(:prop2) { create(:property, user: user, address: "742 Evergreen Terrace") }
  let!(:tax_profile_prop2) do
    create(
      :property_tax_profile,
      property: prop2,
      tax_year: 2025,
      schedule_e_property_type: "single_family_residence"
    )
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)

    unit = create(:rentable_unit, property: prop2)
    tenancy = create(:tenancy, rentable_unit: unit, commencement_date: Date.new(2025, 1, 1))
    create(:rent_term, tenancy: tenancy, amount_cents: 200_000, effective_from: Date.new(2025, 1, 1))
    party = create(:party, user: user)
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant")

    Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 200_000,
      received_on: Date.new(2025, 6, 1),
      payment_method: "check"
    )

    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "displays schedule E readiness across properties and navigates to setup and schedule E views", :js do
    visit reports_path(year: 2025)

    expect(page).to have_text("Reports")
    expect(page).to have_text("123 Main St")
    expect(page).to have_text("Needs tax profile")
    expect(page).to have_link("Set up profile")

    expect(page).to have_text("742 Evergreen Terrace")
    expect(page).to have_text("Ready")
    expect(page).to have_text("$2,000.00")
    expect(page).to have_link("View")
    expect(page).to have_link("Download PDF")

    # Click view on 742 Evergreen Terrace
    within("#property_#{prop2.id}_schedule_e_status") do
      click_on "View"
    end

    expect(page).to have_text("Schedule E — 2025")
    expect(page).to have_text("742 Evergreen Terrace")
    expect(page).to have_text("Rents received")
    expect(page).to have_text("$2,000.00")
  end
end
