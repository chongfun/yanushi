require "rails_helper"

RSpec.describe "Charges UI", type: :system do
  let(:user) { create(:user) }
  let(:property) { create(:property, user: user) }
  let(:unit) { create(:rentable_unit, property: property) }
  let(:party) { create(:party, user: user, display_name: "Jane Tenant") }
  let!(:tenancy) do
    create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.current - 2.months,
      termination_date: Date.current + 10.months
    )
  end
  let!(:tenancy_party) do
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: tenancy.commencement_date)
  end
  let!(:rent_term) do
    create(:rent_term,
      tenancy: tenancy,
      amount_cents: 150_000,
      effective_from: tenancy.commencement_date,
      due_day: 1
    )
  end

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "allows creating a manual late fee charge via standalone form in real Turbo browser", :js do
    visit new_tenancy_charge_path(tenancy)

    expect(page).to have_content("Add charge")
    within("form#charge-form") do
      select "Late fee", from: "Charge type"
    end
    page.execute_script("document.getElementById('charge-amount').value = '50.00'")
    page.execute_script("document.getElementById('charge-desc').value = 'Late payment fee'")
    page.execute_script("document.querySelector('form#charge-form').requestSubmit()")

    expect(page).to have_content("Charge was successfully created.")
    expect(page).to have_current_path(tenancy_path(tenancy))
    expect(page).to have_css("#tenancy_activity", text: "Late payment fee")
  end

  it "voids a charge from its detail page", :js do
    charge = Charges::CreateFeeService.call(
      tenancy: tenancy,
      charge_kind: "late_fee",
      amount_cents: 5000,
      charge_date: Date.current,
      due_on: Date.current,
      description: "Late payment fee"
    ).value!.data[:charge]

    visit charge_path(charge)
    expect(page).to have_content("$50.00")

    click_on "Void"
    expect(page).to have_css("#confirm-modal[open]")
    within("#confirm-modal") do
      click_on "Confirm"
    end

    expect(page).to have_content("was successfully voided")
    expect(charge.reload).to be_voided
  end
end
