require 'rails_helper'

RSpec.describe "Expenses", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:rental_property, user: user, address: "999 Expense Ave") }

  before do
    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "creates an expense with IRS category successfully" do
    visit expenses_path

    click_on "New expense"

    select property.address, from: "Rental property"
    select "Repairs", from: "Category"
    fill_in "Expense date", with: Date.today.to_s
    fill_in "Amount", with: "450.00"
    fill_in "Description", with: "Fixed the leaky roof"

    click_on "Create Expense"

    expect(page).to have_text("Expense was successfully created")
    expect(page).to have_text("Repairs")
    expect(page).to have_text("Fixed the leaky roof")
  end
end
