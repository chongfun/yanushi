require "rails_helper"

RSpec.describe "Expenses", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "999 Expense Ave") }

  before do
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "creates an expense with IRS category successfully" do
    visit expenses_path

    click_on "New expense"

    select property.address, from: "Property"
    select "Repairs", from: "Category"
    fill_in "Expense date", with: Date.today.to_s
    fill_in "Amount", with: "450.00"
    fill_in "Description", with: "Fixed the leaky roof"

    click_on "Create Expense"

    expect(page).to have_text("Expense was successfully created")
    expect(page).to have_text("Repairs")
    expect(page).to have_text("Fixed the leaky roof")
  end

  it "creates a reimbursed expense and displays immutable info on edit" do
    unit = create(:rentable_unit, property: property)
    party = create(:party, user: user, display_name: "Tenant Party")
    tenancy = create(:tenancy, rentable_unit: unit)
    create(:tenancy_party, tenancy: tenancy, party: party, role: "tenant")

    visit new_expense_path

    select property.address, from: "Property"
    select "Utilities", from: "Category"
    fill_in "Expense date", with: Date.today.to_s
    fill_in "Amount", with: "120.00"
    fill_in "Description", with: "Water bill"

    check "Tenant Reimbursable (Charges Tenant Running Account)"
    select "#{property.address} - Tenancy ##{tenancy.id} (#{party.display_name})", from: "Tenancy to Charge"
    fill_in "Charge Amount (Defaults to expense amount if left blank)", with: "120.00"

    click_on "Create Expense"

    expect(page).to have_text("Expense was successfully created")
    expense = Expense.last
    expect(expense.reimbursed?).to be(true)

    # Edit the expense
    visit edit_expense_path(expense)

    expect(page).to have_text("Linked Reimbursement Charges")
    expect(page).to have_text("Tenancy ##{tenancy.id}")
    expect(page).to have_text("$120.00")
    expect(page).not_to have_field("Tenant Reimbursable (Charges Tenant Running Account)")
  end

  it "supports splitting one expense across multiple tenancies via Add Reimbursement Charge" do
    unit_a = create(:rentable_unit, property: property, name: "Unit A")
    unit_b = create(:rentable_unit, property: property, name: "Unit B")
    party_a = create(:party, user: user, display_name: "Tenant Alice")
    party_b = create(:party, user: user, display_name: "Tenant Bob")
    tenancy_a = create(:tenancy, rentable_unit: unit_a)
    tenancy_b = create(:tenancy, rentable_unit: unit_b)
    create(:tenancy_party, tenancy: tenancy_a, party: party_a, role: "tenant")
    create(:tenancy_party, tenancy: tenancy_b, party: party_b, role: "tenant")

    expense = create(:expense, property: property, amount: 300.0, category: "utilities", description: "Water bill $300")

    # Visit expense show page
    visit expense_path(expense)
    expect(page).to have_content("Tenant Reimbursements")
    expect(page).to have_content("No tenant reimbursement charges have been posted")

    # Add first reimbursement for Unit A
    click_on "＋ Add Reimbursement Charge"
    select "#{unit_a.display_name} - Tenancy ##{tenancy_a.id} (#{party_a.display_name})", from: "Tenancy to Charge"
    fill_in "Reimbursement Amount ($)", with: "150.00"
    fill_in "Description / Memo", with: "Water share - Unit A"
    click_on "Post Reimbursement Charge"

    expect(page).to have_current_path(expense_path(expense))
    expect(page).to have_content("Reimbursement charge was successfully created and posted.")
    expect(page).to have_content(unit_a.display_name)
    expect(page).to have_content("$150.00")

    # Add second reimbursement for Unit B
    click_on "＋ Add Reimbursement Charge"
    select "#{unit_b.display_name} - Tenancy ##{tenancy_b.id} (#{party_b.display_name})", from: "Tenancy to Charge"
    fill_in "Reimbursement Amount ($)", with: "150.00"
    fill_in "Description / Memo", with: "Water share - Unit B"
    click_on "Post Reimbursement Charge"

    expect(page).to have_current_path(expense_path(expense))
    expect(page).to have_content(unit_b.display_name)
    expect(page).to have_content(unit_a.display_name)
    expect(page).to have_content("Fully Reimbursed")
    expect(expense.reload.reimbursement_charges.count).to eq(2)
    expect(expense.fully_reimbursed?).to be true

    # Visit edit page
    visit edit_expense_path(expense)
    expect(page).to have_content("Property cannot be changed after reimbursement charges have been posted")
    expect(page).to have_content("Fully Reimbursed")
    expect(page).not_to have_link("＋ Add Reimbursement Charge")
  end
end
