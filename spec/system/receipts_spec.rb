require "rails_helper"

RSpec.describe "Receipts", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Payment Ave") }
  let!(:unit) { create(:rentable_unit, property: property, name: "Unit 1") }
  let!(:party) { create(:party, user: user, display_name: "Ledger Tester") }
  let!(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.today, late_period_days: 5) }

  before do
    Accounting::ChartOfAccounts.ensure_for(user)
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: Date.today)
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "records a payment and verifies details and PDF download link", :js do
    visit receipts_path

    click_on "Record receipt", match: :first

    expect(page).to have_css("h1", text: "Record receipt")

    find("#receipt-tenancy").find(:option, text: property.address).select_option
    select party.display_name, from: "receipt-payer"
    page.execute_script("document.getElementById('receipt-amount').value = '1000.00'")
    page.execute_script("document.getElementById('receipt-method').value = 'Zelle'")
    fill_in "receipt-date", with: Date.today.strftime("%Y-%m-%d")
    page.execute_script("document.getElementById('receipt-ref').value = 'ZEL-1001'")

    page.execute_script("document.querySelector('main form').requestSubmit()")

    expect(page).to have_text("Payment recorded successfully.")
    expect(page).to have_text("$1,000.00")
    expect(page).to have_text("Ledger Tester")
    expect(page).to have_text("ZEL-1001")
    expect(page).to have_link("Download PDF")
  end

  it "records a payment from the standalone tenancy receipt form in real Turbo browser", :js do
    visit new_tenancy_receipt_path(tenancy)

    expect(page).to have_content("Record receipt")
    select party.display_name, from: "receipt-payer"
    fill_in "receipt-amount", with: "750.00"
    fill_in "receipt-method", with: "Check"

    click_button "Record receipt"

    expect(page).to have_text("Payment recorded successfully.")
    expect(page).to have_current_path(tenancy_path(tenancy))
    expect(page).to have_css("#tenancy_balance", text: "credit")
    expect(page).to have_css("#tenancy_activity", text: "Check")
  end

  it "corrects a payment through the correction flow", :js do
    res = Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 100_000,
      received_on: Date.today,
      payment_method: "zelle"
    )
    receipt = res.value!.data[:receipt]

    visit receipt_path(receipt)
    find("summary", text: "More").click
    click_on "Correct receipt"

    expect(page).to have_text("keeps the original receipt as a voided record")
    fill_in "Amount", with: "1100.00"

    click_on "Save correction"

    expect(page).to have_text("Payment corrected successfully.")
    expect(page).to have_text("$1,100.00")
  end

  it "voids a payment with confirmation", :js do
    res = Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 100_000,
      received_on: Date.today,
      payment_method: "zelle"
    )
    receipt = res.value!.data[:receipt]

    visit receipt_path(receipt)
    find("summary", text: "More").click
    click_on "Void receipt…"
    within("#confirm-modal") do
      expect(page).to have_text("Void this receipt?")
      click_button "Confirm"
    end

    expect(page).to have_text("Payment has been voided")
    expect(page).to have_text("This receipt was voided.")
  end
end
