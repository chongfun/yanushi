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
    driven_by(:rack_test)
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "allows creating and voiding a manual late fee charge from the tenancy page" do
    visit tenancy_path(tenancy)

    expect(page).to have_content("Charges & Obligations")
    click_on "＋ Add Charge", match: :first

    expect(page).to have_content("Add Charge for Tenancy ##{tenancy.id}")
    select "Late Fee", from: "Charge Type"
    fill_in "Amount ($)", with: "50.00"
    fill_in "Description / Memo", with: "Late payment fee"
    click_on "Post Charge"

    expect(page).to have_current_path(tenancy_path(tenancy))
    expect(page).to have_content("Charge was successfully created.")
    expect(page).to have_content("Late Fee")
    expect(page).to have_content("$50.00")
    expect(page).to have_content("Late payment fee")

    # Now void the charge
    charge = Charge.find_by(charge_kind: "late_fee")
    expect(charge).to be_present

    within("tr#charge_#{charge.id}") do
      click_on "Void"
    end

    expect(page).to have_current_path(tenancy_path(tenancy))
    expect(page).to have_content("was successfully voided.")
    expect(charge.reload).to be_voided

    within("tr#charge_#{charge.id}") do
      expect(page).to have_content("Voided")
    end
  end
end
