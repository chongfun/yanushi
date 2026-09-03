require "rails_helper"

RSpec.describe "Expenses", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Expense Ave") }
  let!(:unit) { create(:rentable_unit, property: property) }
  let!(:party) { create(:party, user: user, display_name: "Tenant Party") }
  let!(:tenancy) { create(:tenancy, rentable_unit: unit) }
  let!(:tenancy_party) { create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant") }

  before do
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
    expect(page).to have_button("Sign out")
  end

  it "creates an expense and adds tenant reimbursement charges" do
    visit expenses_path

    click_on "Record expense", match: :first

    select property.address, from: "Property"
    select "Repairs", from: "Category"
    fill_in "Date Paid", with: Date.today.to_s
    fill_in "Amount ($)", with: "450.00"
    fill_in "Vendor / Payee", with: "Roof Repair Pro"
    fill_in "Description", with: "Fixed the leaky roof"

    click_on "Record Expense"

    expect(page).to have_text("Expense was successfully created")
    expect(page).to have_text("Repairs")
    expect(page).to have_text("Fixed the leaky roof")
    expect(page).to have_text("$450.00")
    expect(page).to have_text("Posted")

    expense = Expense.last

    # Add reimbursement charge
    click_on "Add reimbursement charge"
    select "#{unit.display_name} - Tenancy ##{tenancy.id} (#{party.display_name})", from: "Tenancy to Charge"
    fill_in "Reimbursement Amount ($)", with: "150.00"
    fill_in "Description / Memo", with: "Roof repair tenant share"
    click_on "Post Reimbursement Charge"

    expect(page).to have_current_path(expense_path(expense))
    expect(page).to have_content("Reimbursement charge was successfully created and posted.")
    expect(page).to have_content("$150.00")
    expect(expense.reload.reimbursement_charges.count).to eq(1)
  end

  it "supports correcting and voiding an expense when no active reimbursements exist" do
    expense = create(:expense, :posted, property: property, amount_cents: 20_000, expense_kind: "utilities", description: "Water bill")

    visit expense_path(expense)

    # Correct expense (from the More menu)
    find("summary", text: "More").click
    click_on "Correct expense"
    expect(page).to have_content("Reversal & Replacement Notice")

    fill_in "expense[amount]", with: "250.00"
    fill_in "expense[description]", with: "Corrected water bill"
    click_on "Post Corrected Expense"

    expect(page).to have_content("Expense was successfully corrected.")
    expect(page).to have_content("$250.00")
    expect(page).to have_content("Replacement Expense")

    # Visit the original superseded expense and verify audit trail
    visit expense_path(expense)
    expect(page).to have_content("Expense Corrected")
    expect(page).to have_content("Corrected (Superseded)")
    expect(page).not_to have_content("Expense Voided")
    replacement = expense.reload.superseded_by
    expect(page).to have_link("Expense ##{replacement.id}", href: expense_path(replacement))

    # Check index page shows Corrected badge
    visit expenses_path
    within("#expense_#{expense.id}") do
      expect(page).to have_content("Corrected")
    end

    # Void the replacement expense
    visit expense_path(replacement)
    find("summary", text: "More").click
    click_on "Void expense…"

    expect(page).to have_content("Expense was successfully voided and reversed.")
    expect(page).to have_content("Expense Voided")
    expect(page).to have_content("Voided & Reversed")
  end
end
