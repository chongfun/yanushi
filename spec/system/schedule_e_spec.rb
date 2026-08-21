require "rails_helper"

RSpec.describe "ScheduleE", type: :system do
  let!(:user) { create(:user) }
  let!(:property) { create(:property, user: user, address: "Test Isolation St") }
  let!(:unit) { create(:rentable_unit, property: property) }

  before do
    visit new_session_path
    fill_in "email", with: user.email
    fill_in "password", with: "password"
    click_on "Sign in"
  end

  it "verifies schedule e summary accuracy with all expense categories" do
    year = Date.current.year

    tenancy = create(:tenancy,
      rentable_unit: unit,
      commencement_date: Date.new(year, 1, 1),
      termination_date: Date.new(year, 12, 31),
      agreement_type: "fixed_term"
    )

    create(:receipt,
      tenancy: tenancy,
      amount_cents: 500_000,
      received_on: Date.new(year, 1, 5),
      payment_method: "Zelle"
    )

    create(:receipt,
      tenancy: tenancy,
      amount_cents: 15_000,
      received_on: Date.new(year, 2, 10),
      payment_method: "Check"
    )

    categories = Expense::EXPENSE_KINDS

    total_expenses = 0
    categories.each_with_index do |kind, index|
      amount = 100.00 + (index * 10)
      total_expenses += amount
      create(:expense, :posted,
        property: property,
        expense_kind: kind,
        amount_cents: (amount * 100).to_i,
        paid_on: Date.new(year, 3, 1),
        description: "Test #{kind}"
      )
    end

    visit property_path(property, year: year)
    click_on "📋 Schedule E"

    expect(page).to have_text("Rents Received")
    expect(page).to have_text("$5,150.00")
    expect(page).to have_text("Total Income")
    expect(page).to have_text("$5,150.00")

    categories.each_with_index do |_kind, index|
      amount = 100.00 + (index * 10)
      formatted_amount = ActionController::Base.helpers.number_to_currency(amount)
      expect(page).to have_text(formatted_amount)
    end

    formatted_total_expenses = ActionController::Base.helpers.number_to_currency(total_expenses)
    expect(page).to have_text("Total Expenses")
    expect(page).to have_text(formatted_total_expenses)

    net_income = 5150.00 - total_expenses
    formatted_net = ActionController::Base.helpers.number_to_currency(net_income.abs)

    expect(page).to have_text("Net Rental Income (Loss)")
    expect(page).to have_text(formatted_net)
  end
end
