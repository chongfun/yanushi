require "rails_helper"

RSpec.describe "Receipts", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Payment Ave") }
  let!(:unit) { create(:rentable_unit, property: property, name: "Unit 1") }
  let!(:party) { create(:party, user: user, display_name: "Ledger Tester") }
  let!(:tenancy) { create(:tenancy, rentable_unit: unit, agreement_type: "month_to_month", commencement_date: Date.today, late_period_days: 5) }

  before do
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant", effective_from: Date.today)
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "records a payment and verifies details and PDF download link" do
    visit receipts_path

    click_on "＋ Record Payment"

    select "##{tenancy.id} - #{property.address} (#{unit.display_name})", from: "Tenancy / Unit"
    select party.display_name, from: "Payer (Party)"
    fill_in "Amount ($)", with: "1000.00"
    fill_in "Received Date", with: Date.today.to_s
    fill_in "Payment Method", with: "Zelle"
    fill_in "External Reference / Txn #", with: "ZEL-1001"

    click_on "Record Payment"

    expect(page).to have_text("Payment recorded successfully.")
    expect(page).to have_text("$1,000.00")
    expect(page).to have_text("Ledger Tester")
    expect(page).to have_text("ZEL-1001")
    expect(page).to have_link("Download PDF Receipt")
  end

  it "records a payment from the tenancy show page" do
    visit tenancy_path(tenancy)

    click_on "＋ Record Payment", match: :first

    select party.display_name, from: "Payer (Party)"
    fill_in "Amount ($)", with: "750.00"
    fill_in "Received Date", with: Date.today.to_s
    fill_in "Payment Method", with: "Check"

    click_on "Record Payment"

    expect(page).to have_text("Payment recorded successfully.")
    expect(page).to have_text("$750.00")
  end

  it "corrects a payment through the correction flow" do
    res = Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 100_000,
      received_on: Date.today,
      payment_method: "zelle"
    )
    receipt = res.value!.data[:receipt]

    visit receipt_path(receipt)
    click_on "Correct Payment"

    expect(page).to have_text("Correction Semantics")
    fill_in "Amount ($)", with: "1100.00"

    click_on "Save Replacement Payment"

    expect(page).to have_text("Payment corrected successfully.")
    expect(page).to have_text("$1,100.00")
  end

  it "voids a payment with confirmation" do
    res = Receipts::CreateService.call(
      tenancy: tenancy,
      payer_party: party,
      amount_cents: 100_000,
      received_on: Date.today,
      payment_method: "zelle"
    )
    receipt = res.value!.data[:receipt]

    visit receipt_path(receipt)
    click_on "Void Payment"

    expect(page).to have_text("Payment has been voided")
    expect(page).to have_text("This payment was voided.")
  end
end
