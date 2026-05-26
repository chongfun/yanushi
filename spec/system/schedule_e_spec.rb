require 'rails_helper'

RSpec.describe "ScheduleE", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:rental_property, user: user, address: "Test Isolation St") }

  before do
    # Log in
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "verifies schedule e summary accuracy with all expense categories" do
    year = Date.current.year

    lease = create(:lease,
      rental_property: property,
      commencement_date: Date.new(year, 1, 1),
      termination_date: Date.new(year, 12, 31),
      annual_rental_amount: 12000,
      lease_type: :term
    )

    # Create tenant payments
    create(:tenant_payment,
      lease: lease,
      amount: 5000.00,
      payment_date: Date.new(year, 1, 5),
      payment_method: "Zelle"
    )

    create(:tenant_payment,
      lease: lease,
      amount: 150.00,
      payment_date: Date.new(year, 2, 10),
      payment_method: "Check"
    )

    categories = [
      "advertising", "auto_and_travel", "cleaning_and_maintenance", "commissions",
      "insurance", "legal_and_other_professional_fees", "management_fees",
      "mortgage_interest", "other_interest", "repairs", "supplies", "taxes",
      "utilities", "depreciation_expense", "other"
    ]

    total_expenses = 0
    categories.each_with_index do |category, index|
      amount = 100.00 + (index * 10)
      total_expenses += amount
      create(:expense,
        rental_property: property,
        category: category,
        amount: amount,
        expense_date: Date.new(year, 3, 1),
        description: "Test #{category}"
      )
    end

    visit rental_property_path(property, year: year)
    click_on "📋 Schedule E"

    expect(page).to have_text("Rents Received")
    expect(page).to have_text("$5,150.00")
    expect(page).to have_text("Total Income")
    expect(page).to have_text("$5,150.00")

    categories.each_with_index do |category, index|
      amount = 100.00 + (index * 10)
      formatted_amount = ActionController::Base.helpers.number_to_currency(amount)
      expect(page).to have_text(formatted_amount)
    end

    formatted_total_expenses = ActionController::Base.helpers.number_to_currency(total_expenses)
    expect(page).to have_text("Total Expenses")
    expect(page).to have_text(formatted_total_expenses)

    net_income = 5150.00 - total_expenses
    formatted_net = ActionController::Base.helpers.number_to_currency(net_income.abs)

    if net_income < 0
      expect(page).to have_text("Net Loss")
    else
      expect(page).to have_text("Net Income")
    end
    expect(page).to have_text(formatted_net)
  end
end
